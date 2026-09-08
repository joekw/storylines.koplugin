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
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local logger = require("logger")
local socketutil = require("socketutil")
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
--
-- It is also how the plugin decides a sitting is *over*: a session whose last
-- page turn is older than this cannot grow any further, so it is safe to stop
-- re-reading it. Using "are there later rows?" instead would mean the session
-- you are in the middle of right now is never sent, because nothing follows it.
local SESSION_GAP_SECONDS = 600

-- Match the server's own caps, so a batch is never refused for size. Sessions
-- need this as much as documents do: one widened query can fold several
-- thousand sittings out of a long history.
local MAX_DOCUMENTS_PER_PUSH = 500
local MAX_SESSIONS_PER_PUSH = 2000

-- Row limits, not session limits: `page_stat_data` holds one row per page turn,
-- and a session is many rows.
--
-- Escalating rather than fixed. A query that ends mid-sitting can send nothing
-- (see `sessionPlan`), and if every sitting in the window is unfinished the
-- watermark cannot move at all — so when that happens the query is simply
-- widened.
--
-- The last step is unbounded on purpose. A ceiling here is not a safety valve,
-- it is permanent data loss: for history that has already been written the
-- shape never changes, so a window that cannot yield a sendable sitting at the
-- ceiling will never yield one, and everything from there on is stranded
-- however many times it retries. The common steps stay small because they are
-- what runs on a book close; the unbounded pass is the one that guarantees
-- progress.
local ROW_LIMIT_STEPS = { 2000, 8000, 32000, math.maxinteger }

-- Page turns before an automatic sync. Progress arrives in bursts anyway.
local DEFAULT_PAGES_BEFORE_SYNC = 50

-- Two request profiles. An automatic sync runs on the UI thread at moments the
-- user is not expecting to wait — closing a book, reconnecting — so it gets
-- short timeouts and a hard cap on round trips. An interactive one is behind a
-- menu tap, where waiting is understood, and is allowed to drain a backlog.
local AUTOMATIC = { block = 5, total = 15, batches = 2 }
local INTERACTIVE = { block = 10, total = 30, batches = 20 }

-- KOReader's statistics table predates the plugin and is read-only here. We
-- never write to it.
local STATS_DB = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local Storylines = WidgetContainer:extend{
    name = "storylines",
    is_doc_only = false,
}

-- MARK: - Lifecycle

--- Settings are shared across instances, deliberately.
---
--- `is_doc_only = false` means both FileManager and ReaderUI construct an
--- instance of this plugin, and two `LuaSettings:open` calls on one file give
--- two independent in-memory copies. Whichever flushed last would win, which is
--- how a pairing — or an unpair — silently reverts. Same approach as kosync's
--- `KOSync.settings_obj`.
function Storylines:loadSettings()
    if not Storylines.settings_obj then
        Storylines.settings_obj = LuaSettings:open(DataStorage:getSettingsDir() .. "/storylines.lua")
    end
    self.settings = Storylines.settings_obj
end

function Storylines:init()
    self:loadSettings()
    self.last_page_synced = nil
    self.page_update_counter = 0

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()
end

--- Cancels anything scheduled against this instance.
---
--- Without this a deferred sync outlives the ReaderUI that scheduled it: the
--- closure keeps the whole dead reader and its document alive, and when it
--- eventually fires it writes settings from an instance that no longer reflects
--- what the surviving one did.
function Storylines:onCloseWidget()
    for _index, scheduled in ipairs(self.scheduled or {}) do
        UIManager:unschedule(scheduled)
    end
    self.scheduled = nil
    self.deferred_sync = nil
end

