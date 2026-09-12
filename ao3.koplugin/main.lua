--[[--
AO3 Reader plugin for KOReader.

This file only wires the plugin into KOReader's UI (menu entries, widgets).
All Archive of Our Own HTTP/parsing logic lives in ao3client.lua so it can be
unit-tested on its own with busted, without a running KOReader instance.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local AO3Reader = WidgetContainer:extend({
    name = "ao3reader",
    is_doc_only = false,
})

function AO3Reader:init()
    self.ui.menu:registerToMainMenu(self)
end

function AO3Reader:addToMainMenu(menu_items)
    menu_items.ao3reader = {
        text = _("AO3 Reader"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Marked for Later"),
                callback = function()
                    -- TODO: implemented in a later session (needs login())
                end,
            },
            {
                text = _("Search AO3"),
                callback = function()
                    -- TODO: implemented in a later session
                end,
            },
        },
    }
end

return AO3Reader
