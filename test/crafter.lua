-- test/crafter.lua: the crafter service (craft.recipes and craft.engine)
-- against a simulated vault, a simulated crafty turtle and a simulated
-- smelter line (run with node test/run.cjs crafter). The simulation
-- behaves like the real ones: the turtle takes from the input chest in
-- slot order and refuses mismatches, stacks have sizes, the vault can be
-- full, the smelter takes its time.

---------------------------------------------------------------------------
-- CraftOS stand-ins
---------------------------------------------------------------------------
local files = {}
local T = { clock = 0, epoch = 1700000000000 }

local function combine(...)
  local parts = {}
  for _, p in ipairs({ ... }) do
    for seg in tostring(p):gmatch("[^/]+") do parts[#parts + 1] = seg end
  end
  return table.concat(parts, "/")
end

fs = {}
function fs.combine(a, b) return combine(a, b) end
function fs.getDir(p) p = combine(p) return p:match("^(.*)/[^/]*$") or "" end
function fs.exists(p) return files[combine(p)] ~= nil end
function fs.isDir() return false end
function fs.makeDir() end
function fs.delete(p) files[combine(p)] = nil end
function fs.move(a, b) files[combine(b)] = files[combine(a)] files[combine(a)] = nil end
function fs.getSize(p) return #(files[combine(p)] or "") end
function fs.attributes(p) return { modified = 0 } end
function fs.open(p, mode)
  p = combine(p)
  if mode == "r" then
    if not files[p] then return nil end
    local s = files[p]
    return { readAll = function() return s end, close = function() end }
  end
  local buf = mode == "a" and (files[p] or "") or ""
  return {
    write = function(s) buf = buf .. s end,
    writeLine = function(s) buf = buf .. s .. "\n" end,
    close = function() files[p] = buf end,
  }
end

textutils = {}
local function ser(v, indent)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t ~= "table" then return tostring(v) end
  local parts = {}
  for k, val in pairs(v) do
    local ks = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. ser(k) .. "]")
    parts[#parts + 1] = ks .. " = " .. ser(val)
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end
function textutils.serialise(v) return ser(v) end
function textutils.unserialise(s)
  local fn = load("return " .. s, "=ser", "t", {})
  if not fn then return nil end
  local ok, v = pcall(fn)
  return ok and v or nil
end
textutils.serialize, textutils.unserialize = textutils.serialise, textutils.unserialise

local queued = {}
os.clock = function() return T.clock end
os.epoch = function() return T.epoch end
os.queueEvent = function(name, ...) queued[#queued + 1] = { name, ... } end
os.startTimer = function() return 1 end
os.pullEvent = function() error("the tests drive the engine with tick()") end
sleep = function() end
peripheral = { call = function() error("no peripherals in the simulation") end }

package.path = package.path
local util = require("lib.util")
local Recipes = require("craft.recipes")
local Engine = require("craft.engine")

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
local MAX = { ["minecraft:diamond_pickaxe"] = 1, ["minecraft:ender_pearl"] = 16 }
local function maxOf(name) return MAX[name] or 64 end
local function nameOf(id) return util.titleCase(id) end

-- What the simulated turtle can craft: the ingredients (sorted item ids)
-- -> what one craft gives.
local RECIPES = {
  ["minecraft:oak_log"] = { name = "minecraft:oak_planks", count = 4 },
  ["minecraft:oak_planks+minecraft:oak_planks"] = { name = "minecraft:stick", count = 4 },
  ["minecraft:diamond+minecraft:diamond+minecraft:diamond+minecraft:stick+minecraft:stick"] = { name = "minecraft:diamond_pickaxe", count = 1 },
  ["minecraft:iron_ingot+minecraft:iron_ingot+minecraft:iron_ingot+minecraft:iron_ingot+minecraft:iron_ingot+minecraft:iron_ingot+minecraft:iron_ingot+minecraft:iron_ingot+minecraft:iron_ingot"] = { name = "minecraft:iron_block", count = 1 },
  ["minecraft:oak_planks+minecraft:oak_planks+minecraft:oak_planks+minecraft:oak_planks"] = { name = "minecraft:crafting_table", count = 1 },
}
local SMELT = { ["minecraft:raw_iron"] = "minecraft:iron_ingot", ["minecraft:oak_log"] = "minecraft:charcoal" }

---------------------------------------------------------------------------
-- The vault and the chests on its network
---------------------------------------------------------------------------
local function newInv(size) return { size = size, slots = {} } end

-- Puts up to `count` of an item into an inventory: into `slot`, or in
-- slot order. Returns how many got in.
local function insert(inv, name, count, slot)
  local moved = 0
  local function into(s, n)
    local d = inv.slots[s]
    if d then
      if d.name ~= name then return 0 end
      local m = math.min(maxOf(name) - d.count, n)
      if m <= 0 then return 0 end
      d.count = d.count + m
      return m
    end
    local m = math.min(maxOf(name), n)
    inv.slots[s] = { name = name, count = m }
    return m
  end
  if slot then return into(slot, count) end
  for s = 1, inv.size do
    if moved >= count then break end
    moved = moved + into(s, count - moved)
  end
  return moved
end

local function total(inv)
  local n = 0
  for _, st in pairs(inv.slots) do n = n + st.count end
  return n
end

local function newVault()
  local sim = { stock = {}, invs = {}, full = false, calls = {} }
  local V = { sim = sim }
  local function called(op) sim.calls[op] = (sim.calls[op] or 0) + 1 end
  local function inv(name)
    local i = sim.invs[name]
    if not i then error("cannot read " .. tostring(name) .. ": No peripheral named " .. tostring(name), 0) end
    return i
  end
  function V.count(item)
    called("count")
    return sim.stock[item] or 0
  end
  function V.details(key)
    called("details")
    return { name = key, displayName = nameOf(key), maxCount = maxOf(key) }
  end
  function V.withdraw(item, count, to, toSlot)
    called("withdraw")
    local have = sim.stock[item] or 0
    if have <= 0 then error("not in storage: " .. item, 0) end
    local target = inv(to)
    local n = math.min(count, have)
    local moved = insert(target, item, n, toSlot)
    sim.stock[item] = have - moved
    return moved, moved < count and "the target is full" or nil
  end
  function V.deposit(from, opts)
    called("deposit")
    opts = opts or {}
    local src = inv(from)
    local moved, items, msg = 0, {}, nil
    local budget = opts.count or math.huge
    local slots = {}
    for s in pairs(src.slots) do slots[#slots + 1] = s end
    table.sort(slots)
    if #slots == 0 then return 0, {}, "nothing to store" end
    for _, s in ipairs(slots) do
      if (not opts.slot or opts.slot == s) and budget > moved then
        local st = src.slots[s]
        if not opts.item or st.name == opts.item then
          if sim.full then
            msg = "storage is full"
          else
            local n = math.min(st.count, budget - moved)
            sim.stock[st.name] = (sim.stock[st.name] or 0) + n
            items[st.name] = (items[st.name] or 0) + n
            moved = moved + n
            st.count = st.count - n
            if st.count <= 0 then src.slots[s] = nil end
          end
        end
      end
    end
    return moved, items, msg
  end
  function V.move(from, fromSlot, to, toSlot, count)
    called("move")
    local src, dst = inv(from), inv(to)
    local st = src.slots[fromSlot]
    if not st then return 0 end
    local n = math.min(count or st.count, st.count)
    local moved = insert(dst, st.name, n, toSlot)
    st.count = st.count - moved
    if st.count <= 0 then src.slots[fromSlot] = nil end
    return moved
  end
  function V.inventory(name)
    called("inventory")
    local i = inv(name)
    local items = {}
    for s, st in pairs(i.slots) do items[#items + 1] = { slot = s, key = st.name, name = st.name, count = st.count } end
    table.sort(items, function(a, b) return a.slot < b.slot end)
    return { name = name, size = i.size, items = items, total = total(i), stacks = #items }
  end
  return V
end

---------------------------------------------------------------------------
-- The crafty turtle (what craft.worker does, on the simulated chests)
---------------------------------------------------------------------------
local function newLink(vault, input, output)
  local link = { calls = 0, away = false, rounds = {}, id = 15 }
  function link:setTurtle() end
  function link:ping()
    if self.away then return nil, "turtle #15 did not answer" end
    return { crafty = true, fuel = 100, free = 16, label = "Crafty", build = self.build }
  end
  function link:clear() return { ok = true, dropped = {} } end
  function link:update(url, build)
    self.updates = (self.updates or 0) + 1
    self.updatedTo = { url = url, build = build }
    if self.updateFails then return { ok = false, error = self.updateFails } end
    self.build = build -- it fetches that build and comes back with it
    return { ok = true, build = build, rebooting = true }
  end
  function link:craft(grid, limit)
    if self.away then return nil, "turtle #15 did not answer" end
    self.calls = self.calls + 1
    local src, dst = vault.sim.invs[input], vault.sim.invs[output]
    local taken = {}
    local function dropAll()
      local dropped = {}
      for _, t in pairs(taken) do
        if t.count > 0 then
          insert(dst, t.name, t.count)
          dropped[#dropped + 1] = { name = t.name, count = t.count }
        end
      end
      return dropped
    end
    for _, g in ipairs(grid) do
      local slot
      for s = 1, src.size do
        if src.slots[s] then slot = s break end
      end
      local st = slot and src.slots[slot]
      local take = st and math.min(g.count, st.count) or 0
      if st then
        st.count = st.count - take
        if st.count <= 0 then src.slots[slot] = nil end
        taken[g.slot] = { name = st.name, count = take }
      end
      if not st or st.name ~= g.name or take ~= g.count then
        local dropped = dropAll()
        return { ok = false, dropped = dropped, error = string.format("slot %d: expected %d %s, got %d %s", g.slot, g.count, util.shortName(g.name), take, st and util.shortName(st.name) or "nothing") }
      end
    end
    local names = {}
    for _, t in pairs(taken) do names[#names + 1] = t.name end
    table.sort(names)
    local r = RECIPES[table.concat(names, "+")]
    if not r then return { ok = false, error = "No matching recipe", dropped = dropAll() } end
    local n = limit
    for _, t in pairs(taken) do n = math.min(n, t.count) end
    for _, t in pairs(taken) do t.count = t.count - n end
    local made = n * r.count
    self.rounds[#self.rounds + 1] = { crafts = n, result = r.name }
    local left = made - insert(dst, r.name, made)
    local dropped = dropAll()
    local reply = { ok = true, made = made, dropped = dropped, result = { name = r.name, displayName = nameOf(r.name), maxCount = maxOf(r.name) } }
    if left > 0 then reply.left = { { name = r.name, count = left } } end
    return reply
  end
  return link
end

-- The smelter line: hoppers take from the input chest, furnaces smelt
-- `rate` items per advance, hoppers put the result in the finish chest.
local function smelt(vault, smeltIn, smeltOut, rate)
  local src, dst = vault.sim.invs[smeltIn], vault.sim.invs[smeltOut]
  local n = 0
  for s = 1, src.size do
    local st = src.slots[s]
    while st and st.count > 0 and n < rate do
      local out = SMELT[st.name]
      if not out then break end
      if insert(dst, out, 1) == 0 then return n end
      st.count = st.count - 1
      n = n + 1
    end
    if st and st.count <= 0 then src.slots[s] = nil end
  end
  return n
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local failures, passed = 0, 0
local function test(name, fn)
  files = {}
  queued = {}
  T.clock, T.epoch = 0, 1700000000000
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures = failures + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end

local function eq(a, b, what)
  if a ~= b then error((what or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function check(cond, what, ...)
  if not cond then error((what or "check failed") .. (select("#", ...) > 0 and (": " .. table.concat({ ... }, " ")) or ""), 2) end
end

local CFG = { input = "in", output = "out", recipeChest = "recipe", smeltIn = "sin", smeltOut = "sout", smeltStall = 300 }

local function world(opts)
  opts = opts or {}
  local vault = newVault()
  vault.sim.invs["in"] = newInv(27)
  vault.sim.invs["out"] = newInv(27)
  vault.sim.invs["recipe"] = newInv(27)
  vault.sim.invs["sin"] = newInv(27)
  vault.sim.invs["sout"] = newInv(27)
  for k, v in pairs(opts.stock or {}) do vault.sim.stock[k] = v end
  local link = newLink(vault, "in", "out")
  local cfg = {}
  for k, v in pairs(CFG) do cfg[k] = v end
  for k, v in pairs(opts.cfg or {}) do cfg[k] = v end
  local logs = {}
  local eng = Engine.new({
    vault = vault, root = "/warehouse", link = link, cfg = cfg,
    log = function(m) logs[#logs + 1] = m end,
    clock = function() return T.clock end, epoch = function() return T.epoch end,
  })
  return { vault = vault, link = link, eng = eng, logs = logs, cfg = cfg }
end

-- A fresh engine over the same files, as after a reboot.
local function reboot(w)
  w.link = newLink(w.vault, "in", "out")
  w.eng = Engine.new({
    vault = w.vault, root = "/warehouse", link = w.link, cfg = w.cfg,
    log = function(m) w.logs[#w.logs + 1] = m end,
    clock = function() return T.clock end, epoch = function() return T.epoch end,
  })
  return w.eng
end

-- Runs the scheduler for `n` passes, a second apart, with the smelter
-- working in between.
local function ticks(w, n, rate)
  for _ = 1, n do
    w.eng:tick()
    T.clock = T.clock + 1
    T.epoch = T.epoch + 1000
    if rate then smelt(w.vault, "sin", "sout", rate) end
  end
end

local function until_(w, cond, max, rate)
  for _ = 1, max or 200 do
    if cond() then return true end
    ticks(w, 1, rate)
  end
  return cond()
end

local function stepOf(grid, result, kind)
  local step = { kind = kind or "craft", grid = {} }
  for cell, id in pairs(grid) do
    step.grid[cell] = { key = id, name = id, displayName = nameOf(id), slot = Recipes.CELL_SLOTS[cell] }
  end
  if kind == "smelt" then
    step.input = step.grid[1]
    step.grid = nil
  end
  if result then step.result = { key = result[1], name = result[1], displayName = nameOf(result[1]), count = result[2], maxCount = maxOf(result[1]) } end
  return step
end

local PLANKS = function(r) return stepOf({ [1] = "minecraft:oak_log" }, r ~= false and { "minecraft:oak_planks", 4 } or nil) end
local STICKS = function(r) return stepOf({ [1] = "minecraft:oak_planks", [4] = "minecraft:oak_planks" }, r ~= false and { "minecraft:stick", 4 } or nil) end
local PICKAXE = function(r)
  return stepOf({ [1] = "minecraft:diamond", [2] = "minecraft:diamond", [3] = "minecraft:diamond", [5] = "minecraft:stick", [8] = "minecraft:stick" }, r ~= false and { "minecraft:diamond_pickaxe", 1 } or nil)
end

local function summary(w, id) return w.eng:summary(w.eng:get(id)) end

---------------------------------------------------------------------------
-- The model
---------------------------------------------------------------------------
test("a recipe is read off the chest's top left 3x3, with the result in slot 9", function()
  local inv = { size = 27, items = {
    { slot = 1, key = "minecraft:oak_planks", name = "minecraft:oak_planks", count = 7 },
    { slot = 10, key = "minecraft:oak_planks", name = "minecraft:oak_planks", count = 1 },
    { slot = 9, key = "minecraft:stick", name = "minecraft:stick", count = 4 },
    { slot = 27, key = "minecraft:dirt", name = "minecraft:dirt", count = 1 },
  } }
  local function details(key) return { displayName = nameOf(key), maxCount = maxOf(key) } end
  local step = Recipes.scan(inv, details, "craft")
  eq(step.kind, "craft", "kind")
  eq(step.grid[1].key, "minecraft:oak_planks", "cell 1")
  eq(step.grid[4].key, "minecraft:oak_planks", "cell 4 (second row)")
  eq(step.grid[2], nil, "cell 2 empty")
  eq(step.grid[1].slot, 1, "remembers the chest slot")
  eq(step.result.key, "minecraft:stick", "result from slot 9")
  eq(step.result.count, 4, "result count")
  eq(Recipes.describe(step), "Craft 2 Oak Planks -> 4 Stick", "described")
  local ing = Recipes.ingredients(step)
  eq(#ing, 1, "one ingredient kind") eq(ing[1].cells, 2, "in two cells")
  eq(select(2, Recipes.scan({ size = 27, items = {} }, details)), "nothing in the 3x3 (top left of the chest)", "empty chest")
  -- A dropper is the grid itself.
  local d = Recipes.scan({ size = 9, items = { { slot = 5, key = "minecraft:oak_log", name = "minecraft:oak_log", count = 1 } } }, details)
  eq(d.grid[5].key, "minecraft:oak_log", "cell 5 of a dropper")
  eq(d.result, nil, "a dropper has no result slot")
  -- A smelt step: one kind of item in the grid, the result in slot 9.
  local s = Recipes.scan({ size = 27, items = {
    { slot = 11, key = "minecraft:raw_iron", name = "minecraft:raw_iron", count = 3 },
    { slot = 9, key = "minecraft:iron_ingot", name = "minecraft:iron_ingot", count = 1 } } }, details, "smelt")
  eq(s.kind, "smelt", "smelt") eq(s.input.key, "minecraft:raw_iron", "input") eq(s.result.key, "minecraft:iron_ingot", "result")
  eq(Recipes.describe(s), "Smelt 1 Raw Iron -> 1 Iron Ingot", "described")
  local _, err = Recipes.scan({ size = 27, items = {
    { slot = 1, key = "minecraft:raw_iron", name = "minecraft:raw_iron", count = 3 },
    { slot = 2, key = "minecraft:raw_gold", name = "minecraft:raw_gold", count = 3 } } }, details, "smelt")
  check(err and err:find("one kind"), "two kinds refused", tostring(err))
  eq(Recipes.turtleSlot(4), 5, "cell 4 is turtle slot 5") eq(Recipes.turtleSlot(9), 11, "cell 9 is turtle slot 11")
end)

test("an order is planned backwards: later steps' needs, minus what the vault holds", function()
  local rec = { steps = { PLANKS(), STICKS(), PICKAXE() } }
  local stock = {}
  local plan = Recipes.plan(rec, 2, function(k) return stock[k] or 0 end)
  eq(plan.ops[3], 2, "2 pickaxe crafts")
  eq(plan.ops[2], 1, "4 sticks needed: 1 stick craft")
  eq(plan.ops[1], 1, "2 planks needed: 1 plank craft")
  eq(plan.need["minecraft:diamond"], 6, "6 diamonds")
  eq(Recipes.external(plan)["minecraft:oak_log"], 1, "from the vault: 1 log")
  eq(Recipes.external(plan)["minecraft:diamond"], 6, "and 6 diamonds")
  eq(Recipes.external(plan)["minecraft:stick"], nil, "sticks are made")
  stock["minecraft:stick"] = 3
  plan = Recipes.plan(rec, 2, function(k) return stock[k] or 0 end)
  eq(plan.ops[2], 1, "3 sticks in stock, 4 needed: still 1 craft")
  stock["minecraft:stick"] = 100
  plan = Recipes.plan(rec, 2, function(k) return stock[k] or 0 end)
  eq(plan.ops[2], 0, "enough sticks: no stick craft")
  eq(plan.ops[1], 0, "so no planks either")
  stock["minecraft:diamond_pickaxe"] = 100
  eq(Recipes.plan(rec, 2, function(k) return stock[k] or 0 end).ops[3], 2, "the final step always makes what was ordered")
  eq(select(2, Recipes.plan({ steps = { PLANKS(false) } }, 1, function() return 0 end)), "step 1 has no result yet", "unlearned")
  eq(select(2, Recipes.plan({ steps = {} }, 1, function() return 0 end)), "the recipe has no steps", "empty")
  -- Batches: a stack per cell, results in the free slots.
  local details = function(k) return { maxCount = maxOf(k) } end
  eq(Recipes.maxBatch(PLANKS(), details), 64, "planks: 64 a round")
  eq(Recipes.maxBatch(PICKAXE(), details), 7, "pickaxes: 7 a round (unstackable results)")
  eq(Recipes.maxBatch(stepOf({ [1] = "minecraft:ender_pearl" }, { "minecraft:dirt", 1 }), details), 16, "pearls: 16 a round")
end)

---------------------------------------------------------------------------
-- The engine
---------------------------------------------------------------------------
test("a step without a result is learned by crafting once, then an order is made", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 10 } })
  local rec = w.eng:add({ name = "Planks", steps = { PLANKS(false) } })
  eq(summary(w, rec.id).state, "learning", "needs learning")
  ticks(w, 2)
  eq(w.link.calls, 1, "one craft to learn")
  eq(rec.steps[1].result.key, "minecraft:oak_planks", "learned the result")
  eq(rec.steps[1].result.count, 4, "and how many a craft gives")
  eq(w.vault.sim.stock["minecraft:oak_planks"], 4, "the learning craft's planks went to the vault")
  eq(w.vault.sim.stock["minecraft:oak_log"], 9, "one log used")
  eq(summary(w, rec.id).state, "idle", "idle now")
  eq(summary(w, rec.id).result, "Oak Planks", "shows what it makes")
  w.eng:order(rec.id, 10)
  eq(summary(w, rec.id).state, "queued", "queued")
  check(until_(w, function() return summary(w, rec.id).state == "idle" end, 20), "done", summary(w, rec.id).text)
  eq(w.link.calls, 2, "one round for 3 crafts")
  eq(w.link.rounds[2].crafts, 3, "3 crafts (10 planks need 3)")
  eq(w.vault.sim.stock["minecraft:oak_planks"], 16, "16 planks in the vault")
  eq(w.vault.sim.stock["minecraft:oak_log"], 6, "3 logs used")
  local s = summary(w, rec.id)
  eq(s.made, 12, "made 12") eq(s.runs, 1, "one run") eq(s.crafts, 4, "4 crafts in all")
  eq(total(w.vault.sim.invs["in"]), 0, "input chest empty") eq(total(w.vault.sim.invs["out"]), 0, "output chest empty")
  -- The recipe and its stats survive on disk.
  local list = Recipes.load("/warehouse")
  eq(list[1].steps[1].result.key, "minecraft:oak_planks", "saved")
  w.eng:saveState(true)
  local st = util.readTable("/warehouse/data/crafter/state")
  eq(st.recipes[rec.id].stats.made, 12, "stats saved")
end)

test("a three-step order runs each step through the vault; stock of intermediates is used first", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 5, ["minecraft:diamond"] = 6 } })
  local rec = w.eng:add({ name = "Pickaxe", steps = { PLANKS(), STICKS(), PICKAXE() } })
  w.eng:runTimes(rec.id, 2)
  check(until_(w, function() return summary(w, rec.id).runs == 1 end, 30), "done", summary(w, rec.id).text)
  local stock = w.vault.sim.stock
  eq(stock["minecraft:diamond_pickaxe"], 2, "2 pickaxes")
  eq(stock["minecraft:diamond"], 0, "diamonds used")
  eq(stock["minecraft:oak_log"], 4, "one log used")
  eq(stock["minecraft:oak_planks"], 2, "2 planks left over")
  eq(stock["minecraft:stick"], 0, "4 sticks made, 4 used")
  eq(#w.link.rounds, 3, "three rounds")
  eq(w.link.rounds[1].result, "minecraft:oak_planks", "planks first")
  eq(w.link.rounds[3].result, "minecraft:diamond_pickaxe", "pickaxes last")
  eq(summary(w, rec.id).made, 2, "made 2")
  -- Enough sticks around: the first two steps are skipped.
  stock["minecraft:stick"] = 50
  stock["minecraft:diamond"] = 3
  w.eng:order(rec.id, 1)
  check(until_(w, function() return summary(w, rec.id).runs == 2 end, 30), "second run done", summary(w, rec.id).text)
  eq(#w.link.rounds, 4, "one more round only")
  eq(stock["minecraft:oak_log"], 4, "no log used")
  eq(stock["minecraft:stick"], 48, "sticks from stock")
  eq(stock["minecraft:diamond_pickaxe"], 3, "3 pickaxes")
end)

test("missing ingredients: the recipe waits and says for what, and goes on when they arrive", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 5 } })
  local rec = w.eng:add({ name = "Pickaxe", steps = { PLANKS(), STICKS(), PICKAXE() } })
  w.eng:order(rec.id, 1)
  ticks(w, 6)
  local s = summary(w, rec.id)
  eq(s.state, "waiting", "waiting")
  eq(s.text, "waiting for Diamond", "says what for")
  check(s.progress and s.progress:find("step 3/3"), "the planks and sticks are done", tostring(s.progress))
  eq(w.vault.sim.stock["minecraft:stick"], 4, "sticks made meanwhile")
  w.vault.sim.stock["minecraft:diamond"] = 3
  check(until_(w, function() return summary(w, rec.id).runs == 1 end, 20), "finished once diamonds came", summary(w, rec.id).text)
  eq(w.vault.sim.stock["minecraft:diamond_pickaxe"], 1, "pickaxe made")
  eq(summary(w, rec.id).state, "idle", "idle")
end)

test("always: round after round, two recipes taking turns; stop ends it", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 1000, ["minecraft:oak_planks"] = 1000 } })
  local a = w.eng:add({ name = "Planks", mode = "always", steps = { PLANKS() } })
  local b = w.eng:add({ name = "Sticks", mode = "always", steps = { STICKS() } })
  ticks(w, 8)
  local pa, pb = 0, 0
  for _, r in ipairs(w.link.rounds) do
    if r.result == "minecraft:oak_planks" then pa = pa + 1 else pb = pb + 1 end
  end
  check(pa >= 3 and pb >= 3, "both got turns", pa, pb)
  check(w.link.rounds[1].result ~= w.link.rounds[2].result, "taking turns")
  eq(w.link.rounds[1].crafts, 64, "a full stack a round")
  check(summary(w, a.id).made >= 3 * 256, "planks keep coming", summary(w, a.id).made)
  w.eng:stop(a.id)
  eq(a.mode, "off", "stop switches always off")
  local n = #w.link.rounds
  ticks(w, 4)
  for i = n + 1, #w.link.rounds do eq(w.link.rounds[i].result, "minecraft:stick", "only sticks after the stop") end
  eq(summary(w, a.id).state, "idle", "planks idle")
  -- Out of logs: it waits rather than fails.
  w.eng:setMode(a.id, "always")
  w.vault.sim.stock["minecraft:oak_log"] = 0
  ticks(w, 4)
  eq(summary(w, a.id).text, "waiting for Oak Log", "waits for logs")
  eq(summary(w, a.id).errors, 0, "no error counted")
end)

test("rate: so many items every so often, skipping a period it is still busy with", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 1000 } })
  local rec = w.eng:add({ name = "Planks", mode = "rate", rateCount = 100, rateSeconds = 60, steps = { PLANKS() } })
  ticks(w, 3)
  check(until_(w, function() return summary(w, rec.id).runs == 1 end, 10), "first batch at once")
  eq(summary(w, rec.id).made, 100, "100 planks")
  ticks(w, 30)
  eq(summary(w, rec.id).runs, 1, "nothing more within the period")
  check(summary(w, rec.id).text:find("100 every 60s, next in"), "says when", summary(w, rec.id).text)
  ticks(w, 35)
  check(until_(w, function() return summary(w, rec.id).runs == 2 end, 10), "second batch after the period")
  -- Busy with a big order when the period comes: counted as behind, not piled up.
  w.eng:order(rec.id, 2000)
  w.link.away = true
  ticks(w, 130)
  check(summary(w, rec.id).behind >= 2, "behind", summary(w, rec.id).behind)
  w.link.away = false
  check(until_(w, function() return summary(w, rec.id).runs == 3 end, 400), "the order finishes")
  eq(summary(w, rec.id).made, 2200, "no extra period's worth added")
end)

