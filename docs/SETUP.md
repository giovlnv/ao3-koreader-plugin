# Development environment setup (Windows 10)

## 1. WSL2 + Ubuntu

KOReader has no native Windows build, so the desktop emulator (used for
fast iteration without copying files to the Kindle every time) runs inside
WSL2.

1. Open PowerShell **as Administrator** and run:
   ```powershell
   wsl --install
   ```
   This turns on the WSL + Virtual Machine Platform Windows features and
   installs Ubuntu by default. Reboot when prompted.
   - If that command fails (older Windows 10 builds sometimes need the
     features enabled by hand):
     ```powershell
     dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
     dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
     ```
     then reboot and run `wsl --install -d Ubuntu`.
2. Launch "Ubuntu" from the Start menu once, and set a Unix username and
   password when it asks.
3. Confirm it's actually WSL**2**, not WSL1:
   ```powershell
   wsl -l -v
   ```
4. Install the VS Code extension **"WSL"** (`ms-vscode-remote.remote-wsl`).

### Cloning this repo into the Linux filesystem

WSL2 has two filesystems visible to it: its own Linux one (fast, where
`~` = `/home/<your-linux-username>`) and Windows' one mounted at
`/mnt/c/...` (works, but noticeably slower for git status/builds with lots
of small files — the Windows folder you already have, e.g.
`/mnt/c/Users/giova/Documents/github/...`, is reachable from WSL this way,
but it's not where you want KOReader's build living). So this becomes a
**second, separate clone** of the same GitHub repo — one copy on the
Windows side (already there, from publishing earlier), one inside Ubuntu
(for building/testing). Git keeps them in sync via push/pull, not by
sharing files directly.

One-time setup, in the **Ubuntu terminal** (Start menu → Ubuntu):
```bash
sudo apt update && sudo apt install -y git
git config --global user.name "your name"
git config --global user.email "the email your GitHub account uses"
```

Then clone, from your Linux home directory:
```bash
cd ~
mkdir -p projects && cd projects
git clone https://github.com/<you>/ao3-koreader-plugin.git
```
If the repo is private, this first clone will ask for GitHub credentials —
easiest is to install the GitHub CLI (`sudo apt install gh`) and run
`gh auth login` once, which then makes `git clone`/`git push` work without
further prompts.

Once it's cloned, open it in VS Code from right there:
```bash
cd ao3-koreader-plugin
code .
```
The first time, this triggers VS Code to install its "server" component
inside WSL, then reopens the window connected to WSL — you'll see
"WSL: Ubuntu" in the bottom-left corner instead of "Publish to GitHub".
From here on you get the exact same VS Code UI, including the Source
Control panel, just backed by Linux instead of Windows — that's the
day-to-day setup, terminal only as a fallback rather than the main way you
work.

**GUI alternative to the `git clone` command above**, if you'd rather stay
out of the terminal entirely once git itself is installed: connect to WSL
first (blue "><" icon, bottom-left → *Connect to WSL*), then use
**Source Control → Clone Repository → Clone from GitHub**, pick
`ao3-koreader-plugin`, and choose a folder under your Linux home (e.g.
`/home/<you>/projects`) when it asks where to put it.

Going forward, treat the WSL copy as the one you actually edit and commit
from (it's the one that can also run the emulator/tests) — the Windows
folder from the "Publish to GitHub" step can just sit there, or you can
delete it later, since it's redundant once the WSL clone exists.

## 2. Build and run the KOReader emulator (inside WSL/Ubuntu)

Follow KOReader's own build instructions, since exact commands can change
between releases:
https://github.com/koreader/koreader/blob/master/doc/Building.md

Roughly, inside the Ubuntu shell:
```bash
git clone https://github.com/koreader/koreader.git
cd koreader
./kodev build
./kodev run
```
The first build takes a while (it pulls a lot of submodules). Once it
launches, symlink this repo's plugin folder into it so edits show up after
an in-app restart, without rebuilding KOReader itself:
```bash
ln -s /path/to/ao3-koreader-plugin/ao3.koplugin ~/koreader/plugins/ao3.koplugin
```
(Restart KOReader from its own menu after each change — it's interpreted
Lua, so no rebuild step is needed for plugin code.)

## 3. Deploying to your Kindle

1. Connect the Kindle via USB — it should mount as a drive.
2. Copy the whole `ao3.koplugin` folder into `koreader/plugins/` on the
   Kindle (commonly `/mnt/us/koreader/plugins/`, depending on how KOReader
   was installed there).
3. Eject safely, then on the Kindle: KOReader menu → restart KOReader.

## 4. Running tests and lint (inside WSL/Ubuntu)

```bash
sudo apt install luarocks
luarocks install busted
luarocks install luacheck
```
Then, from the repo root:
```bash
busted
luacheck .
```

## 5. (Optional) Claude Code CLI, so Claude can actually run Lua here

The Claude sessions working on this project through Cowork (chat/cloud)
can't execute Lua at all — the cloud sandbox and the bridge into this
Windows machine both block package installs and outside network access
(apt, pip, npm, and direct downloads from lua.org/luarocks.org all get
refused). Every "not yet verified by busted" caveat in `CLAUDE.md` traces
back to that: those sessions can read and reason about the code, but
never actually run it.

Your WSL2 Ubuntu install doesn't have that restriction — it's your own
machine, with normal internet access. Installing the Claude Code CLI
*there* gives a Claude session a real shell in this exact environment,
able to install the toolchain from step 4 above and actually run
`busted`/`luacheck` itself, not just reason about whether they'd pass.

1. In a WSL2/Ubuntu terminal (not PowerShell):
   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   ```
   (npm install works too, but needs Node.js 22+ and doesn't auto-update —
   the script above is the simpler default.)
2. Check it installed: `claude --version`
3. From the repo root: `cd ~/projects/ao3-koreader-plugin && claude` — the
   first run opens a browser to log in (needs a Claude Pro/Max/Team/
   Enterprise plan, or a Console API account; the free Claude.ai plan
   doesn't include CLI access).
4. Nothing else to set up: Claude Code reads this repo's `CLAUDE.md`
   automatically on start, so it already has this project's conventions,
   architecture notes, and current status. Worth asking it, early on, to
   install the toolchain from step 4 and run `busted`/`luacheck` once —
   that's the first real confirmation this whole project has had that the
   test suite actually passes, rather than just reading right by eye.

## 6. Pushing to GitHub

Easiest path, entirely inside VS Code, no terminal needed:

1. Open this folder in VS Code (ideally through the WSL connection above).
2. Sign in to GitHub if it prompts you (Accounts icon, bottom-left).
3. Open **Source Control** (`Ctrl+Shift+G`) → **Publish to GitHub**. Pick a
   name (e.g. `ao3-koreader-plugin`) and public/private.

Terminal equivalent, kept here for troubleshooting:
```bash
git init
git add .
git commit -m "Initial scaffold"
git branch -M main
git remote add origin https://github.com/<you>/ao3-koreader-plugin.git
git push -u origin main
```
