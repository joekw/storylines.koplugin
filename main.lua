--[[--
Storylines sync.

Pushes reading state to Storylines: position, session history with real
durations, and KOReader's own book status, rating and review.

Why this exists rather than using the built-in Progress sync (kosync): kosync's
protocol carries a file checksum, a percentage and nothing else — only for the
book currently open. That is not enough to identify which library book a file
is, and it throws away the reading history KOReader has already recorded. This
plugin reads that history straight out of `statistics.sqlite3` and sends real
metadata alongside it.

It also has its own settings, so it does not touch the kosync plugin's single
`custom_server` slot. Running both at once is fine and expected.

@module koplugin.storylines
--]]--

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local ReadHistory = require("readhistory")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local logger = require("logger")
local socketutil = require("socketutil")
local util = require("util")
local JSON = require("json")
local T = require("ffi/util").template
local _ = require("gettext")

-- Never a Supabase URL: this endpoint is baked into a plugin that users update
-- by copying a folder onto the device, so the indirection through our own
-- domain is what lets the backend move without a plugin release.
local ENDPOINT = "https://storylines.software/sync"

-- Consecutive page turns further apart than this are separate sittings. Ten
-- minutes is long enough to cover putting the device down mid-chapter and
-- short enough that an evening and the next morning don't merge.
local SESSION_GAP_SECONDS = 600

-- Matches the server's own caps, so a batch is never refused for size. A first
-- sync of years of history pages through these.
local MAX_DOCUMENTS_PER_PUSH = 500
local MAX_SESSIONS_PER_PUSH = 2000

-- Batches per invocation. A very large backlog finishes over several syncs
-- rather than blocking the UI on one.
local MAX_BATCHES_PER_SYNC = 20

-- Page turns before an automatic sync. Progress arrives in bursts anyway.
local DEFAULT_PAGES_BEFORE_SYNC = 50

local CONNECT_TIMEOUT = 10
local TOTAL_TIMEOUT = 30

-- KOReader's statistics table predates the plugin and is read-only here. We
-- never write to it.
local STATS_DB = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local Storylines = WidgetContainer:extend{
    name = "storylines",
    is_doc_only = false,
}

function Storylines:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/storylines.lua")
    self.page_update_counter = 0
    self.syncing = false

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()
end

function Storylines:onDispatcherRegisterActions()
    Dispatcher:registerAction("storylines_sync_now", {
        category = "none",
        event = "StorylinesSyncNow",
        title = _("Sync to Storylines now"),
        general = true,
    })
end

function Storylines:isPaired()
    local token = self.settings:readSetting("token")
    return type(token) == "string" and token ~= ""
end

function Storylines:autoSyncEnabled()
    return self.settings:nilOrTrue("auto_sync")
end

function Storylines:pagesBeforeSync()
    return self.settings:readSetting("pages_before_sync") or DEFAULT_PAGES_BEFORE_SYNC
end

-- MARK: - Menu

function Storylines:addToMainMenu(menu_items)
    menu_items.storylines = {
        text = _("Storylines sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    return self:isPaired() and _("Paired with Storylines") or _("Pair with Storylines")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    if self:isPaired() then
                        self:showStatus()
                    else
                        self:promptForCode(touchmenu_instance)
                    end
                end,
            },
            {
                text = _("Sync now"),
                keep_menu_open = true,
                enabled_func = function() return self:isPaired() end,
                callback = function()
                    self:syncNow(true)
                end,
            },
            {
                text = _("Sync automatically"),
                checked_func = function() return self:autoSyncEnabled() end,
                enabled_func = function() return self:isPaired() end,
                callback = function()
                    self.settings:saveSetting("auto_sync", not self:autoSyncEnabled())
                    self.settings:flush()
                end,
                separator = true,
            },
            {
                text = _("Unpair this device"),
                keep_menu_open = true,
                enabled_func = function() return self:isPaired() end,
                callback = function(touchmenu_instance)
                    self:unpair()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        },
    }
