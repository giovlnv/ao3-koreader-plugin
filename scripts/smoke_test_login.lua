--[[--
Manual, one-off check that AO3Client:login() still works against the real
archiveofourown.org — not part of the automated test suite (busted never
makes real network calls; see spec/ao3client_spec.lua).

Run this whenever a real login attempt from the plugin fails unexpectedly,
to find out fast whether AO3 changed something (its login field names, its
CSRF setup, etc.) versus a bug in our own code.

Credentials come from environment variables so they never end up in a file,
in git, in shell history (as long as you use the env-var-prefix form below,
not `export`), or pasted into a chat with anyone, Claude included.

Usage (from the repo root, inside WSL/Ubuntu):
    luarocks install --local luasec   # one-time; only this script needs it
    AO3_USER='your-username-or-email' AO3_PASS='your-password' \
        luajit scripts/smoke_test_login.lua
]]

package.path = "./ao3.koplugin/?.lua;" .. package.path

local AO3Client = require("ao3client")

local username = os.getenv("AO3_USER")
local password = os.getenv("AO3_PASS")

if not username or not password then
    print("Set AO3_USER and AO3_PASS environment variables first — see the")
    print("comment at the top of this script for the exact command.")
    os.exit(1)
end

print("Attempting login as " .. username .. " ...")

local client = AO3Client.new()
local ok, err = client:login(username, password)

if ok then
    print("Login succeeded.")
    print("Session cookie (first 20 chars): " .. client.session_cookie:sub(1, 20) .. "...")
    os.exit(0)
else
    print("Login failed: " .. tostring(err))
    print("If this is unexpected, the first thing to check is whether")
    print("archiveofourown.org's login form still uses the field names")
    print("documented at the top of ao3.koplugin/ao3client.lua.")
    os.exit(1)
end
