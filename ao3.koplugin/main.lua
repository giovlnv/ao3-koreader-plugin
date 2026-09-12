--[[--
AO3 Reader plugin for KOReader.

This file only wires the plugin into KOReader's UI (menu entries, dialogs,
result screens). All Archive of Our Own HTTP/parsing logic lives in
ao3client.lua so it can be unit-tested on its own with busted, without a
running KOReader instance — nothing in this file is covered by the busted
suite, since it all depends on real KOReader widgets.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local T = ffiUtil.template
local _ = require("gettext")

local AO3Client = require("ao3client")
local MenuSetup = require("menu_setup")

-- Every format AO3's own "Download" dropdown offers on a real work page,
-- confirmed directly (see CLAUDE.md) -- AZW3 (Kindle's own format) included,
-- even though only the other four were in the original v1 roadmap wording.
local DOWNLOAD_FORMATS = { "EPUB", "MOBI", "PDF", "HTML", "AZW3" }

--- Where downloaded works get saved -- user-configurable (see
--- "Download settings" in addToMainMenu()), falling back to KOReader's own
--- configured library folder if nothing's been chosen yet.
-- @return string
local function getDownloadDir()
    return G_reader_settings:readSetting("ao3_download_dir")
        or require("apps/filemanager/filemanagerutil").getHomeFolder()
end

--- Whether to file a downloaded work under a subfolder named after its
--- series, when it has one -- off by default (opt-in, see "Download
--- settings"), since it changes where files land and shouldn't surprise
--- anyone who hasn't asked for it.
-- @return boolean
local function getUseSeriesFolders()
    local value = G_reader_settings:readSetting("ao3_use_series_folders")
    if value == nil then
        return false
    end
    return value
end

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

-- Every field in a work table (title, author, tags, summary, ...) is
-- free-form text AO3's own users wrote, not something this plugin
-- generated -- and can and does contain "&"/"<"/">" for real (e.g. a
-- fandom crossover tagged "Fandom A & Fandom B"). formatWorkDetails()
-- below builds real HTML now (see its own comment for why), so every one
-- of those values needs this before being embedded, or a literal "&" in a
-- title would either break the markup or silently vanish.
local function escapeHtml(str)
    return (tostring(str):gsub("[&<>\"']", {
        ["&"] = "&amp;",
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ['"'] = "&quot;",
        ["'"] = "&#39;",
    }))
end

--[[--
Formats one work's AO3-style details (rating/warnings/tags/summary/stats,
same fields AO3's own listing pages show) as HTML, for TextViewer's HTML
rendering mode (see the `text_format = "html"` passed alongside this in
showWorkListing() below) -- real section headers and bold labels, a
deliberate revision from this plugin's first pass at this screen, which
just stacked everything as plain text lines with no visual hierarchy at
all. TextViewer's HTML mode is backed by the same real HTML+CSS engine
KOReader uses to render actual books (confirmed in
~/koreader/frontend/ui/widget/scrollhtmlwidget.lua -- not a guess), so
headings/bold/italic all render properly; TextViewer's own internal CSS
is fixed and not overridable from here, so this deliberately sticks to
plain semantic tags (h4/p/b/i) rather than trying to control exact styling.

Every field but title/author/url is optional -- see parse_work_listing()
in ao3client.lua -- and simply omitted here when a blurb didn't have it.

@param work table  one entry from AO3Client's work listing/search results
@return string  HTML
]]
local function formatWorkDetails(work)
    local parts = { "<p><i>" .. T(_("by %1"), escapeHtml(work.author)) .. "</i></p>" }

    local badges = {}
    for _idx, value in ipairs({ work.rating, work.category, work.status }) do
        if value then
            table.insert(badges, escapeHtml(value))
        end
    end
    if #badges > 0 then
        table.insert(parts, "<p>" .. table.concat(badges, " &middot; ") .. "</p>")
    end

    if work.warnings and #work.warnings > 0 then
        table.insert(parts, "<p><b>" .. _("Warnings:") .. "</b> "
            .. escapeHtml(table.concat(work.warnings, ", ")) .. "</p>")
    end

    if work.series and #work.series > 0 then
        local series_lines = {}
        for _idx, series in ipairs(work.series) do
            table.insert(series_lines, T(_("Part %1 of %2"), series.part, escapeHtml(series.name)))
        end
        table.insert(parts, "<p><i>" .. table.concat(series_lines, "; ") .. "</i></p>")
    end

    local stats = {}
    if work.words then
        table.insert(stats, T(_("%1 words"), work.words))
    end
    if work.chapters then
        table.insert(stats, T(_("Chapters: %1"), escapeHtml(work.chapters)))
    end
    if #stats > 0 then
        table.insert(parts, "<p>" .. table.concat(stats, " &middot; ") .. "</p>")
    end

    if work.tags and #work.tags > 0 then
        table.insert(parts, "<h4>" .. _("Tags") .. "</h4><p>"
            .. escapeHtml(table.concat(work.tags, ", ")) .. "</p>")
    end

    if work.summary and work.summary ~= "" then
        table.insert(parts, "<h4>" .. _("Summary") .. "</h4>")
        -- work.summary already has "\n\n" between paragraphs and single
        -- "\n" for in-paragraph line breaks (see strip_summary_html() in
        -- ao3client.lua) -- turn each into its own <p>, with <br> for the
        -- line breaks within one, rather than one <p> HTML would silently
        -- collapse all that whitespace back out of.
        for paragraph in (work.summary .. "\n\n"):gmatch("(.-)\n\n") do
            if paragraph ~= "" then
                table.insert(parts, "<p>" .. escapeHtml(paragraph):gsub("\n", "<br>") .. "</p>")
            end
        end
    end

    table.insert(parts, "<p><a href=\"" .. escapeHtml(work.url) .. "\">" .. escapeHtml(work.url) .. "</a></p>")

    return table.concat(parts)
end

--- The folder a given work's file would be saved into: the configured
--- download folder, plus a series-named subfolder if that's turned on and
--- the work actually has a series (first one, if it's in several -- see
--- ao3client.lua's extract_series()).
-- @param work table
-- @return string
local function downloadDirFor(work)
    local dir = getDownloadDir()
    if getUseSeriesFolders() and work.series and #work.series > 0 then
        dir = dir .. "/" .. util.getSafeFilename(work.series[1].name, dir)
    end
    return dir
end

--[[--
Writes already-downloaded bytes to disk under downloadDirFor(work), asking
before overwriting an existing file (matching the convention KOReader's own
OPDS plugin uses for the same situation). Creates the destination folder
(and any series subfolder) if it doesn't exist yet.

@param work table
@param url string  the download URL bytes came from, from getDownloadUrl()
  -- used only to derive the filename, not fetched again here
@param bytes string  raw file content, from AO3Client:downloadFile()
]]
function AO3Reader:saveDownloadedFile(work, url, bytes)
    local dir = downloadDirFor(work)
    local ok, mkdir_err = util.makePath(dir)
    if not ok then
        UIManager:show(InfoMessage:new({
            text = T(_("Could not create folder %1: %2"), dir, mkdir_err),
        }))
        return
    end

    local filename = util.getSafeFilename(AO3Client.filenameFromDownloadUrl(url), dir)
    local path = dir .. "/" .. filename

    local function write()
        local file, open_err = io.open(path, "wb")
        if not file then
            UIManager:show(InfoMessage:new({ text = T(_("Could not save file: %1"), open_err) }))
            return
        end
        file:write(bytes)
        file:close()

        UIManager:show(InfoMessage:new({ text = T(_("Saved to %1"), path), timeout = 3 }))

        -- Only present when this plugin's menu was opened from the file
        -- browser, not from inside a book's own reader menu.
        if self.ui.file_chooser then
            self.ui.file_chooser:refreshPath()
        end
    end

    if lfs.attributes(path) then
        UIManager:show(ConfirmBox:new({
            text = T(_("%1 already exists. Overwrite?"), path),
            ok_text = _("Overwrite"),
            ok_callback = write,
        }))
    else
        write()
    end
end

--[[--
Fetches a work's download link for one format and saves it. Two blocking
network calls in a row (getDownloadUrl() fetches the work page,
downloadFile() fetches the actual file), each with its own loading message
since they can each take a moment.

@param work table
@param format string  one of DOWNLOAD_FORMATS
]]
function AO3Reader:downloadWork(work, format)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new({ text = T(_("Finding %1 download link…"), format) })
        UIManager:show(info)
        UIManager:forceRePaint()

        local url, find_err = self.ao3:getDownloadUrl(work.id, format)
        UIManager:close(info)
        if not url then
            UIManager:show(InfoMessage:new({ text = T(_("Could not download: %1"), find_err) }))
            return
        end

        info = InfoMessage:new({ text = _("Downloading…") })
        UIManager:show(info)
        UIManager:forceRePaint()

        local bytes, download_err = self.ao3:downloadFile(url)
        UIManager:close(info)
        if not bytes then
            UIManager:show(InfoMessage:new({ text = T(_("Could not download: %1"), download_err) }))
            return
        end

        self:saveDownloadedFile(work, url, bytes)
    end)
end

--- Shows one button per available format; tapping one downloads and saves
--- the work in that format. The currently configured destination folder is
--- shown in the title so it's visible before committing to a download --
--- changing it lives in "Download settings" (see addToMainMenu()), not here.
-- @param work table
function AO3Reader:showDownloadDialog(work)
    local dialog
    local function formatButton(format)
        return {
            text = format,
            callback = function()
                UIManager:close(dialog)
                self:downloadWork(work, format)
            end,
        }
    end

    local rows = {}
    for i = 1, #DOWNLOAD_FORMATS, 2 do
        local row = { formatButton(DOWNLOAD_FORMATS[i]) }
        if DOWNLOAD_FORMATS[i + 1] then
            table.insert(row, formatButton(DOWNLOAD_FORMATS[i + 1]))
        end
        table.insert(rows, row)
    end
    table.insert(rows, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })

    dialog = ButtonDialog:new({
        title = T(_("Download “%1”\n\nSave to: %2"), work.title, downloadDirFor(work)),
        buttons = rows,
    })
    UIManager:show(dialog)
end

--[[--
Fetches a work listing and shows it as a Menu, tapping an entry shows its
full AO3-style details (rating, warnings, tags, summary, word/chapter
counts) in a scrollable TextViewer, with a Download button that opens
showDownloadDialog(). Shared by showMarkedForLater() and showMyWorks(),
which differ only in the fetch function, the loading message, and the
screen title.

@param loading_text string  shown (with a forced repaint) before the
  blocking fetch call, so the screen doesn't look frozen while it runs
@param empty_text string  shown instead of an (empty) Menu when there's
  nothing to list
@param error_prefix string  prefixed to fetch_fn's error message, e.g.
  "Could not load Marked for Later"
@param menu_title string  the resulting Menu widget's title
@param fetch_fn function  called with self.ao3, returns (works, err) —
  e.g. AO3Client.getMyWorks, or a closure over a search query
@param requires_login boolean  true for account-only listings (Marked for
  Later, My Works); false for AO3Client:search(), which is public and works
  logged out too
]]
function AO3Reader:showWorkListing(loading_text, empty_text, error_prefix, menu_title, fetch_fn, requires_login)
    if requires_login and not self:isLoggedIn() then
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
        for _idx, work in ipairs(works) do
            table.insert(item_table, {
                text = work.title .. " — " .. work.author,
                callback = function()
                    local viewer
                    viewer = TextViewer:new({
                        title = work.title,
                        title_multilines = true,
                        text = formatWorkDetails(work),
                        text_format = "html",
                        text_type = "book_info",
                        add_default_buttons = true,
                        buttons_table = {
                            {
                                {
                                    text = _("Download"),
                                    callback = function()
                                        UIManager:close(viewer)
                                        self:showDownloadDialog(work)
                                    end,
                                },
                            },
                        },
                    })
                    UIManager:show(viewer)
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
        AO3Client.getMarkedForLater,
        true
    )
end

function AO3Reader:showMyWorks()
    self:showWorkListing(
        _("Loading My Works…"),
        _("You haven't posted any works."),
        _("Could not load My Works"),
        _("My Works"),
        AO3Client.getMyWorks,
        true
    )
end

function AO3Reader:showSearchDialog()
    local dialog
    dialog = InputDialog:new({
        title = _("Search AO3"),
        input_hint = _("Title, tag, or free text"),
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
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        UIManager:close(dialog)
                        self:doSearch(query)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AO3Reader:doSearch(query)
    if not query or query == "" then
        UIManager:show(InfoMessage:new({ text = _("Enter something to search for."), timeout = 2 }))
        return
    end

    self:showWorkListing(
        _("Searching AO3…"),
        _("No results found."),
        _("Search failed"),
        T(_("AO3 search: %1"), query),
        function(ao3) return ao3:search(query) end,
        false
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
    -- not nested under menu_items.ao3reader itself. "My Works" is the one
    -- exception: it lives inside the account item's own submenu instead
    -- (see below) since it's specifically about the logged-in account, not
    -- a peer of "Marked for Later"/"Search AO3".
    menu_items.ao3_account = {
        -- One item does both jobs, switching on login state: logged out,
        -- it reads "Public" and tapping opens a one-item submenu ("Log in
        -- to AO3"); logged in, it shows the username instead and tapping
        -- opens a submenu with "My Works" above "Log out". text_func/
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
                        text = _("My Works"),
                        callback = function()
                            self:showMyWorks()
                        end,
                    },
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

    menu_items.ao3_search = {
        text = _("Search AO3"),
        callback = function()
            self:showSearchDialog()
        end,
    }

    menu_items.ao3_download_settings = {
        text = _("Download settings"),
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Download folder: %1"), getDownloadDir())
                end,
                -- ui/downloadmgr is KOReader's own folder-picker widget --
                -- the same one used for e.g. the OPDS plugin's own download
                -- folder setting.
                callback = function()
                    require("ui/downloadmgr"):new({
                        onConfirm = function(path)
                            G_reader_settings:saveSetting("ao3_download_dir", path)
                        end,
                    }):chooseDir(getDownloadDir())
                end,
            },
            {
                text = _("Organize into series folders"),
                checked_func = getUseSeriesFolders,
                callback = function()
                    G_reader_settings:saveSetting("ao3_use_series_folders", not getUseSeriesFolders())
                end,
            },
        },
    }
end

return AO3Reader
