-- Run with `busted` from the repo root (see docs/SETUP.md).
-- Only pure logic is tested here — no real HTTP requests are ever made;
-- every test injects a fake http_request function instead.

local AO3Client = require("ao3client")

-- Builds a fake http_request that returns each entry in `responses` in
-- order, one per call, and fails the test loudly on an unexpected extra
-- call (e.g. login() making a request it shouldn't have).
local function fake_http(responses)
    local call = 0
    return function(opts)
        call = call + 1
        local r = responses[call]
        assert.is_not_nil(r, "unexpected extra HTTP call #" .. call .. " to " .. tostring(opts.url))
        return r.ok, r.status, r.headers, r.body
    end
end

describe("AO3Client", function()
    it("starts with no session until login() succeeds", function()
        local client = AO3Client.new()
        assert.is_nil(client.session_cookie)
    end)

    it("raises until getDownloadUrl() is actually implemented", function()
        local client = AO3Client.new()
        assert.has_error(function()
            client:getDownloadUrl(12345, "EPUB")
        end)
    end)
end)

describe("AO3Client#login", function()
    it("fails fast without making any HTTP call when username is missing", function()
        local client = AO3Client.new(function()
            error("should not have made an HTTP call")
        end)

        local ok, err = client:login("", "somepass")

        assert.is_false(ok)
        assert.is_not_nil(err)
    end)

    it("fails fast without making any HTTP call when password is missing", function()
        local client = AO3Client.new(function()
            error("should not have made an HTTP call")
        end)

        local ok, err = client:login("someuser", "")

        assert.is_false(ok)
        assert.is_not_nil(err)
    end)

    it("logs in given a CSRF token and a redirect to the user\'s own page", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, headers = {}, body = '<meta name="csrf-token" content="tok123">' },
            {
                ok = 1,
                status = 302,
                headers = {
                    ["location"] = "https://archiveofourown.org/users/someuser",
                    ["set-cookie"] = "_otwarchive_session=abc123; path=/; HttpOnly",
                },
            },
        }))

        local ok, err = client:login("someuser", "somepass")

        assert.is_true(ok)
        assert.is_nil(err)
        assert.are.equal("_otwarchive_session=abc123", client.session_cookie)
    end)

    it("rejects a login that redirects back to the login page despite a 302 and a cookie", function()
        -- The actual shape of a wrong password on AO3: Devise's stock
        -- failure handling redirects (302), and the session cookie gets
        -- re-emitted anyway (flash message + CSRF both touch the Rails
        -- session) -- so status and cookie presence alone both look exactly
        -- like a successful login. Only the redirect target (back to
        -- /users/login, instead of /users/<username>) actually tells them
        -- apart. Regression check for the bug where wrong credentials were
        -- read as a successful login.
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, headers = {}, body = '<meta name="csrf-token" content="tok123">' },
            {
                ok = 1,
                status = 302,
                headers = {
                    ["location"] = "https://archiveofourown.org/users/login",
                    ["set-cookie"] = "_otwarchive_session=deadbeef; path=/; HttpOnly",
                },
            },
        }))

        local ok, err = client:login("someuser", "wrongpass")

        assert.is_false(ok)
        assert.is_not_nil(err)
        assert.is_nil(client.session_cookie)
    end)

    it("still finds the session cookie among other comma-joined cookies", function()
        -- Regression check for the LuaSocket header-folding gotcha described
        -- in ao3client.lua: multiple Set-Cookie headers arrive joined by
        -- LuaSocket into one string, and cookie expiry dates contain commas
        -- too (e.g. "Expires=Wed, 21 Oct 2026 ...").
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, headers = {}, body = '<meta name="csrf-token" content="tok123">' },
            {
                ok = 1,
                status = 302,
                headers = {
                    ["set-cookie"] = "_ga=GA1.2.123; expires=Wed, 21 Oct 2026 07:28:00 GMT, "
                        .. "_otwarchive_session=abc123; path=/; HttpOnly",
                },
            },
        }))

        local ok = client:login("someuser", "somepass")

        assert.is_true(ok)
        assert.are.equal("_otwarchive_session=abc123", client.session_cookie)
    end)

    it("fails when the login page has no CSRF token", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, headers = {}, body = "<html>no token here</html>" },
        }))

        local ok, err = client:login("someuser", "somepass")

        assert.is_false(ok)
        assert.is_not_nil(err)
    end)

    it("fails when AO3 re-renders the login form instead of redirecting", function()
        -- This is what a wrong password looks like: HTTP 200 with the form
        -- (and an error banner) again, instead of a redirect.
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, headers = {}, body = '<meta name="csrf-token" content="tok123">' },
            { ok = 1, status = 200, headers = {}, body = "<html>invalid login</html>" },
        }))

        local ok, err = client:login("someuser", "wrongpass")

        assert.is_false(ok)
        assert.is_not_nil(err)
    end)

    it("percent-encodes the credentials and token in the POST body", function()
        local captured_post_opts
        local client = AO3Client.new(function(opts)
            if opts.method == "POST" then
                captured_post_opts = opts
                return 1, 302, { ["set-cookie"] = "_otwarchive_session=abc123" }
            end
            return 1, 200, {}, '<meta name="csrf-token" content="tok/123">'
        end)

        client:login("some+user@example.com", "p@ss word!")

        assert.is_not_nil(captured_post_opts)
        assert.matches("authenticity_token=tok%%2F123", captured_post_opts.body)
        assert.matches("user%[login%]=some%%2Buser%%40example%.com", captured_post_opts.body)
        assert.matches("user%[password%]=p%%40ss%+word%%21", captured_post_opts.body)
    end)

    it("fails cleanly when the initial GET itself fails", function()
        local client = AO3Client.new(fake_http({
            { ok = nil, status = "connection refused" },
        }))

        local ok, err = client:login("someuser", "somepass")

        assert.is_false(ok)
        assert.is_not_nil(err)
    end)
