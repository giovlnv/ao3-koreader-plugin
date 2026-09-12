--[[--
One-time setup that makes "AO3 Reader" its own top-level menu tab (next to
Tools, Search, Settings) instead of a submenu buried inside Tools, and
installs the icon that tab uses.

Both pieces write outside this plugin's own folder -- KOReader-wide files
and directories, not private to us -- so this module is deliberately
conservative:

- The icon just gets copied into KOReader's own user-icons directory (the
  first place ui/widget/iconwidget.lua looks for an icon by name, ahead of
  its own bundled set -- see DataStorage:getDataDir() .. "/icons" there).
  It's a plain file copy, skipped once the file already exists.
- The tab itself is added by writing to KOReader's own menu-order override
  files (frontend/ui/menusorter.lua's MenuSorter:readMSSettings(), which
  every menu -- reader and file manager -- already checks for a
  "<config_prefix>_menu_order.lua" in the settings directory, merging
  whatever keys it finds on top of the built-in defaults). This is a real,
  supported KOReader customization point, not a hack -- but the file is
  KOReader-wide, so this only ever ADDS our own tab id to the shared tab
  row, never touches or reorders anything else already there, and does
  nothing at all to that row once our tab id is already present.
  The item list *inside* our own tab (existing[TAB_ID]) is different: it's
  kept in sync with TAB_ITEM_IDS below on every call, since nothing but this
  plugin has a reason to touch it, and this plugin's own item list has
  already changed once during development -- see patchOrderFile()'s own
  comment for why "sync our part, never touch anyone else's" is the actual
  rule here, not "write once and never again".

None of this is covered by the busted suite -- like main.lua, it depends on
a real KOReader environment (DataStorage, the settings directory, the real
menu-order modules), not just plain Lua. Checked by hand in the emulator or
on-device instead.
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local MenuSetup = {}

-- Both of KOReader's main menus get the same treatment; see
-- frontend/apps/reader/modules/readermenu.lua and
-- frontend/apps/filemanager/filemanagermenu.lua, which each build their
-- "KOMenu:menu_buttons" tab row from ui/elements/<prefix>_menu_order.lua
-- merged with settings/<prefix>_menu_order.lua (if present).
local ORDER_CONFIG_PREFIXES = { "reader", "filemanager" }

local TAB_ID = "ao3reader"
local TAB_ITEM_IDS = { "ao3_account", "ao3_marked_for_later", "ao3_search" }
local ICON_NAME = "ao3"

--[[--
Copies this plugin's bundled icon/ao3.svg into KOReader's user-icons
directory, if it isn't there already. After this, any menu_items entry
anywhere can use `icon = "ao3"` and KOReader will find it -- see
ui/widget/iconwidget.lua's ICONS_DIRS, which checks
DataStorage:getDataDir() .. "/icons" before its own bundled icon sets.

@param plugin_dir string  this plugin's own folder (self.path from
  KOReader's plugin loader -- see main.lua's init())
]]
function MenuSetup.ensureIconInstalled(plugin_dir)
    local ok, err = pcall(function()
        local icons_dir = DataStorage:getDataDir() .. "/icons"
        if lfs.attributes(icons_dir, "mode") ~= "directory" then
            local made, mkdir_err = lfs.mkdir(icons_dir)
            if not made then
                error("could not create " .. icons_dir .. ": " .. tostring(mkdir_err))
            end
        end

        local dest = icons_dir .. "/" .. ICON_NAME .. ".svg"
        if lfs.attributes(dest) then
            return -- already installed, nothing to do
        end

        local source = plugin_dir .. "/icon/" .. ICON_NAME .. ".svg"
        local src_file = io.open(source, "rb")
        if not src_file then
            error("bundled icon missing at " .. source)
        end
        local svg_data = src_file:read("*a")
        src_file:close()

        local dest_file = io.open(dest, "wb")
        if not dest_file then
            error("could not open " .. dest .. " for writing")
        end
        dest_file:write(svg_data)
        dest_file:close()
    end)
    if not ok then
        -- Cosmetic only (KOReader falls back to a "not found" icon glyph
        -- if this never runs) -- never worth failing plugin init over.
        logger.warn("ao3reader: could not install tab icon:", err)
    end
end

