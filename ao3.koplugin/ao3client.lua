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

-- AO3's login form, as of checking against a currently-maintained unofficial
-- AO3 client library (see docs/SETUP.md notes) — Rails form/param names are
-- an implementation detail AO3 could change without notice. If login starts
-- failing with "login rejected" even for correct credentials, check these
-- three constants first, by re-inspecting the real login page.
local LOGIN_FIELD_USERNAME = "user[login]"
local LOGIN_FIELD_PASSWORD = "user[password]"
local SESSION_COOKIE_NAME = "_otwarchive_session"

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

    local response_chunks = {}
    local ok, status, headers = https.request({
        url = opts.url,
        method = opts.method or "GET",
        headers = opts.headers,
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
    return self
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

    local page_ok, page_status, _, page_body = self.http_request({
        url = LOGIN_URL,
        method = "GET",
    })
    if not page_ok then
        return false, "could not reach AO3 (" .. tostring(page_status) .. ")"
    end

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
        },
        body = body,
    })
    if not post_ok then
        return false, "login request failed (" .. tostring(post_status) .. ")"
    end

    -- AO3 redirects (302/303) on a successful login, and re-renders the
    -- login form (200, with an error message in the body) on bad credentials.
    if post_status ~= 302 and post_status ~= 303 then
        return false, "login rejected — check username/password"
    end

    -- LuaSocket folds repeated response headers (like multiple Set-Cookie
    -- lines) into one comma-joined string, which mangles cookie expiry dates
    -- (they contain commas too). Rather than trying to parse that properly,
    -- just pull out the one cookie value we actually need.
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

    local ok, status, _, body = self.http_request({
        url = url,
        method = "GET",
        headers = { Cookie = self.session_cookie },
    })
    if not ok then
        return nil, "could not reach AO3 (" .. tostring(status) .. ")"
    end
    if status ~= 200 then
        return nil, "unexpected response (" .. tostring(status) .. ") — the session may have expired, try login() again"
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