test("smelting: items go to the smelter's input chest, results are caught from its finish chest", function()
  local w = world({ stock = { ["minecraft:raw_iron"] = 30 } })
  local smeltStep = stepOf({ [1] = "minecraft:raw_iron" }, { "minecraft:iron_ingot", 1 }, "smelt")
  local block = stepOf({ [1] = "minecraft:iron_ingot", [2] = "minecraft:iron_ingot", [3] = "minecraft:iron_ingot", [4] = "minecraft:iron_ingot", [5] = "minecraft:iron_ingot",
    [6] = "minecraft:iron_ingot", [7] = "minecraft:iron_ingot", [8] = "minecraft:iron_ingot", [9] = "minecraft:iron_ingot" }, { "minecraft:iron_block", 1 })
  local rec = w.eng:add({ name = "Iron block", steps = { smeltStep, block } })
  w.eng:order(rec.id, 2)
  ticks(w, 2, 4)
  local s = summary(w, rec.id)
  check(s.text:find("smelting 0/18") or s.text:find("smelting %d+/18"), "18 to smelt", s.text)
  eq(total(w.vault.sim.invs["sin"]) + total(w.vault.sim.invs["sout"]) + (w.vault.sim.stock["minecraft:iron_ingot"] or 0), 18, "18 raw iron sent, some smelted already")
  check(until_(w, function() return summary(w, rec.id).runs == 1 end, 40, 4), "done", summary(w, rec.id).text)
  eq(w.vault.sim.stock["minecraft:iron_block"], 2, "2 blocks")
  eq(w.vault.sim.stock["minecraft:iron_ingot"], 0, "all 18 ingots used")
  eq(w.vault.sim.stock["minecraft:raw_iron"], 12, "12 raw iron left")
  eq(summary(w, rec.id).smelted, 18, "smelted 18")
  eq(w.eng:status().smelter.items, 18, "the finish chest was emptied 18 times over")
  -- Whatever else lands in the finish chest goes to the vault too.
  insert(w.vault.sim.invs["sout"], "minecraft:charcoal", 5)
  ticks(w, 4)
  eq(w.vault.sim.stock["minecraft:charcoal"], 5, "caught")
  -- A stalled smelter is reported, not failed.
  w.eng:order(rec.id, 1)
  ticks(w, 320)
  check(summary(w, rec.id).text:find("nothing came out"), "stalled", summary(w, rec.id).text)
  eq(summary(w, rec.id).errors, 0, "no error")
  check(until_(w, function() return summary(w, rec.id).runs == 2 end, 40, 2), "finishes when the smelter works again")
end)

