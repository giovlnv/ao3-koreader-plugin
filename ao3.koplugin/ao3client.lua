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
True when `body` looks like AO3's login page rather than the page we asked
for. Reuses the exact form field name (`user[login]`) login() itself
submits credentials to, since that's already confirmed correct against the
real site — not a new guess.

A logged-in-only page can come back as this in more ways than a non-200
status: AO3 may 302-redirect an expired/rejected session straight to
/users/login, and some HTTP clients (including, as far as we've been able to
tell, the one this plugin runs on) follow that redirect transparently and
hand back a plain 200 with the login page's body — which, without this
check, parse_work_listing() would just silently read as zero works, no error
at all. That's indistinguishable on screen from a genuinely empty list,
which is exactly the bug this guards against. login() itself also uses this,
to confirm a session it just captured actually works before reporting
success — see the comment there.

Only call this against a page that's known to require a genuinely working
session (like Marked for Later) or that IS the login page itself. A public,
logged-out AO3 page also matches this pattern -- its header nav carries the
same `user[login]` field in its own persistent mini login form -- which is
why search() deliberately does not use this check (see there).

@param body string?
@return boolean
]]
local function looks_like_login_page(body)
    return body ~= nil and body:find('name="user%[login%]"') ~= nil
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
Reads one of the four "required tags" badges every work blurb has (rating,
archive-warning status, category, and complete/WIP status) -- confirmed
against a real search-results page. Each is a `<span class="X-value Y"
title="Human Readable Text">`, where Y (`class_suffix` here) is the fixed
part identifying which badge it is (e.g. "rating", "category", "iswip") and
the human-readable text AO3 itself displays is right there in `title` --
no need to decode AO3's own short internal value codes (e.g. "general
audience") at all.

@param html string  one work's blurb HTML
@param class_suffix string  "rating", "category", or "iswip"
@return string?
]]
local function extract_badge(html, class_suffix)
    return html:match('class="[%w%-]+ ' .. class_suffix .. '"%s+title="([^"]+)"')
end

--[[--
Collects every tag AO3 links to `/tags/...` within a specific `<li
class='NAME'>...</li>` grouping in a blurb's "Tags" section (e.g.
class_name="warnings" for archive warnings, "freeforms" for freeform tags).
Confirmed against a real blurb: AO3 renders one such `<li>` per tag, not one
`<li>` holding a comma-joined list, so multiple warnings/etc. need this to
gmatch across all of them, the same shape split_work_blurbs()'s sibling
helper extract_all_tags() below handles for the whole "Tags" list at once.

@param html string  one work's blurb HTML
@param class_name string  e.g. "warnings", "characters", "relationships"
@return string[]
]]
local function extract_tag_group(html, class_name)
    local tags = {}
    for li in html:gmatch("<li class='" .. class_name .. "'>(.-)</li>") do
        local text = li:match('class="tag"[^>]*>([^<]+)</a>')
        if text then
            table.insert(tags, html_unescape(text))
        end
    end
    return tags
end

--[[--
Collects every tag in a blurb's whole "Tags" section (warnings, characters,
relationships, and freeform tags together, in the order AO3 lists them) --
everything inside the single `<ul class="tags commas">...</ul>` block.
Deliberately bounded to that block, not just "every `class=\"tag\"` link in
the blurb": the fandom heading above it (`<h5 class="fandoms heading">`) has
its own separate `class="tag"` links that this must not also pick up.

@param html string  one work's blurb HTML
@return string[]
]]
local function extract_all_tags(html)
    local list_html = html:match('<ul class="tags commas">(.-)</ul>')
    if not list_html then
        return {}
    end
    local tags = {}
    for text in list_html:gmatch('class="tag"[^>]*>([^<]+)</a>') do
        table.insert(tags, html_unescape(text))
    end
    return tags
end

--[[--
Reads one `<dd class="NAME">...</dd>` value out of a blurb's stats block
(words, chapters, etc.), with any inner tags stripped -- confirmed against a
real blurb, "chapters" sometimes wraps its number in a link (to the latest
chapter) while a plain one-shot's doesn't, so this always strips tags rather
than assuming either shape.

@param html string  one work's blurb HTML
@param class_name string  e.g. "words", "chapters"
@return string?
]]
local function extract_stat(html, class_name)
    local raw = html:match('<dd class="' .. class_name .. '"[^>]*>(.-)</dd>')
    return raw and (raw:gsub("<[^>]+>", ""))
