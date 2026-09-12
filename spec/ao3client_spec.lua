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
            -- login() verifies the captured session against Marked for
            -- Later before trusting it -- see the "verifies the session..."
            -- tests below for that behavior on its own.
            { ok = 1, status = 200, headers = {}, body = "<p>No works here.</p>" },
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
            { ok = 1, status = 200, headers = {}, body = "<p>No works here.</p>" },
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

    it("resends Cloudflare's cookies from the GET on the login POST", function()
        -- Regression check: archiveofourown.org sits behind Cloudflare, which
        -- sets __cf_bm/_cfuvid on the very first request. A client that
        -- drops these (as this plugin used to) gets treated as a different
        -- client on every subsequent request -- the confirmed cause of
        -- getMarkedForLater()/getMyWorks() coming back redirected to the
        -- login page despite login() itself succeeding. See CLAUDE.md.
        local captured_post_opts
        local client = AO3Client.new(function(opts)
            if opts.method == "POST" then
                captured_post_opts = opts
                return 1, 302, { ["location"] = "https://archiveofourown.org/users/someuser" }
            end
            return 1, 200, {
                ["set-cookie"] = "__cf_bm=cfbm123; path=/; HttpOnly, "
                    .. "_cfuvid=cfuvid456; path=/; HttpOnly",
            }, '<meta name="csrf-token" content="tok123">'
        end)

        client:login("someuser", "somepass")

        assert.is_not_nil(captured_post_opts)
        assert.are.equal("__cf_bm=cfbm123; _cfuvid=cfuvid456", captured_post_opts.headers.Cookie)
    end)

    it("resends the anonymous session cookie from the GET on the login POST", function()
        -- Regression check for a real bug, confirmed by replicating this
        -- exact request with curl against the real site: Rails' default
        -- cookie session store keeps the CSRF secret inside the session
        -- cookie itself, so without sending back the anonymous session the
        -- GET established, AO3 rejects the POST at the CSRF/session layer
        -- (redirecting to /auth_error) before ever looking at the
        -- credentials -- regardless of whether they're correct. See
        -- CLAUDE.md.
        local captured_post_opts
        local client = AO3Client.new(function(opts)
            if opts.method == "POST" then
                captured_post_opts = opts
                return 1, 302, { ["location"] = "https://archiveofourown.org/users/someuser" }
            end
            return 1, 200, { ["set-cookie"] = "_otwarchive_session=preloginvalue; path=/; HttpOnly" },
                '<meta name="csrf-token" content="tok123">'
        end)

        client:login("someuser", "somepass")

        assert.is_not_nil(captured_post_opts)
        assert.are.equal("_otwarchive_session=preloginvalue", captured_post_opts.headers.Cookie)
    end)

    it("combines the pre-login session cookie with Cloudflare's cookies on the POST", function()
        local captured_post_opts
        local client = AO3Client.new(function(opts)
            if opts.method == "POST" then
                captured_post_opts = opts
                return 1, 302, { ["location"] = "https://archiveofourown.org/users/someuser" }
            end
            return 1, 200, {
                ["set-cookie"] = "_otwarchive_session=preloginvalue; path=/; HttpOnly, "
                    .. "__cf_bm=cfbm123; path=/; HttpOnly",
            }, '<meta name="csrf-token" content="tok123">'
        end)

        client:login("someuser", "somepass")

        assert.are.equal(
            "_otwarchive_session=preloginvalue; __cf_bm=cfbm123",
            captured_post_opts.headers.Cookie
        )
    end)

    it("rejects a login redirected to /auth_error, not just /users/login", function()
        -- Regression check: AO3's Warden-level CSRF/session rejection
        -- redirects to /auth_error ("Session Expired"), a different target
        -- from Devise's own /users/login credential-rejection redirect --
        -- confirmed against the real site. Both must be treated as failure.
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, headers = {}, body = '<meta name="csrf-token" content="tok123">' },
            {
                ok = 1,
                status = 302,
                headers = {
                    ["location"] = "https://archiveofourown.org/auth_error",
                    ["set-cookie"] = "_otwarchive_session=deadbeef; path=/; HttpOnly",
                },
            },
        }))

        local ok, err = client:login("someuser", "somepass")

        assert.is_false(ok)
        assert.is_not_nil(err)
        assert.is_nil(client.session_cookie)
    end)

    it("verifies the session against Marked for Later, rejecting it if that looks like the login page", function()
        -- Regression check: a redirect to /users/<username> plus a cookie
        -- is exactly what the Cloudflare cookie bug in CLAUDE.md also looked
        -- like, despite the resulting session not actually working. login()
        -- now confirms the session for real instead of trusting the
        -- redirect-target heuristic alone.
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
            {
                ok = 1,
                status = 200,
                headers = {},
                body = '<meta name="csrf-token" content="tok123">'
                    .. '<input name="user[login]" type="text">',
            },
        }))

        local ok, err = client:login("someuser", "somepass")

        assert.is_false(ok)
        assert.is_not_nil(err)
        assert.is_nil(client.session_cookie)
    end)

    it("rejects the session if the verification request gets a non-200 response", function()
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
            { ok = 1, status = 403, headers = {}, body = "" },
        }))

        local ok, err = client:login("someuser", "somepass")

        assert.is_false(ok)
        assert.is_not_nil(err)
        assert.is_nil(client.session_cookie)
    end)

    it("rejects the session cleanly when the verification request itself fails", function()
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
            { ok = nil, status = "connection refused" },
        }))

        local ok, err = client:login("someuser", "somepass")

        assert.is_false(ok)
        assert.is_not_nil(err)
        assert.is_nil(client.session_cookie)
    end)

    it("sends the accumulated cookies (session + Cloudflare) when verifying", function()
        local captured_verify_opts
        local call = 0
        local client = AO3Client.new(function(opts)
            call = call + 1
            if call == 1 then
                return 1, 200, { ["set-cookie"] = "__cf_bm=cfbm123; path=/; HttpOnly" },
                    '<meta name="csrf-token" content="tok123">'
            elseif call == 2 then
                return 1, 302, {
                    ["location"] = "https://archiveofourown.org/users/someuser",
                    ["set-cookie"] = "_otwarchive_session=abc123; path=/; HttpOnly",
                }
            end
            captured_verify_opts = opts
            return 1, 200, {}, "<p>No works here.</p>"
        end)

        local ok = client:login("someuser", "somepass")

        assert.is_true(ok)
        assert.is_not_nil(captured_verify_opts)
        assert.are.equal(
            "https://archiveofourown.org/users/someuser/readings?show=to-read",
            captured_verify_opts.url
        )
        assert.are.equal(
            "_otwarchive_session=abc123; __cf_bm=cfbm123",
            captured_verify_opts.headers.Cookie
        )
    end)

    it("uses the redirect's real username, not the typed login, when logging in by email", function()
        -- Regression check for a real bug: AO3's login field accepts either
        -- a username or an account's email (same Devise `user[login]`
        -- field either way), but only the username is a valid URL segment.
        -- Verifying against /users/<whatever was typed>/readings would 404
        -- for an email login and wrongly reject a genuinely correct one --
        -- exactly what was reported live. The redirect target already names
        -- the real username, so that's what must be used instead.
        local captured_verify_opts
        local client = AO3Client.new(function(opts)
            if opts.method == "POST" then
                return 1, 302, {
                    ["location"] = "https://archiveofourown.org/users/RealUsername",
                    ["set-cookie"] = "_otwarchive_session=abc123; path=/; HttpOnly",
                }
            end
            if captured_verify_opts then
                -- Shouldn't happen -- only one GET (the login page) should
                -- precede the verify GET, this is a safety net so a bug
                -- reintroducing a wrong verify URL fails loudly instead of
                -- quietly overwriting captured_verify_opts a second time.
                error("unexpected extra GET to " .. opts.url)
            end
            if opts.url:find("/users/RealUsername/", 1, true) then
                captured_verify_opts = opts
                return 1, 200, {}, "<p>No works here.</p>"
            end
            return 1, 200, {}, '<meta name="csrf-token" content="tok123">'
        end)

        local ok, err = client:login("someone@example.com", "somepass")

        assert.is_true(ok)
        assert.is_nil(err)
        assert.is_not_nil(captured_verify_opts)
        assert.are.equal("RealUsername", client.username)
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

    it("also sends Cloudflare's cookies picked up during login, and updates them on rotation", function()
        local client = logged_in_client(nil)
        client.extra_cookies = { ["__cf_bm"] = "cfbm-old" }

        local captured_opts
        local client_calls = 0
        client.http_request = function(opts)
            client_calls = client_calls + 1
            captured_opts = opts
            if client_calls == 1 then
                -- Cloudflare rotates __cf_bm on this response.
                return 1, 200, { ["set-cookie"] = "__cf_bm=cfbm-new; path=/; HttpOnly" }, SAMPLE_PAGE
            end
            return 1, 200, {}, SAMPLE_PAGE
        end

        client:getMarkedForLater()
        assert.are.equal("_otwarchive_session=abc123; __cf_bm=cfbm-old", captured_opts.headers.Cookie)

        client:getMarkedForLater()
        assert.are.equal("_otwarchive_session=abc123; __cf_bm=cfbm-new", captured_opts.headers.Cookie)
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

describe("AO3Client#search", function()
    -- A trimmed-down but structurally real search-results page: two works,
    -- one anonymous -- and, crucially, AO3's persistent header nav "log in"
    -- mini-form, present on every real logged-out page. That form uses the
    -- exact same `user[login]` field name looks_like_login_page() checks
    -- for, which is why search() must not use that check (see ao3client.lua).
    local SAMPLE_PAGE = [[
        <input name="user[login]" type="text" placeholder="Username or Email">
        <ol class="work index group">
        <li id="work_555" class="work blurb group work-555">
          <h4 class="heading">
            <a href="/works/555">A Searched Fic</a>
            by
            <a rel="author" href="/users/someauthor/pseuds/someauthor">someauthor</a>
          </h4>
        </li>
        <li id="work_666" class="anonymous work blurb group work-666">
          <h4 class="heading">
            <a href="/works/666">An Anonymous Result</a>
          </h4>
        </li>
        </ol>
    ]]

    it("fails fast without making any HTTP call when the query is empty", function()
        local client = AO3Client.new(function()
            error("should not have made an HTTP call")
        end)

        local works, err = client:search("")

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)

    it("builds the search URL from the query, percent-encoded", function()
        local captured_opts
        local client = AO3Client.new(function(opts)
            captured_opts = opts
            return 1, 200, {}, SAMPLE_PAGE
        end)

        client:search("found family & hurt/comfort")

        assert.are.equal(
            "https://archiveofourown.org/works/search?work_search[query]="
                .. "found+family+%26+hurt%2Fcomfort",
            captured_opts.url
        )
    end)

    it("parses works out of a search-results page, in order", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = SAMPLE_PAGE },
        }))

        local works, err = client:search("test")

        assert.is_nil(err)
        assert.are.equal(2, #works)
        assert.are.equal("A Searched Fic", works[1].title)
        assert.are.equal("someauthor", works[1].author)
        assert.are.equal("An Anonymous Result", works[2].title)
        assert.are.equal("Anonymous", works[2].author)
    end)

    it("does NOT treat the page as an expired session despite the header's own login form", function()
        -- Regression check for the false positive this would otherwise be:
        -- every real, logged-out search page contains name="user[login]" in
        -- its header nav, which would wrongly trigger the same
        -- looks_like_login_page() check fetchWorkListing() uses.
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = SAMPLE_PAGE },
        }))

        local works, err = client:search("test")

        assert.is_nil(err)
        assert.are.equal(2, #works)
    end)

    it("works before login() has ever been called", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = SAMPLE_PAGE },
        }))

        local works, err = client:search("test")

        assert.is_nil(err)
        assert.is_not_nil(works)
    end)

    it("returns an empty list, not an error, when nothing matches", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = "<p>No results found.</p>" },
        }))

        local works, err = client:search("asdfqwerty")

        assert.is_nil(err)
        assert.are.equal(0, #works)
    end)

    it("fails on a non-200 response", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 500, body = "" },
        }))

        local works, err = client:search("test")

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)

    it("fails cleanly when the request itself fails", function()
        local client = AO3Client.new(fake_http({
            { ok = nil, status = "connection refused" },
        }))

        local works, err = client:search("test")

        assert.is_nil(works)
        assert.is_not_nil(err)
    end)

    it("sends whatever cookies are already known", function()
        local captured_opts
        local client = AO3Client.new(function(opts)
            captured_opts = opts
            return 1, 200, {}, SAMPLE_PAGE
        end)
        client.session_cookie = "_otwarchive_session=abc123"

        client:search("test")

        assert.are.equal("_otwarchive_session=abc123", captured_opts.headers.Cookie)
    end)