--- Schedules work and remembers it, so `onCloseWidget` can cancel it.
---
--- Anything scheduled anonymously outlives this instance: the closure pins the
--- reader and its document in memory, and then runs against an object that no
--- longer reflects what the surviving instance did.
function Storylines:scheduleTracked(seconds, action)
    self.scheduled = self.scheduled or {}
    self.scheduled[#self.scheduled + 1] = action
    UIManager:scheduleIn(seconds, action)
end

function Storylines:onDispatcherRegisterActions()
    Dispatcher:registerAction("storylines_sync_now", {
        category = "none",
        event = "StorylinesSyncNow",
        title = _("Sync to Storylines now"),
        general = true,
    })
end

-- MARK: - Settings access

function Storylines:setSetting(key, value)
    self.settings:saveSetting(key, value)
    Storylines.settings_dirty = true
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
                    self:setSetting("auto_sync", not self:autoSyncEnabled())
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

--- Coerces whatever the server put in an error field into something safe to
--- display. A JSON object here would crash the text widget, on a menu callback
--- that KOReader does not wrap in a pcall.
local function displayableError(value, fallback)
    if type(value) == "string" and value ~= "" then return value end
    return fallback
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

    -- Interactive, so bringing the network up (and prompting for it, if that is
    -- how the device is configured) is expected here.
    if NetworkMgr:willRerunWhenOnline(function() self:claim(code, touchmenu_instance) end) then
        return
    end

    -- pcall'd because this is reached from a menu callback, which KOReader
    -- invokes bare: an error would propagate into the menu widget.
    local ok, response, status = pcall(function()
        return self:request("POST", "/claim", {
            code = code,
            name = self:deviceName(),
            platform = self:platformName(),
            koreader_version = self:koreaderVersion(),
        }, INTERACTIVE, true)
    end)

    if not ok then
        logger.warn("Storylines: pairing failed:", tostring(response))
        UIManager:show(InfoMessage:new{ text = _("Couldn't pair. Please try again.") })
        return
    end

    if status == 200 and type(response) == "table" and type(response.token) == "string" then
        self:setSetting("token", response.token)
        self:setSetting("account_id", response.account_id)
        self:setSetting("paired_at", os.time())
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
        text = displayableError(type(response) == "table" and response.error or nil,
                                _("Couldn't pair. Check the code and try again.")),
    })
end

function Storylines:unpair()
    self.settings:delSetting("token")
    self.settings:delSetting("account_id")
    self.settings:delSetting("paired_at")
    -- Deliberately keeping last_session_start: re-pairing to the same account
    -- should not re-send history the server already has, and a genuinely new
    -- account gets everything because the server has nothing to collide with.
    Storylines.settings_dirty = true
    self.settings:flush()
    UIManager:show(InfoMessage:new{ text = _("Unpaired from Storylines."), timeout = 2 })
end

