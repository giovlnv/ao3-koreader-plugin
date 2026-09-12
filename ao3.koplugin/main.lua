--[[--
AO3 Reader plugin for KOReader.

This file only wires the plugin into KOReader's UI (menu entries, dialogs,
result screens). All Archive of Our Own HTTP/parsing logic lives in
ao3client.lua so it can be unit-tested on its own with busted, without a
running KOReader instance — nothing in this file is covered by the busted
suite, since it all depends on real KOReader widgets.
]]

local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local _ = require("gettext")

local AO3Client = require("ao3client")
local MenuSetup = require("menu_setup")

local AO3Reader = WidgetContainer:extend({
    name = "ao3reader",
    is_doc_only = false,
})

function AO3Reader:init()
    -- One client for the plugin's lifetime. Logging in again (or a fresh
    -- KOReader restart) is currently the only way to get a new session —
    -- nothing is persisted to disk yet, on purpose: only session_cookie
    -- would be safe to persist (never the password), and that's a
    -- follow-up, not done here.
    self.ao3 = AO3Client.new()
    self.ui.menu:registerToMainMenu(self)

    -- Gives "AO3 Reader" its own top-level tab (next to Tools/Search/
    -- Settings) instead of being buried inside Tools -- see menu_setup.lua
    -- for how, and why it's safe to call this on every init(). self.path
    -- is set by KOReader's own plugin loader (pluginloader.lua) to this
    -- plugin's folder, which is where the bundled icon file lives.
    MenuSetup.ensureIconInstalled(self.path)
    MenuSetup.ensureTabInstalled()
end

function AO3Reader:isLoggedIn()
    return self.ao3.session_cookie ~= nil
end

function AO3Reader:showLoginDialog()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Log in to AO3"),
        fields = {
            { hint = _("Username or email") },
            { hint = _("Password"), text_type = "password" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Log in"),
                    callback = function()
                        local fields = dialog:getFields()
                        local username, password = fields[1], fields[2]
                        UIManager:close(dialog)
                        self:doLogin(username, password)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AO3Reader:doLogin(username, password)
    NetworkMgr:runWhenOnline(function()
        -- Show feedback before the blocking call below, not just after it
        -- returns: login() runs synchronously (see ao3client.lua), so
        -- without this the screen would otherwise look frozen for however
        -- long the request takes. forceRePaint() is what makes the message
        -- actually draw before that call starts, instead of only queuing a
        -- repaint that never gets a chance to run — same pattern KOReader's
        -- other online plugins (e.g. wallabag) use around their own
        -- blocking requests.
        local info = InfoMessage:new({ text = _("Logging in to AO3…") })
        UIManager:show(info)
        UIManager:forceRePaint()

        local ok, err = self.ao3:login(username, password)
        UIManager:close(info)

        if ok then
            UIManager:show(InfoMessage:new({
                text = T(_("Logged in to AO3 as %1."), username),
                timeout = 3,
            }))
        else
            UIManager:show(InfoMessage:new({
                text = T(_("AO3 login failed: %1"), err),
            }))
        end
    end)
end

function AO3Reader:logout()
    self.ao3 = AO3Client.new()
    UIManager:show(InfoMessage:new({
        text = _("Logged out of AO3."),
        timeout = 2,
    }))
end

--[[--
Fetches a work listing and shows it as a Menu, tapping an entry just shows
its AO3 URL for now (downloading isn't implemented yet -- see
AO3Client:getDownloadUrl()). Shared by showMarkedForLater() and
showMyWorks(), which differ only in the fetch function, the loading
message, and the screen title.

@param loading_text string  shown (with a forced repaint) before the
  blocking fetch call, so the screen doesn't look frozen while it runs
@param empty_text string  shown instead of an (empty) Menu when there's
  nothing to list
@param error_prefix string  prefixed to fetch_fn's error message, e.g.
  "Could not load Marked for Later"
@param menu_title string  the resulting Menu widget's title
@param fetch_fn function  self.ao3's own getter, e.g. AO3Client.getMyWorks
]]
function AO3Reader:showWorkListing(loading_text, empty_text, error_prefix, menu_title, fetch_fn)
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new({ text = _("Log in to AO3 first.") }))
        return
    end

    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new({ text = loading_text })
        UIManager:show(info)
        UIManager:forceRePaint()

        local works, err = fetch_fn(self.ao3)
        UIManager:close(info)

        if not works then
            UIManager:show(InfoMessage:new({
                text = T(_("%1: %2"), error_prefix, err),
            }))
            return
        end

        if #works == 0 then
            UIManager:show(InfoMessage:new({ text = empty_text }))
            return
        end

        local item_table = {}
        for _, work in ipairs(works) do
            table.insert(item_table, {
                text = work.title .. " — " .. work.author,
                callback = function()
                    -- Downloading isn't implemented yet (that's
                    -- getDownloadUrl(), still a TODO) — showing the real
                    -- URL here just confirms the data on screen is real,
                    -- not placeholder text.
                    UIManager:show(InfoMessage:new({ text = work.url }))
                end,
            })
        end

        UIManager:show(Menu:new({
            title = menu_title,
            item_table = item_table,
        }))
    end)