test("a smelt step without a result learns it from what comes out", function()
  local w = world({ stock = { ["minecraft:raw_iron"] = 3 } })
  local rec = w.eng:add({ name = "Ingots", steps = { stepOf({ [1] = "minecraft:raw_iron" }, nil, "smelt") } })
  ticks(w, 2)
  eq(summary(w, rec.id).state, "learning", "learning")
  check(summary(w, rec.id).text:find("smelting one Raw Iron"), "says so", summary(w, rec.id).text)
  eq(total(w.vault.sim.invs["sin"]), 1, "one sent")
  ticks(w, 6, 1)
  eq(rec.steps[1].result and rec.steps[1].result.key, "minecraft:iron_ingot", "learned")
  eq(summary(w, rec.id).state, "idle", "idle")
  eq(w.vault.sim.stock["minecraft:iron_ingot"], 1, "the ingot is in the vault")
end)

test("learning takes ingredients from the recipe chest when the vault has none", function()
  local w = world()
  insert(w.vault.sim.invs["recipe"], "minecraft:oak_log", 3, 1)
  local rec = w.eng:add({ name = "Planks", steps = { PLANKS(false) } })
  ticks(w, 2)
  eq(rec.steps[1].result and rec.steps[1].result.key, "minecraft:oak_planks", "learned from the chest's log")
  eq(w.vault.sim.invs["recipe"].slots[1].count, 2, "one log taken from the recipe chest")
  eq(w.vault.sim.stock["minecraft:oak_planks"], 4, "planks stored")
  -- Nothing anywhere (the planks it just made are gone): it waits for the item.
  w.vault.sim.stock["minecraft:oak_planks"] = 0
  local rec2 = w.eng:add({ name = "Sticks", steps = { STICKS(false) } })
  ticks(w, 2)
  eq(summary(w, rec2.id).text, "learn: waiting for Oak Planks", "waits")
  w.vault.sim.stock["minecraft:oak_planks"] = 2
  ticks(w, 3)
  eq(rec2.steps[1].result and rec2.steps[1].result.key, "minecraft:stick", "learned once planks were there")
end)

