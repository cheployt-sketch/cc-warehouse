-- parcel: the Parcel Service, an app on the warehouse API that moves items
-- between inventories and the vault by itself, task by task.
--
-- Tasks live in /warehouse/parcels (edited from the control panel, by hand,
-- or by apps); stats go to /warehouse/data/parcels.stats. A task is:
--
--   { id = "t1", name = "Farm", enabled = true, kind = "deposit",
--     inventory = "minecraft:chest_2", interval = 5,
--     items = { { item = "minecraft:wheat", limit = 2000 }, ... },  -- empty: everything
--     maxPerRun = 256, totalLimit = nil }
--
-- deposit  moves items from the inventory into the vault. With a list, only
--          those items; `limit` stops an item once the vault holds that many.
-- withdraw moves items from the vault into the inventory. Each item has
--          `keep` (top the inventory up to this many), `perRun` (at most this
--          many per run) and `total` (a lifetime budget); without `keep` it
--          sends `perRun` every run. The container's room is the last limit.
-- interval seconds between runs; maxPerRun caps items per run; totalLimit is
--          a lifetime budget for the whole task. Several tasks may move the
--          same items; each keeps its own stats.
--
-- The service hosts it by default (config `parcels = true`); `parcels` runs
-- it on its own, on any paired computer. The file is re-read when it
-- changes; a "parcel_run" event (with a task id) runs a task at once.
-- Tasks may sit in folders (`folder`, see lib.folders; `folders` in the
-- file keeps empty ones), which only the control panel cares about. The
-- moves tasks make are not counted as "recent" by the screens.

local util = require("lib.util")

local P = {}
P.__index = P

local CHECK = 1 -- seconds between looks at the clock and the file