end

function Storylines:showStatus()
    local last = self.settings:readSetting("last_sync_at")
    local text = last
        and T(_("Last synced %1."), os.date("%Y-%m-%d %H:%M", last))
        or _("Paired, but nothing has synced yet.")
    UIManager:show(InfoMessage:new{ text = text })
end

-- MARK: - Pairing

function Storylines:promptForCode(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Pair with Storylines"),
        description = _("In Storylines, go to Settings › Import › Kindle sync and tap Show pairing code."),
        input = "",
        input_hint = "ABCD-EFGH",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Pair"),
                is_enter_default = true,
                callback = function()
                    local code = dialog:getInputText()
                    UIManager:close(dialog)
                    self:claim(code, touchmenu_instance)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Storylines:claim(code, touchmenu_instance)
    if not code or code == "" then return end

    if NetworkMgr:willRerunWhenOnline(function() self:claim(code, touchmenu_instance) end) then
        return
    end

    local response, status = self:request("POST", "/claim", {
        code = code,
        name = self:deviceName(),
        platform = self:platformName(),
        koreader_version = self:koreaderVersion(),
    }, true)

    if status == 200 and response and response.token then
        self.settings:saveSetting("token", response.token)
        self.settings:saveSetting("account_id", response.account_id)
        self.settings:saveSetting("paired_at", os.time())
        self.settings:flush()
        if touchmenu_instance then touchmenu_instance:updateItems() end
        UIManager:show(InfoMessage:new{
            text = _("Paired. Syncing your books now…"),
            timeout = 3,
        })
        -- Straight into the first sync: this is the moment the user is
        -- watching, and it is when the whole history goes up.
        UIManager:nextTick(function() self:syncNow(true) end)
        return
    end

    UIManager:show(InfoMessage:new{
        text = (response and response.error) or _("Couldn't pair. Check the code and try again."),
    })
end

function Storylines:unpair()
    self.settings:delSetting("token")
    self.settings:delSetting("account_id")
    self.settings:delSetting("paired_at")
    -- Deliberately keeping last_session_start: re-pairing to the same account
    -- should not re-send history the server already has, and a genuinely new
    -- account gets everything because the server has nothing to collide with.
    self.settings:flush()
    UIManager:show(InfoMessage:new{ text = _("Unpaired from Storylines."), timeout = 2 })
end

-- MARK: - Device description

function Storylines:deviceName()
    local configured = self.settings:readSetting("device_name")
    if configured and configured ~= "" then return configured end
    return Device.model or "E-reader"
end

function Storylines:platformName()
    if Device:isKindle() then return "kindle" end
    if Device:isKobo() then return "kobo" end
    if Device:isAndroid() then return "android" end
    if Device:isPocketBook() then return "pocketbook" end
    if Device:isRemarkable() then return "remarkable" end
    return "other"
end

function Storylines:koreaderVersion()
    local ok, Version = pcall(require, "version")
    if ok and Version then
        local short = Version:getShortVersion()
        if short then return short end
    end
    return nil
end

-- MARK: - HTTP

--- Performs one request. Returns (decoded body or nil, status code or nil).
---
--- `anonymous` skips the Authorization header, which only /claim needs — it is
--- the one route called before there is a token to send.
function Storylines:request(method, path, body_table, anonymous)
    -- KOReader's luasocket build handles https through socket.http on most
    -- platforms, but not all of them, and ssl.https is absent from some
    -- builds. Resolving both and picking by scheme is four lines and works
    -- everywhere.
    local http = require("socket.http")
    local ok_https, https = pcall(require, "ssl.https")
    local requester = (ok_https and https and ENDPOINT:match("^https")) and https.request or http.request

    local body_json = body_table and JSON.encode(body_table) or nil
    local headers = { ["Accept"] = "application/json" }

    if body_json then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_json)
    end

    if not anonymous then
        local token = self.settings:readSetting("token")
        if not token then return nil, nil end
        headers["Authorization"] = "Bearer " .. token
    end

    local sink = {}
    socketutil:set_timeout(CONNECT_TIMEOUT, TOTAL_TIMEOUT)
    local _result, status = requester{
        url = ENDPOINT .. path,
        method = method,
        headers = headers,
        source = body_json and ltn12.source.string(body_json) or nil,
        sink = ltn12.sink.table(sink),
    }
    socketutil:reset_timeout()

    if type(status) ~= "number" then
        logger.warn("Storylines: request failed:", path, tostring(status))
        return nil, nil
    end

    local raw = table.concat(sink)
    local decoded
    if raw ~= "" then
        local ok, parsed = pcall(JSON.decode, raw)
        if ok then decoded = parsed end
    end

    return decoded, status