--- A 401 means the device was unpaired from the app, or the account was
--- deleted. Clearing the token stops a device that is no longer welcome from
--- retrying forever, and makes the menu offer pairing again.
function Storylines:handleRejectedToken()
    logger.warn("Storylines: token rejected, unpairing")
    self.settings:delSetting("token")
    self.settings:delSetting("account_id")
    self.settings:delSetting("paired_at")
    Storylines.settings_dirty = true
    self.settings:flush()
    UIManager:show(InfoMessage:new{
        text = _("Storylines rejected this device. Pair it again to resume syncing."),
    })
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
function Storylines:request(method, path, body_table, profile, anonymous)
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

    -- Order matters, and getting it wrong is silent. `socketutil.table_sink`
    -- reads `socketutil.total_timeout` when the sink is *constructed*, and
    -- short-circuits to a plain `ltn12.sink.table` if it is still the default
    -- -1 — which is exactly what `reset_timeout` restores. Build the sink first
    -- and the total timeout is never enforced by anything, because LuaSocket
    -- resets its own timeout between polls; a slow-drip response would then
    -- hold the UI thread indefinitely, which is the whole point of having a
    -- short automatic profile. Every KOReader caller sets the timeout first.
    --
    -- First argument is LuaSocket's per-block timeout, second the total.
    socketutil:set_timeout(profile.block, profile.total)

    local sink = {}
    local collector = socketutil.table_sink and socketutil.table_sink(sink) or ltn12.sink.table(sink)
    -- `socket.http` handles https here: KOReader's socketutil requires
    -- `ssl.https` unconditionally at load, so a build without LuaSec could not
    -- run this plugin at all.
    local _result, status = http.request{
        url = ENDPOINT .. path,
        method = method,
        headers = headers,
        source = body_json and ltn12.source.string(body_json) or nil,
        sink = collector,
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

--- Fills gaps in what the sidecar knew from what the statistics database knows.
---
--- Declared before its caller on purpose. As a `local function` further down the
--- file it would be out of scope at the call site, which compiles to a global
--- lookup, yields nil, and throws — inside a pcall, so the only symptom is that
--- nothing ever syncs.
---
--- KOReader writes the bare literal "N/A" into the statistics table rather than
--- leaving a column null, so those have to be treated as absent or they end up
--- as book titles. (It is not translated, so comparing the literal is safe.)
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

--- Metadata from the statistics database, keyed by checksum.
---
--- The sidecar's cached `doc_props` is the better source when it is there, but
--- it can be absent or cleared — and the server treats an absent field as "no
--- longer known", so pushing a nil title would erase one it had already
--- learned. The statistics `book` table always has a title and authors for
--- anything with reading history, which makes it the right backstop. It is
--- also the only source for `total_read_time`.
---
--- Aggregated by checksum rather than read row-by-row: the table's unique index
--- is (title, authors, md5), so editing a book's metadata between opens leaves
--- several rows sharing one checksum. Taking whichever row SQLite happened to
--- return last would report a fraction of the real reading time, while the
--- session query below correctly unions every `id_book` under that checksum.
function Storylines:collectBookStats()
    if lfs.attributes(STATS_DB, "mode") ~= "file" then return {} end

    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 then return {} end

    local stats = {}

    local ok, err = pcall(function()
        local conn = SQ3.open(STATS_DB, "ro")
        local ok_query, rows = pcall(function()
            return conn:exec([[
                SELECT md5,
                       MAX(title),
                       MAX(authors),
                       MAX(series),
                       MAX(language),
                       MAX(pages),
                       SUM(total_read_time),
                       MAX(last_open)
                FROM book
                WHERE md5 IS NOT NULL
                GROUP BY md5;
            ]])
        end)
        conn:close()

        if not ok_query then error(rows) end
        -- `exec` returns columns, not rows, and nil for an empty result.
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

--- Everything we know about each book, keyed by document checksum.
---
--- The checksum comes from the sidecar's own `partial_md5_checksum`, which
--- KOReader computes on open and which *is* the `book.md5` the statistics table
--- joins on. Recomputing it with `util.partialMD5` would mean twelve file reads
--- per book per sync, and a cache to invalidate, for a value already on disk.
function Storylines:collectBooks()
    local by_md5 = {}
    local remembered = self.settings:readSetting("identifiers") or {}
    local stats = self:collectBookStats()
    local seen_md5 = {}

    for _index, entry in ipairs(ReadHistory.hist or {}) do
        local file = entry.file

        if file and lfs.attributes(file, "mode") == "file" then
            local ok_settings, settings = pcall(function() return DocSettings:open(file) end)

            if ok_settings and settings then
                local md5 = settings:readSetting("partial_md5_checksum")

                if md5 and md5 ~= "" then
                    local props = settings:readSetting("doc_props") or {}
                    local book = {
                        doc_key = md5,
                        filename = file:match("([^/]+)$") or file,
                        title = props.title,
                        authors = props.authors,
                        series = props.series,
                        series_index = tonumber(props.series_index),
                        language = props.language,
                        identifiers = props.identifiers,
                        koreader_pages = tonumber(settings:readSetting("doc_pages")),
                        percentage = tonumber(settings:readSetting("percent_finished")),
                        -- Left nil rather than "" when neither key exists: an
                        -- empty string is a value, and the server would store
                        -- it over a position it already had.
                        position = settings:readSetting("last_xpointer")
                            or (settings:readSetting("last_page") and tostring(settings:readSetting("last_page")))
                            or nil,
                        -- When this device last opened the book. The app uses it
                        -- as the watermark for "is this position news", so it
                        -- has to be the device's own reckoning.
                        last_open = tonumber(entry.time),
                    }

                    local summary = settings:readSetting("summary")
                    if type(summary) == "table" then
                        book.summary_status = summary.status
                        book.summary_rating = tonumber(summary.rating)
                        book.summary_note = summary.note
                        book.summary_modified = summary.modified
                    end

                    -- Identifiers live in the sidecar's cached props, which can
                    -- be cleared. Once seen they are remembered here, because
                    -- the server treats an absent field as "no longer known"
                    -- and an ISBN is what makes matching exact rather than a
                    -- guess.
                    if book.identifiers and book.identifiers ~= "" then
                        remembered[md5] = book.identifiers
                    elseif remembered[md5] then
                        book.identifiers = remembered[md5]
                    end

                    mergeStats(book, stats[md5])
                    book.isbn = self:isbnFrom(book.identifiers)
                    book.device_name = self:deviceName()

                    by_md5[md5] = book
                    seen_md5[md5] = true
                end
            end
        end
    end

    -- Pruned to what the history still holds, so this can't grow for ever.
    local kept = {}
    for md5, value in pairs(remembered) do
        if seen_md5[md5] then kept[md5] = value end
    end
    self:setSetting("identifiers", kept)

    return by_md5
end

--- Pulls an ISBN out of crengine's `doc.identifiers`.
---
--- The field is a free-form list of `scheme:value` pairs whose separator and
--- casing vary by publisher, and it routinely carries Calibre ids, Goodreads
--- ids and ASINs alongside — several of which are ten or thirteen digits and
--- would otherwise be mistaken for an ISBN. Since an ISBN match bypasses title
--- *and* author verification in the app, a false one is worse than none, so:
--- an explicitly labelled `isbn:` wins outright, and an unlabelled candidate
--- has to pass its check digit and, at thirteen digits, carry a real Bookland
--- prefix.
function Storylines:isbnFrom(identifiers)
    if type(identifiers) ~= "string" or identifiers == "" then return nil end

    local labelled = identifiers:lower():match("isbn[:=]%s*([%dxX%-%s]+)")
    if labelled then
        local candidate = self:validISBN(labelled)
        if candidate then return candidate end
    end

    for token in identifiers:gmatch("[%dXx%-]+") do
        local candidate = self:validISBN(token)
        if candidate then return candidate end
    end
    return nil
end

--- Normalises and check-digit-validates an ISBN, or returns nil.
function Storylines:validISBN(raw)
    local value = raw:gsub("[%s%-]", ""):upper()

    if #value == 10 then
        local sum = 0
        for index = 1, 10 do
            local character = value:sub(index, index)
            local digit = (character == "X") and 10 or tonumber(character)
            -- X is only ever legal as the final check digit.
            if not digit or (character == "X" and index ~= 10) then return nil end
            sum = sum + digit * (11 - index)
        end
        return (sum % 11 == 0) and value or nil
    end

    if #value == 13 then
        if not (value:sub(1, 3) == "978" or value:sub(1, 3) == "979") then return nil end
        local sum = 0
        for index = 1, 13 do
            local digit = tonumber(value:sub(index, index))
            if not digit then return nil end
            sum = sum + digit * ((index % 2 == 1) and 1 or 3)
        end
        return (sum % 10 == 0) and value or nil
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
---
--- Returns (sessions, watermark). The watermark is the crux, and it has to
--- satisfy two things at once: never skip a row, and never re-send a session
--- under a *different* `started_at` — because that key is the server's identity
--- for the sitting, so a shifted one is a duplicate rather than a correction.
--- See `sessionPlan`.
function Storylines:collectSessions(since)
    for step, limit in ipairs(ROW_LIMIT_STEPS) do
        local sessions, watermark, truncated = self:querySessions(since, limit)

        -- nil means the database could not be read. Propagated rather than
        -- flattened to an empty list, so the caller can tell a failure from a
        -- device with no history.
        if sessions == nil then return nil, nil end

        -- Something to send, or the query reached the end of the history:
        -- either way this is the answer.
        if #sessions > 0 or not truncated then
            return sessions, watermark
        end

        -- Nothing sendable *and* rows left unread: every sitting in the window
        -- is unfinished, so widening is the only way the watermark can move.
        -- The final step reads without a limit, so this cannot be the reason it
        -- ends — if it ever is, say so plainly rather than implying a retry
        -- will help, because for already-written history it will not.
        if step == #ROW_LIMIT_STEPS then
            logger.warn("Storylines: no sendable sitting even unbounded; history from",
                        since, "onwards is stalled")
            return sessions, watermark
        end
    end

    return {}, nil
end

--- One pass at `limit` rows. Returns (sendable sessions, watermark, truncated).
function Storylines:querySessions(since, limit)
    if lfs.attributes(STATS_DB, "mode") ~= "file" then return {}, nil, false end

    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 then
        logger.warn("Storylines: no sqlite binding, skipping history")
        return {}, nil, false
    end

    local sessions = {}
    local row_count = 0
    local last_row_start = nil

    local ok, err = pcall(function()
        local conn = SQ3.open(STATS_DB, "ro")
        local ok_query, rows = pcall(function()
            -- Ordered by time across all books, never by book. Grouping by book
            -- first would let the row limit cut mid-book while the watermark
            -- advanced past a *different* book's later rows, losing everything
            -- in between. Interleaved books are handled instead by keeping one
            -- open session per book.
            --
            -- The bounds are integers this code produced, so they are formatted
            -- in rather than bound; ljsqlite3's prepared-statement row
            -- iteration differs between builds and `exec` is the portable path.
            --
            -- `md5 IS NOT NULL` is load-bearing beyond filtering: a nil in the
            -- first column would leave a hole in the returned array and `#`
            -- would truncate the batch silently.
            return conn:exec(string.format([[
                SELECT b.md5, d.page, d.start_time, d.duration, d.total_pages
                FROM page_stat_data d
                JOIN book b ON b.id = d.id_book
                WHERE d.start_time > %d AND b.md5 IS NOT NULL
                ORDER BY d.start_time
                LIMIT %d;
            ]], math.floor(since), math.floor(limit)))
        end)
        conn:close()

        if not ok_query then error(rows) end
        if not rows or not rows[1] then return end

        local open = {}

        --- `open_at_end` marks a session that unread rows could still extend.
        ---
        --- Not simply "was still open when the rows ran out". `open` holds only
        --- the latest session per book — a gap-closed one is replaced, never
        --- deleted — so at the end of the window *every* book that appears
        --- anywhere in it has a session sitting in `open`, whether or not the
        --- row limit cut anything of its. Flagging all of them collapsed the
        --- boundary onto the oldest session in the window and froze the
        --- watermark for good.
        local function close_session(entry, open_at_end)
            local count = 0
            for _page in pairs(entry.pages_seen) do count = count + 1 end
            entry.pages = count
            entry.pages_seen = nil
            entry.open_at_end = open_at_end
            sessions[#sessions + 1] = entry
        end

        row_count = #rows[1]

        for index = 1, row_count do
            local md5 = rows[1][index]
            local page = tonumber(rows[2][index]) or 0
            local start_time = tonumber(rows[3][index]) or 0
            local duration = tonumber(rows[4][index]) or 0
            local total_pages = tonumber(rows[5][index]) or 0

            last_row_start = start_time

            local entry = open[md5]
            if entry and start_time - entry.ends_at > SESSION_GAP_SECONDS then
                -- Ended by a real gap, so it is complete whatever else this
                -- query does or doesn't reach.
                close_session(entry, false)
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
            -- The last row's own start, which is what the watermark is
            -- compared against — `ends_at` includes the reading time and would
            -- overshoot.
            entry.last_start = start_time
            -- The page count in force at the end of the sitting: if the font
            -- changed mid-session, the later value matches the pages actually
            -- turned.
            if total_pages > 0 then entry.total_pages = total_pages end
            entry.pages_seen[page] = true
        end

        -- Unread rows all start at or after the last row this query read, so a
        -- session can only be extended by one if its own end is within a gap of
        -- that point. Anything that finished earlier is complete, however the
        -- query was cut.
        for _md5, entry in pairs(open) do
            close_session(entry, (last_row_start - entry.ends_at) <= SESSION_GAP_SECONDS)
        end
    end)

    if not ok then
        -- nil, not an empty list. A database that cannot be read is not a
        -- device with nothing to say, and reporting "Synced 0 sessions" for a
        -- corrupt statistics file is the same silent-success shape that hid
        -- the plugin being a complete no-op.
        logger.warn("Storylines: could not read statistics:", tostring(err))
        return nil, nil, false
    end

    table.sort(sessions, function(a, b) return a.started_at < b.started_at end)

    local truncated = row_count >= limit
    local watermark, sendable = self:sessionPlan(sessions, truncated, last_row_start, since)

    -- Bookkeeping for the fold, not part of the payload.
    for _index, session in ipairs(sendable) do
        session.ends_at = nil
        session.open_at_end = nil
        session.last_start = nil
    end

    return sendable, watermark, truncated
end

--- Decides how far the watermark may move, and which sessions are safe to send.
---
--- A session is only sendable once it can no longer change, because
--- `(document, started_at)` is the server's identity for a sitting: re-sending
--- the same reading under a shifted `started_at` is a duplicate, not a
--- correction, and its duration is then counted twice.
---
--- Two independent ways a session can still change:
---
---   * It may still be *being read*. That is a wall-clock question — "is its
---     last page turn more than a gap ago" — not a "are there later rows" one.
---     Asking about rows would mean the sitting in progress right now is never
---     sent, because by definition nothing follows it.
---   * The query may have stopped mid-sitting. Any session still open when the
---     rows ran out can continue in rows this query didn't reach.
---
--- The second is what broke the previous two attempts. Holding back only the
--- newest session is not enough: with several books interleaved, *every*
--- session is open at the boundary, and the older ones were being sent
--- truncated and then re-folded under new keys on the following pass. Verified
--- by simulation over interleaved, sequential, oversized-sitting and
--- two-years-of-history shapes.
---
--- Everything from the earliest unsendable session onwards is withheld
--- together, since the watermark is a single point in time and cannot express
--- "these but not those".
function Storylines:sessionPlan(sessions, truncated, last_row_start, since)
    if #sessions == 0 then return nil, {} end

    local now = os.time()
    local boundary = nil

    local function lower(candidate)
        if not boundary or candidate < boundary then
            boundary = candidate
            return true
        end
        return false
    end

    for _index, session in ipairs(sessions) do
        local settled = (now - session.ends_at) > SESSION_GAP_SECONDS
        local may_continue = session.open_at_end and truncated

        if not settled or may_continue then
            lower(session.started_at)
        end
    end

    -- A session occupies a span, not an instant, so choosing by `started_at`
    -- alone is not enough: the watermark re-reads every row from `boundary`
    -- onwards, and a session that began before it but ran past it would have
    -- its tail re-folded into a *new* session with a different `started_at` —
    -- a duplicate the server cannot collapse, with its time counted twice.
    --
    -- Withholding such a session lowers the boundary, which can bring another
    -- one into the same situation, so this settles to a fixed point. It
    -- terminates because the boundary only ever decreases and is bounded below
    -- by the earliest session in the batch.
    local function settleCrossings()
        local changed = true
        while changed do
            changed = false
            for _index, session in ipairs(sessions) do
                if boundary and session.started_at < boundary and session.last_start >= boundary then
                    if lower(session.started_at) then changed = true end
                end
            end
        end
    end

    local function currentlySendable()
        local out = {}
        for _index, session in ipairs(sessions) do
            if not boundary or session.started_at < boundary then
                out[#out + 1] = session
            end
        end
        return out
    end

    settleCrossings()
    local sendable = currentlySendable()

    -- Deliberately not capped here. Capping by lowering the boundary looked
    -- tidy — watermark and payload stay in step — but with enough overlapping
    -- sittings the re-settling drags the boundary back past the first session
    -- and empties the batch, which freezes the watermark and reports success:
    -- the exact failure this whole function exists to prevent.
    --
    -- Size is a transport concern, not a correctness one. `performSync` splits
    -- the result across requests and only advances the watermark once every
    -- one of them has landed, which keeps the two questions apart.
    local watermark = boundary and (boundary - 1) or (last_row_start or since)
    return math.max(watermark, since), sendable
end

-- MARK: - Syncing

--- Whether it is safe to use the network without interrupting the user.
---
--- Deliberately *not* `willRerunWhenOnline` on the automatic paths. That calls
--- `isOnline`, which does a blocking DNS lookup, and when offline falls through
--- to `promptWifiOn` — the default action — so closing a book would pop "turn
--- on Wi-Fi?" every single time, and suspending would pop it as the screen goes
--- dark. kosync refuses to do this for the same reason.
local function canSyncQuietly()
    return NetworkMgr:isConnected()
end

function Storylines:syncNow(interactive)
    if not self:isPaired() then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Pair with Storylines first.") })
        end
        return
    end

    -- Class-level, like the settings: both the FileManager and the ReaderUI
    -- instance exist at once, and two concurrent syncs would race the same
    -- watermark.
    if Storylines.syncing then return end

    local profile = interactive and INTERACTIVE or AUTOMATIC

    if interactive then
        if NetworkMgr:willRerunWhenOnline(function() self:syncNow(true) end) then
            return
        end
    elseif not canSyncQuietly() then
        return
    end

    Storylines.syncing = true
    self.page_update_counter = 0

    local ok, err = pcall(function() self:performSync(interactive, profile) end)

    Storylines.syncing = false

    if not ok then
        logger.warn("Storylines: sync failed:", tostring(err))
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Sync failed. Please try again.") })
        end
    end
end

function Storylines:performSync(interactive, profile)
    local books = self:collectBooks()

    -- Only what has changed since the last successful push. Without this every
    -- sync re-sends every book in the reading history — including free-text
    -- reviews — which at fifty page turns, every close and every reconnect is
    -- a lot of bytes for no new information.
    local signatures = self.settings:readSetting("doc_signatures") or {}
    local fresh_signatures = {}
    local documents = {}

    for md5, book in pairs(books) do
        local signature = JSON.encode(book)
        fresh_signatures[md5] = signature
        if signatures[md5] ~= signature then
            documents[#documents + 1] = book
        end
    end

    local pushed_documents = 0
    local pushed_sessions = 0
    local failed = false

    -- Documents first: they are small, they carry the metadata that makes the
    -- history meaningful, and the app can act on a position without any
    -- history at all.
    for offset = 1, #documents, MAX_DOCUMENTS_PER_PUSH do
        local batch = {}
        for index = offset, math.min(offset + MAX_DOCUMENTS_PER_PUSH - 1, #documents) do
            batch[#batch + 1] = documents[index]
        end

        local response, status = self:request("POST", "/push", { documents = batch }, profile)
        if status == 401 then
            self:handleRejectedToken()
            return
        end
        if status ~= 200 then
            failed = true
            break
        end
        pushed_documents = pushed_documents + (tonumber(response and response.documents) or 0)
    end

    if not failed and #documents > 0 then
        -- Recorded only once the push landed, so a failure re-sends next time.
        self:setSetting("doc_signatures", fresh_signatures)
    end

    -- Then history, paging from the watermark. The watermark only advances on a
    -- 200, so an interrupted sync resumes rather than losing a chunk.
    if not failed then
        for _batch = 1, profile.batches do
            local since = self.settings:readSetting("last_session_start") or 0
            local sessions, watermark = self:collectSessions(since)

            -- Unreadable statistics database. Reported as a failure so the
            -- user isn't told the sync succeeded with nothing to send.
            if sessions == nil then
                failed = true
                break
            end

            -- Nothing to send does not always mean nothing to do: a window
            -- holding only unfinished sittings still moves the watermark up to
            -- just below the earliest of them, so the settled history before
            -- that point is never re-read.
            if #sessions == 0 then
                if not watermark or watermark <= since then break end
                self:setSetting("last_session_start", watermark)
                self.settings:flush()
            else
                -- Split for transport only. `sessionPlan` decided which
                -- sittings are safe to send as one unit, so the watermark moves
                -- only after every part of that unit has landed — a partial
                -- push must be re-sent, and re-sending is harmless because the
                -- keys are stable.
                local rejected = false

                for offset = 1, #sessions, MAX_SESSIONS_PER_PUSH do
                    local chunk = {}
                    for index = offset, math.min(offset + MAX_SESSIONS_PER_PUSH - 1, #sessions) do
                        chunk[#chunk + 1] = sessions[index]
                    end

                    local response, status = self:request("POST", "/push", { sessions = chunk }, profile)
                    if status == 401 then
                        self:handleRejectedToken()
                        return
                    end
                    if status ~= 200 then
                        failed = true
                        rejected = true
                        break
                    end

                    pushed_sessions = pushed_sessions + (tonumber(response and response.sessions) or 0)
                end

                if rejected then break end

                if not watermark or watermark <= since then break end
                self:setSetting("last_session_start", watermark)
                self.settings:flush()
            end
        end
    end

    if not failed then
        self:setSetting("last_sync_at", os.time())
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

-- MARK: - Events

function Storylines:onStorylinesSyncNow()
    self:syncNow(true)
    return true
end

function Storylines:onCloseDocument()
    if not self:autoSyncEnabled() then return end
    -- Closing a book is the single best moment to sync: the statistics plugin
    -- has just flushed the last page's duration, and the user is not reading.
    -- Bounded to two round trips with short timeouts, because this runs inline
    -- on the UI thread before the reader finishes closing.
    self:syncNow(false)

    -- The sitting that just ended is by definition unsettled, so the sync above
    -- deliberately withholds it. Every other trigger fires on *new* activity,
    -- so without this a reader who finishes a book and doesn't open another
    -- would never see that last sitting arrive.
    --
    -- Untracked on purpose: the reader widget closes moments after this, and
    -- `onCloseWidget` cancelling it would cancel the entire point. Safe because
    -- it captures no instance — the settings and the sync mutex are both
    -- class-level.
    UIManager:scheduleIn(SESSION_GAP_SECONDS + 60, Storylines.catchUpSync)
end

--- Delivers the final sitting once it has had time to settle.
---
--- A plain function, not a method: it must not hold a reference to the reader
--- instance that scheduled it, since that instance is torn down seconds later.
function Storylines.catchUpSync()
    local worker = setmetatable({}, { __index = Storylines })
    worker:loadSettings()
    if not worker:isPaired() or not worker:autoSyncEnabled() then return end
    worker:syncNow(false)
end

function Storylines:onNetworkConnected()
    if not self:autoSyncEnabled() then return end
    if not self:isPaired() then return end
    self:scheduleTracked(1, function() self:syncNow(false) end)
end

-- Deliberately no onSuspend. `Device:_beforeSuspend` broadcasts it inline on the
-- UI thread, immediately before the device writes to /sys/power/state, so any
-- network call there freezes the device for as long as it takes to time out.
-- Nothing is lost by skipping it: the statistics database is already on disk,
-- and closing the book, reconnecting, or the next fifty page turns all sync.

function Storylines:onPageUpdate(pageno)
    if not self:autoSyncEnabled() then return end

    -- PageUpdate also fires on rerenders, jumps and the position restore at
    -- open, so it is not a page-turn counter on its own. The statistics plugin
    -- guards the same way.
    if pageno and pageno == self.last_page_synced then return end
    self.last_page_synced = pageno

    self.page_update_counter = self.page_update_counter + 1
    if self.page_update_counter < self:pagesBeforeSync() then return end

    -- Deferred rather than immediate, so a run of quick page turns coalesces
    -- into one sync once the reader actually settles. Built before it is
    -- unscheduled, because unscheduling nil is not something UIManager is
    -- asked to do anywhere else, and cancelled in `onCloseWidget` so it cannot
    -- outlive this instance.
    self.deferred_sync = self.deferred_sync or function() self:syncNow(false) end
    UIManager:unschedule(self.deferred_sync)
    self:scheduleTracked(10, self.deferred_sync)
end

function Storylines:onFlushSettings()
    -- Guarded: flushing rewrites the file and renames a backup, and this fires
    -- on every suspend and every reader close whether or not anything changed.
    if self.settings and Storylines.settings_dirty then
        self.settings:flush()
        Storylines.settings_dirty = false
    end
end

return Storylines
