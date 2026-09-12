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
  - `main.lua` — KOReader integration only (menu entries, widgets). No
    HTTP or HTML-parsing logic belongs here.
  - `ao3client.lua` — all AO3 HTTP/parsing logic. Framework-agnostic on
    purpose so it can be unit tested with `busted` without a running
    KOReader instance.
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

`getMarkedForLater()` is implemented and unit-tested (5 more tests, all
mocked) but **not yet verified against the real site** — unlike login, its
HTML parsing was designed from secondary sources (other AO3 tools'
selectors), not from directly inspecting a real "Marked for Later" page's
markup. Design notes for whoever picks this up:

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
  `getMarkedForLater()` parses with plain string patterns. `split_work_blurbs()`
  anchors on `id="work_<id>" class="...blurb..."`, which several independent
  AO3 tools agree is how every work-listing page marks up one entry, then
  slices the page "up to the next work's id" rather than trying to find a
  matching closing `</li>` (nested `<li>`s inside a work's tags make that
  unreliable with plain patterns). Only page 1 is read — AO3 paginates this
  list, and later pages are a follow-up, not done yet.
- If real works come back with a wrong/empty title or "Anonymous" for an
  author who does have one, that's the first place to look: the `<h4>`
  title/author markup was inferred from other tools' code, not seen
  directly, the same caveat login's field names had before being checked
  for real.

Not yet implemented: `search()`, `getDownloadUrl()`.

`main.lua` now has real UI, not just menu stubs: "Log in to AO3" (a
`MultiInputDialog` with username + password fields), "Log out", and
"Marked for Later" (fetches the real list and shows it as a `Menu` —
tapping a work currently just shows its AO3 URL in an `InfoMessage`, since
there's nothing to download yet). "Search AO3" is still an empty stub —
`AO3Client:search()` doesn't exist yet to call. The menu's `sorting_hint`
is now `"tools"`, so it's under KOReader's top-level Tools menu instead of
buried in Search, for faster access while testing.

Design notes on the UI layer:
- One `AO3Client` instance lives on the plugin for its whole lifetime
  (`self.ao3`, created in `init()`). Nothing is persisted to disk yet —
  logging in again is currently the only way to get a session back after a
  KOReader restart. Persisting `session_cookie` + username (never the
  password) via `G_reader_settings` is a reasonable follow-up.
- Both the login call and the Marked for Later fetch are wrapped in
  `NetworkMgr:runWhenOnline(...)`, so they wait for Wi-Fi instead of
  failing outright when it's off (the normal state on a Kindle to save
  battery) — this matters much more on a real Kindle than in the WSL
  emulator, where networking is already up.
- None of `main.lua` is covered by the busted suite — it's all real
  KOReader widgets (`MultiInputDialog`, `Menu`, `InfoMessage`,
  `NetworkMgr`), which only exist inside a running KOReader. Verifying it
  means actually running the emulator or a device, not `busted`.

Next session: with the emulator running (symlink `ao3.koplugin` into
`koreader/plugins/`, per docs/SETUP.md), check the Tools menu shows "AO3
Reader", try "Log in to AO3" with real credentials, then "Marked for
Later" — this is also the first real, end-to-end check of
`getMarkedForLater()`'s HTML parsing against the live site (still
unverified per the note above). If titles/authors look right, move on to
`search()`; if not, the parsing assumptions in `ao3client.lua` are the
first thing to revisit.
