-- lib.service: the warehouse API. Every operation an app can ask for is in
-- Service.ops. Requests from every transport, and from the access point
-- screens, go through one queue, so two operations never interleave and the
-- index stays exact.
--
-- A request is { id, op, args }; the answer is { id, ok = true, result } or
-- { id, ok = false, error }. Transports add req.transport ("local" or
-- "rednet") and, for rednet, req.sender (the paired computer's ID).

local util = require("lib.util")
local config = require("lib.config")
local VERSION = require("lib.version")
local Access = require("lib.access")
local transport = require("lib.transport")
local secure = require("lib.secure")

local Service = {}
Service.__index = Service

-- opts: index, cfg, log, root, runner (lib.runner, which runs the screens
-- and transports), key (the warehouse key, for rednet).
function Service.new(opts)
  local self = setmetatable({}, Service)
  self.index = opts.index
  self.cfg = opts.cfg
  self.log = opts.log
  self.root = opts.root
  self.runner = opts.runner
  self.key = opts.key
  self.queue = {}
  self.subscribers = {} -- computer ID -> os.clock() when the subscription ends
  self.started = os.clock()
  self.screens = {} -- the running access points (lib.access objects)
  self.screenSeq = 0
  self.access = {} -- screens by position in the config and by name
  self.sendEvent = nil -- set by the rednet transport: function(id, event)
  self.stopping = false
  self.configSeen = config.modified(self.root)
  self.index.onChange = function(changes)
    self:emit({ type = "change", items = changes, version = self.index.version })
  end
  return self
end

-- Screens run as tasks of the runner, so they can start and stop while the
-- service runs.
function Service:addScreen(apCfg)
  self.screenSeq = self.screenSeq + 1
  local ap = Access.new(self, apCfg, self.cfg)
  ap.id = self.screenSeq
  self.screens[#self.screens + 1] = ap
  self.runner:add("screen:" .. ap.id, function() ap:run() end)
  return ap
end

function Service:removeScreen(ap)
  ap:stop()
  self.runner:remove("screen:" .. ap.id)
  for i, s in ipairs(self.screens) do
    if s == ap then
      table.remove(self.screens, i)
      break
    end
  end
end

function Service:indexScreens()
  self.access = {}
  for i, apCfg in ipairs(self.cfg.access or {}) do
    for _, ap in ipairs(self.screens) do
      if ap.cfg == apCfg then
        self.access[i] = ap
        if apCfg.name then self.access[apCfg.name] = ap end
      end
    end
  end
end

-- Makes the running screens match cfg.access: existing ones are matched by
-- name, then by monitor, and given their new settings; the rest are started
-- or stopped. Returns the names added, changed and removed.
function Service:applyScreens()
  local leftover = { table.unpack(self.screens) }
  local function take(pred)
    for i, ap in ipairs(leftover) do
      if pred(ap) then
        table.remove(leftover, i)
        return ap
      end
    end
  end
  local added, updated, removed = {}, {}, {}
  for _, apCfg in ipairs(self.cfg.access or {}) do
    local ap = take(function(s) return s.cfg.name ~= nil and s.cfg.name == apCfg.name end)
      or take(function(s) return s.cfg.monitor == apCfg.monitor end)
    if ap then
      if ap:reconfigure(apCfg, self.cfg) then updated[#updated + 1] = ap.name end
    else
      ap = self:addScreen(apCfg)
      added[#added + 1] = ap.name
    end
  end
  for _, ap in ipairs(leftover) do
    removed[#removed + 1] = ap.name
    self:removeScreen(ap)
  end
  self:indexScreens()
  return added, updated, removed
end

function Service:startRednet()
  if not self.key or not self.runner or self.runner:has("rednet") then return end
  local service = self
  self.runner:add("rednet", function() transport.runRednet(service, service.key) end)
end

function Service:stopRednet()
  if self.runner then self.runner:remove("rednet") end
  self.sendEvent = nil
  pcall(rednet.unhost, secure.PROTOCOL)
end

function Service:rehost()
  pcall(rednet.unhost, secure.PROTOCOL)
  local ok, err = pcall(rednet.host, secure.PROTOCOL, self.cfg.hostname or "vault")
  if not ok then self.log.warn("rednet.host failed: " .. tostring(err)) end
end

-- Tells every listener about something that happened: local apps get a
-- "warehouse_event" event, subscribed computers get a sealed message.
function Service:emit(ev)
  os.queueEvent("warehouse_event", ev)
  if self.sendEvent then
    local now = os.clock()
    for id, until_ in pairs(self.subscribers) do
      if until_ < now then self.subscribers[id] = nil else self.sendEvent(id, ev) end
    end
  end
end

-- Queues a request; reply(response) runs once it has been handled.
function Service:submit(req, reply)
  self.queue[#self.queue + 1] = { req = req, reply = reply }
  os.queueEvent("warehouse_wake")
end

-- Handles one request now. Returns the response table.
function Service:handle(req)
  if type(req) ~= "table" or type(req.op) ~= "string" then return { ok = false, error = "bad request" } end
  local op = self.ops[req.op]
  if not op then return { id = req.id, ok = false, error = "unknown op: " .. req.op } end
  local args = req.args
  if type(args) ~= "table" then args = {} end
  local ok, res = pcall(op, self, args, req)
  if ok then return { id = req.id, ok = true, result = res } end
  return { id = req.id, ok = false, error = tostring(res) }
end

function Service:runWorker()
  while true do
    local job = table.remove(self.queue, 1)
    if job then
      local resp = self:handle(job.req)
      local ok, err = pcall(job.reply, resp)
      if not ok then self.log.warn("reply failed: " .. tostring(err)) end
    else
      os.pullEvent("warehouse_wake")
    end
  end
end

-- For code inside the service (the screens): queue a request and wait for
-- its result. Returns ok, result-or-error.
function Service:request(op, args)
  local done, resp = false, nil
  self:submit({ id = {}, op = op, args = args or {}, transport = "local", internal = true }, function(r)
    done, resp = true, r
    os.queueEvent("warehouse_done")
  end)
  while not done do os.pullEvent("warehouse_done") end
  if resp.ok then return true, resp.result end
  return false, resp.error
end

function Service:accessPoint(which)
  local ap = self.access[which or 1]
  if not ap then error("no such access point: " .. tostring(which), 0) end
  return ap
end

local function needName(a, k)
  if type(a[k]) ~= "string" or a[k] == "" then error("'" .. k .. "' must name an inventory", 0) end
  return a[k]
end

local function needCount(a, k)
  local n = tonumber(a[k])
  if not n or n < 1 then error("'" .. k .. "' must be a positive number", 0) end
  return math.floor(n)
end

-- The operations. Each gets (service, args, request) and returns the result
-- or raises an error with a message for the caller.
local ops = {}
Service.ops = ops

-- Short descriptions, returned by the `help` op and shown by the CLI.
Service.help = {
  { "ping", "", "Who is serving: name, version, computer ID, hostname, uptime." },
  { "stats", "", "Slots used/free, item and kind totals, per-inventory fill." },
  { "items", "filter?, category?, sort?, limit?, offset?", "Everything stored: key, name, displayName, count, maxCount, category. category: block, item, resource, unstackable or recent; sort: count (default) or name." },
  { "item", "item", "One item with its stack locations. item: key, name or display name." },
  { "count", "item", "How many of an item are stored (a plain name counts every NBT variant)." },
  { "withdraw", "item, count, to, toSlot?", "Move items out of storage into inventory `to`. Returns moved." },
  { "deposit", "from, slot?, slots?, item?, count?", "Move items from inventory `from` into storage, onto existing stacks first. Returns moved and items." },
  { "move", "from, fromSlot, to, toSlot?, count?", "A raw move between any two inventories on the network." },
  { "compact", "", "Merge partial stacks so storage holds as few stacks as possible." },
  { "rescan", "inventory?", "Re-read storage (one inventory, or all) and fix the index." },
  { "rediscover", "", "Pick up storage inventories attached or removed since start." },
  { "inventories", "", "The storage inventories and their fill." },
  { "peripherals", "", "Every inventory on the network with its role: storage, access, excluded or free." },
  { "details", "key", "Cached details of an item kind: displayName, maxCount, tags, ..." },
  { "subscribe", "ttl?", "Over rednet: receive change events for ttl seconds (default 60). Local apps get warehouse_event events anyway." },
  { "unsubscribe", "", "Stop receiving events." },
  { "config", "", "Presets, hostname, storage rules and access points (no PINs)." },
  { "access", "", "The access points and whether their screens are up." },
  { "help", "", "This list." },
  { "reload", "", "Read the config file again and apply it: screens, storage, categories, hostname, rednet." },
  { "shutdown", "", "Stop the service (local requests only)." },
}

function ops.help() return Service.help end

function ops.ping(self)
  return {
    name = "warehouse", version = VERSION, id = os.getComputerID(), hostname = self.cfg.hostname,
    uptime = os.clock() - self.started, items = self.index.totals.items, indexVersion = self.index.version,
  }
end

function ops.stats(self) return self.index:stats() end

function ops.items(self, a)
  local items, total = self.index:list({ filter = a.filter, category = a.category, sort = a.sort, limit = a.limit, offset = a.offset })
  return { items = items, total = total, version = self.index.version }
end

function ops.item(self, a)
  local key, err = self.index:resolve(a.item or a.key)
  if not key then error(err, 0) end
  return self.index:info(key)
end

function ops.count(self, a)
  if type(a.item) ~= "string" then error("'item' must be an item key or name", 0) end
  return self.index:count(a.item)
end

function ops.withdraw(self, a)
  local key, err = self.index:resolve(a.item or a.key)
  if not key then error(err, 0) end
  local count = needCount(a, "count")
  local to = needName(a, "to")
  local moved, why, code = self.index:withdraw(key, count, to, a.toSlot)
  if code == "refused" then error(why, 0) end
  local line = string.format("withdraw %d of %d x %s -> %s%s", moved, count, key, to, why and (" (" .. why .. ")") or "")
  if moved > 0 then self.log.info(line) else self.log.debug(line) end
  return { moved = moved, key = key, message = why }
end

function ops.deposit(self, a)
  local from = needName(a, "from")
  local moved, byKey, message, code = self.index:deposit(from, { slot = a.slot, slots = a.slots, item = a.item, count = a.count })
  if code == "refused" then error(message, 0) end
  local line = string.format("deposit %d from %s%s", moved, from, message and (" (" .. message .. ")") or "")
  if moved > 0 then self.log.info(line) else self.log.debug(line) end
  return { moved = moved, items = byKey, message = message }
end

function ops.move(self, a)
  local from, to = needName(a, "from"), needName(a, "to")
  local fromSlot = needCount(a, "fromSlot")
  local n, err = self.index:move(from, fromSlot, to, a.toSlot, a.count)
  if err then error(err, 0) end
  self.log.info(string.format("move %d: %s[%d] -> %s", n, from, fromSlot, to))
  return { moved = n }
end

function ops.compact(self)
  local n = self.index:compact()
  self.log.info("compact: " .. n .. " moves")
  return { moves = n }
end

function ops.rescan(self, a)
  if a.inventory then
    local ok, err = self.index:scan(a.inventory)
    if not ok then error(err, 0) end
  else
    self.index:scanAll()
  end
  return self.index:stats()
end

function ops.rediscover(self)
  local names = config.storageNames(self.cfg)
  local want = {}
  for _, n in ipairs(names) do want[n] = true end
  local added, removed = {}, {}
  for _, n in ipairs(names) do
    if not self.index.invs[n] and self.index:addInventory(n) then
      self.index:scan(n)
      added[#added + 1] = n
    end
  end
  for _, n in ipairs({ table.unpack(self.index.order) }) do
    if not want[n] then
      self.index:removeInventory(n)
      removed[#removed + 1] = n
    end
  end
  if #added > 0 then self.log.info("storage added: " .. table.concat(added, ", ")) end
  if #removed > 0 then self.log.warn("storage gone: " .. table.concat(removed, ", ")) end
  return { added = added, removed = removed }
end

function ops.inventories(self) return self.index:stats().inventories end

function ops.peripherals(self) return config.peripherals(self.cfg) end

function ops.details(self, a)
  if type(a.key) ~= "string" then error("'key' must be an item key", 0) end
  return self.index:detail(a.key)
end

function ops.subscribe(self, a, req)
  if req.transport ~= "rednet" then return { ttl = 0, note = "local apps receive warehouse_event events without subscribing" } end
  local ttl = tonumber(a.ttl) or 60
  self.subscribers[req.sender] = os.clock() + ttl
  return { ttl = ttl }
end

function ops.unsubscribe(self, a, req)
  if req.sender then self.subscribers[req.sender] = nil end
  return true
end

function ops.config(self)
  local access = {}
  for i, ap in ipairs(self.cfg.access or {}) do
    access[i] = { name = ap.name, chest = ap.chest, monitor = ap.monitor, scale = ap.scale, locked = ap.pin ~= nil }
  end
  return {
    presets = self.cfg.presets, stackPresets = self.cfg.stackPresets, hostname = self.cfg.hostname, storage = self.cfg.storage,
    access = access, rescanSeconds = self.cfg.rescanSeconds, lockAfter = self.cfg.lockAfter, categories = self.cfg.categories,
  }
end

function ops.access(self)
  local out = {}
  for i, ap in ipairs(self.cfg.access or {}) do
    local live = self.access[i]
    out[i] = { name = ap.name, chest = ap.chest, monitor = ap.monitor, up = live and live.ok or false, locked = live and live:isLocked() or false }
  end
  return out
end

-- Applies the config file to the running service. Screens keep their
-- state; only what changed is touched.
function ops.reload(self)
  local cfg, err = config.load(self.root)
  self.configSeen = config.modified(self.root)
  if not cfg then error(err, 0) end
  local old = self.cfg
  self.cfg = cfg
  for _, ap in ipairs(self.screens) do ap.global = cfg end
  if cfg.logLevel ~= old.logLevel and self.log.setLevel then self.log.setLevel(cfg.logLevel) end
  self.index:reclassify(cfg.categories or {})
  local storage = ops.rediscover(self)
  local added, updated, removed = self:applyScreens()
  local notes = {}
  local wasOn, isOn = old.rednet ~= false, cfg.rednet ~= false
  if wasOn ~= isOn then
    if isOn then self:startRednet() else self:stopRednet() end
    notes[#notes + 1] = "rednet " .. (isOn and "on" or "off")
  elseif isOn and cfg.hostname ~= old.hostname then
    self:rehost()
    notes[#notes + 1] = "hostname " .. tostring(cfg.hostname)
  end
  self.log.info(string.format("config applied: %d screen(s) (%d added, %d changed, %d removed), storage %d added, %d removed%s",
    #self.screens, #added, #updated, #removed, #storage.added, #storage.removed, #notes > 0 and ("; " .. table.concat(notes, ", ")) or ""))
  return { storage = storage, screens = { added = added, updated = updated, removed = removed }, notes = notes }
end

function ops.shutdown(self, a, req)
  if req.transport ~= "local" then error("shutdown is only allowed from the warehouse computer", 0) end
  self.stopping = true
  os.queueEvent("warehouse_stop")
  return true
end

-- Test hooks for the screens: the drawn text, and a fake tap. Local only.
ops["debug.screen"] = function(self, a, req)
  if req.transport ~= "local" then error("debug ops are only allowed from the warehouse computer", 0) end
  return self:accessPoint(a.access):screenLines()
end

ops["debug.touch"] = function(self, a, req)
  if req.transport ~= "local" then error("debug ops are only allowed from the warehouse computer", 0) end
  local ap = self:accessPoint(a.access)
  os.queueEvent("monitor_touch", ap.cfg.monitor, needCount(a, "x"), needCount(a, "y"))
  return true
end

return Service
