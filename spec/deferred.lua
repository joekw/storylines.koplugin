-- A session that spans a still-in-progress sitting must be deferred, never
-- duplicated -- and must land once the later sitting settles. One scalar
-- watermark cannot say "re-read B but not A", so deferring A is forced.
local stub = dofile("stub.lua")
stub.install()
local real_os_time = os.time

local rows = {
    {"A",1,99000,60,300},{"B",1,99010,60,200},
    {"A",2,99290,60,300},{"B",2,99550,60,200},
}

local Storylines = assert(loadfile("../main.lua"))()
local plugin = setmetatable({}, { __index = Storylines })
plugin:loadSettings()
plugin.settings.data = {}
stub.rows = rows
stub.books = {}

local server = {}
local function drain(now, label)
    os.time = function() return now end
    local since = plugin.settings:readSetting("last_session_start") or 0
    local guard = 0
    while guard < 50 do
        guard = guard + 1
        local sessions, watermark = plugin:collectSessions(since)
        for _, s in ipairs(sessions) do
            local key = s.doc_key .. ":" .. s.started_at
            server[key] = s.duration
        end
        if not watermark or watermark <= since then break end
        since = watermark
        plugin.settings:saveSetting("last_session_start", since)
    end
    os.time = real_os_time

    local keys = {}
    for k in pairs(server) do keys[#keys+1] = k end
    table.sort(keys)
    print(string.format("  %-38s server rows: [%s]", label, table.concat(keys, ", ")))
    return keys
end

print("boundary-crossing, two phases:")
local phase1 = drain(100000, "B still being read")
local phase2 = drain(101000, "10 min later, B settled")

-- A's real sitting is 99000..99350 (120s); B's is 99010..99610 (120s).
local expected = { ["A:99000"] = 120, ["B:99010"] = 120 }
local ok = true
for k, d in pairs(expected) do
    if server[k] ~= d then ok = false; print("  MISSING or wrong: " .. k) end
end
for k, d in pairs(server) do
    if not expected[k] then ok = false; print("  SPURIOUS: " .. k .. " = " .. d) end
end
if #phase1 ~= 0 then
    ok = false
    print("  UNEXPECTED: something was sent while B was still in progress")
end

print(ok and "\nPASS  deferred, then delivered exactly once" or "\nFAIL")
os.exit(ok and 0 or 1)