end)

describe("AO3Client#getMarkedForLater", function()
    -- getMarkedForLater() only needs the state login() would have set; skip
    -- re-running a fake login handshake in every test and just set it directly.
    local function logged_in_client(http_request)
        local client = AO3Client.new(http_request)
        client.session_cookie = "_otwarchive_session=abc123"
        client.username = "someuser"
        return client
    end

    -- A trimmed-down but structurally real reading-list page: two works,
    -- one with a normal author, one anonymous with an HTML entity in its
    -- title — both things that show up in real AO3 listings.
    local SAMPLE_PAGE = [[
        <ol class="reading work index group">
        <li id="work_111" class="reading work blurb group work-111">
          <h4 class="heading">
            <a href="/works/111">A Very Good Fic</a>
            by
            <a rel="author" href="/users/someauthor/pseuds/someauthor">someauthor</a>
          </h4>
          <h5 class="fandoms heading">
            <a class="tag" href="/tags/Some%20Fandom/works">Some Fandom</a>
          </h5>
        </li>
        <li id="work_222" class="reading work blurb group work-222">
          <h4 class="heading">
            <a href="/works/222">Another Fic &amp; Friends</a>
          </h4>
        </li>
        </ol>
    ]]

    it("fails without making a request when not logged in", function()
        local client = AO3Client.new(function()
            error("should not have made an HTTP call")
        end)

        local works, err = client:getMarkedForLater()

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)

    it("parses works out of a reading-list page, in order", function()
        local client = logged_in_client(fake_http({
            { ok = 1, status = 200, body = SAMPLE_PAGE },
        }))

        local works, err = client:getMarkedForLater()

        assert.is_nil(err)
        assert.are.equal(2, #works)

        assert.are.equal("111", works[1].id)
        assert.are.equal("A Very Good Fic", works[1].title)
        assert.are.equal("someauthor", works[1].author)
        assert.are.equal("https://archiveofourown.org/works/111", works[1].url)

        -- entity-decoded title, and no author link -> Anonymous.
        assert.are.equal("Another Fic & Friends", works[2].title)
        assert.are.equal("Anonymous", works[2].author)
    end)

    it("sends the session cookie and builds the URL from the username", function()
        local captured_opts
        local client = logged_in_client(function(opts)
            captured_opts = opts
            return 1, 200, {}, SAMPLE_PAGE
        end)

        client:getMarkedForLater()

        assert.are.equal(
            "https://archiveofourown.org/users/someuser/readings?show=to-read",
            captured_opts.url
        )
        assert.are.equal("_otwarchive_session=abc123", captured_opts.headers.Cookie)
    end)

    it("returns an empty list, not an error, when there's nothing marked", function()
        local client = logged_in_client(fake_http({
            { ok = 1, status = 200, body = "<p>No works here.</p>" },
        }))

        local works, err = client:getMarkedForLater()

        assert.is_nil(err)
        assert.are.equal(0, #works)
    end)

    it("fails when the session looks expired", function()
        -- A real expired session gets redirected to the login page; a non-200
        -- status is the simplest reliable signal to check for that here.
        local client = logged_in_client(fake_http({
            { ok = 1, status = 403, body = "" },
        }))

        local works, err = client:getMarkedForLater()

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)

    it("fails cleanly when the request itself fails", function()
        local client = logged_in_client(fake_http({
            { ok = nil, status = "connection refused" },
        }))

        local works, err = client:getMarkedForLater()

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)

    it("treats a login-page response as an expired session, not an empty list", function()
        -- A 200 with AO3's own login page in the body -- e.g. an
        -- expired/rejected session cookie that got silently redirected back
        -- to /users/login -- used to read as "zero works found", with no
        -- error at all. This is the regression check for that.
        local client = logged_in_client(fake_http({
            {
                ok = 1,
                status = 200,
                body = '<meta name="csrf-token" content="tok123">'
                    .. '<input name="user[login]" type="text">',
            },
        }))

        local works, err = client:getMarkedForLater()

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)
end)

describe("AO3Client#getMyWorks", function()
    -- Same helper as the getMarkedForLater describe block above (kept local
    -- to each block rather than shared, since busted specs don't share
    -- upvalues across sibling describe() calls without extra plumbing).
    local function logged_in_client(http_request)
        local client = AO3Client.new(http_request)
        client.session_cookie = "_otwarchive_session=abc123"
        client.username = "someuser"
        return client
    end

    -- Unlike a Marked for Later blurb, a work on your OWN "My Works" page can
    -- have no `rel="author"` link at all (AO3 just doesn't bother linking
    -- "by yourself") — that's the one behavioural difference this getter has
    -- from getMarkedForLater(), so the fixture exercises both: one blurb
    -- with the author link present, one without.
    local SAMPLE_PAGE = [[
        <ol class="work index group">
        <li id="work_333" class="work blurb group work-333">
          <h4 class="heading">
            <a href="/works/333">My First Fic</a>
            by
            <a rel="author" href="/users/someuser/pseuds/someuser">someuser</a>
          </h4>
        </li>
        <li id="work_444" class="work blurb group work-444">
          <h4 class="heading">
            <a href="/works/444">My Second Fic</a>
          </h4>
        </li>
        </ol>
    ]]

    it("fails without making a request when not logged in", function()
        local client = AO3Client.new(function()
            error("should not have made an HTTP call")
        end)

        local works, err = client:getMyWorks()

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)

    it("parses works out of a works page, in order", function()
        local client = logged_in_client(fake_http({
            { ok = 1, status = 200, body = SAMPLE_PAGE },
        }))

        local works, err = client:getMyWorks()

        assert.is_nil(err)
        assert.are.equal(2, #works)

        assert.are.equal("333", works[1].id)
        assert.are.equal("My First Fic", works[1].title)
        assert.are.equal("someuser", works[1].author)

        -- No author link on this one -> falls back to the logged-in
        -- username, NOT "Anonymous" (that's the difference from
        -- getMarkedForLater() this getter exists to cover).
        assert.are.equal("My Second Fic", works[2].title)
        assert.are.equal("someuser", works[2].author)
    end)

    it("sends the session cookie and builds the URL from the username", function()
        local captured_opts
        local client = logged_in_client(function(opts)
            captured_opts = opts
            return 1, 200, {}, SAMPLE_PAGE
        end)

        client:getMyWorks()

        assert.are.equal(
            "https://archiveofourown.org/users/someuser/works",
            captured_opts.url
        )
        assert.are.equal("_otwarchive_session=abc123", captured_opts.headers.Cookie)
    end)

    it("returns an empty list, not an error, when nothing's been posted", function()
        local client = logged_in_client(fake_http({
            { ok = 1, status = 200, body = "<p>No works here.</p>" },
        }))

        local works, err = client:getMyWorks()

        assert.is_nil(err)
        assert.are.equal(0, #works)
    end)

    it("fails when the session looks expired", function()
        local client = logged_in_client(fake_http({
            { ok = 1, status = 403, body = "" },
        }))

        local works, err = client:getMyWorks()

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)

    it("fails cleanly when the request itself fails", function()
        local client = logged_in_client(fake_http({
            { ok = nil, status = "connection refused" },
        }))

        local works, err = client:getMyWorks()

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)

    it("treats a login-page response as an expired session, not an empty list", function()
        local client = logged_in_client(fake_http({
            {
                ok = 1,
                status = 200,
                body = '<meta name="csrf-token" content="tok123">'
                    .. '<input name="user[login]" type="text">',
            },
        }))

        local works, err = client:getMyWorks()

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)
end)