test("learning finds the ingredient wherever it lies in the recipe chest", function()
  local w = world()
  -- The log was scanned in cell 1 (slot 1) but has been moved to slot 21 since.
  insert(w.vault.sim.invs["recipe"], "minecraft:oak_log", 3, 21)
  local rec = w.eng:add({ name = "Planks", steps = { PLANKS(false) } })
  ticks(w, 2)
  eq(rec.steps[1].result and rec.steps[1].result.key, "minecraft:oak_planks", "learned from the moved log")
  eq(w.vault.sim.invs["recipe"].slots[21].count, 2, "one log taken from slot 21")
end)

test("a turtle on another build is sent to the folder's source for ours, once", function()
  local w = world()
  files[fs.combine("/warehouse", "data/build")] = "ours-1"
  files[fs.combine("/warehouse", "data/source")] = "https://gist/raw/warehouse.lua"
  w.link.build = "theirs-1"
  ticks(w, 2)
  eq(w.link.updates, 1, "told to update")
  eq(w.link.updatedTo.url, "https://gist/raw/warehouse.lua", "from our source")
  eq(w.link.updatedTo.build, "ours-1", "to our build")
  eq(w.eng.turtle.state, "away", "away while it reboots")
  ticks(w, 15)
  eq(w.eng.turtle.state, "ready", "back")
  eq(w.eng.turtle.msg, nil, "same build now, nothing to say")
  eq(w.link.updates, 1, "not asked again")
  -- A turtle that cannot update (no HTTP, say) is told once, then left alone.
  local w2 = world()
  files[fs.combine("/warehouse", "data/build")] = "ours-2"
  files[fs.combine("/warehouse", "data/source")] = "https://gist/raw/warehouse.lua"
  w2.link.build = nil
  w2.link.updateFails = "HTTP is turned off on this turtle"
  ticks(w2, 2)
  eq(w2.link.updates, 1, "tried once")
  eq(w2.eng.turtle.state, "ready", "still usable")
  assert(w2.eng.turtle.msg:find("could not update it"), w2.eng.turtle.msg)
  ticks(w2, 70)
  eq(w2.link.updates, 1, "not tried again")
  -- Without a source, only the message.
  local w3 = world()
  files[fs.combine("/warehouse", "data/build")] = "ours-3"
  files[fs.combine("/warehouse", "data/source")] = nil
  w3.link.build = "theirs-3"
  ticks(w3, 2)
  eq(w3.link.updates, nil, "nowhere to send it")
  assert(w3.eng.turtle.msg:find("another crafter build"), w3.eng.turtle.msg)
end)

