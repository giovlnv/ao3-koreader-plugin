--[[--
AO3Client: talks to archiveofourown.org.

Deliberately has no KOReader UI code in it — only building requests, parsing
responses, and returning plain Lua tables. That keeps it testable with
busted on a regular machine, without KOReader or a live network connection
(tests inject a fake http_request function instead — see AO3Client.new()).

AO3 has no official API: everything here means fetching the normal HTML
pages (and, for logged-in views, sending the session cookie AO3's login
form gives back) and picking values out of the markup. Be a good citizen:
space out requests, and only fetch what your own account can already see.
]]

local AO3Client = {}
AO3Client.__index = AO3Client

local BASE_URL = "https://archiveofourown.org"
local LOGIN_URL = BASE_URL .. "/users/login"

-- Sent on every request, merged under whatever the caller passes (so e.g.
-- login()'s Content-Type/Content-Length still win). AO3's own terms ask
-- automated tools to identify themselves rather than impersonate a browser,
-- and a missing/generic User-Agent is also a common trigger for anti-bot
-- blocking -- this plugin only fetches things the logged-in user's own
-- account can already see, so there's nothing to hide from AO3 here.
local DEFAULT_USER_AGENT = "ao3-koreader-plugin (personal KOReader plugin; "
    .. "fetches only the logged-in account's own pages)"

-- AO3's login form, as of checking against a currently-maintained unofficial
-- AO3 client library (see docs/SETUP.md notes) — Rails form/param names are
-- an implementation detail AO3 could change without notice. If login starts
-- failing with "login rejected" even for correct credentials, check these
-- three constants first, by re-inspecting the real login page.
local LOGIN_FIELD_USERNAME = "user[login]"
local LOGIN_FIELD_PASSWORD = "user[password]"
local SESSION_COOKIE_NAME = "_otwarchive_session"

-- AO3 sits behind Cloudflare, which sets its own bot-management cookies
-- alongside the app's session cookie -- confirmed by inspecting real
-- response headers from archiveofourown.org (`server: cloudflare`,
-- `set-cookie: __cf_bm=...`, `set-cookie: _cfuvid=...`). A real browser (and
-- every requests.Session()-based unofficial AO3 client) automatically keeps
-- and resends these on every request; a client that only tracks
-- _otwarchive_session, as this plugin used to, gets treated as a different
-- client on each request. That's the confirmed cause of a real bug: login()
-- itself succeeded, but getMarkedForLater()/getMyWorks() came back
-- redirected to the login page every time -- see CLAUDE.md.
local EXTRA_COOKIE_NAMES = { "__cf_bm", "_cfuvid" }

-- Standard percent-encoding for a form field value.
local function url_encode(str)
    str = tostring(str)
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w _%%%-%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end

-- Only the handful of entities that actually show up in fic titles/author
-- names (ampersands and quotes, mostly). Not a general HTML-entity decoder.
local HTML_ENTITIES = {
    ["&amp;"] = "&",
    ["&lt;"] = "<",
    ["&gt;"] = ">",
    ["&quot;"] = '"',
    ["&#39;"] = "'",
    ["&apos;"] = "'",
}

local function html_unescape(str)
    if not str then
        return str
    end
    return (str:gsub("&#?%w+;", function(entity)
        return HTML_ENTITIES[entity] or entity
    end))
end

--[[--
Pulls any of `names` out of a response's Set-Cookie header and merges them
into `into` (a plain name -> value table, kept across calls so a later
response's rotated __cf_bm, e.g., overwrites an earlier one instead of being
lost). Reuses the same "match up to the next ; or ," trick login() already
relies on for SESSION_COOKIE_NAME, since LuaSocket folds multiple Set-Cookie
headers into one comma-joined string and cookie expiry dates contain commas
too -- see the module comment on default_http_request().

@param headers table?  lowercase-keyed response headers
@param names string[]  cookie names to look for
@param into table  name -> value, mutated in place
]]
local function merge_cookies(headers, names, into)
    local set_cookie = headers and (headers["set-cookie"] or headers["Set-Cookie"])
    if not set_cookie then
        return
    end
    for _, name in ipairs(names) do
        local value = set_cookie:match(name .. "=([^;,]+)")
        if value then
            into[name] = value
        end
    end
end

--[[--
Splits a listing page's body into one chunk per work, anchored on
`id="work_<id>"` — confirmed, across several independent AO3 tools, to be
how every work-listing page (search results, bookmarks, reading lists)
marks up each entry. Deliberately does NOT try to find the matching closing
`</li>`: AO3's markup nests other `<li>` elements inside a work's own block
(for tags, warnings, etc.), which plain pattern matching can't balance
correctly. Slicing "up to the next work's id" instead sidesteps that
entirely, at the cost of not knowing exactly where one work's HTML ends —
harmless here since we only ever search forward for specific fields.

@param body string  the page's HTML
@return { {id = string, html = string}, ... }
]]
local function split_work_blurbs(body)
    local markers = {}
    local search_from = 1
    while true do
        local start_pos, end_pos, work_id = body:find('id="work_(%d+)" class="[^"]-blurb', search_from)
        if not start_pos then
            break
        end
        table.insert(markers, { id = work_id, start = start_pos })
        search_from = end_pos + 1
    end

    local blurbs = {}
    for i, marker in ipairs(markers) do
        local chunk_end = (markers[i + 1] and markers[i + 1].start - 1) or #body
        table.insert(blurbs, { id = marker.id, html = body:sub(marker.start, chunk_end) })
    end
    return blurbs
end

--[[--
Does the actual HTTP work, using KOReader/LuaJIT's bundled LuaSec, with
KOReader's own socketutil timeouts applied so a stalled connection fails
loudly instead of freezing the UI. Kept as a plain function (not a method,
no upvalues into AO3Client) so a test can pass in a completely different
one — see AO3Client.new().

`require(...)` for ssl.https/ltn12/socketutil happens in here rather than at
file scope so that unit tests, which never call this function, don't need
LuaSec (or a running KOReader, for socketutil) installed just to run.

@param opts table: { url, method, headers, body }
@return ok boolean|nil   truthy on a completed request (any HTTP status)
@return status number|string  HTTP status code, or an error message if ok is falsy
@return headers table   lowercase response header names -> value
@return body string     response body
]]
local function default_http_request(opts)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")

    -- LuaSec's own timeout (60s, hardcoded into ssl.https.request(), and not
    -- overridable through its public API — it explicitly rejects a custom
    -- `create` function) covers the TCP connect and the TLS handshake, but
    -- nothing after that: a server that trickles back a byte every few
    -- seconds could otherwise hang the request (and, since this all runs
    -- synchronously, the whole KOReader UI) indefinitely. socketutil is
    -- KOReader's own fix for exactly this, used the same way by every other
    -- online plugin (wallabag, opds, ...): it bounds both a single read
    -- ("block") and the request as a whole ("total"). It does NOT cover DNS
    -- resolution — that happens before any socket exists, so a broken
    -- resolver can still hang past this timeout. See CLAUDE.md.
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)

    local request_headers = { ["User-Agent"] = DEFAULT_USER_AGENT }
    for key, value in pairs(opts.headers or {}) do
        request_headers[key] = value
    end

    local response_chunks = {}
    local ok, status, headers = https.request({
        url = opts.url,
        method = opts.method or "GET",
        headers = request_headers,
        source = opts.body and ltn12.source.string(opts.body) or nil,
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()

    return ok, status, headers or {}, table.concat(response_chunks)
end

--- @param http_request function?  overrides the real HTTP call; tests pass
---   a fake here so no network call is ever made in the unit test suite.
function AO3Client.new(http_request)
    local self = setmetatable({}, AO3Client)
    self.http_request = http_request or default_http_request
    self.session_cookie = nil -- set by login(), required for getMarkedForLater()
    self.extra_cookies = {} -- Cloudflare's cookies (EXTRA_COOKIE_NAMES) -- see merge_cookies()
    return self
end

--- Builds the value for a request's Cookie header from everything known so
--- far: the AO3 session cookie (once login() has set it) plus any Cloudflare
--- cookies picked up from previous responses. Returns nil (no header at all)
--- rather than an empty string when nothing is known yet.
-- @return string?
function AO3Client:buildCookieHeader()
    local parts = {}
    if self.session_cookie then
        table.insert(parts, self.session_cookie)
    end
    for _, name in ipairs(EXTRA_COOKIE_NAMES) do
        local value = self.extra_cookies[name]
        if value then
            table.insert(parts, name .. "=" .. value)
        end
    end
    return #parts > 0 and table.concat(parts, "; ") or nil
end

--[[--
Logs in and stores the session cookie needed for account-only pages (e.g.
Marked for Later). Two round trips, like a browser would do: a GET for the
login page's CSRF token, then a POST with the credentials.

@param username string
@param password string
@return boolean ok
@return string? err  set when ok is false
]]
function AO3Client:login(username, password)
    if not username or username == "" then
        return false, "username is required"
    end
    if not password or password == "" then
        return false, "password is required"
    end

    local page_ok, page_status, page_headers, page_body = self.http_request({
        url = LOGIN_URL,
        method = "GET",
    })
    if not page_ok then
        return false, "could not reach AO3 (" .. tostring(page_status) .. ")"
    end
    -- Cloudflare hands out __cf_bm/_cfuvid on this very first request, before
    -- any credentials are even involved -- capture them now so the POST below
    -- can send them straight back, the way a real browser would.
    merge_cookies(page_headers, EXTRA_COOKIE_NAMES, self.extra_cookies)

    -- AO3 (a Rails app) exposes the CSRF token as a <meta> tag on every page.
    local csrf_token = page_body and page_body:match('name="csrf%-token" content="([^"]+)"')
    if not csrf_token then
        return false, "could not find the login form's CSRF token — AO3's login page may have changed"
    end

    local body = table.concat({
        "authenticity_token=" .. url_encode(csrf_token),
        LOGIN_FIELD_USERNAME .. "=" .. url_encode(username),
        LOGIN_FIELD_PASSWORD .. "=" .. url_encode(password),
    }, "&")

    local post_ok, post_status, post_headers = self.http_request({
        url = LOGIN_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#body),
            Cookie = self:buildCookieHeader(),
        },
        body = body,
    })
    if not post_ok then
        return false, "login request failed (" .. tostring(post_status) .. ")"
    end
    -- Cloudflare may rotate __cf_bm again on this response; keep whatever's
    -- freshest regardless of whether the login itself succeeds below.
    merge_cookies(post_headers, EXTRA_COOKIE_NAMES, self.extra_cookies)

    -- AO3 redirects (302/303) on BOTH a successful login and a rejected one
    -- -- confirmed against AO3's own source: it's plain Devise underneath,
    -- and Devise's stock failure handling also 302s, back to the login page
    -- itself. The status code alone can't tell the two apart; the redirect
    -- *target* can: success goes to /users/<username> (or a preserved deep
    -- link), failure goes back to /users/login. (A previous version of this
    -- function only checked the status code, which meant a wrong password
    -- was misread as a successful login -- see CLAUDE.md.)
    if post_status ~= 302 and post_status ~= 303 then
        return false, "login rejected — check username/password"
    end
    local location = post_headers and (post_headers["location"] or post_headers["Location"])
    if location and location:find("/users/login", 1, true) then
        return false, "login rejected — check username/password"
    end

    -- LuaSocket folds repeated response headers (like multiple Set-Cookie
    -- lines) into one comma-joined string, which mangles cookie expiry dates
    -- (they contain commas too). Rather than trying to parse that properly,
    -- just pull out the one cookie value we actually need.
    --
    -- Note this cookie alone can't be trusted as a success signal either --
    -- AO3 sets/rotates it on essentially every response, failed logins
    -- included, since flash messages and CSRF tokens both touch the Rails
    -- session. The location check above is what actually decides success;
    -- this just extracts the value once we already know it succeeded.
    local set_cookie = post_headers and post_headers["set-cookie"]
    local session_value = set_cookie and set_cookie:match(SESSION_COOKIE_NAME .. "=([^;,]+)")
    if not session_value then
        return false, "login looked successful but no session cookie came back"
    end

    self.session_cookie = SESSION_COOKIE_NAME .. "=" .. session_value
    self.username = username
    return true
end

--[[--
Turns a listing page's body into work entries. Shared by getMarkedForLater()
and getMyWorks(), which are otherwise identical except for the URL they hit
and what "no author link on the blurb" should fall back to (a Marked for
Later entry with no author link is really anonymous; a My Works entry with
no author link is just AO3 omitting "by yourself" — it's still you).

@param body string  the page's HTML
@param fallback_author string  used when a blurb has no `rel="author"` link
@return table[] works  list of { id, title, author, url }
]]
local function parse_work_listing(body, fallback_author)
    local works = {}
    for _, blurb in ipairs(split_work_blurbs(body)) do
        -- Anchor the title link to this specific work's id, not just "the
        -- first /works/ link", since a blurb can also link to a series or
        -- a related work before its own title in some layouts.
        local title = blurb.html:match('href="/works/' .. blurb.id .. '"[^>]*>([^<]+)</a>')
        if title then
            local authors = {}
            for author in blurb.html:gmatch('rel="author"[^>]*>([^<]+)</a>') do
                table.insert(authors, html_unescape(author))
            end

            table.insert(works, {
                id = blurb.id,
                title = html_unescape(title),
                author = #authors > 0 and table.concat(authors, ", ") or fallback_author,
                url = BASE_URL .. "/works/" .. blurb.id,
            })
        end
        -- A blurb whose title we couldn't find is silently skipped rather
        -- than failing the whole list — better to show 19 of 20 works than
        -- none, if AO3's markup has a variant we didn't account for.
    end
    return works
end

--[[--
True when `body` looks like AO3's login page rather than the listing page we
asked for. Reuses the exact form field name (`user[login]`) login() itself
submits credentials to, since that's already confirmed correct against the
real site — not a new guess.

A logged-in-only page can come back as this in more ways than a non-200
status: AO3 may 302-redirect an expired/rejected session straight to
/users/login, and some HTTP clients (including, as far as we've been able to
tell, the one this plugin runs on) follow that redirect transparently and
hand back a plain 200 with the login page's body — which, without this
check, parse_work_listing() would just silently read as zero works, no error
at all. That's indistinguishable on screen from a genuinely empty list,
which is exactly the bug this guards against.

@param body string?
@return boolean
]]
local function looks_like_login_page(body)
    return body ~= nil and body:find('name="user%[login%]"') ~= nil
end

--[[--
Fetches a logged-in-only listing page and turns it into work entries. Shared
GET/status-check/parse plumbing for getMarkedForLater() and getMyWorks().

@param url string
@param fallback_author string  passed through to parse_work_listing()
@return table[]? works
@return string? err
]]
function AO3Client:fetchWorkListing(url, fallback_author)
    if not self.session_cookie or not self.username then
        return nil, "not logged in"
    end

    local ok, status, headers, body = self.http_request({
        url = url,
        method = "GET",
        headers = { Cookie = self:buildCookieHeader() },
    })
    if not ok then
        return nil, "could not reach AO3 (" .. tostring(status) .. ")"
    end
    merge_cookies(headers, EXTRA_COOKIE_NAMES, self.extra_cookies)
    if status ~= 200 then
        return nil, "unexpected response (" .. tostring(status) .. ") — the session may have expired, try login() again"
    end
    if looks_like_login_page(body) then
        return nil, "AO3 sent back the login page instead of your results — "
            .. "the session has likely expired, log in again"
    end

    return parse_work_listing(body, fallback_author)
end

--[[--
Returns the works on the user's "Marked for Later" list. Requires a prior
successful login() (needs both the session cookie and the username, to
build the URL).

Only reads page 1 — AO3 paginates this list, and going past page 1 is left
for a later session (see CLAUDE.md).

@return table[]? works  list of { id, title, author, url }, most-recent first
@return string? err
]]
function AO3Client:getMarkedForLater()
    -- Checked here too (fetchWorkListing() checks again) so url_encode()
    -- below never runs on a nil username.
    if not self.username then
        return nil, "not logged in"
    end
    return self:fetchWorkListing(
        BASE_URL .. "/users/" .. url_encode(self.username) .. "/readings?show=to-read",
        "Anonymous"
    )
end

--[[--
Returns the works the logged-in user has posted themselves (AO3's "My
Works" page). Same pagination caveat as getMarkedForLater(): only page 1.

@return table[]? works  list of { id, title, author, url }, most-recent first
@return string? err
]]
function AO3Client:getMyWorks()
    -- Same reason as getMarkedForLater(): avoid url_encode(nil) below.
    if not self.username then
        return nil, "not logged in"
    end
    return self:fetchWorkListing(
        BASE_URL .. "/users/" .. url_encode(self.username) .. "/works",
        self.username
    )
end

--- Searches AO3 works by free-text query.
-- @param query string
-- @return table[]? works
-- @return string? err
function AO3Client:search(query)
    -- TODO: GET BASE_URL .. "/works/search?work_search[query]=" .. query
    error("not implemented yet")
end

--- Returns the direct download URL AO3 generates for a work.
-- @param work_id string|number
-- @param format string one of "EPUB", "MOBI", "PDF", "HTML"
-- @return string? url
-- @return string? err
function AO3Client:getDownloadUrl(work_id, format)
    -- TODO: work pages expose a "Download" dropdown with links shaped like
    -- BASE_URL .. "/downloads/<work_id>/<title-slug>.<format>"
    -- (the title-slug segment is derived from the work title; test against
    -- a real work page to get the exact rule right)
    error("not implemented yet")
end

return AO3Client
