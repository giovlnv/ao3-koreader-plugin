# Project conventions

AO3 reader plugin for KOReader (Kindle). Personal project, single
maintainer. Read this before making changes.

## Architecture decision

Pure Lua `.koplugin` — no separate backend process, no WASM (unlike
rakuyomi, which needs those because it supports many manga sites through
compiled source plugins). AO3 already generates EPUB/MOBI/PDF/HTML files
per work, so this plugin never builds a book itself: it authenticates,
finds works, and fetches the file AO3 already made.

## Layout

- `ao3.koplugin/` — the actual KOReader plugin. This exact folder is what
  gets copied to `koreader/plugins/` on the Kindle.
  - `_meta.lua` — plugin manifest KOReader reads to list it in Tools ->
    Plugin management: `fullname = "AO3 fic search"`, plus a one-line
    `description`. This is the plugin's actual user-facing name; it's
    unrelated to `ao3reader` (the internal module/tab id, never shown as
    text) or to "AO3 Reader", which is just what this doc and code
    comments call the plugin informally.
  - `main.lua` — KOReader integration only (menu entries, widgets). No
    HTTP or HTML-parsing logic belongs here.
  - `ao3client.lua` — all AO3 HTTP/parsing logic. Framework-agnostic on
    purpose so it can be unit tested with `busted` without a running
    KOReader instance.
  - `menu_setup.lua` — one-time setup that gives "AO3 Reader" its own
    top-level menu tab and installs its icon. Writes to KOReader-wide
    files outside this plugin's own folder (see its own module comment for
    why that's safe) — not something `ao3client.lua`'s "framework-agnostic"
    rule applies to.
  - `icon/ao3.svg` — the tab's icon, copied into KOReader's user-icons
    directory by `menu_setup.lua` on first run.
- `spec/` — busted tests for `ao3client.lua`.
- `docs/SETUP.md` — environment setup (WSL2, KOReader emulator, Kindle
  deployment, GitHub).

## Conventions

- Lua target: LuaJIT (`std = "luajit"` in `.luacheckrc`), matching
  KOReader itself.
- Run `luacheck .` and `busted` before committing (docs/SETUP.md has the
  commands; run them inside WSL2/Ubuntu).
- Unit tests never make real HTTP requests — stub/mock the network layer.
  Anything that needs a live AO3 response gets checked by hand on-device
  or in the desktop emulator.
- AO3 has no official API and its terms don't allow bulk automated
  scraping — this plugin only ever fetches things the logged-in user's own
  account can already see, and requests should be spaced out, not fired in
  a tight loop.
- Commit messages: short imperative summary line (e.g. `Add AO3 login
  flow`), body only if the "why" isn't obvious from the diff.
- Prefer one feature per session/branch (e.g. "login", "search",
  "download") — keeps sessions easy to review and easy to pick back up.

## Roadmap (v1 scope, as agreed)

1. AO3 login + session cookie storage — done, see Status
2. "Marked for Later" list → browsable menu — done, see Status
3. Search AO3 by title/tag — done, see "Added: search()..." below
4. Fetch a work's direct EPUB download link and save it where KOReader's
   library expects new books — not started; the last major roadmap item
5. (stretch) quick-look at a work's summary/metadata before downloading —
   done, see "Added: rich work metadata..." below

## Status

`login()` is implemented, unit-tested, **and confirmed working against the
real archiveofourown.org** (verified with `scripts/smoke_test_login.lua`).
The field names documented in `ao3client.lua` are correct as of this check.