end

-- MARK: - Reading local state

--- Maps a document checksum to everything we know about that file.
---
--- KOReader's statistics table stores only a checksum, never a path, so the
--- file list comes from the reading history and is joined back by checksum.
--- Computing `partialMD5` is twelve 1 KiB reads, but doing it for every book on
--- every sync still adds up, so results are cached against size and mtime.
function Storylines:collectBooks()
    local by_md5 = {}
    local cache = self.settings:readSetting("md5_cache") or {}
    local fresh_cache = {}
    local remembered = self.settings:readSetting("identifiers") or {}
    local stats = self:collectBookStats()

    for _index, entry in ipairs(ReadHistory.hist or {}) do
        local file = entry.file
        local attributes = file and lfs.attributes(file)

        if attributes and attributes.mode == "file" then
            local stamp = string.format("%d:%d", attributes.size or 0, attributes.modification or 0)
            local cached = cache[file]
            local md5 = (cached and cached.stamp == stamp) and cached.md5 or nil

            if not md5 then
                local ok, computed = pcall(util.partialMD5, file)
                md5 = ok and computed or nil
            end

            if md5 then
                fresh_cache[file] = { stamp = stamp, md5 = md5 }
                local book = {
                    doc_key = md5,
                    filename = file:match("([^/]+)$") or file,
                    -- When this device last opened the book. The app uses it as
                    -- the watermark for "is this position news", so it has to
                    -- be the device's own reckoning rather than a server time.
                    last_open = tonumber(entry.time),
                }

                local ok_settings, settings = pcall(function() return DocSettings:open(file) end)
                if ok_settings and settings then
                    local props = settings:readSetting("doc_props") or {}
                    book.title = props.title or props.display_title
                    book.authors = props.authors
                    book.series = props.series
                    book.series_index = tonumber(props.series_index)
                    book.language = props.language
                    book.identifiers = props.identifiers
                    book.koreader_pages = tonumber(settings:readSetting("doc_pages"))
                    book.percentage = tonumber(settings:readSetting("percent_finished"))
                    book.position = settings:readSetting("last_xpointer")
                        or tostring(settings:readSetting("last_page") or "")

                    local summary = settings:readSetting("summary")
                    if type(summary) == "table" then
                        book.summary_status = summary.status
                        book.summary_rating = tonumber(summary.rating)
                        book.summary_note = summary.note
                        book.summary_modified = summary.modified
                    end
                end

                -- Identifiers live in the sidecar's cached props, which can be
                -- cleared. Once seen they are remembered here, because the
                -- server treats an absent field as "no longer known" and an
                -- ISBN is what makes matching exact rather than a guess.
                if book.identifiers and book.identifiers ~= "" then
                    remembered[md5] = book.identifiers
                elseif remembered[md5] then
                    book.identifiers = remembered[md5]
                end

                mergeStats(book, stats[md5])
                book.isbn = self:isbnFrom(book.identifiers)
                book.device_name = self:deviceName()
                by_md5[md5] = book
            end
        end
    end

    self.settings:saveSetting("md5_cache", fresh_cache)
    self.settings:saveSetting("identifiers", remembered)
    return by_md5
end