test("the turtle going away: items go back to the vault, the run waits and resumes", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 100 } })
  local rec = w.eng:add({ name = "Planks", steps = { PLANKS() } })
  w.link.away = true
  w.eng:order(rec.id, 100)
  ticks(w, 3)
  local s = summary(w, rec.id)
  eq(s.state, "waiting", "waiting")
  check(s.text:find("turtle #15 did not answer"), "says the turtle is away", s.text)
  eq(w.eng:status().turtle.state, "away", "turtle away")
  eq(w.vault.sim.stock["minecraft:oak_log"], 100, "nothing taken out")
  eq(total(w.vault.sim.invs["in"]), 0, "input chest empty")
  -- Away in the middle of a round: what was put in the chest goes back.
  w.link.away = false
  ticks(w, 12)
  eq(w.eng:status().turtle.state, "ready", "turtle back")
  check(summary(w, rec.id).runs == 1, "finished", summary(w, rec.id).text)
  eq(w.vault.sim.stock["minecraft:oak_planks"], 100, "100 planks")
  local function away() w.link.away = true end
  w.eng:order(rec.id, 8)
  local craft = w.link.craft
  w.link.craft = function(self, grid, limit) away() return nil, "turtle #15 did not answer" end
  ticks(w, 2)
  eq(total(w.vault.sim.invs["in"]), 0, "logs put back")
  eq(w.vault.sim.stock["minecraft:oak_log"], 75, "all 75 logs in the vault")
  w.link.craft = craft
  w.link.away = false
  check(until_(w, function() return summary(w, rec.id).runs == 2 end, 20), "finished after the turtle came back")
