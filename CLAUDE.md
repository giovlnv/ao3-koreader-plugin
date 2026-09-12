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

1. AO3 login + session cookie storage
2. "Marked for Later" list → browsable menu
3. Search AO3 by title/tag
4. Fetch a work's direct EPUB download link and save it where KOReader's
   library expects new books
5. (stretch) quick-look at a work's summary/metadata before downloading

## Status

`login()` is implemented, unit-tested, **and confirmed working against the
real archiveofourown.org** (verified with `scripts/smoke_test_login.lua`).
The field names documented in `ao3client.lua` are correct as of this check.

`getMarkedForLater()` and `getMyWorks()` (AO3's "My Works" page — every work
the logged-in user has posted themselves) are implemented and unit-tested
(11 tests between them, all mocked) but **neither is yet verified against
the real site** — unlike login, their HTML parsing was designed from
secondary sources (other AO3 tools' selectors), not from directly
inspecting real pages' markup. They share almost all of their code
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
  pattern-matches for `_otwarchive_session=...` specifically, to sidestep a
  known LuaSocket gotcha where repeated `Set-Cookie` headers get
  comma-joined and cookie expiry dates (which contain commas) mangle the
  result.
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
  in it shows the username and tapping opens a one-item submenu ("Log
  out"). Both states are genuine submenus (`sub_item_table_func` never
  returns `nil`), which avoids a submenu-arrow-always-shows cosmetic quirk
  an earlier version of this had.
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
- `menu_setup.lua`'s `ensureTabInstalled()` writes to both of those files,
  once: it reads whatever's there already (or KOReader's own built-in
  default, if nothing's been customized yet), appends `"ao3reader"` to the
  tab row, adds `["ao3reader"] = {"ao3_account", "ao3_marked_for_later",
  "ao3_my_works", "ao3_search"}`, and writes the merged result back. It
  never touches any other key already in the file, and does nothing at all
  once `["ao3reader"]` is already present — so a normal restart doesn't
  keep rewriting these files, and any later hand-edits to them (reordering
  our tab's items, say) stick.
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
  defined), and `ao3_account`/`ao3_marked_for_later`/`ao3_my_works`/
  `ao3_search` are flat sibling items under it, the same way `read_timer`/
  `calibre`/etc. sit flat under the built-in `tools` tab — not nested
  inside `menu_items.ao3reader` itself.
- The new tab lands last (rightmost, after "main") in both menus, since
  `ensureTabInstalled()` just appends to whatever tab row it finds. Not
  tried yet on-device, so unconfirmed whether that's actually the best
  spot — easy to change later (either re-order by hand in the settings
  files, or ask to change where `patchOrderFile()` inserts `"ao3reader"`).

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

Next session: with the emulator running (symlink `ao3.koplugin` into
`koreader/plugins/`, per docs/SETUP.md) — this session's whole top-level-tab
mechanism (`menu_setup.lua`) has never run against a real KOReader, so
treat all of it as unverified, not just the usual "check the HTML parsing"
caveat:
- Confirm a new tab actually appears (both in the file manager and after
  opening a book), showing the icon, not a "missing icon" placeholder.
- Confirm tapping it shows "Public", "Marked for Later", "My Works", and
  "Search AO3" as flat items — if it instead falls back into the Tools
  menu as before, `menu_setup.lua`'s write likely failed silently (it never
  raises, only `logger.warn`s — check `crash.log` for "ao3reader:" lines).
- Log in with real credentials and confirm the account item switches to
  the username with "Log out" in its submenu; try "Marked for Later" and
  "My Works" — this is also the first real, end-to-end check of both
  getters' HTML parsing against the live site (still unverified per the
  note above). If titles/authors look right, move on to `search()`; if
  not, the parsing assumptions in `ao3client.lua` are the first thing to
  revisit.
- Peek at `settings/reader_menu_order.lua` and `settings/
  filemanager_menu_order.lua` afterwards to sanity-check what actually got
  written.
- Check Tools -> Plugin management (or wherever this KOReader build lists
  plugins) shows "AO3 fic search" with its description — confirms
  `_meta.lua` is well-formed and actually found.