-- Item spec strings, for the panel and the command line:
--   deposit:  name[<limit]         e.g. minecraft:wheat<2000
--   withdraw: name[=keep][/perRun][#total]   e.g. minecraft:coal=64/32
function P.parseItems(kind, text)
  local out = {}
  for tok in tostring(text or ""):gmatch("[^,]+") do
    tok = tok:gsub("^%s+", ""):gsub("%s+$", "")
    if tok ~= "" and tok ~= "all" and tok ~= "*" then
      local name = tok:match("^([^<=/#]+)")
      name = name and name:gsub("%s+$", "")
      if not name or name == "" then return nil, "bad item: " .. tok end
      local spec = { item = name }
      if kind == "deposit" then
        local limit = tok:match("<%s*(%d+)")
        if limit then spec.limit = tonumber(limit) end
      else
        local keep, per, total = tok:match("=%s*(%d+)"), tok:match("/%s*(%d+)"), tok:match("#%s*(%d+)")
        if keep then spec.keep = tonumber(keep) end
        if per then spec.perRun = tonumber(per) end
        if total then spec.total = tonumber(total) end
        if not keep and not per then return nil, tok .. ": say how many, =keep or /perRun" end
      end
      out[#out + 1] = spec
    end
  end
  return out
end

function P.formatItems(kind, items)
  if not items or #items == 0 then return kind == "deposit" and "all" or "" end
  local parts = {}
  for _, s in ipairs(items) do
    local t = s.item
    if kind == "deposit" then
      if s.limit then t = t .. "<" .. s.limit end
    else
      if s.keep then t = t .. "=" .. s.keep end
      if s.perRun then t = t .. "/" .. s.perRun end
      if s.total then t = t .. "#" .. s.total end
    end
    parts[#parts + 1] = t
  end
  return table.concat(parts, ",")
end

function P.configPath(root) return fs.combine(root, "parcels") end
function P.statsPath(root) return fs.combine(root, "data/parcels.stats") end

function P.loadConfig(root)
  return util.readTable(P.configPath(root)) or { tasks = {} }
end

function P.saveConfig(root, cfg)
  local ok = util.writeTable(P.configPath(root), cfg)
  os.queueEvent("parcel_reload")
  return ok
end

function P.loadStats(root)
  return util.readTable(P.statsPath(root)) or {}
end

function P.newId(cfg)
  local n = 0
  for _, t in ipairs(cfg.tasks or {}) do
    local k = tonumber(tostring(t.id):match("^t(%d+)$"))
    if k and k > n then n = k end
  end
  return "t" .. (n + 1)
end

-- opts: vault (client library), root, log(msg)
function P.new(opts)
  local self = setmetatable({}, P)
  self.vault = opts.vault
  self.root = opts.root
  self.log = opts.log or function() end
  self.tasks = {}
  self.stats = P.loadStats(self.root)
  self.next = {} -- task id -> os.clock() of the next run
  self.seen = nil
  return self
end

local function mtime(path)
  if not fs.exists(path) then return nil end
  local ok, a = pcall(fs.attributes, path)
  return ok and a and (a.modified or 0) or 0
end

function P:load()
  local cfg = P.loadConfig(self.root)
  self.tasks = {}
  for i, t in ipairs(cfg.tasks or {}) do
    t.id = t.id or ("t" .. i)
    t.kind = t.kind == "withdraw" and "withdraw" or "deposit"
    t.interval = tonumber(t.interval) or 5
    t.items = t.items or {}
    if t.enabled == nil then t.enabled = true end
    self.tasks[#self.tasks + 1] = t
    if not self.next[t.id] then self.next[t.id] = os.clock() + 1 end
  end
  self.seen = mtime(P.configPath(self.root))
end

function P:statsFor(id)
  local s = self.stats[id]
  if not s then
    s = { runs = 0, moved = 0, errors = 0, items = {} }
    self.stats[id] = s
  end
  return s
end

function P:saveStats()
  util.writeTable(P.statsPath(self.root), self.stats)
end

local function matches(spec, it)
  return util.itemMatches(spec.item, it.name, it.key)
end

-- Runs one task now. Returns the number moved and a message.
function P:runTask(t)
  local v = self.vault
  local st = self:statsFor(t.id)
  local budget = math.huge
  if t.totalLimit then budget = math.max(0, t.totalLimit - st.moved) end
  if t.maxPerRun then budget = math.min(budget, t.maxPerRun) end
  if budget <= 0 then return 0, "lifetime budget used up" end
  local moved, notes, noted = 0, {}, {}
  local function tally(key, n)
    moved = moved + n
    st.items[key] = (st.items[key] or 0) + n
  end
  local function note(s)
    if s and s ~= "nothing to store" and not noted[s] then
      noted[s] = true
      notes[#notes + 1] = s
    end
  end
  if t.kind == "deposit" then
    if #t.items == 0 then
      local n, byKey, msg = v.deposit(t.inventory, { count = budget < math.huge and budget or nil, recent = false })
      for k, c in pairs(byKey) do tally(k, c) end
      note(msg)
    else
      local inv = v.inventory(t.inventory)
      local vaultCount = {} -- per kind, asked once and kept up to date here
      for _, it in ipairs(inv.items) do
        if budget - moved <= 0 then break end
        for _, spec in ipairs(t.items) do
          if matches(spec, it) then
            local allowed = budget - moved
            if spec.limit then
              if not vaultCount[it.key] then vaultCount[it.key] = v.count(it.key) end
              allowed = math.min(allowed, spec.limit - vaultCount[it.key])
            end
            if allowed > 0 then
              local n, _, msg = v.deposit(t.inventory, { slot = it.slot, count = math.min(allowed, it.count), recent = false })
              tally(it.key, n)
              if vaultCount[it.key] then vaultCount[it.key] = vaultCount[it.key] + n end
              note(msg)
            elseif spec.limit then
              note(util.shortName(spec.item) .. " at limit")
            end
            break
          end
        end
      end
    end
  else
    local inv = v.inventory(t.inventory)
    for _, spec in ipairs(t.items) do
      if budget - moved <= 0 then break end
      local have = 0
      for _, it in ipairs(inv.items) do
        if matches(spec, it) then have = have + it.count end
      end
      local want
      if spec.keep then want = spec.keep - have else want = spec.perRun or 0 end
      if spec.perRun then want = math.min(want, spec.perRun) end
      if spec.total then want = math.min(want, spec.total - (st.items[spec.item] or 0)) end
      want = math.min(want, budget - moved)
      if want > 0 then
        local ok, n, why = pcall(v.withdraw, spec.item, want, t.inventory, nil, { recent = false })
        if ok then
          tally(spec.item, n)
          if why then note(util.shortName(spec.item) .. ": " .. why) end
        else
          note(util.shortName(spec.item) .. ": " .. tostring(n))
        end
      end
    end
  end
  return moved, #notes > 0 and table.concat(notes, "; ") or nil
end

-- Runs every task that is due (or the one task `force` names, due or
-- not). Stats go to disk when a run changed something, and otherwise at
-- most every STATS_EVERY seconds, so idle tasks do not wear the disk.
local STATS_EVERY = 15

function P:runDue(force)
  local now = os.clock()
  local ran = false
  for _, t in ipairs(self.tasks) do
    if (t.enabled and now >= (self.next[t.id] or 0)) or force == t.id then
      self.next[t.id] = now + t.interval
      if t.inventory and t.inventory ~= "" then
        local st = self:statsFor(t.id)
        local ok, moved, msg = pcall(self.runTask, self, t)
        st.runs = st.runs + 1
        st.lastRun = os.epoch("utc")
        if ok then
          if moved > 0 or msg ~= st.lastMessage then self.statsDirty = true end
          st.moved = st.moved + moved
          st.lastMoved = moved
          st.lastMessage = msg
          if moved > 0 then self.log("parcel " .. tostring(t.name or t.id) .. ": " .. moved .. " moved" .. (msg and (" (" .. msg .. ")") or "")) end
        else
          st.errors = st.errors + 1
          st.lastMoved = 0
          st.lastMessage = tostring(moved)
          self.statsDirty = true
          self.log("parcel " .. tostring(t.name or t.id) .. " failed: " .. tostring(moved))
        end
        ran = true
      end
    end
  end
  if ran and (self.statsDirty or now - (self.statsSaved or 0) >= STATS_EVERY) then
    self.statsDirty = false
    self.statsSaved = now
    self:saveStats()
  end
end

function P:run()
  self:load()
  self.log("parcel service: " .. #self.tasks .. " task(s)")
  local timer = os.startTimer(CHECK)
  local due = os.clock() + CHECK
  local fileCheck = 0
  while true do
    local ev, a = os.pullEvent()
    if ev == "parcel_reload" then
      self:load()
      self.log("parcel service: tasks reloaded, " .. #self.tasks)
    elseif ev == "parcel_run" and type(a) == "string" then
      self:runDue(a)
    elseif ev == "parcel_reset" and type(a) == "string" then
      self.stats[a] = nil
      self:saveStats()
    elseif ev == "timer" and (a == timer or os.clock() >= due) then
      timer = os.startTimer(CHECK)
      due = os.clock() + CHECK
      fileCheck = fileCheck + 1
      if fileCheck >= 2 then
        fileCheck = 0
        if mtime(P.configPath(self.root)) ~= self.seen then self:load() end
      end
      self:runDue()
    end
  end
end

return P