--- Metadata from the statistics database, keyed by checksum.
---
--- The sidecar's cached `doc_props` is the better source when it is there, but
--- it can be absent or cleared — and the server treats an absent field as "no
--- longer known", so pushing a nil title would erase one it had already
--- learned. The statistics `book` table always has a title and authors for
--- anything with reading history, which makes it the right backstop. It is
--- also the only source for `total_read_time`.
function Storylines:collectBookStats()
    if lfs.attributes(STATS_DB, "mode") ~= "file" then return {} end

    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 then return {} end

    local stats = {}

    local ok, err = pcall(function()
        local conn = SQ3.open(STATS_DB, "ro")
        local rows = conn:exec([[
            SELECT md5, title, authors, series, language, pages, total_read_time, last_open
            FROM book
            WHERE md5 IS NOT NULL;
        ]])
        conn:close()

        if not rows or not rows[1] then return end

        for index = 1, #rows[1] do
            stats[rows[1][index]] = {
                title = rows[2][index],
                authors = rows[3][index],
                series = rows[4][index],
                language = rows[5][index],
                pages = tonumber(rows[6][index]),
                total_read_time = tonumber(rows[7][index]),
                last_open = tonumber(rows[8][index]),
            }
        end
    end)

    if not ok then
        logger.warn("Storylines: could not read book statistics:", tostring(err))
        return {}
    end

    return stats
end

--- Fills gaps in what the sidecar knew from what the statistics database knows.
---
--- KOReader writes "N/A" into the statistics table rather than leaving a column
--- null, so those have to be treated as absent or they end up as book titles.
local function mergeStats(book, stats)
    if not stats then return end

    local function usable(value)
        return value ~= nil and value ~= "" and value ~= "N/A"
    end

    if not usable(book.title) and usable(stats.title) then book.title = stats.title end
    if not usable(book.authors) and usable(stats.authors) then book.authors = stats.authors end
    if not usable(book.series) and usable(stats.series) then book.series = stats.series end
    if not usable(book.language) and usable(stats.language) then book.language = stats.language end

    if not book.koreader_pages and stats.pages and stats.pages > 0 then
        book.koreader_pages = stats.pages
    end
    if stats.total_read_time and stats.total_read_time > 0 then
        book.total_read_time = stats.total_read_time
    end
    if not book.last_open and stats.last_open then
        book.last_open = stats.last_open
    end
end

--- Pulls an ISBN out of crengine's `doc.identifiers`, which is a free-form list
--- of `scheme:value` pairs whose separator and casing vary by publisher.
function Storylines:isbnFrom(identifiers)
    if type(identifiers) ~= "string" or identifiers == "" then return nil end

    for candidate in identifiers:gmatch("[%dXx%-]+") do
        local stripped = candidate:gsub("[%s%-]", ""):upper()
        if stripped:match("^%d%d%d%d%d%d%d%d%d[%dX]$") or stripped:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
            return stripped
        end
    end
    return nil
end

