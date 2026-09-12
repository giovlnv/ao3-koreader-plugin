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

--[[--
Does the actual HTTP work, using KOReader/LuaJIT's bundled LuaSec. Kept as a
plain function (not a method, no upvalues into AO3Client) so a test can pass
in a completely different one — see AO3Client.new().

`require("ssl.https")` happens in here rather than at file scope so that
unit tests, which never call this function, don't need LuaSec installed
just to run.

@param opts table: { url, method, headers, body }
@return ok boolean|nil   truthy on a completed request (any HTTP status)
@return status number|string  HTTP status code, or an error message if ok is falsy
@return headers table   lowercase response header names -> value
@return body string     response body
]]
local function default_http_request(opts)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")

    local response_chunks = {}
    local ok, status, headers = https.request({
        url = opts.url,
        method = opts.method or "GET",
        headers = opts.headers,
        source = opts.body and ltn12.source.string(opts.body) or nil,
        sink = ltn12.sink.table(response_chunks),
    })

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
    return true
end

--- Returns the works on the user's "Marked for Later" list. Requires a
--- prior successful login().
-- @return table[]? works  list of { id, title, author, fandom, url }
-- @return string? err
function AO3Client:getMarkedForLater()
    -- TODO: GET BASE_URL .. "/users/<username>/readings?show=to-read",
    -- sending Cookie: self.session_cookie
    error("not implemented yet")
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