`getMarkedForLater()` and `getMyWorks()` (AO3's "My Works" page — every work
the logged-in user has posted themselves) are implemented, unit-tested, and
**confirmed working against the real archiveofourown.org** — both now
return real parsed results on-device, after fixing the Cloudflare
cookie-handling bug described below. Their HTML parsing was originally
designed from secondary sources (other AO3 tools' selectors), not from
directly inspecting real pages' markup, but the live test raised no sign of
a parsing mismatch. They share almost all of their code
(`fetchWorkListing()` + `parse_work_listing()`; the only difference is the
URL and what an author-less blurb falls back to — "Anonymous" for Marked
for Later, the logged-in username for My Works, since AO3 just doesn't
bother linking "by yourself" on your own works page). Design notes for
whoever picks this up:

- `AO3Client.new(http_request)` takes an optional HTTP function so tests can
  inject a fake transport; the real one (`default_http_request`, using
  `ssl.https` + `ltn12`) is only `require`d lazily, so running the tests
  doesn't need LuaSec installed at all.
- Cookie extraction deliberately doesn't do general cookie parsing: it
  pattern-matches for specific cookie names (`_otwarchive_session`, plus
  Cloudflare's `__cf_bm`/`_cfuvid` — see "Fixed: Cloudflare's bot-management
  cookies were dropped" below) one at a time, to sidestep a known LuaSocket
  gotcha where repeated `Set-Cookie` headers get comma-joined and cookie
  expiry dates (which contain commas) mangle the result.
- There's no HTML/DOM library available to a plain KOReader Lua plugin, so
  parsing is done with plain string patterns. `split_work_blurbs()` anchors
  on `id="work_<id>" class="...blurb..."`, which several independent AO3
  tools agree is how every work-listing page marks up one entry, then
  slices the page "up to the next work's id" rather than trying to find a
  matching closing `</li>` (nested `<li>`s inside a work's tags make that
  unreliable with plain patterns). Only page 1 is read — AO3 paginates
  these lists, and later pages are a follow-up, not done yet.
- If real works come back with a wrong/empty title or the wrong
  Anonymous/username fallback, that's the first place to look: the `<h4>`
  title/author markup was inferred from other tools' code, not seen
  directly, the same caveat login's field names had before being checked
  for real.

`main.lua` now has real UI, not just menu stubs: a combined account menu
item (see below), "Marked for Later" and "My Works" (each fetches the real
list and shows it as a `Menu` — tapping a work currently just shows its
AO3 URL in an `InfoMessage`, since there's nothing to download yet), and
"Search AO3" (still a stub — `AO3Client:search()` doesn't exist yet, so it
just says so). As of this session these are no longer nested inside
KOReader's Tools menu at all — they're flat items under AO3 Reader's own
top-level tab, installed by `menu_setup.lua`. See "AO3 Reader's own menu
tab" below for how and why.

Design notes on the UI layer:
- One `AO3Client` instance lives on the plugin for its whole lifetime
  (`self.ao3`, created in `init()`). Nothing is persisted to disk yet —
  logging in again is currently the only way to get a session back after a
  KOReader restart. Persisting `session_cookie` + username (never the
  password) via `G_reader_settings` is a reasonable follow-up.
- Every blocking network call (login, Marked for Later, My Works) is
  wrapped in `NetworkMgr:runWhenOnline(...)`, so it waits for Wi-Fi instead
  of failing outright when it's off (the normal state on a Kindle to save
  battery) — this matters much more on a real Kindle than in the WSL
  emulator, where networking is already up. Each also shows an
  `InfoMessage` + `UIManager:forceRePaint()` right before its blocking call
  (see "Known issue" below for why that matters), closed once the call
  returns. `showMarkedForLater()` and `showMyWorks()` share this whole
  fetch/loading/empty/error/list dance via `showWorkListing()` — they only
  differ in which `AO3Client` getter they call and their on-screen strings.
- The account item (`menu_items.ao3_account`) is one entry that switches on
  login state via `text_func` / `sub_item_table_func` (both re-evaluated by
  KOReader's `touchmenu.lua` on every tap, which is what makes this track
  login state without needing the menu rebuilt): logged out it reads
  "Public" and tapping opens a one-item submenu ("Log in to AO3"); logged
  in it shows the username and tapping opens a two-item submenu, "My
  Works" above "Log out". Both states are genuine submenus
  (`sub_item_table_func` never returns `nil`), which avoids a
  submenu-arrow-always-shows cosmetic quirk an earlier version of this had.
  "My Works" moved here (it was briefly a flat top-level item, a sibling of
  "Marked for Later"/"Search AO3") because it's specifically about the
  logged-in account, not a peer of the other two — `menu_setup.lua`'s
  `TAB_ITEM_IDS` dropped `"ao3_my_works"` to match; see "AO3 Reader's own
  menu tab" below for how an already-installed tab picks up an item-list
  change like this one without the user having to do anything.
- None of `main.lua` (or `menu_setup.lua`) is covered by the busted suite —
  both depend on real KOReader (widgets that only exist inside a running
  KOReader; `DataStorage`, the settings directory, and the real menu-order
  modules for `menu_setup.lua`). Verifying either means actually running
  the emulator or a device, not `busted`.

## AO3 Reader's own menu tab

Ask changed twice on how to cut down taps to reach this plugin. First
try was a KOReader `Dispatcher`-registered action bindable to a gesture
(Settings -> Taps and gestures) — dropped per later feedback: wanted
something usable without a setup step, not a gesture binding. Second ask
was literally an icon in KOReader's top status-bar row (Wi-Fi,
frontlight, etc.) — checked `readermenu.lua` directly: that row is
hardcoded core UI, no extension point for a `.koplugin` to add to it.
Actual answer, found by inspecting a real KOReader install (this
project's Kindle files, mounted read-only for reference) rather than
guessing: **a whole new top-level tab**, a real peer of Tools/Search/
Settings, which is what was actually wanted ("a menu like Tools, Search,
Settings etc").

How it works — confirmed by reading KOReader's own source
(`frontend/ui/menusorter.lua`, `frontend/ui/elements/reader_menu_order.lua`
/ `filemanager_menu_order.lua`, `frontend/ui/widget/iconwidget.lua`), not
assumed:

- KOReader's reader and file-manager menus each build their top tab row
  (`["KOMenu:menu_buttons"]`) from a built-in order table, but
  `MenuSorter:readMSSettings()` also checks for a user override file —
  `settings/reader_menu_order.lua` / `settings/filemanager_menu_order.lua`
  — and merges any keys it finds on top. This is a real, documented
  KOReader customization point (not a hack), but the files are
  KOReader-wide, not private to this plugin.
- `menu_setup.lua`'s `ensureTabInstalled()` writes to both of those files:
  it reads whatever's there already (or KOReader's own built-in default, if
  nothing's been customized yet), appends `"ao3reader"` to the tab row if
  it's not there yet, and sets `["ao3reader"]` to `TAB_ITEM_IDS`
  (`{"ao3_account", "ao3_marked_for_later", "ao3_search"}` as of this
  session), writing the merged result back. It never touches any other key
  already in the file. It skips the write entirely once both the tab row
  and `["ao3reader"]`'s item list already match — see the "no longer
  treats the whole tab as install-once" note further down for why the item
  list specifically stays synced instead of being frozen forever like the
  original version of this did.
- A new tab also needs an icon: `ui/widget/iconwidget.lua` checks
  `DataStorage:getDataDir() .. "/icons"` for a same-named `.svg`/`.png`
  before falling back to KOReader's own bundled set. `ensureIconInstalled()`
  copies `icon/ao3.svg` there once. That icon is a plain hand-drawn
  placeholder (a rectangle with a slit down the middle, evenodd-cut so the
  slit is a real hole, not an overlay — no existing KOReader icon fit
  "AO3", and drawing an exact copy of AO3's own branding felt like the
  wrong reference anyway for a personal tool). Trivial to swap for
  something better later — replace `icon/ao3.svg` and delete the copy
  under `<KOReader data dir>/icons/ao3.svg` so `ensureIconInstalled()`
  re-copies it.
- `menu_items.ao3reader` itself is now the tab (`{icon = "ao3"}`, no text —
  exactly how `readermenu.lua`'s own `tools`/`search`/`setting` entries are
  defined), and `ao3_account`/`ao3_marked_for_later`/`ao3_search` are flat
  sibling items under it, the same way `read_timer`/`calibre`/etc. sit flat
  under the built-in `tools` tab — not nested inside `menu_items.ao3reader`
  itself. `ao3_my_works` is deliberately not one of these three: "My Works"
  now lives inside the account item's own submenu instead (see the Status
  section above) since it's about the logged-in account specifically, not
  a peer of "Marked for Later"/"Search AO3".
- The new tab lands last (rightmost, after "main") in both menus, since
  `ensureTabInstalled()` just appends to whatever tab row it finds. Not
  tried yet on-device, so unconfirmed whether that's actually the best
  spot — easy to change later (either re-order by hand in the settings
  files, or ask to change where `patchOrderFile()` inserts `"ao3reader"`).
- `patchOrderFile()` no longer treats the whole tab as "installed, never
  touch again" once `existing[TAB_ID]` exists. It still only ever *adds*
  `"ao3reader"` to the shared tab row and never reorders or touches any
  other tab there — that part hasn't changed. But the item list *inside*
  our own tab (`existing[TAB_ID]` itself) is now kept in sync with
  `TAB_ITEM_IDS` on every call (a plain list-equality check decides whether
  a rewrite is needed at all, so a normal restart still doesn't rewrite the
  file every time). This changed because it had to: this plugin's own item
  list already changed once during development (dropping `"ao3_my_works"`
  when it moved into the account submenu — see below), and without this,
  an already-installed tab on a device that had run an earlier version
  would keep pointing at a `menu_items` key that no longer exists. Nothing
  else in either settings file is touched by this.

## Fixed: wrong credentials were read as a successful login

Second live-test finding: logging in with a wrong username/password still
showed as logged in (username shown in the account menu instead of
"Public"), and then behaved strangely on "Marked for Later" (since it was
never really authenticated, whatever `login()` handed it as a session
cookie wasn't a working one).

Root cause, confirmed against AO3's own source (`otwcode/otwarchive` is
plain Devise underneath `Users::SessionsController`, not custom auth):
`login()`'s check —"302/303 means success, 200 means failure"— was wrong.
**AO3 redirects (302) on a rejected login too** — Devise's stock failure
handling 302s straight back to `/users/login` with a flash error, it
doesn't re-render the form inline. And the `_otwarchive_session` cookie
gets set/rotated on that redirect regardless of whether the login actually
succeeded, since flash messages and the CSRF token both touch the Rails
session on every request. So a wrong password produced exactly the same
`(302, has a session cookie)` shape `login()` was treating as proof of
success.

The part that actually differs is the redirect *target*: success goes to
`/users/<username>` (or a preserved deep link), failure goes back to
`/users/login`. Fix: `login()` now also checks the POST response's
`Location` header and rejects the login if it points back at
`/users/login`, before ever looking at the cookie. Two things changed in
the tests (`spec/ao3client_spec.lua`): the existing "logs in" test now
includes a realistic `Location: .../users/someuser` header, and a new test
asserts rejection when `Location` points back at `/users/login` despite a
302 status and a cookie being present — the exact shape of the original bug.

Not independently re-verified against a live wrong-password attempt yet
(same caveat as everything else in this section) — next session's
checklist below covers it.

## Known issue: login/list requests could hang the whole UI (mitigated)

The emulator froze completely on "Log in to AO3" — no visible response at
all, not even the "typing" cursor blinking. Root cause: `login()` and
`getMarkedForLater()` both call `ssl.https.request()` synchronously, on
KOReader's single UI thread, with nothing bounding how long that call can
take:

- LuaSec's `https.request()` has a hardcoded 60s timeout covering the TCP
  connect and the TLS handshake — and explicitly refuses a caller-supplied
  `create` function, so there's no way to shorten *that* part through its
  public API. But that timeout doesn't cover the read loop afterwards: a
  server that trickles back a byte every few seconds could stall the
  request (and, since it's synchronous, the whole UI) indefinitely.
- DNS resolution isn't covered by any of this at all. It happens before a
  socket even exists, so neither LuaSec's timeout nor LuaSocket's
  `settimeout()` bounds it (confirmed against LuaSocket's own docs). If
  the emulator's environment (e.g. WSL2's resolver) can't resolve
  `archiveofourown.org`, or is just slow to, the request can hang well
  past 60 seconds with no error ever surfacing.

Fix applied in `default_http_request()`: it now wraps the request with
KOReader's own `socketutil` module (`socketutil:set_timeout(LARGE_BLOCK_TIMEOUT,
LARGE_TOTAL_TIMEOUT)` / `socketutil:reset_timeout()`), the same mechanism
every other KOReader online plugin (wallabag, opds, ...) uses. That bounds
both a single read and the request as a whole to well under a minute, so a
stalled *connection* now fails with a clear error instead of hanging
forever. It does **not** fix a hung DNS lookup — that's still outside
Lua's control here.

If the freeze comes back (screen stays frozen for much longer than ~30s,
with no "AO3 login failed" message ever appearing): the next diagnostic
step is checking whether the WSL2 emulator's networking, not the plugin,
is the problem — e.g. from a plain WSL terminal (not the emulator),
`curl -v --max-time 10 https://archiveofourown.org` and `cat
/etc/resolv.conf`. WSL2's auto-generated resolver (which proxies DNS
through the Windows host) is a known source of flaky/hanging DNS,
especially after sleep/resume or a VPN/network change — if `curl` hangs or
fails too, that points there rather than at this plugin's code.

Not yet implemented: `search()`, `getDownloadUrl()`.

## First live test: Marked for Later came back empty, My Works timed out

First real on-device test of `getMarkedForLater()`/`getMyWorks()` (a real
account, logged in, with actual entries in "Marked for Later" and zero
published works). Results:

- **Marked for Later showed "Nothing in Marked for Later" despite the
  account genuinely having entries** (confirmed by opening the same URL —
  `/users/<name>/readings?show=to-read` — in a real browser). Checked the
  real markup this generates by reading AO3's own source
  (`otwcode/otwarchive` on GitHub, `app/views/readings/_reading_blurb.html.erb`
  and `app/views/works/_work_blurb.html.erb`): both partials render
  `id="work_<id>" class="...blurb..."` in the same shape, sharing the same
  `works/work_module` partial for the title/author markup — so
  `split_work_blurbs()`/`parse_work_listing()` should structurally handle
  both pages identically, and there's no evidence of a page-specific parsing
  bug. That points at a different, and quietly dangerous, bug: **before this
  fix, any HTTP 200 response that didn't contain matching blurb markup was
  read as "an empty list", with no way to tell that apart from a real
  rejected/expired session.** If AO3 responded with something other than the
  listing page — most plausibly its own login page, if the session cookie
  was rejected for that specific request, or a redirect that got followed
  transparently into one — that would explain exactly what was seen: silence
  where an error should have been.
  - Fix: `fetchWorkListing()` now calls a new `looks_like_login_page(body)`
    check (reusing the exact `user[login]` form-field name `login()` already
    submits credentials to) before treating a 200 response as real results.
    If it matches, it now returns a clear error ("AO3 sent back the login
    page instead of your results — the session has likely expired") instead
    of silently reporting zero works. Two regression tests added (one per
    getter) in `spec/ao3client_spec.lua`.
  - Also added a `DEFAULT_USER_AGENT` header, now sent (and merged under any
    caller-supplied headers) on every request in `default_http_request()`.
    AO3's terms ask automated tools to identify themselves, and a
    missing/generic User-Agent is also a common trigger for anti-bot
    blocking on sites like this — a plausible independent contributor to
    getting served something other than the real page. Genuinely honest,
    not a browser-impersonation string.
  - **Confirmed correct**: the next live test did show the "session has
    likely expired" error on both getters (not silence), proving the
    login-page detection itself works as designed. The *why* behind the
    rejection turned out to be a real cookie-handling bug, not a page-
    specific quirk — see "Fixed: Cloudflare's bot-management cookies were
    dropped" below.
- **My Works timed out** ("could not reach AO3 (timeout)") for an account
  with zero published works — which per AO3's own `WorksController#index`
  source has no special-case redirect or slow path for zero results, it just
  renders the same page with an empty `<ol>`. A real socket-level timeout
  (`ok` came back falsy) happens before any of the parsing/session-detection
  logic above even runs, so this looks unrelated to the Marked-for-Later
  bug — most likely the same category of flakiness already documented below
  ("Known issue: login/list requests could hang the whole UI"), i.e.
  Wi-Fi/DNS/connection hiccups rather than a plugin bug. Not changed this
  session beyond what the User-Agent addition might incidentally help with
  (some anti-bot setups intentionally stall requests they're suspicious of,
  which would also present as a timeout) — if it recurs consistently
  (not just once) specifically on My Works and nothing else, that pattern
  itself would be a useful clue to bring back here.

**Confirmed in the follow-up session** (real emulator, real account, WSL2 +
WSLg): the top-level tab appears with its icon and the correct flat items
(also double-checked directly in `settings/filemanager_menu_order.lua`),
login with real credentials switches the account item to the username, and
— after the Cloudflare cookie fix below — both "Marked for Later" and "My
Works" return real, correctly parsed results. That closes out this
session's whole checklist except the items listed under "Next session"
below.

## Fixed: Cloudflare's bot-management cookies were dropped, breaking every request after login

Root cause of the "First live test" bug above, found by curling AO3's real
login page directly (not guessed): `archiveofourown.org` runs behind
**Cloudflare** (`server: cloudflare`), which sets two of its own cookies —
`__cf_bm` (Bot Management) and `_cfuvid` — on every response, alongside the
app's own `_otwarchive_session`. A real browser, and every working
unofficial AO3 client checked for comparison (e.g. `wendytg/ao3_api`, which
just uses Python's `requests.Session()` for its whole GET→POST→GET flow),
automatically keeps and resends *all* of a site's cookies. This plugin only
ever tracked `_otwarchive_session` and silently dropped the Cloudflare ones
— it didn't even resend the login page GET's cookies on the login POST
itself. Without them, Cloudflare has no way to recognize a follow-up
request as coming from the same client that just authenticated, so every
account-page request (`/users/<name>/readings?show=to-read`,
`/users/<name>/works` — exactly the two pages `getMarkedForLater()`/
`getMyWorks()` hit) got bounced back to the login page, even though
`login()` itself succeeded.

Fix, in `ao3client.lua`: a small generalized cookie jar. `merge_cookies()`
pulls `__cf_bm`/`_cfuvid` (listed in `EXTRA_COOKIE_NAMES`) out of *any*
response's `Set-Cookie` header the same way `_otwarchive_session` was
already extracted, and `AO3Client:buildCookieHeader()` combines whatever's
known (session cookie + Cloudflare cookies) into one `Cookie` header sent
on every request — including, now, the login POST itself, using cookies
picked up from the login page's own GET. Cookies are re-merged after every
response (login's GET and POST, and every `fetchWorkListing()` call), since
`__cf_bm` rotates periodically. `session_cookie`'s own meaning is
unchanged, so this didn't require touching any test that asserted on it
directly. Two regression tests added in `spec/ao3client_spec.lua`: one
confirming the login POST resends cookies captured from the GET, one
confirming `getMarkedForLater()` sends the full cookie set and picks up a
rotated `__cf_bm` on the next call.

Confirmed fixed live: after this change, both "Marked for Later" and "My
Works" returned real results in the emulator against a real logged-in
account (see "Confirmed in the follow-up session" above) — no more
redirect-to-login on either getter.

## Added: search()

`AO3Client:search(query)` (`GET /works/search?work_search[query]=...`) is
implemented, unit-tested, and **confirmed working live** — it returns real
results in the emulator. Unlike the two account-only getters, it's public:
works whether or not `login()` has ever succeeded.

Important subtlety found while building it, from fetching a real, logged-out
AO3 search-results page directly (not guessed): **every AO3 page, logged out
or not, carries a "log in" mini-form in its own persistent header nav**,
using the exact same `name="user[login]"` field `looks_like_login_page()`
checks for. Reusing that check (or `fetchWorkListing()`, which uses it) for
`search()` would misread every real, logged-out search result as an expired
session. `search()` therefore does its own thing: a plain GET, a non-200
status is a real error, and a 200 with zero matching blurbs is just zero
results — the same way the other getters already treat an empty listing.
`looks_like_login_page()`'s own doc comment now calls this out explicitly so
it doesn't get reused somewhere else it doesn't belong.

Wired into `main.lua`: "Search AO3" opens a real `InputDialog` (its
`input_hint`/`getInputText()`/`is_enter_default` API was checked against
KOReader's own source at `~/koreader/frontend/ui/widget/inputdialog.lua`
before use, not guessed) and reuses `showWorkListing()`, which gained a
`requires_login` parameter for this (`false` for search, `true` for the two
account-only getters) since search doesn't need the "log in first" gate.

## Added: rich work metadata (rating, warnings, tags, summary, chapters, words)

`parse_work_listing()` (shared by all three getters — `search()`,
`getMarkedForLater()`, `getMyWorks()`) now also extracts, per work: `rating`,
`category`, `status` (Complete Work / Work in Progress — from the four
"required tags" badges, whose `title="..."` attribute is AO3's own
human-readable text, no internal-code decoding needed), `warnings` (a list
— a blurb can have more than one), `tags` (everything in the blurb's "Tags"
section — warnings/characters/relationships/freeform together, in AO3's own
order), `words` (a number), `chapters` (raw "x/y" text), and `summary`
(plain, entity-decoded, multi-paragraph text, HTML-stripped by a new
`strip_summary_html()` — not a general HTML-to-text converter, just enough
for AO3's own simple rich-text summaries). Every field but
`id`/`title`/`author`/`url` is nil/empty rather than an error when a
particular blurb doesn't have that markup (e.g. no summary written).

All of this was written against real markup fetched directly from a live
AO3 search-results page (saved while building `search()`), not inferred
from other tools — `spec/ao3client_spec.lua`'s new fixture is that same
real blurb, trimmed. One consequence worth knowing: AO3 renders one `<li>`
per repeated tag of the same kind (confirmed from a blurb with several
`<li class='characters'>` entries) rather than one `<li>` holding a
comma-separated list — `extract_tag_group()` accounts for this, but the
multi-*warning* case specifically is inferred from that same pattern, not
independently observed on a real multi-warning work.

`main.lua`'s work-listing Menu now shows this in a scrollable `TextViewer`
(tapping a work) instead of the old plain `InfoMessage` with just the URL —
`formatWorkDetails()` assembles rating/category/status/warnings/word+chapter
counts/tags/summary/url into one readable block, omitting whichever fields
a given work doesn't have.

## Fixed: login() trusted its own success heuristic without verifying the session actually worked

Follow-up to the Cloudflare cookie bug above, from live testing: a report
that "login still doesn't work" turned out to be about trust, not failure —
`login()`'s redirect-target check (302 to `/users/<username>`, not back to
`/users/login`) is exactly the same shape a *successful-looking but
non-functional* login has, which is precisely what the Cloudflare cookie bug
was. Trusting that heuristic alone, and only finding out the session didn't
really work on the next unrelated request, isn't good enough.

Fix: `login()` now confirms the session it just captured against a real
account-only page — "Marked for Later" specifically, since it's already
confirmed (from this plugin's own bug history) to genuinely require a
working session, unlike e.g. a user's public profile or "My Works" page,
which anyone can view logged out. Only if that comes back `200` and doesn't
look like the login page does `login()` report success; otherwise it rolls
`session_cookie` back to `nil` and returns an error, same as a rejected
password. This costs one extra request per login but happens once, not per
listing fetch. `looks_like_login_page()` was moved earlier in the file (it's
now needed inside `login()`, which is defined before where it used to live)
— purely a reordering, its behavior is unchanged. 5 new tests cover the
verify-passes, verify-shows-login-page, verify-non-200, verify-request-fails,
and verify-sends-accumulated-cookies cases.

**First live retest of this fix found a second, real bug it exposed**: "even
a genuine account gets rejected." Root cause — AO3's login field accepts
either a username or the account's email (same Devise `user[login]` field
either way), but `login()` was building the verify URL (and setting
`self.username`) from whatever was literally typed into the login form. For
anyone who logs in with their email (common), `/users/<url-encoded
email>/readings?show=to-read` isn't a real AO3 URL — it 404s, and the new
verify step correctly-per-its-own-logic, but wrongly, rejected a perfectly
valid login. This was a real logic bug, not a network/timing flake, and was
found by re-reading the code rather than more live trial-and-error: the
success redirect (`Location: .../users/<username>`) already names AO3's own
canonical username for the account regardless of how the person logged in,
so `login()` now extracts and uses *that* (`canonical_username`) for the
verify URL and for `self.username`, falling back to the typed value only if
the redirect didn't have the expected `/users/<name>` shape. Also: the two
verify-failure error messages now include the actual HTTP status from the
verification request, so a future live failure carries real diagnostic
information instead of a generic "try again." New regression test: login by
email address, confirming `self.username` ends up as the redirect's real
username, not the email.

**Second live retest found the actual root cause**, reported as "login
always returning code 200." This time confirmed with a controlled
experiment against the real site (curl, not KOReader) rather than more
guessing: replicated `login()`'s exact GET-then-POST flow twice, identical
except for one variable. **Without** resending the GET's own
`_otwarchive_session` cookie on the POST, AO3 redirects (302) to
`/auth_error` ("Session Expired") — a Warden-level CSRF/session rejection
that happens *before* Devise ever looks at the credentials, regardless of
whether they're correct. **With** it, the POST returns 200 with a genuine
flash-error cookie (`flash_is_set=1`) — AO3 actually evaluating the
credentials for real, the shape `login()`'s existing 200-means-rejected
check already expected. Root cause: Rails' default cookie-based session
store keeps the CSRF secret *inside* the session cookie itself, not
server-side, so the anonymous session the login-page GET establishes has to
be sent back on the POST for the submitted `authenticity_token` to validate
at all — `login()` extracted the token from that GET's body but never
resent the cookie carrying its secret.

Fix: `login()` now captures the GET's own `_otwarchive_session` value
(`pre_login_session`, kept as a local, not folded into `self.extra_cookies`/
`buildCookieHeader()` — it's only relevant for the one POST immediately
below, and would otherwise leave a stale pre-login value sitting around
after a real session, or a rejection, is known moments later) and sends it
back alongside the Cloudflare cookies on the POST. Separately, also
hardened the failure-redirect check: `/auth_error` is confirmed to be a
distinct redirect target from `/users/login` for a rejection, and wasn't
being checked for at all before — a login that failed this way would have
looked "successful" (redirect status without the `/users/login` substring)
and been silently accepted, right up until the verify step. Both are
independently real bugs; the second is now effectively unreachable in
normal operation once the first is fixed, but is still correctly handled if
it ever comes up some other way. 4 new regression tests.

**Not yet re-confirmed live on-device** as of writing — the curl experiment
proves the underlying HTTP mechanics, but nobody has yet seen this actual
code path run inside the real emulator/KOReader. Next session's first item.

Next session:
- Live-retest login end-to-end with both the verification step and the
  canonical-username fix: does a real login (by username, and separately by
  email if that's what's normally used) now correctly report success?
- Live-retest a deliberately wrong password (error shown, account menu
  stays "Public") — still not re-confirmed since the original wrong-password
  fix; also now exercises a second rejection path (the verify step) that a
  wrong password should never actually reach.
- Check Tools -> Plugin management shows "AO3 fic search" with its
  description — not yet checked on a real KOReader build.
- Peek at `settings/reader_menu_order.lua` (the reader-mode, as opposed to
  file-manager, tab order file) to confirm it matches
  `filemanager_menu_order.lua`'s already-confirmed shape.
- `getDownloadUrl()` is the one remaining unimplemented roadmap item (see
  its TODO in `ao3client.lua`) — fetching a work's EPUB link and saving it
  where KOReader's library expects new books.
- Consider whether `tags`/`warnings` should be split further (e.g.
  separating characters/relationships/freeform tags instead of one flat
  list) once there's an actual UI need for that distinction — deliberately
  kept as one flat list for now (see "Added: rich work metadata" above).