--- Reads new page-level rows out of the statistics database and folds them into
--- sessions.
---
--- Reads `page_stat_data` rather than the `page_stat` view on purpose. The view
--- rescales historical durations to the book's *current* page count, which is
--- what you want for a progress bar and wrong for history: a sitting read at
--- 300 pages should be measured against the 300 pages it was read at, and each
--- raw row already carries the `total_pages` in force at the time. The raw
--- table is also far cheaper — the view expands rows through a numbers table,
--- and there is an index on `page_stat_data.start_time` for exactly this query.
function Storylines:collectSessions(since, limit)
    if lfs.attributes(STATS_DB, "mode") ~= "file" then return {}, nil end

    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 then
        logger.warn("Storylines: no sqlite binding, skipping history")
        return {}, nil
    end

    local sessions = {}

    local ok, err = pcall(function()
        local conn = SQ3.open(STATS_DB, "ro")

        -- Ordered by time across all books, never by book. Grouping by book
        -- first would mean a row limit could cut mid-book while the watermark
        -- advanced past a *different* book's later rows, silently losing
        -- everything in between. Interleaved books are handled instead by
        -- keeping one open session per book.
        --
        -- The bounds are integers this code produced, so they are formatted in
        -- rather than bound; ljsqlite3's prepared-statement row iteration
        -- differs between builds and `exec` is the portable path.
        local rows = conn:exec(string.format([[
            SELECT b.md5, d.page, d.start_time, d.duration, d.total_pages
            FROM page_stat_data d
            JOIN book b ON b.id = d.id_book
            WHERE d.start_time > %d AND b.md5 IS NOT NULL
            ORDER BY d.start_time
            LIMIT %d;
        ]], math.floor(since), math.floor(limit)))

        conn:close()

        -- `exec` returns columns, not rows.
        if not rows or not rows[1] then return end

        local open = {}

        local function close_session(entry)
            local count = 0
            for _page in pairs(entry.pages_seen) do count = count + 1 end
            entry.pages = count
            entry.pages_seen = nil
            entry.ends_at = nil
            sessions[#sessions + 1] = entry
        end

        for index = 1, #rows[1] do
            local md5 = rows[1][index]
            local page = tonumber(rows[2][index]) or 0
            local start_time = tonumber(rows[3][index]) or 0
            local duration = tonumber(rows[4][index]) or 0
            local total_pages = tonumber(rows[5][index]) or 0

            local entry = open[md5]
            if entry and start_time - entry.ends_at > SESSION_GAP_SECONDS then
                close_session(entry)
                entry = nil
            end

            if not entry then
                entry = {
                    doc_key = md5,
                    started_at = start_time,
                    duration = 0,
                    total_pages = total_pages,
                    ends_at = start_time,
                    pages_seen = {},
                }
                open[md5] = entry
            end

            entry.duration = entry.duration + duration
            entry.ends_at = start_time + duration
            -- The page count in force at the end of the sitting: if the font
            -- changed mid-session, the later value matches the pages actually
            -- turned.
            if total_pages > 0 then entry.total_pages = total_pages end
            entry.pages_seen[page] = true
        end

        for _md5, entry in pairs(open) do
            close_session(entry)
        end
    end)

    if not ok then
        logger.warn("Storylines: could not read statistics:", tostring(err))
        return {}, nil
    end

    table.sort(sessions, function(a, b) return a.started_at < b.started_at end)

    -- The last session may still be growing — the reader could be mid-sitting,
    -- or its later page turns could be in the next batch — so the watermark
    -- stops just short of it. Those rows are re-read next time and the session
    -- is re-sent complete, which the server resolves by overwriting the row
    -- with the same (document, start) key rather than ignoring it.
    --
    -- Re-reading one session's rows is the whole cost. When nothing newer ever
    -- arrives the watermark stops moving, and the caller's loop notices that
    -- and stops rather than pushing the same tail forever.
    local watermark = nil
    if #sessions > 0 then
        watermark = sessions[#sessions].started_at - 1
    end

    return sessions, watermark
end

-- MARK: - Syncing

function Storylines:syncNow(interactive)
    if not self:isPaired() then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Pair with Storylines first.") })
        end
        return
    end

    if self.syncing then return end

    if NetworkMgr:willRerunWhenOnline(function() self:syncNow(interactive) end) then
        return
    end

    self.syncing = true
    self.page_update_counter = 0

    local ok, err = pcall(function() self:performSync(interactive) end)

    self.syncing = false

    if not ok then
        logger.warn("Storylines: sync failed:", tostring(err))
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Sync failed. Please try again.") })
        end
    end
end

function Storylines:performSync(interactive)
    local books = self:collectBooks()

    local documents = {}
    for _md5, book in pairs(books) do
        documents[#documents + 1] = book
    end

    local pushed_documents = 0
    local pushed_sessions = 0
    local failed = false

    -- Documents first: they are small, they carry the metadata that makes the
    -- history meaningful, and the app can act on a position without any
    -- history at all.
    for offset = 1, math.max(#documents, 1), MAX_DOCUMENTS_PER_PUSH do
        local batch = {}
        for index = offset, math.min(offset + MAX_DOCUMENTS_PER_PUSH - 1, #documents) do
            batch[#batch + 1] = documents[index]
        end
        if #batch == 0 then break end

        local response, status = self:request("POST", "/push", { documents = batch })
        if status == 401 then
            self:handleRejectedToken()
            return
        end
        if status ~= 200 then
            failed = true
            break
        end
        pushed_documents = pushed_documents + (response and response.documents or 0)
    end

    -- Then history, paging from the watermark. The watermark only advances on a
    -- 200, so an interrupted first sync resumes rather than losing a chunk.
    if not failed then
        for _batch = 1, MAX_BATCHES_PER_SYNC do
            local since = self.settings:readSetting("last_session_start") or 0
            local sessions, highest = self:collectSessions(since, MAX_SESSIONS_PER_PUSH)

            if #sessions == 0 then break end

            local response, status = self:request("POST", "/push", { sessions = sessions })
            if status == 401 then
                self:handleRejectedToken()
                return
            end
            if status ~= 200 then
                failed = true
                break
            end

            pushed_sessions = pushed_sessions + (response and response.sessions or 0)

            -- Guard against a batch whose rows all share the watermark's
            -- timestamp, which would otherwise loop forever on the same rows.
            if not highest or highest <= since then break end
            self.settings:saveSetting("last_session_start", highest)
            self.settings:flush()
        end
    end

    if not failed then
        self.settings:saveSetting("last_sync_at", os.time())
        self.settings:flush()
    end

    if interactive then
        UIManager:show(InfoMessage:new{
            text = failed
                and _("Couldn't reach Storylines. It'll try again later.")
                or T(_("Synced %1 books and %2 sessions."), pushed_documents, pushed_sessions),
            timeout = 3,
        })
    end
end

--- A 401 means the device was unpaired from the app, or the account was
--- deleted. Clearing the token stops a device that is no longer welcome from
--- retrying forever, and makes the menu offer pairing again.
function Storylines:handleRejectedToken()
    logger.warn("Storylines: token rejected, unpairing")
    self.settings:delSetting("token")
    self.settings:delSetting("account_id")
    self.settings:flush()
    UIManager:show(InfoMessage:new{
        text = _("Storylines rejected this device. Pair it again to resume syncing."),
    })
end

-- MARK: - Events

function Storylines:onStorylinesSyncNow()
    self:syncNow(true)
    return true
end

function Storylines:onCloseDocument()
    if not self:autoSyncEnabled() then return end
    -- Closing a book is the single best moment to sync: the statistics plugin
    -- has just flushed the last page's duration, and the user is not reading.
    self:syncNow(false)
end

function Storylines:onSuspend()
    if not self:autoSyncEnabled() then return end
    self:syncNow(false)
end

function Storylines:onNetworkConnected()
    if not self:autoSyncEnabled() then return end
    if not self:isPaired() then return end
    UIManager:scheduleIn(1, function() self:syncNow(false) end)
end

function Storylines:onPageUpdate()
    if not self:autoSyncEnabled() then return end
    self.page_update_counter = self.page_update_counter + 1
    if self.page_update_counter < self:pagesBeforeSync() then return end

    -- Deferred rather than immediate, so a run of quick page turns coalesces
    -- into one sync once the reader actually settles. Built before it is
    -- unscheduled, because unscheduling nil on the first page turn is not
    -- something UIManager is asked to do anywhere else.
    self.deferred_sync = self.deferred_sync or function() self:syncNow(false) end
    UIManager:unschedule(self.deferred_sync)
    UIManager:scheduleIn(10, self.deferred_sync)
end

function Storylines:onFlushSettings()
    if self.settings then self.settings:flush() end
end

return Storylines
