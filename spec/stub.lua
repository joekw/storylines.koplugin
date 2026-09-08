-- Stub KOReader environment so the real main.lua can be loaded and driven.
local M = {}

local real_require = require
local registry = {}

local function reg(name, mod) registry[name] = mod end

-- logger
local logmsgs = {}
reg("logger", {
  warn = function(...) local t={} for i,v in ipairs({...}) do t[i]=tostring(v) end
    logmsgs[#logmsgs+1] = "WARN "..table.concat(t," ") end,
  info = function() end, dbg = function() end, err = function() end,
})
M.logmsgs = logmsgs

reg("datastorage", { getSettingsDir = function() return "/tmp/koset" end })
reg("device", { model = "TestReader", isKindle=function() return false end,
  isKobo=function() return true end, isAndroid=function() return false end,
  isPocketBook=function() return false end, isRemarkable=function() return false end })
reg("dispatcher", { registerAction = function() end })
reg("version", { getShortVersion = function() return "2026.01" end })

-- LuaSettings in-memory
local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings.open() return setmetatable({data={}, flushes=0}, LuaSettings) end
function LuaSettings:readSetting(k, d) local v=self.data[k]; if v==nil then return d end; return v end
function LuaSettings:saveSetting(k,v) self.data[k]=v end
function LuaSettings:delSetting(k) self.data[k]=nil end
function LuaSettings:nilOrTrue(k) local v=self.data[k]; return v==nil or v==true end
function LuaSettings:flush() self.flushes=self.flushes+1 end
reg("luasettings", LuaSettings)

reg("ui/network/manager", { isConnected=function() return true end,
  willRerunWhenOnline=function() return false end })
reg("readhistory", { hist = {} })

local shown = {}
reg("ui/uimanager", { show=function(_, w) shown[#shown+1]=w end,
  nextTick=function(_,f) end, scheduleIn=function() end, unschedule=function() end,
  close=function() end })
M.shown = shown

reg("ui/widget/infomessage", { new=function(_, t) return t end })
reg("ui/widget/inputdialog", { new=function(_, t) return t end })

local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer
function WidgetContainer:extend(o)
  o = o or {}
  o.__index = o
  return setmetatable(o, { __index = self, __call = function(cls, t) return t end })
end
reg("ui/widget/container/widgetcontainer", WidgetContainer)

reg("ltn12", { source={string=function(s) return s end}, sink={table=function(t) return t end} })
reg("socketutil", { set_timeout=function() end, reset_timeout=function() end })
reg("ffi/util", { template=function(fmt, ...)
  local args={...}
  return (fmt:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end)) end })
reg("gettext", setmetatable({}, {__call=function(_, s) return s end}))

-- deterministic JSON good enough for signatures
local function enc(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys+1]=k end
    table.sort(keys, function(a,b) return tostring(a)<tostring(b) end)
    local parts = {}
    for _,k in ipairs(keys) do parts[#parts+1]=string.format("%q",tostring(k))..":"..enc(v[k]) end
    return "{"..table.concat(parts,",").."}"
  end
  error("cannot encode "..t)
end
reg("json", { encode=enc, decode=function(s) return { documents=1, sessions=1 } end })

-- HTTP recorder
M.requests = {}
reg("socket.http", { request = function(t)
  M.requests[#M.requests+1] = { url=t.url, method=t.method, body=t.source }
  return 1, M.next_status or 200, {}, "OK"
end })

-- lfs
reg("libs/libkoreader-lfs", { attributes=function(p, what)
  if what=="mode" then return "file" end
  return nil
end })

-- DocSettings
M.docsettings = {}
reg("docsettings", { open=function(_, path)
  local d = M.docsettings[path] or {}
  return { readSetting=function(_, k) return d[k] end }
end })

-- fake sqlite: M.rows is an array of {md5, page, start_time, duration, total_pages}
--              M.books is an array of book rows for collectBookStats
M.rows = {}
M.books = {}
M.query_log = {}
local function columnise(rowset, ncol)
  if #rowset == 0 then return nil, 0 end
  local out = {}
  for c = 1, ncol do
    out[c] = {}
    for r = 1, #rowset do out[c][r] = rowset[r][c] end
  end
  return out, #rowset
end
reg("lua-ljsqlite3/init", { open=function(_, mode)
  return {
    exec = function(_, sql)
      M.query_log[#M.query_log+1] = sql
      if sql:find("FROM book") and sql:find("GROUP BY md5") then
        return columnise(M.books, 8)
      end
      local since = tonumber(sql:match("start_time > (%-?%d+)"))
      local limit = tonumber(sql:match("LIMIT (%d+)"))
      local sel = {}
      for _, r in ipairs(M.rows) do
        if r[3] > since then
          sel[#sel+1] = r
          if #sel >= limit then break end
        end
      end
      return columnise(sel, 5)
    end,
    close = function() end,
  }
end })

M.registry = registry
function M.install()
  local g = _G
  g.require = function(name)
    if registry[name] ~= nil then return registry[name] end
    return real_require(name)
  end
end
return M