end

--[[--
Turns a summary blockquote's inner HTML into plain text. AO3 summaries are
free-form rich text an author wrote (paragraphs, the occasional bold/italic
or link), not structured data, so this isn't a general HTML-to-text
converter -- it only needs to be good enough for that: paragraph/line breaks
become actual newlines so multi-paragraph summaries don't run together into
one block, every other tag is dropped, and HTML entities are decoded.

@param html string  the blockquote's inner HTML (without the tag itself)
@return string
]]
local function strip_summary_html(html)
    local text = html:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n\n"):gsub("<[^>]+>", "")
    text = html_unescape(text)
    text = text:gsub("[ \t]+", " ")
    text = text:gsub(" ?\n ?", "\n")
    text = text:gsub("\n\n+", "\n\n")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
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

    -- Rails' default cookie-based session store keeps the CSRF secret
    -- *inside* the session cookie itself, not server-side -- so the
    -- anonymous session this very GET just established has to be sent back
    -- on the POST below for the submitted authenticity_token to validate at
    -- all. Confirmed missing this makes AO3 redirect to /auth_error
    -- ("Session Expired") regardless of whether the credentials are correct
    -- -- found by replicating this exact two-request flow with curl against
    -- the real site (a controlled A/B: identical request, only this cookie
    -- present or absent), not by guessing. This is deliberately kept local
    -- rather than folded into self.extra_cookies/buildCookieHeader(): it's
    -- only ever relevant for the one POST immediately below, and self
    -- shouldn't hold a stale pre-login session value once a real one (or a
    -- rejection) is known a few lines later.
    local pre_login_cookie = page_headers and page_headers["set-cookie"]
    local pre_login_session = pre_login_cookie
        and pre_login_cookie:match(SESSION_COOKIE_NAME .. "=([^;,]+)")

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

    local post_cookie_parts = {}
    if pre_login_session then
        table.insert(post_cookie_parts, SESSION_COOKIE_NAME .. "=" .. pre_login_session)
    end
    local cloudflare_cookie_header = self:buildCookieHeader()
    if cloudflare_cookie_header then
        table.insert(post_cookie_parts, cloudflare_cookie_header)
    end
    local post_cookie_header = #post_cookie_parts > 0 and table.concat(post_cookie_parts, "; ") or nil

    local post_ok, post_status, post_headers = self.http_request({
        url = LOGIN_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#body),
            Cookie = post_cookie_header,
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
    if location and (location:find("/users/login", 1, true) or location:find("/auth_error", 1, true)) then
        -- /auth_error ("Session Expired") is a distinct redirect target from
        -- /users/login -- confirmed against the real site -- that Warden's
        -- own failure handling uses for a CSRF/session-level rejection
        -- (happening before Devise even looks at the credentials), as
        -- opposed to Devise's own "wrong password" rejection which goes
        -- back to /users/login. The pre-login cookie fix above should mean
        -- this is never hit in practice now, but treating it as anything
        -- other than a rejection would be wrong regardless.
        return false, "login rejected — check username/password"
    end

    -- AO3's login field accepts either an account's username or its email
    -- (confirmed: it's the same Devise `user[login]` field either way) --
    -- but only the username is a valid URL segment. The redirect target
    -- above already names AO3's own canonical username for this account, so
    -- prefer that over whatever was actually typed into the login form for
    -- anything URL-related below; falling back to the typed value only if
    -- the redirect didn't have the expected shape.
    local canonical_username = (location and location:match("/users/([^/]+)")) or username

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

    -- Don't just trust the redirect-target heuristic above: that's exactly
    -- what the Cloudflare cookie bug in CLAUDE.md looked like too (login()
    -- said "success", but the saved session didn't actually work for the
    -- very next request). Confirm the cookies captured so far genuinely
    -- authenticate before telling the caller login succeeded, by fetching
    -- an account-only page a logged-out (or wrongly-authenticated) client
    -- can never see. "Marked for Later" is used here specifically because
    -- it's confirmed, from direct testing against the real site, to require
    -- a genuinely working session -- unlike e.g. a user's public profile or
    -- "My Works" page, which anyone can view logged out.
    self.session_cookie = SESSION_COOKIE_NAME .. "=" .. session_value
    local verify_ok, verify_status, verify_headers, verify_body = self.http_request({
        url = BASE_URL .. "/users/" .. url_encode(canonical_username) .. "/readings?show=to-read",
        method = "GET",
        headers = { Cookie = self:buildCookieHeader() },
    })
    if verify_ok then
        merge_cookies(verify_headers, EXTRA_COOKIE_NAMES, self.extra_cookies)
    end
    if not verify_ok then
        self.session_cookie = nil
        return false, "login looked successful but verifying it failed (" .. tostring(verify_status) .. ")"
    end
    if verify_status ~= 200 or looks_like_login_page(verify_body) then
        self.session_cookie = nil
        return false, "login looked successful but the saved session doesn't actually work "
            .. "(verification got status " .. tostring(verify_status) .. ") — try again"
    end

    self.username = canonical_username
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
@return table[] works  list of { id, title, author, url, rating, category,
  status, warnings, tags, words, chapters, summary } -- every field past
  `url` is nil/empty if the expected markup wasn't found in that blurb,
  rather than failing the whole entry (see below)
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

            -- Summary is genuinely optional (very short blurbs, or a work
            -- whose author didn't write one, have no "Summary" block at
            -- all) -- unlike title, its absence isn't a sign the whole
            -- blurb didn't parse, so it's not covered by the "skipped
            -- entirely" comment below.
            local summary_html = blurb.html:match('<blockquote class="userstuff summary">(.-)</blockquote>')

            local words = extract_stat(blurb.html, "words")

            table.insert(works, {
                id = blurb.id,
                title = html_unescape(title),
                author = #authors > 0 and table.concat(authors, ", ") or fallback_author,
                url = BASE_URL .. "/works/" .. blurb.id,
                rating = extract_badge(blurb.html, "rating"),
                category = extract_badge(blurb.html, "category"),
                status = extract_badge(blurb.html, "iswip"),
                warnings = extract_tag_group(blurb.html, "warnings"),
                tags = extract_all_tags(blurb.html),
                words = words and tonumber((words:gsub(",", ""))),
                chapters = extract_stat(blurb.html, "chapters"),
                summary = summary_html and strip_summary_html(summary_html),
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

--[[--
Searches AO3 works by free-text query (the same request AO3's own "Search
Works" box makes: GET /works/search?work_search[query]=...). Public --
works whether or not login() has succeeded.

Deliberately does NOT reuse fetchWorkListing()/looks_like_login_page(): a
logged-out AO3 page always carries a "log in" mini-form in its own header
nav using the exact same `user[login]` field name looks_like_login_page()
checks for, so applying that check here would misread every real,
logged-out search result page as an expired session -- confirmed by
fetching a real one directly (see CLAUDE.md). A non-200 status is still a
real error; a 200 with zero matching blurbs is just zero results, same as
the other listing getters.

Only reads page 1 — AO3 paginates search results too, same as
getMarkedForLater()/getMyWorks() (see CLAUDE.md).

@param query string  free-text search query
@return table[]? works  list of { id, title, author, url }
@return string? err
]]
function AO3Client:search(query)
    if not query or query == "" then
        return nil, "search query is required"
    end

    local ok, status, headers, body = self.http_request({
        url = BASE_URL .. "/works/search?work_search[query]=" .. url_encode(query),
        method = "GET",
        headers = { Cookie = self:buildCookieHeader() },
    })
    if not ok then
        return nil, "could not reach AO3 (" .. tostring(status) .. ")"
    end
    merge_cookies(headers, EXTRA_COOKIE_NAMES, self.extra_cookies)
    if status ~= 200 then
        return nil, "unexpected response (" .. tostring(status) .. ") searching AO3"
    end

    return parse_work_listing(body, "Anonymous")
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
