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
        local ok, err = self.ao3:login(username, password)
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

function AO3Reader:showMarkedForLater()
    if not self:isLoggedIn() then
        UIManager:show(InfoMessage:new({ text = _("Log in to AO3 first.") }))
        return
    end

    NetworkMgr:runWhenOnline(function()
        local works, err = self.ao3:getMarkedForLater()

        if not works then
            UIManager:show(InfoMessage:new({
                text = T(_("Could not load Marked for Later: %1"), err),
            }))
            return
        end

        if #works == 0 then
            UIManager:show(InfoMessage:new({ text = _("Nothing in Marked for Later.") }))
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
            title = _("Marked for Later"),
            item_table = item_table,
        }))
    end)
end

function AO3Reader:addToMainMenu(menu_items)
    menu_items.ao3reader = {
        text = _("AO3 Reader"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Log in to AO3"),
                callback = function()
                    self:showLoginDialog()
                end,
            },
            {
                text = _("Log out"),
                callback = function()
                    self:logout()
                end,
            },
            {
                text = _("Marked for Later"),
                callback = function()
                    self:showMarkedForLater()
                end,
            },
            {
                text = _("Search AO3"),
                callback = function()
                    -- TODO: implemented once AO3Client:search() exists
                end,
            },
        },
    }
end

return AO3Reader
