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
  KOReader-wide, so this only ever ADDS our own tab id and never touches or
  resets anything else already in it, and does nothing at all once it
  detects its own change is already there (so a normal KOReader restart
  doesn't rewrite these files every time, and any manual edits the user
  makes to them afterwards -- reordering items within our tab, for
  instance -- are left alone for good).

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
local TAB_ITEM_IDS = { "ao3_account", "ao3_marked_for_later", "ao3_my_works", "ao3_search" }
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

--- Adds TAB_ID to one menu's order override file, if it isn't there
-- already. See the module comment for why this only ever adds to, and
-- never rewrites, anything else already in the file.
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

    if existing[TAB_ID] ~= nil then
        return -- our tab is already installed here
    end

    -- Start from whatever the user (or an earlier plugin) already put in
    -- this file's tab row, if anything; otherwise fall back to KOReader's
    -- own built-in default for this menu, the same table readermenu.lua/
    -- filemanagermenu.lua would use if this override file didn't exist.
    local buttons = existing["KOMenu:menu_buttons"]
    if buttons then
        local copy = {}
        for _, id in ipairs(buttons) do
            table.insert(copy, id)
        end
        buttons = copy
    else
        local base_order = require("ui/elements/" .. config_prefix .. "_menu_order")
        buttons = {}
        for _, id in ipairs(base_order["KOMenu:menu_buttons"]) do
            table.insert(buttons, id)
        end
    end

    local already_present = false
    for _, id in ipairs(buttons) do
        if id == TAB_ID then
            already_present = true
        end
    end
    if not already_present then
        table.insert(buttons, TAB_ID)
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