end)

test("a craft that fails on the turtle is a problem the user has to look at; an order clears it", function()
  local w = world({ stock = { ["minecraft:dirt"] = 10 } })
  local rec = w.eng:add({ name = "Nonsense", mode = "always", steps = { stepOf({ [1] = "minecraft:dirt" }, { "minecraft:diamond", 1 }) } })
  ticks(w, 4)
  local s = summary(w, rec.id)
  eq(s.state, "problem", "problem")
  eq(s.text, "step 1: No matching recipe", "says what")
  eq(s.errors, 1, "one error, not one per tick")
  eq(w.link.calls, 1, "not tried again by itself")
  eq(w.vault.sim.stock["minecraft:dirt"], 10, "the dirt came back")
  w.eng:order(rec.id, 1)
  ticks(w, 2)
  eq(summary(w, rec.id).errors, 2, "tried again on the order")
  eq(summary(w, rec.id).state, "problem", "still a problem")
  -- The wrong thing in the input chest (someone put something there): refused by the turtle.
  local w2 = world({ stock = { ["minecraft:oak_log"] = 10 } })
  local rec2 = w2.eng:add({ name = "Planks", steps = { PLANKS() } })
  w2.vault.sim.full = true
  insert(w2.vault.sim.invs["in"], "minecraft:dirt", 1, 1)
  w2.eng:order(rec2.id, 4)
  ticks(w2, 2)
  check(summary(w2, rec2.id).state == "waiting" and summary(w2, rec2.id).text:find("full"), "waits while the chest cannot be emptied", summary(w2, rec2.id).text)
  w2.vault.sim.full = false
  ticks(w2, 3)
  eq(summary(w2, rec2.id).runs, 1, "goes on once it can")
end)

