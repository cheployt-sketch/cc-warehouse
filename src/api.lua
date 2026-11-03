-- warehouse/api.lua: the client library for apps.
--
--   local wh = require("/warehouse/api")
--   local vault = wh.connect()
--   print(vault.count("minecraft:cobblestone"))
--   vault.withdraw("minecraft:cobblestone", 128, "minecraft:chest_3")
--   vault.deposit("minecraft:chest_3")
--
-- connect() finds the service: on the same computer it talks through
-- events (no setup needed); from another computer it talks over rednet,
-- sealed with the warehouse key you paired with `wh pair`. Every method
-- raises an error with a readable message when the service refuses or does
-- not answer; vault.try(op, args) returns ok, result-or-error instead.
--
-- Change events: vault.pullEvent(timeout) returns the next
-- { type = "change", items = { { key, delta, count }, ... } } or nil.

local API = { VERSION = "0.1.0" }

-- Where the warehouse folder is, so the libraries can be found from any
-- program directory. Normally /warehouse.
local ROOT = "/warehouse"
do
  local ok, info = pcall(function() return debug.getinfo(1, "S") end)
  local src = ok and info and info.source
  if type(src) == "string" and src:sub(1, 1) == "@" then
    local dir = fs.getDir(src:sub(2))
    if fs.exists(fs.combine(dir, "lib/secure.lua")) then ROOT = "/" .. dir end
  end
end
API.ROOT = ROOT

-- Programs started by the shell have require and package; code loaded some
-- other way (an eval, an app with its own environment) may not, so bring a
-- small loader that finds the warehouse modules and CraftOS's own.
local function makeRequire()
  if type(package) == "table" and type(require) == "function" and type(package.path) == "string" then
    package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path
    return require
  end
  local loaded, env = {}, nil
  local function req(name)
    if loaded[name] ~= nil then return loaded[name] end
    local rel = tostring(name):gsub("%.", "/")
    for _, pattern in ipairs({ ROOT .. "/?.lua", ROOT .. "/?/init.lua", "/rom/modules/main/?.lua", "/rom/modules/main/?/init.lua" }) do
      local path = pattern:gsub("%?", rel)
      if fs.exists(path) and not fs.isDir(path) then
        local fn, err = loadfile(path, nil, env)
        if not fn then error(err, 0) end
        local v = fn(name)
        if v == nil then v = true end
        loaded[name] = v
        return v
      end
    end
    error("module '" .. tostring(name) .. "' not found", 2)
  end
  env = setmetatable({ require = req }, { __index = _ENV })
  return req
end
local require = makeRequire()

local util = require("lib.util")
local secure -- loaded only when rednet is needed (crypto init takes a moment)

local Client = {}
Client.__index = Client

local counter = 0
local function newId()
  counter = counter + 1
  return os.epoch("utc") .. "-" .. os.getComputerID() .. "-" .. counter .. "-" .. math.random(1, 1000000)
end

local function openModems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      rednet.open(name)
      n = n + 1
    end
  end
  return n
end

-- Sends one request and waits for its reply. Returns ok, result-or-error.
function Client:call(op, args)
  local id = newId()
  local req = { id = id, op = op, args = args or {}, from = os.getComputerID() }
  local timer = os.startTimer(self.timeout)
  if self.mode == "local" then
    os.queueEvent("warehouse_request", req)
    while true do
      local ev, a = os.pullEvent()
      if ev == "warehouse_reply" and type(a) == "table" and a.id == id then
        if a.ok then return true, a.result end
        return false, a.error
      elseif ev == "timer" and a == timer then
        return false, "the warehouse service did not answer (is it running?)"
      end
    end
  end
  rednet.send(self.server, secure.seal(self.key, "req", req), secure.PROTOCOL)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and c == secure.REPLY_PROTOCOL then
      local body = secure.open(self.key, "resp", b)
      if body and body.id == id then
        if body.ok then return true, body.result end
        return false, body.error
      end
    elseif ev == "timer" and a == timer then
      return false, "warehouse #" .. tostring(self.server) .. " did not answer"
    end
  end
end

Client.try = Client.call

local function must(self, op, args)
  local ok, res = self:call(op, args)
  if not ok then error(tostring(res), 3) end
  return res
end

-- Is a service running on this computer? (Answers within `timeout` seconds.)
local function probeLocal(timeout)
  local id = newId()
  os.queueEvent("warehouse_request", { id = id, op = "ping", args = {} })
  local timer = os.startTimer(timeout)
  while true do
    local ev, a = os.pullEvent()
    if ev == "warehouse_reply" and type(a) == "table" and a.id == id then return a.ok and a.result or false end
    if ev == "timer" and a == timer then return false end
  end
end