end)

describe("parse_work_listing rich metadata (rating, warnings, tags, summary, chapters, words)", function()
    -- Real markup, trimmed of comments/whitespace-only lines, taken directly
    -- from a live archiveofourown.org search-results page -- not guessed
    -- from other tools' selectors, unlike some of this plugin's earlier
    -- parsing (see CLAUDE.md). Exercised through search(), since that's
    -- where this was actually asked for, but parse_work_listing() is shared
    -- code -- getMarkedForLater()/getMyWorks() get these fields too.
    local RICH_SAMPLE_PAGE = [[
        <input name="user[login]" type="text">
        <ol class="work index group">
        <li id="work_6090505" class="work blurb group work-6090505 user-73090" role="article">
          <div class="header module">
            <h4 class="heading">
              <a href="/works/6090505">TEST TEST TEST</a>
              by
              <a rel="author" href="/users/AniManGa19930/pseuds/AniManGa19930">AniManGa19930</a>
            </h4>
            <h5 class="fandoms heading">
              <span class="landmark">Fandoms:</span>
              <a class="tag" href="/tags/IDOLiSH7%20(Video%20Game)/works">IDOLiSH7 (Video Game)</a>
            </h5>
            <ul class="required-tags">
              <li><span class="rating-general-audience rating"
                title="General Audiences"><span class="text">General Audiences</span></span></li>
              <li><span class="warning-no warnings"
                title="No Archive Warnings Apply"><span class="text">No Archive Warnings Apply</span></span></li>
              <li><span class="category-gen category"
                title="Gen"><span class="text">Gen</span></span></li>
              <li><span class="complete-yes iswip"
                title="Complete Work"><span class="text">Complete Work</span></span></li>
            </ul>
          </div>
          <h6 class="landmark heading">Tags</h6>
          <ul class="tags commas">
            <li class='warnings'><strong><a class="tag"
              href="/tags/No%20Archive%20Warnings%20Apply/works">No Archive Warnings Apply</a></strong></li>
            <li class='characters'><a class="tag" href="/tags/Yotsuba%20Tamaki/works">Yotsuba Tamaki</a></li>
            <li class='characters'><a class="tag" href="/tags/Izumi%20Iori/works">Izumi Iori</a></li>
          </ul>
          <h6 class="landmark heading">Summary</h6>
          <blockquote class="userstuff summary">
            <p>Student's biggest problem? TEST.<br>Idolish Seven's biggest problem? TAMAKI &amp; TEST.</p>
          </blockquote>
          <dl class="stats">
            <dt class="language">Language:</dt>
            <dd class="language" lang="en">English</dd>
            <dt class="words">Words:</dt>
            <dd class="words">2,402</dd>
            <dt class="chapters">Chapters:</dt>
            <dd class="chapters">1/1</dd>
            <dt class="kudos">Kudos:</dt>
            <dd class="kudos"><a href="/works/6090505#kudos">185</a></dd>
          </dl>
        </li>
        <li id="work_777" class="work blurb group work-777">
          <h4 class="heading">
            <a href="/works/777">A Bare-Bones Blurb</a>
          </h4>
        </li>
        </ol>
    ]]

    it("extracts rating, category, and completion status from the required-tags badges", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = RICH_SAMPLE_PAGE },
        }))

        local works = client:search("test")

        assert.are.equal("General Audiences", works[1].rating)
        assert.are.equal("Gen", works[1].category)
        assert.are.equal("Complete Work", works[1].status)
    end)

    it("extracts the archive-warning tags as a list", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = RICH_SAMPLE_PAGE },
        }))

        local works = client:search("test")

        assert.are.same({ "No Archive Warnings Apply" }, works[1].warnings)
    end)

    it("extracts every tag in the Tags section, not just fandoms", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = RICH_SAMPLE_PAGE },
        }))

        local works = client:search("test")

        assert.are.same(
            { "No Archive Warnings Apply", "Yotsuba Tamaki", "Izumi Iori" },
            works[1].tags
        )
    end)

    it("extracts word count as a number and chapters as the raw 'x/y' text", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = RICH_SAMPLE_PAGE },
        }))

        local works = client:search("test")

        assert.are.equal(2402, works[1].words)
        assert.are.equal("1/1", works[1].chapters)
    end)

    it("extracts the summary as plain, entity-decoded, multi-line text", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = RICH_SAMPLE_PAGE },
        }))

        local works = client:search("test")

        assert.are.equal(
            "Student's biggest problem? TEST.\nIdolish Seven's biggest problem? TAMAKI & TEST.",
            works[1].summary
        )
    end)

    it("leaves the new fields nil/empty, not erroring, when a blurb has none of this markup", function()
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = RICH_SAMPLE_PAGE },
        }))

        local works = client:search("test")

        local bare = works[2]
        assert.are.equal("A Bare-Bones Blurb", bare.title)
        assert.is_nil(bare.rating)
        assert.is_nil(bare.category)
        assert.is_nil(bare.status)
        assert.is_nil(bare.words)
        assert.is_nil(bare.chapters)
        assert.is_nil(bare.summary)
        assert.are.same({}, bare.warnings)
        assert.are.same({}, bare.tags)
    end)

    it("collects more than one warning tag when a work has several", function()
        -- Inferred from the confirmed one-<li>-per-tag pattern real AO3
        -- markup uses for repeated tags of the same kind (see the two
        -- 'characters' <li>s above, taken directly from the real page) --
        -- not independently observed with multiple warnings specifically.
        local page = [[
            <ol class="work index group">
            <li id="work_1" class="work blurb group work-1">
              <h4 class="heading"><a href="/works/1">Multi-Warning Fic</a></h4>
              <ul class="tags commas">
                <li class='warnings'><a class="tag"
                  href="/tags/Graphic%20Depictions%20Of%20Violence/works">Graphic Depictions Of Violence</a></li>
                <li class='warnings'><a class="tag"
                  href="/tags/Major%20Character%20Death/works">Major Character Death</a></li>
              </ul>
            </li>
            </ol>
        ]]
        local client = AO3Client.new(fake_http({
            { ok = 1, status = 200, body = page },
        }))

        local works = client:search("test")

        assert.are.same(
            { "Graphic Depictions Of Violence", "Major Character Death" },
            works[1].warnings
        )
    end)
end)
