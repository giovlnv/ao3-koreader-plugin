# AO3 Reader for KOReader

A KOReader plugin to browse your Archive of Our Own "Marked for Later" list,
search for fics, and download them (as EPUB) straight onto your Kindle.

Loosely inspired by [rakuyomi](https://github.com/hanatsumi/rakuyomi), but
much simpler: AO3 already generates EPUB/MOBI/PDF files for every work, so
this plugin never builds a book itself — it authenticates, finds works, and
fetches the file AO3 already made. That means pure Lua, no separate backend
process.

**Status:** early scaffold, not yet functional — see `CLAUDE.md` for the
roadmap and current state.

## Install (once it's working)

Copy the `ao3.koplugin/` folder into `koreader/plugins/` on your device
(commonly `/mnt/us/koreader/plugins/` on a Kindle) and restart KOReader.

## Development

See [`docs/SETUP.md`](docs/SETUP.md) for setting up WSL2, running the
KOReader desktop emulator, running tests/lint, and deploying to a Kindle for
real-device testing.