-- opts: mode ("local" or "rednet"; default: local if a service runs here,
-- else rednet), server (computer ID), hostname, key (base64, instead of
-- the paired key), timeout (seconds, default 10).
local function connect(opts)
  opts = opts or {}
  local self = setmetatable({ timeout = opts.timeout or 10 }, Client)
  if opts.mode ~= "rednet" then
    local info = probeLocal(opts.probeTimeout or 1)
    if info then
      self.mode = "local"
      self.info = info
      return self
    end
    if opts.mode == "local" then error("no warehouse service is running on this computer", 2) end
  end
  secure = secure or require("lib.secure")
  local cred = util.readTable(ROOT .. "/data/client") or {}
  self.key = secure.decodeKey(opts.key or cred.key)
  if not self.key then error("not paired with a warehouse: run 'wh pair <key>' (the key is shown by 'warehouse key' on the warehouse computer)", 2) end
  if openModems() == 0 then error("no modem attached, so the warehouse cannot be reached", 2) end
  self.server = opts.server or cred.server
  if not self.server then
    self.server = rednet.lookup(secure.PROTOCOL, opts.hostname or cred.hostname)
    if not self.server then error("no warehouse answered on rednet (is it running, with a modem in range?)", 2) end
  end
  self.mode = "rednet"
  local ok, res = self:call("ping")
  if not ok then error("warehouse #" .. tostring(self.server) .. ": " .. tostring(res), 2) end
  self.info = res
  return self
end

-- Stores the key (base64) and, when it can be found, the server, so that
-- connect() works from now on. Returns the server's ping, or raises.
function API.pair(keyString, opts)
  opts = opts or {}
  secure = secure or require("lib.secure")
  local key = secure.decodeKey(keyString)
  if not key then error("that is not a warehouse key", 2) end
  local cred = { key = secure.encodeKey(key), hostname = opts.hostname }
  if openModems() > 0 then
    local c = setmetatable({ timeout = opts.timeout or 5, key = key, mode = "rednet" }, Client)
    c.server = opts.server or rednet.lookup(secure.PROTOCOL, opts.hostname)
    if c.server then
      local ok, res = c:call("ping")
      if ok then
        cred.server = c.server
        cred.hostname = res.hostname
        util.writeTable(ROOT .. "/data/client", cred)
        return res
      end
    end
  end
  util.writeTable(ROOT .. "/data/client", cred)
  return nil
end

function API.unpair()
  local p = ROOT .. "/data/client"
  if fs.exists(p) then fs.delete(p) end
end

-- The API. Each method returns the op's result or raises an error.
function Client:ping() return must(self, "ping") end
function Client:help() return must(self, "help") end
function Client:stats() return must(self, "stats") end

-- opts: filter, sort ("count" or "name"), limit, offset. Returns the list
-- and the total number of matches.
function Client:items(opts)
  local r = must(self, "items", opts or {})
  return r.items, r.total
end

function Client:find(text, limit) return self:items({ filter = text, limit = limit }) end
function Client:item(item) return must(self, "item", { item = item }) end
function Client:count(item) return must(self, "count", { item = item }) end

-- Moves `count` of `item` into inventory `to` (slot `toSlot` or anywhere).
-- Returns the number moved and, when fewer, the reason.
function Client:withdraw(item, count, to, toSlot)
  local r = must(self, "withdraw", { item = item, count = count, to = to, toSlot = toSlot })
  return r.moved, r.message
end

-- Moves items from inventory `from` into storage. opts: slot, slots, item,
-- count. Returns the number moved, a table key -> moved, and a message when
-- not everything could be stored.
function Client:deposit(from, opts)
  opts = opts or {}
  local r = must(self, "deposit", { from = from, slot = opts.slot, slots = opts.slots, item = opts.item, count = opts.count })
  return r.moved, r.items, r.message
end

function Client:move(from, fromSlot, to, toSlot, count)
  return must(self, "move", { from = from, fromSlot = fromSlot, to = to, toSlot = toSlot, count = count }).moved
end

function Client:compact() return must(self, "compact").moves end
function Client:rescan(inventory) return must(self, "rescan", { inventory = inventory }) end
function Client:rediscover() return must(self, "rediscover") end
function Client:inventories() return must(self, "inventories") end
function Client:peripherals() return must(self, "peripherals") end
function Client:details(key) return must(self, "details", { key = key }) end
function Client:config() return must(self, "config") end
function Client:access() return must(self, "access") end
function Client:shutdown() return must(self, "shutdown") end

-- Asks for change events (needed over rednet; harmless locally).
function Client:subscribe(ttl)
  ttl = ttl or 60
  local r = must(self, "subscribe", { ttl = ttl })
  self.subscribedUntil = os.clock() + (r.ttl or ttl)
  return r
end

-- Waits up to `timeout` seconds (forever if nil) for the next change
-- event. Keeps the rednet subscription alive by itself.
function Client:pullEvent(timeout)
  if self.mode == "rednet" and (not self.subscribedUntil or os.clock() > self.subscribedUntil - 20) then self:subscribe(60) end
  local timer = timeout and os.startTimer(timeout)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "warehouse_event" and self.mode == "local" and type(a) == "table" then
      return a
    elseif ev == "rednet_message" and self.mode == "rednet" and c == secure.EVENT_PROTOCOL and a == self.server then
      local body = secure.open(self.key, "event", b, self.seenEvents)
      if body and type(body.event) == "table" then return body.event end
    elseif ev == "timer" and timer and a == timer then
      return nil
    end
  end
end

-- Lets methods be called with a dot as well as a colon: vault.count(x).
local function dotted(self)
  return setmetatable({}, {
    __index = function(_, k)
      local f = Client[k]
      if type(f) == "function" then return function(...) return f(self, ...) end end
      return self[k]
    end,
  })
end

function API.connect(opts)
  local c = connect(opts)
  c.seenEvents = {}
  return dotted(c)
end

return API