-- Every value in one of these menu-order files is a flat array of strings
-- (item/tab ids, or the "----..." separator) -- see any of the
-- ui/elements/*_menu_order.lua files for what this format actually looks
-- like. That's the only shape serializeOrderTable() needs to handle.
local function serializeStringArray(array)
    local lines = {}
    for _, value in ipairs(array) do
        table.insert(lines, "        " .. string.format("%q", value) .. ",")
    end
    return table.concat(lines, "\n")
end

local function serializeOrderTable(t)
    local lines = { "return {" }
    for key, value in pairs(t) do
        table.insert(lines, "    [" .. string.format("%q", key) .. "] = {")
        table.insert(lines, serializeStringArray(value))
        table.insert(lines, "    },")
    end
    table.insert(lines, "}")
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

local function lists_equal(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

--[[--
Adds TAB_ID to one menu's order override file (only ever adding it to the
tab row, never touching any other tab's presence or order there), and keeps
our own tab's item list (existing[TAB_ID]) in sync with TAB_ITEM_IDS above.

That second part is a deliberate departure from "never touch it again":
unlike the tab row itself (a real, user-editable customization point other
plugins and hand-edits also share), the item list under our own TAB_ID is
private to this plugin -- nothing else has a reason to edit it -- so keeping
it synced with the code is safe, and necessary: this plugin's own menu items
have already changed once during development (see CLAUDE.md), and a stale
item list here would mean an already-installed tab silently pointing at a
menu_items key that no longer exists. Writes are still skipped entirely
once both the tab row and the item list already match what this call would
produce, so a normal restart still doesn't keep rewriting these files.
]]
local function patchOrderFile(config_prefix)
    local path = DataStorage:getSettingsDir() .. "/" .. config_prefix .. "_menu_order.lua"

    local existing = {}
    if lfs.attributes(path) then
        local ok, loaded = pcall(dofile, path)
        if ok and type(loaded) == "table" then
            existing = loaded
        else
            -- Don't touch a file we can't parse -- could be a hand
            -- edit-in-progress, or a format this code doesn't understand.
            logger.warn("ao3reader: could not read", path, "-- leaving it alone:", loaded)
            return
        end
    end

    -- Start from whatever the user (or an earlier plugin) already put in
    -- this file's tab row, if anything; otherwise fall back to KOReader's
    -- own built-in default for this menu, the same table readermenu.lua/
    -- filemanagermenu.lua would use if this override file didn't exist.
    local buttons = existing["KOMenu:menu_buttons"]
    local tab_already_present = false
    if buttons then
        local copy = {}
        for _, id in ipairs(buttons) do
            table.insert(copy, id)
            if id == TAB_ID then
                tab_already_present = true
            end
        end
        buttons = copy
    else
        local base_order = require("ui/elements/" .. config_prefix .. "_menu_order")
        buttons = {}
        for _, id in ipairs(base_order["KOMenu:menu_buttons"]) do
            table.insert(buttons, id)
        end
    end

    if not tab_already_present then
        table.insert(buttons, TAB_ID)
    end

    local items_already_current = type(existing[TAB_ID]) == "table" and lists_equal(existing[TAB_ID], TAB_ITEM_IDS)
    if tab_already_present and items_already_current then
        return -- nothing to do; already installed with the current item list
    end

    existing["KOMenu:menu_buttons"] = buttons
    existing[TAB_ID] = TAB_ITEM_IDS

    local ok, write_err = pcall(function()
        local file = io.open(path, "w")
        if not file then
            error("could not open " .. path .. " for writing")
        end
        file:write(serializeOrderTable(existing))
        file:close()
    end)
    if not ok then
        logger.warn("ao3reader: could not write", path, ":", write_err)
    end
end

--- Adds the "AO3 Reader" tab to both the reader and file-manager main
-- menus. Safe to call on every plugin init(): does nothing once already
-- installed (see patchOrderFile() above), and never touches anything else
-- in either file.
function MenuSetup.ensureTabInstalled()
    for _, config_prefix in ipairs(ORDER_CONFIG_PREFIXES) do
        local ok, err = pcall(patchOrderFile, config_prefix)
        if not ok then
            logger.warn("ao3reader: menu order setup failed for", config_prefix, ":", err)
        end
    end
end

return MenuSetup
