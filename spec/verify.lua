-- Drives the REAL main.lua through the stubbed KOReader environment and checks
-- the two properties that matter: no session is ever sent twice under a
-- different start, and no settled history is left behind.
local stub = dofile("stub.lua")
stub.install()

local PLUGIN = "../main.lua"
local GAP = 600

local function fresh()
    package.loaded["storylines_main"] = nil
    local chunk = assert(loadfile(PLUGIN))
    return chunk()
end

-- Ground truth: fold every row, keep sessions that are settled by `now`.
local function truth(rows, now)
    local open, out = {}, {}
    local function close(e)
        local n = 0; for _ in pairs(e.seen) do n = n + 1 end
        e.pages = n; e.seen = nil; out[#out+1] = e
    end
    table.sort(rows, function(a,b) return a[3] < b[3] end)
    for _, r in ipairs(rows) do
        local md5, page, st, dur = r[1], r[2], r[3], r[4]
        local e = open[md5]
        if e and st - e.ends_at > GAP then close(e); e = nil end
        if not e then e = { doc_key=md5, started_at=st, duration=0, ends_at=st, seen={} }; open[md5]=e end
        e.duration = e.duration + dur; e.ends_at = st + dur; e.last_start = st; e.seen[page] = true
    end
    for _, e in pairs(open) do close(e) end

    -- Deliverable at `now`, derived from the watermark's nature rather than
    -- from the implementation: progress is one scalar, so re-reading an
    -- unsettled sitting necessarily re-reads every row at or after its start.
    -- A settled session whose last row falls there cannot be sent yet without
    -- its tail coming back under a different key — it waits for the unsettled
    -- one to finish. `deferred.lua` proves such a session is then delivered.
    local earliest_unsettled = nil
    for _, e in ipairs(out) do
        if (now - e.ends_at) <= GAP and (not earliest_unsettled or e.started_at < earliest_unsettled) then
            earliest_unsettled = e.started_at
        end
    end

    local keep, deferred = {}, 0
    for _, e in ipairs(out) do
        local settled = (now - e.ends_at) > GAP
        local blocked = earliest_unsettled and e.last_start >= earliest_unsettled
        if settled and not blocked then
            keep[#keep+1] = e
        elseif settled then
            deferred = deferred + 1
        end
    end
    return keep, deferred
end

local real_os_time = os.time

local function run(name, rows, now)
    stub.rows = rows
    stub.books = {}
    stub.now = now
    -- The plugin asks os.time() whether a sitting has settled, so the test's
    -- notion of "now" has to be the one it sees.
    os.time = function() return now end

    local Storylines = fresh()
    local plugin = setmetatable({}, { __index = Storylines })
    plugin:loadSettings()
    plugin.settings.data = {}

    -- Server keyed exactly as the real one: (doc_key, started_at).
    local server, sends = {}, 0
    local since, guard = 0, 0

    while guard < 400 do
        guard = guard + 1
        local sessions, watermark = plugin:collectSessions(since)
        if #sessions > 0 then
            sends = sends + 1
            for _, s in ipairs(sessions) do
                local key = s.doc_key .. ":" .. s.started_at
                if server[key] and server[key] ~= s.duration then
                    server[key] = -1  -- contradictory rewrite
                else
                    server[key] = s.duration
                end
            end
        end
        if not watermark or watermark <= since then break end
        since = watermark
    end

    os.time = real_os_time
    local expected, deferred = truth(rows, now)
    local exp_keys, exp_dur = {}, 0
    for _, e in ipairs(expected) do exp_keys[e.doc_key..":"..e.started_at] = e.duration; exp_dur = exp_dur + e.duration end

    local got_dur, spurious, contradictory = 0, 0, 0
    for k, d in pairs(server) do
        if d == -1 then contradictory = contradictory + 1 end
        if not exp_keys[k] then spurious = spurious + 1 end
        got_dur = got_dur + (d == -1 and 0 or d)
    end
    local missing = 0
    for k in pairs(exp_keys) do if not server[k] then missing = missing + 1 end end

    local ok = spurious == 0 and missing == 0 and contradictory == 0 and got_dur == exp_dur
    print(string.format("%s  %-42s sent=%d/%d  batches=%d  spurious=%d missing=%d deferred=%d  duration %d/%d",
        ok and "PASS" or "FAIL", name, (function() local n=0 for _ in pairs(server) do n=n+1 end return n end)(),
        #expected, sends, spurious, missing, deferred, got_dur, exp_dur))
    return ok
end

local results = {}

-- The four-row duplicate the verifier reproduced.
results[#results+1] = run("boundary-crossing session (4 rows)", {
    {"A",1,99000,60,300},{"B",1,99010,60,200},{"A",2,99290,60,300},{"B",2,99550,60,200},
}, 100000)

-- The measured cliff: above 32k unsent rows the old code froze.
local function history(days, rows_per_day, interleave)
    local rows, t = {}, 1000000
    for d = 1, days do
        t = t + 86400
        local book = "S" .. math.floor(d / 14)
        for i = 0, rows_per_day - 1 do rows[#rows+1] = {book, i, t + i*90, 85, 350} end
        if interleave and d % 9 == 0 then
            for i = 0, 5 do rows[#rows+1] = {"alt", i, t + 60 + i*95, 88, 200} end
        end
    end
    return rows, t + 200000
end

local r, n = history(730, 45, false)
results[#results+1] = run(string.format("730 days, %d rows (the 33k cliff)", #r), r, n)

r, n = history(730, 45, true)
results[#results+1] = run("730 days with interleaving", r, n)

r, n = history(1200, 50, true)
results[#results+1] = run(string.format("1200 days, %d rows", #r), r, n)

-- Shapes from the earlier simulation.
local rows = {}
for i = 0, 11 do
    rows[#rows+1] = {"A", 10+i, 1000 + i*200, 60, 300}
    rows[#rows+1] = {"B", 40+i, 1100 + i*200, 60, 200}
end
results[#results+1] = run("two books interleaved", rows, 9000000)

rows = {}
for b = 0, 4 do for i = 0, 29 do rows[#rows+1] = {"BK"..b, i, 300000 + b*40 + i*137, 60, 300} end end
results[#results+1] = run("five books heavily interleaved", rows, 9000000)

rows = {}
for i = 0, 4 do rows[#rows+1] = {"F", i, 100000 + i*70, 65, 250} end
for i = 0, 2 do rows[#rows+1] = {"F", 50+i, 200000 - 200 + i*60, 55, 250} end
results[#results+1] = run("history + sitting in progress", rows, 200000)

results[#results+1] = run("single row", {{"G",1,400000,60,100}}, 9000000)
results[#results+1] = run("empty history", {}, 9000000)

local all = true
for _, ok in ipairs(results) do all = all and ok end
print("\nALL PASS: " .. tostring(all))
os.exit(all and 0 or 1)
