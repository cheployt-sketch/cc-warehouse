-- lib.index: the service's exact picture of deep storage, and the moves that
-- keep it exact.
--
-- Every kind of item is an item key (lib.util.keyOf): the item name, plus its
-- NBT hash when it has one. For each key the index holds the total and every
-- (inventory, slot) that holds some; for each storage inventory it holds what
-- sits in every slot. Moves always name both slots, so items land on existing
-- stacks first and never spread out.
--
-- Peripheral calls take a game tick each, but calls started together finish
-- together, so plans run as parallel batches.

local util = require("lib.util")
local category = require("lib.category")

local Index = {}
Index.__index = Index

local BATCH = 32 -- peripheral calls per parallel batch
local RECENT_MAX = 100 -- item kinds remembered in the recent list

-- Fields of getItemDetail worth remembering per item kind.
local KEEP = { displayName = true, maxCount = true, damage = true, maxDamage = true, durability = true, enchantments = true, tags = true }

local function removeLoc(item, invName, slot)
  local locs = item.locs
  for i = #locs, 1, -1 do
    local l = locs[i]
    if l.inv == invName and l.slot == slot then
      table.remove(locs, i)
      return
    end
  end
end

-- Records that `slot` of `inv` now holds `count` of `key` (nil/0: empty),
-- keeping totals, locations and pending change notes in step.
local function setSlot(self, inv, slot, key, count)
  if not key or count <= 0 then key, count = nil, 0 end
  local old = inv.slots[slot]
  local oldKey = old and old.key or nil
  local oldCount = old and old.count or 0
  if oldKey == key and oldCount == count then return end
  local pending = self.pending
  if oldKey then
    local it = self.items[oldKey]
    it.count = it.count - oldCount
    pending[oldKey] = (pending[oldKey] or 0) - oldCount
    if oldKey ~= key then
      removeLoc(it, inv.name, slot)
      if it.count <= 0 then self.items[oldKey] = nil end
    end
  end
  if key then
    local it = self.items[key]
    if not it then
      local name, nbt = util.splitKey(key)
      it = { key = key, name = name, nbt = nbt, count = 0, locs = {} }
      self.items[key] = it
    end
    it.count = it.count + count
    pending[key] = (pending[key] or 0) + count
    if oldKey ~= key then it.locs[#it.locs + 1] = { inv = inv.name, slot = slot } end
    inv.slots[slot] = { key = key, count = count }
  else
    inv.slots[slot] = nil
  end
  if oldKey and not key then
    inv.used = inv.used - 1
    self.totals.used = self.totals.used - 1
  elseif key and not oldKey then
    inv.used = inv.used + 1
    self.totals.used = self.totals.used + 1
  end
  self.totals.items = self.totals.items + count - oldCount
  self.version = self.version + 1
end

local function runBatch(fns)
  for i = 1, #fns, BATCH do
    parallel.waitForAll(table.unpack(fns, i, math.min(#fns, i + BATCH - 1)))
  end
end

-- Runs fn(move) for every move of the plan in parallel batches. fn returns
-- the number of items actually moved; the plan entries get .moved / .err.
local function execute(plan, fn)
  local fns = {}
  for _, m in ipairs(plan) do
    fns[#fns + 1] = function()
      local ok, n = pcall(fn, m)
      if ok and type(n) == "number" then
        m.moved = n
      else
        m.moved = 0
        m.err = ok and "no result" or tostring(n)
      end
    end
  end
  if #fns > 0 then runBatch(fns) end
end

-- opts: storage (list of inventory names), details (cached item details,
-- key -> table), onDetails(details) called when the cache grows,
-- onChange(changes) called after every operation that changed something,
-- with a list of { key, delta, count }, recent (key -> time of the last
-- move) with onRecent(recent) when it changes, categories (item name ->
-- category overrides) and log(msg).
function Index.new(opts)
  local self = setmetatable({}, Index)
  self.invs = {}
  self.order = {}
  self.items = {}
  self.details = opts.details or {}
  self.onDetails = opts.onDetails
  self.onChange = opts.onChange
  self.recent = opts.recent or {}
  self.onRecent = opts.onRecent
  self.recentDirty = false
  self.categories = opts.categories or {}
  self.log = opts.log or function() end
  self.version = 0
  self.dirty = {}
  self.pending = {}
  self.detailsDirty = false
  self.totals = { slots = 0, used = 0, items = 0 }
  self:reclassify()
  for _, name in ipairs(opts.storage or {}) do self:addInventory(name) end
  return self
end

-- Works out every cached item's category again. Cheap, and needed when the
-- rules or the config's overrides change.
function Index:reclassify(categories)
  if categories then self.categories = categories end
  for _, d in pairs(self.details) do d.category = category.classify(d, self.categories) end
  self.version = self.version + 1
end

-- Notes that an item kind was just moved in or out.
function Index:touchRecent(key)
  self.recent[key] = os.epoch("utc")
  self.recentDirty = true
end

local function pruneRecent(recent)
  local keys = {}
  for k in pairs(recent) do keys[#keys + 1] = k end
  if #keys <= RECENT_MAX then return end
  table.sort(keys, function(a, b) return recent[a] > recent[b] end)
  for i = RECENT_MAX + 1, #keys do recent[keys[i]] = nil end
end

function Index:addInventory(name)
  if self.invs[name] then return true end
  local ok, size = pcall(peripheral.call, name, "size")
  if not ok or type(size) ~= "number" then
    self.log("not an inventory, skipped: " .. tostring(name) .. (ok and "" or (" (" .. tostring(size) .. ")")))
    return false
  end
  self.invs[name] = { name = name, size = size, slots = {}, used = 0 }
  self.order[#self.order + 1] = name
  self.totals.slots = self.totals.slots + size
  self.dirty[name] = true
  return true
end

function Index:removeInventory(name)
  local inv = self.invs[name]
  if not inv then return end
  for slot = 1, inv.size do setSlot(self, inv, slot, nil, 0) end
  self.totals.slots = self.totals.slots - inv.size
  self.invs[name] = nil
  for i, n in ipairs(self.order) do
    if n == name then
      table.remove(self.order, i)
      break
    end
  end
  self.dirty[name] = nil
  self:flush()
end

-- Reports the changes made since the last flush. Returns them too.
function Index:flush()
  local changes = {}
  for key, delta in pairs(self.pending) do
    if delta ~= 0 then
      local it = self.items[key]
      changes[#changes + 1] = { key = key, delta = delta, count = it and it.count or 0 }
    end
  end
  self.pending = {}
  if self.detailsDirty and self.onDetails then
    self.detailsDirty = false
    self.onDetails(self.details)
  end
  if self.recentDirty then
    self.recentDirty = false
    pruneRecent(self.recent)
    if self.onRecent then self.onRecent(self.recent) end
  end
  if #changes > 0 and self.onChange then self.onChange(changes) end
  return changes
end

-- Fetches details (display name, stack size, ...) for item kinds not yet
-- known, reading them from `unknown` (key -> a slot of invName holding it).
function Index:learn(invName, unknown)
  local fns = {}
  for key, slot in pairs(unknown) do
    fns[#fns + 1] = function()
      local ok, d = pcall(peripheral.call, invName, "getItemDetail", slot)
      if ok and type(d) == "table" and d.name and util.keyOf(d.name, d.nbt) == key then
        local keep = { name = d.name }
        for k, v in pairs(d) do
          if KEEP[k] then keep[k] = v end
        end
        if type(d.itemGroups) == "table" then
          local ids = {}
          for _, g in ipairs(d.itemGroups) do
            ids[#ids + 1] = type(g) == "table" and tostring(g.id or g.displayName or "?") or tostring(g)
          end
          keep.itemGroups = ids
        end
        if type(keep.maxCount) ~= "number" then keep.maxCount = 64 end
        if type(keep.displayName) ~= "string" then keep.displayName = util.titleCase(d.name) end
        keep.category = category.classify(keep, self.categories)
        self.details[key] = keep
        self.detailsDirty = true
      end
    end
  end
  if #fns > 0 then runBatch(fns) end
end

-- Re-reads one storage inventory and fixes the index to match it.
function Index:scan(name)
  local inv = self.invs[name]
  if not inv then return nil, "not a storage inventory: " .. tostring(name) end
  local ok, list = pcall(peripheral.call, name, "list")
  if not ok or type(list) ~= "table" then
    self.log("cannot read " .. name .. ": " .. tostring(list))
    return nil, "cannot read " .. name
  end
  local ok2, size = pcall(peripheral.call, name, "size")
  if ok2 and type(size) == "number" and size ~= inv.size then
    for slot = size + 1, inv.size do setSlot(self, inv, slot, nil, 0) end
    self.totals.slots = self.totals.slots - inv.size + size
    inv.size = size
  end
  local unknown = {}
  for slot = 1, inv.size do
    local it = list[slot]
    if it then
      local key = util.keyOf(it.name, it.nbt)
      setSlot(self, inv, slot, key, it.count)
      if not self.details[key] and not unknown[key] then unknown[key] = slot end
    else
      setSlot(self, inv, slot, nil, 0)
    end
  end
  self.dirty[name] = nil
  self:learn(name, unknown)
  self:flush()
  return true
end

function Index:scanAll()
  for _, name in ipairs(self.order) do self:scan(name) end
end

function Index:scanDirty()
  for name in pairs(self.dirty) do self:scan(name) end
end

-- Details of an item kind; a plausible guess when none were fetched yet.
function Index:detail(key)
  local d = self.details[key]
  if d then
    if not d.category then
      d.category = category.classify(d, self.categories)
      self.detailsDirty = true
    end
    return d
  end
  local name = util.splitKey(key)
  d = { name = name, displayName = util.titleCase(name), maxCount = 64, guessed = true }
  d.category = category.classify(d, self.categories)
  return d
end

function Index:maxCount(key)
  local n = self:detail(key).maxCount
  if type(n) ~= "number" or n < 1 then return 64 end
  return n
end

-- Everything in storage. opts: filter (text matched against the item name
-- and display name), category ("block", "item", "resource", "unstackable",
-- or "recent" for the items moved last, newest first), sort ("count", the
-- default, or "name"), limit, offset. Returns the list and the total
-- number of matches.
function Index:list(opts)
  opts = opts or {}
  local cat = opts.category
  if cat == "all" or cat == "" then cat = nil end
  local out = {}
  for key, it in pairs(self.items) do
    if it.count > 0 then
      local d = self:detail(key)
      local wanted = true
      if cat == "recent" then
        wanted = self.recent[key] ~= nil
      elseif cat then
        wanted = d.category == cat
      end
      if wanted and (not opts.filter or opts.filter == "" or util.contains(d.displayName, opts.filter) or util.contains(it.name, opts.filter)) then
        out[#out + 1] = {
          key = key, name = it.name, nbt = it.nbt, displayName = d.displayName, count = it.count, maxCount = d.maxCount,
          stacks = #it.locs, category = d.category, recent = self.recent[key],
        }
      end
    end
  end
  if cat == "recent" and (opts.sort == nil or opts.sort == "recent") then
    table.sort(out, function(a, b)
      if a.recent ~= b.recent then return a.recent > b.recent end
      return a.key < b.key
    end)
  elseif opts.sort == "name" then
    table.sort(out, function(a, b)
      if a.displayName ~= b.displayName then return a.displayName < b.displayName end
      return a.key < b.key
    end)
  else
    table.sort(out, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      if a.displayName ~= b.displayName then return a.displayName < b.displayName end
      return a.key < b.key
    end)
  end
  local total = #out
  if opts.offset or opts.limit then
    local from = (opts.offset or 0) + 1
    local to = opts.limit and (from + opts.limit - 1) or total
    local page = {}
    for i = from, math.min(to, total) do page[#page + 1] = out[i] end
    out = page
  end
  return out, total
end

-- Finds the one item key meant by `item`: an exact key, an item name (when
-- only one NBT variant is stored), or a unique match on the display name.
function Index:resolve(item)
  if type(item) ~= "string" or item == "" then return nil, "no item given" end
  if self.items[item] then return item end
  local matches = {}
  for key, it in pairs(self.items) do
    if it.name == item then matches[#matches + 1] = key end
  end
  if #matches == 1 then return matches[1] end
  if #matches > 1 then return nil, "ambiguous: " .. #matches .. " kinds of " .. item .. " are stored; use the item key" end
  local lower = item:lower()
  for key, it in pairs(self.items) do
    local d = self:detail(key)
    if tostring(d.displayName):lower() == lower or util.shortName(it.name) == lower then matches[#matches + 1] = key end
  end
  if #matches == 1 then return matches[1] end
  if #matches > 1 then return nil, "ambiguous: " .. #matches .. " items are called " .. item .. "; use the item key" end
  for key, it in pairs(self.items) do
    local d = self:detail(key)
    if util.contains(d.displayName, item) or util.contains(it.name, item) then matches[#matches + 1] = key end
  end
  if #matches == 1 then return matches[1] end
  if #matches > 1 then return nil, "ambiguous: " .. #matches .. " items match " .. item .. "; be more specific" end
  return nil, "not in storage: " .. item
end

-- How many of an item are stored. A plain item name counts every NBT
-- variant of it.
function Index:count(item)
  if self.items[item] then return self.items[item].count end
  local n = 0
  for _, it in pairs(self.items) do
    if it.name == item then n = n + it.count end
  end
  if n > 0 then return n end
  local key = self:resolve(item)
  return key and self.items[key].count or 0
end

function Index:info(key)
  local it = self.items[key]
  if not it then return nil end
  local d = self:detail(key)
  local locs = {}
  for _, loc in ipairs(it.locs) do
    local s = self.invs[loc.inv].slots[loc.slot]
    if s and s.key == key then locs[#locs + 1] = { inventory = loc.inv, slot = loc.slot, count = s.count } end
  end
  return { key = key, name = it.name, nbt = it.nbt, displayName = d.displayName, maxCount = d.maxCount, count = it.count, stacks = #locs, locations = locs, detail = d }
end

-- Which stacks to take `count` of `key` from: smallest first, so partial
-- stacks get used up and full ones stay full.
function Index:planWithdraw(key, count)
  local it = self.items[key]
  local stacks = {}
  for _, loc in ipairs(it.locs) do
    local s = self.invs[loc.inv].slots[loc.slot]
    if s and s.key == key then stacks[#stacks + 1] = { inv = loc.inv, slot = loc.slot, count = s.count } end
  end
  table.sort(stacks, function(a, b)
    if a.count ~= b.count then return a.count < b.count end
    if a.inv ~= b.inv then return a.inv < b.inv end
    return a.slot < b.slot
  end)
  local plan, remaining = {}, count
  for _, s in ipairs(stacks) do
    if remaining <= 0 then break end
    local n = math.min(s.count, remaining)
    plan[#plan + 1] = { inv = s.inv, slot = s.slot, n = n }
    remaining = remaining - n
  end
  return plan
end

-- Moves up to `count` of item `key` into inventory `to` (into slot `toSlot`,
-- or anywhere). Returns the number moved and, when fewer than asked, why.
function Index:withdraw(key, count, to, toSlot)
  local it = self.items[key]
  if not it or it.count <= 0 then return 0, "not in storage", "refused" end
  if self.invs[to] then return 0, "target is a storage inventory", "refused" end
  count = math.min(math.floor(count), it.count)
  if count <= 0 then return 0 end
  local moved, err = 0, nil
  -- A round comes up short when the target is full (the next round then
  -- moves nothing and we stop) or when the index was stale (the re-read
  -- fixes it and the next round takes the rest).
  for _ = 1, 3 do
    it = self.items[key]
    local want = math.min(count - moved, it and it.count or 0)
    if want <= 0 then break end
    local plan = self:planWithdraw(key, want)
    execute(plan, function(m) return peripheral.call(m.inv, "pushItems", to, m.slot, m.n, toSlot) end)
    local got, short = 0, false
    for _, m in ipairs(plan) do
      local inv = self.invs[m.inv]
      local s = inv.slots[m.slot]
      setSlot(self, inv, m.slot, key, (s and s.count or 0) - m.moved)
      got = got + m.moved
      if m.moved < m.n then
        short = true
        self.dirty[m.inv] = true
        err = err or m.err
      end
    end
    moved = moved + got
    if short then self:scanDirty() end
    if not short or got == 0 then break end
  end
  if moved > 0 then self:touchRecent(key) end
  self:flush()
  if moved < count then
    if err then return moved, err, (moved == 0) and "refused" or nil end
    return moved, (moved == 0) and ("nothing moved: is " .. tostring(to) .. " full?") or "target full"
  end
  return moved
end

-- Works out where each source stack goes: onto partial stacks of the same
-- item (fullest first), then into empty slots. Returns the plan and the
-- number of items that found no room.
function Index:planDeposit(from, sources, limit)
  limit = limit or math.huge
  local plan = {}
  local assigned = {} -- "inv#slot" -> { key, count (planned additions), inv, slot }
  local newStacks = {} -- key -> ids of empty slots given to it in this plan
  local freeInv, freeSlot = 1, 0
  local function nextFree()
    while freeInv <= #self.order do
      local inv = self.invs[self.order[freeInv]]
      freeSlot = freeSlot + 1
      if freeSlot > inv.size then
        freeInv, freeSlot = freeInv + 1, 0
      elseif not inv.slots[freeSlot] and not assigned[inv.name .. "#" .. freeSlot] then
        return inv.name, freeSlot
      end
    end
    return nil
  end
  local unplaced = 0
  for _, src in ipairs(sources) do
    if limit <= 0 then break end
    local remaining = math.min(src.count, limit)
    local wanted = remaining
    local max = self:maxCount(src.key)
    local targets = {}
    local it = self.items[src.key]
    if it then
      for _, loc in ipairs(it.locs) do
        local s = self.invs[loc.inv].slots[loc.slot]
        if s and s.key == src.key and s.count < max then
          local id = loc.inv .. "#" .. loc.slot
          local a = assigned[id]
          local have = s.count + (a and a.count or 0)
          if have < max then targets[#targets + 1] = { inv = loc.inv, slot = loc.slot, id = id, have = have } end
        end
      end
    end
    for _, id in ipairs(newStacks[src.key] or {}) do
      local a = assigned[id]
      if a.count < max then targets[#targets + 1] = { inv = a.inv, slot = a.slot, id = id, have = a.count } end
    end
    table.sort(targets, function(a, b)
      if a.have ~= b.have then return a.have > b.have end
      return a.id < b.id
    end)
    for _, t in ipairs(targets) do
      if remaining <= 0 then break end
      local n = math.min(max - t.have, remaining)
      plan[#plan + 1] = { from = from, fromSlot = src.slot, key = src.key, inv = t.inv, slot = t.slot, n = n }
      local a = assigned[t.id]
      if a then a.count = a.count + n else assigned[t.id] = { key = src.key, count = n, inv = t.inv, slot = t.slot } end
      remaining = remaining - n
    end
    while remaining > 0 do
      local inv, slot = nextFree()
      if not inv then break end
      local n = math.min(max, remaining)
      local id = inv .. "#" .. slot
      plan[#plan + 1] = { from = from, fromSlot = src.slot, key = src.key, inv = inv, slot = slot, n = n }
      assigned[id] = { key = src.key, count = n, inv = inv, slot = slot }
      newStacks[src.key] = newStacks[src.key] or {}
      table.insert(newStacks[src.key], id)
      remaining = remaining - n
    end
    unplaced = unplaced + remaining
    limit = limit - (wanted - remaining)
  end
  return plan, unplaced
end

-- Moves items from inventory `from` into storage, onto existing stacks
-- first. opts: slot or slots (only these source slots), item (only this
-- item key or name), count (at most this many items). Returns the number
-- moved, a table key -> moved, and a message when not everything moved.
function Index:deposit(from, opts)
  opts = opts or {}
  if self.invs[from] then return 0, {}, "source is a storage inventory", "refused" end
  local want
  if opts.slot then
    want = { [opts.slot] = true }
  elseif opts.slots then
    want = {}
    for _, s in ipairs(opts.slots) do want[s] = true end
  end
  local moved, byKey, err, unplaced, limit = 0, {}, nil, 0, opts.count
  -- A round comes up short when the index was stale about a stack (the
  -- re-read fixes it and the next round places the rest).
  for round = 1, 3 do
    local ok, list = pcall(peripheral.call, from, "list")
    if not ok or type(list) ~= "table" then
      return moved, byKey, "cannot read " .. tostring(from) .. ": " .. tostring(list), (moved == 0) and "refused" or nil
    end
    local sources, unknown = {}, {}
    for slot, it in pairs(list) do
      local key = util.keyOf(it.name, it.nbt)
      if (not want or want[slot]) and (not opts.item or util.itemMatches(opts.item, it.name, key)) then
        sources[#sources + 1] = { slot = slot, key = key, count = it.count }
        if not self.details[key] and not unknown[key] then unknown[key] = slot end
      end
    end
    if #sources == 0 then
      if round == 1 then return 0, {}, "nothing to store" end
      break
    end
    table.sort(sources, function(a, b) return a.slot < b.slot end)
    self:learn(from, unknown)
    local plan
    plan, unplaced = self:planDeposit(from, sources, limit)
    if #plan == 0 then break end
    execute(plan, function(m) return peripheral.call(from, "pushItems", m.inv, m.fromSlot, m.n, m.slot) end)
    local got, short = 0, false
    for _, m in ipairs(plan) do
      local inv = self.invs[m.inv]
      local s = inv.slots[m.slot]
      if s and s.key ~= m.key then
        self.dirty[m.inv] = true -- the index was wrong about this slot
      elseif m.moved > 0 then
        setSlot(self, inv, m.slot, m.key, (s and s.count or 0) + m.moved)
      end
      if m.moved > 0 then
        got = got + m.moved
        byKey[m.key] = (byKey[m.key] or 0) + m.moved
      end
      if m.moved < m.n then
        short = true
        self.dirty[m.inv] = true
        err = err or m.err
      end
    end
    moved = moved + got
    if limit then limit = limit - got end
    if short then self:scanDirty() end
    if not short or got == 0 then break end
  end
  for key in pairs(byKey) do self:touchRecent(key) end
  self:flush()
  local message
  if unplaced > 0 then message = "storage full: " .. unplaced .. " left behind" end
  if err then message = err end
  return moved, byKey, message
end

-- Merges partial stacks of the same item so storage holds as few stacks as
-- possible. Returns the number of moves made.
function Index:compact()
  local plan = {}
  for key, it in pairs(self.items) do
    local max = self:maxCount(key)
    if max > 1 and #it.locs > 1 then
      local partials = {}
      for _, loc in ipairs(it.locs) do
        local s = self.invs[loc.inv].slots[loc.slot]
        if s and s.key == key and s.count < max then partials[#partials + 1] = { inv = loc.inv, slot = loc.slot, count = s.count } end
      end
      if #partials > 1 then
        table.sort(partials, function(a, b)
          if a.count ~= b.count then return a.count > b.count end
          if a.inv ~= b.inv then return a.inv < b.inv end
          return a.slot < b.slot
        end)
        local i, j = 1, #partials -- fill partials[i] (fullest) from partials[j] (emptiest)
        while i < j do
          local room = max - partials[i].count
          if room <= 0 then
            i = i + 1
          else
            local n = math.min(room, partials[j].count)
            plan[#plan + 1] = { key = key, inv = partials[j].inv, slot = partials[j].slot, toInv = partials[i].inv, toSlot = partials[i].slot, n = n }
            partials[i].count = partials[i].count + n
            partials[j].count = partials[j].count - n
            if partials[j].count <= 0 then j = j - 1 end
          end
        end
      end
    end
  end
  execute(plan, function(m) return peripheral.call(m.inv, "pushItems", m.toInv, m.slot, m.n, m.toSlot) end)
  local moves, short = 0, false
  for _, m in ipairs(plan) do
    local src, dst = self.invs[m.inv], self.invs[m.toInv]
    local s, d = src.slots[m.slot], dst.slots[m.toSlot]
    if m.moved > 0 then
      moves = moves + 1
      setSlot(self, src, m.slot, m.key, (s and s.count or 0) - m.moved)
      setSlot(self, dst, m.toSlot, m.key, (d and d.count or 0) + m.moved)
    end
    if m.moved < m.n then
      short = true
      self.dirty[m.inv] = true
      self.dirty[m.toInv] = true
    end
  end
  if short then self:scanDirty() end
  self:flush()
  return moves
end

-- A raw move between any two inventories on the network. Storage
-- inventories involved are re-read afterwards so the index stays exact.
function Index:move(from, fromSlot, to, toSlot, count)
  local ok, n = pcall(peripheral.call, from, "pushItems", to, fromSlot, count, toSlot)
  if not ok then return 0, tostring(n) end
  n = n or 0
  if self.invs[from] then self.dirty[from] = true end
  if self.invs[to] then self.dirty[to] = true end
  self:scanDirty()
  self:flush()
  return n
end

function Index:stats()
  local invs = {}
  for _, name in ipairs(self.order) do
    local inv = self.invs[name]
    invs[#invs + 1] = { name = name, size = inv.size, used = inv.used, free = inv.size - inv.used }
  end
  return {
    slots = self.totals.slots,
    used = self.totals.used,
    free = self.totals.slots - self.totals.used,
    items = self.totals.items,
    types = util.size(self.items),
    inventories = invs,
    version = self.version,
  }
end

return Index