end

function AO3Reader:showMarkedForLater()
    self:showWorkListing(
        _("Loading Marked for Later…"),
        _("Nothing in Marked for Later."),
        _("Could not load Marked for Later"),
        _("Marked for Later"),
        AO3Client.getMarkedForLater
    )
end

function AO3Reader:showMyWorks()
    self:showWorkListing(
        _("Loading My Works…"),
        _("You haven't posted any works."),
        _("Could not load My Works"),
        _("My Works"),
        AO3Client.getMyWorks
    )
end

function AO3Reader:addToMainMenu(menu_items)
    -- "ao3reader" is now the TAB itself, not a submenu entry -- an
    -- icon-only top-level item exactly like KOReader's own built-in
    -- "tools"/"search"/"setting" tabs (see readermenu.lua's init(), which
    -- defines those the same way: just an icon, no text or items of its
    -- own). It only actually appears as a tab once menu_setup.lua has
    -- added "ao3reader" to the menu-order override files; see there for
    -- why that's a one-time, additive-only setup step done from init().
    menu_items.ao3reader = {
        icon = "ao3",
    }

    -- The items below are what menu_setup.lua's TAB_ITEM_IDS lists as
    -- belonging to the "ao3reader" tab -- flat, top-level entries here
    -- (like "read_timer"/"calibre"/etc. under the built-in "tools" tab),
    -- not nested under menu_items.ao3reader itself.
    menu_items.ao3_account = {
        -- One item does both jobs, switching on login state: logged out,
        -- it reads "Public" and tapping opens a one-item submenu ("Log in
        -- to AO3"); logged in, it shows the username instead and tapping
        -- opens a one-item submenu ("Log out"). text_func/
        -- sub_item_table_func are re-evaluated on every tap (see
        -- KOReader's touchmenu.lua onMenuSelect), which is what makes this
        -- track login state instead of needing the menu rebuilt.
        text_func = function()
            if self:isLoggedIn() then
                return self.ao3.username
            end
            return _("Public")
        end,
        sub_item_table_func = function()
            if self:isLoggedIn() then
                return {
                    {
                        text = _("Log out"),
                        callback = function()
                            self:logout()
                        end,
                    },
                }
            end
            return {
                {
                    text = _("Log in to AO3"),
                    callback = function()
                        self:showLoginDialog()
                    end,
                },
            }
        end,
    }

    menu_items.ao3_marked_for_later = {
        text = _("Marked for Later"),
        callback = function()
            self:showMarkedForLater()
        end,
    }

    menu_items.ao3_my_works = {
        text = _("My Works"),
        callback = function()
            self:showMyWorks()
        end,
    }

    menu_items.ao3_search = {
        text = _("Search AO3"),
        callback = function()
            -- TODO: implemented once AO3Client:search() exists
            UIManager:show(InfoMessage:new({
                text = _("Search isn't built yet."),
                timeout = 2,
            }))
        end,
    }
end

return AO3Reader