test("a reboot in the middle of an order carries on from the saved state", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 100, ["minecraft:diamond"] = 30 } })
  local rec = w.eng:add({ name = "Pickaxe", steps = { PLANKS(), STICKS(), PICKAXE() } })
  w.eng:order(rec.id, 10)
  ticks(w, 3)
  check(summary(w, rec.id).state == "running", "running", summary(w, rec.id).text)
  w.eng:saveState(true)
  local before = #w.link.rounds
  local eng = reboot(w)
  local s = eng:summary(eng:get(rec.id))
  eq(s.state, "running", "still running after the reboot")
  eq(s.want, 10, "the same order")
  check(until_(w, function() return eng:summary(eng:get(rec.id)).runs == 1 end, 40), "finished")
  eq(w.vault.sim.stock["minecraft:diamond_pickaxe"], 10, "10 pickaxes")
  check(#w.link.rounds > 0, "rounds after the reboot")
  eq(before + #w.link.rounds >= 4, true, "a few rounds in all")
end)

test("big orders go in rounds of a stack; unstackable results seven at a time", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 100, ["minecraft:stick"] = 100, ["minecraft:diamond"] = 100 } })
  local planks = w.eng:add({ name = "Planks", steps = { PLANKS() } })
  w.eng:order(planks.id, 300)
  check(until_(w, function() return summary(w, planks.id).runs == 1 end, 20), "planks done")
  eq(#w.link.rounds, 2, "two rounds")
  eq(w.link.rounds[1].crafts, 64, "64 then") eq(w.link.rounds[2].crafts, 11, "11")
  eq(w.vault.sim.stock["minecraft:oak_planks"], 300, "300 planks")
  local pick = w.eng:add({ name = "Pickaxe", steps = { PICKAXE() } })
  w.eng:runTimes(pick.id, 10)
  check(until_(w, function() return summary(w, pick.id).runs == 1 end, 20), "pickaxes done")
  eq(#w.link.rounds, 4, "two more rounds")
  eq(w.link.rounds[3].crafts, 7, "7 then") eq(w.link.rounds[4].crafts, 3, "3")
  eq(w.vault.sim.stock["minecraft:diamond_pickaxe"], 10, "10 pickaxes")
  eq(w.vault.sim.stock["minecraft:diamond"], 70, "30 diamonds used")
end)

test("settings: mode, rate and name change on the fly; removing forgets the state", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 100 } })
  local rec = w.eng:add({ name = "Planks", steps = { PLANKS() } })
  w.eng:set(rec.id, { mode = "rate", rateCount = 8, rateSeconds = 120, name = "Boards" })
  eq(rec.name, "Boards", "renamed") eq(rec.rateCount, 8, "rate set")
  check(w.eng:find("boards") == rec, "found by name, any case")
  local ok, err = pcall(w.eng.set, w.eng, rec.id, { mode = "sometimes" })
  check(not ok and err:find("mode must be"), "bad mode refused", tostring(err))
  ok, err = pcall(w.eng.order, w.eng, "nothing", 1)
  check(not ok and err:find("no recipe called"), "unknown recipe", tostring(err))
  local other = w.eng:add({ name = "Planks", steps = { PLANKS() } })
  ok, err = pcall(w.eng.set, w.eng, other.id, { name = "Boards" })
  check(not ok and err:find("already"), "duplicate name refused", tostring(err))
  w.eng:order(other.id, 4)
  ticks(w, 3)
  eq(summary(w, other.id).runs, 1, "the other one ran")
  w.eng:remove(other.id)
  eq(#w.eng.recipes, 1, "removed")
  eq(w.eng.state.recipes[other.id], nil, "its state too")
  check(not util.readTable("/warehouse/data/crafter/state").recipes[other.id], "and on disk")
  local st = w.eng:status()
  eq(#st.recipes, 1, "status lists one") eq(st.recipes[1].name, "Boards", "by its new name")
  eq(st.turtle.state, "ready", "turtle ready")
  -- Editing the steps cancels the run; the stats stay.
  w.eng:order(rec.id, 1000)
  ticks(w, 2)
  check(summary(w, rec.id).state == "running", "running")
  local copy = textutils.unserialise(textutils.serialise(rec))
  copy.steps[1].grid[2] = copy.steps[1].grid[1]
  w.eng:update(rec.id, copy)
  eq(summary(w, rec.id).state, "idle", "run cancelled")
  check(summary(w, rec.id).made > 0, "what was made counts")
end)

test("folders: recipes are filed from their settings, empty folders survive a reload, removing one keeps the recipes", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 100 } })
  local a = w.eng:add({ name = "Planks", steps = { PLANKS() } })
  local b = w.eng:add({ name = "Boards", steps = { PLANKS() }, folder = "Wood" })
  eq(w.eng:addFolder("Tools"), "Tools", "folder made")
  local ok, err = pcall(w.eng.addFolder, w.eng, "tools")
  check(not ok and err:find("already"), "a folder twice (any case) is refused", tostring(err))
  ok, err = pcall(w.eng.addFolder, w.eng, "  ")
  check(not ok and err:find("name"), "a blank name is refused", tostring(err))
  w.eng:set(a.id, { folder = "wood" })
  eq(a.folder, "Wood", "filed under the spelling in use")
  eq(summary(w, a.id).folder, "Wood", "the summary says so")
  local Folders = require("lib.folders")
  local view = Folders.view(w.eng.folders, w.eng:status().recipes)
  eq(#view.folders, 2, "two folders")
  eq(view.folders[1].name, "Tools", "the declared one first")
  eq(view.folders[2].count, 2, "Wood holds both")
  eq(#view.items, 0, "nothing at the top level")
  eq(#Folders.view(w.eng.folders, w.eng:status().recipes, "Wood").items, 2, "both inside Wood")
  reboot(w)
  eq(#w.eng.folders, 1, "Tools survived the reload")
  eq(w.eng:get(a.id).folder, "Wood", "so did the filing")
  w.eng:set(a.id, { folder = "" })
  eq(w.eng:get(a.id).folder, nil, "blank clears it")
  eq(w.eng:removeFolder("Wood"), 1, "removing a folder moves its recipes out")
  eq(w.eng:get(b.id).folder, nil, "to the top level")
  eq(#w.eng.recipes, 2, "and keeps them")
end)

test("keep: makes planks until the vault holds the count, rests, and goes again when some are taken", function()
  local w = world({ stock = { ["minecraft:oak_log"] = 100 } })
  local rec = w.eng:add({ name = "Planks", steps = { PLANKS() }, mode = "keep", keepCount = 16 })
  check(until_(w, function() return w.vault.count("minecraft:oak_planks") >= 16 end, 40), "topped up")
  eq(w.vault.count("minecraft:oak_planks"), 16, "exactly 16 planks (4 crafts)")
  ticks(w, 3)
  check(summary(w, rec.id).text:find("keeping 16: 16 stored", 1, true), "says what it keeps", summary(w, rec.id).text)
  eq(summary(w, rec.id).state, "idle", "and rests")
  ticks(w, 5)
  eq(w.vault.count("minecraft:oak_planks"), 16, "makes nothing while there are enough")
  w.vault.sim.stock["minecraft:oak_planks"] = 6
  check(until_(w, function() return w.vault.count("minecraft:oak_planks") >= 16 end, 40), "goes again once some are taken")
  eq(w.vault.count("minecraft:oak_planks"), 18, "10 lacking means 3 crafts of 4")
  w.eng:set(rec.id, { keepCount = 30 })
  check(until_(w, function() return w.vault.count("minecraft:oak_planks") >= 30 end, 40), "a higher count is topped up to")
  w.eng:set(rec.id, { mode = "off" })
  w.vault.sim.stock["minecraft:oak_planks"] = 0
  ticks(w, 5)
  eq(w.vault.count("minecraft:oak_planks"), 0, "off means off")
end)

print(string.format("%d passed, %d failed", passed, failures))
if failures > 0 then error("tests failed", 0) end
