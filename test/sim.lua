-- test/sim.lua: lib.index against simulated inventories (run with
-- node test/run.cjs). The simulation copies CC:Tweaked's inventory
-- behaviour: pushItems without a target slot fills slots in order, stack
-- sizes come from the item, and the result is the number actually moved.

local MAX = { ["minecraft:ender_pearl"] = 16, ["minecraft:diamond_pickaxe"] = 1 }
local GROUPS = {
  ["minecraft:cobblestone"] = { { id = "minecraft:building_blocks", displayName = "Building Blocks" } },
  ["minecraft:dirt"] = { { id = "minecraft:natural_blocks", displayName = "Natural Blocks" } },
  ["minecraft:iron_ingot"] = { { id = "minecraft:ingredients", displayName = "Ingredients" } },
  ["minecraft:redstone"] = { { id = "minecraft:redstone_blocks", displayName = "Redstone Blocks" }, { id = "minecraft:ingredients", displayName = "Ingredients" } },
  ["minecraft:wheat_seeds"] = { { id = "minecraft:natural_blocks", displayName = "Natural Blocks" } },
}
local TAGS = {
  ["minecraft:ender_pearl"] = { ["c:ender_pearls"] = true },
  ["minecraft:wheat_seeds"] = { ["c:seeds"] = true, ["c:seeds/wheat"] = true },
  ["create:iron_sheet"] = { ["c:plates"] = true, ["c:plates/iron"] = true },
}
local invs = {}
local calls = 0
local epoch = 0 -- a clock that moves one second per call, so "recent" orders are exact

local function maxOf(name) return MAX[name] or 64 end

local function newInv(name, size)
  invs[name] = { size = size, slots = {} }
end

local function put(inv, slot, name, count, nbt)
  invs[inv].slots[slot] = { name = name, count = count, nbt = nbt }
end

peripheral = {}
function peripheral.call(name, method, ...)
  local inv = invs[name]
  if not inv then error("No peripheral named " .. tostring(name)) end
  calls = calls + 1
  if method == "size" then
    return inv.size
  elseif method == "list" then
    local out = {}
    for s, it in pairs(inv.slots) do out[s] = { name = it.name, count = it.count, nbt = it.nbt } end
    return out
  elseif method == "getItemDetail" then
    local it = inv.slots[(...)]
    if not it then return nil end
    return { name = it.name, count = it.count, nbt = it.nbt, displayName = "D:" .. it.name, maxCount = maxOf(it.name), itemGroups = GROUPS[it.name], tags = TAGS[it.name] }
  elseif method == "pushItems" then
    local to, fromSlot, limit, toSlot = ...
    local dst = invs[to]
    if not dst then error("Target '" .. tostring(to) .. "' does not exist") end
    local src = inv.slots[fromSlot]
    if not src then return 0 end
    local n = math.min(src.count, limit or src.count)
    local function insert(slot, cnt)
      if slot > dst.size then return 0 end
      local d = dst.slots[slot]
      if d then
        if d.name ~= src.name or d.nbt ~= src.nbt then return 0 end
        local m = math.min(maxOf(src.name) - d.count, cnt)
        if m <= 0 then return 0 end
        d.count = d.count + m
        return m
      end
      local m = math.min(maxOf(src.name), cnt)
      dst.slots[slot] = { name = src.name, count = m, nbt = src.nbt }
      return m
    end
    local moved = 0
    if toSlot then
      moved = insert(toSlot, n)
    else
      for s = 1, dst.size do
        if n - moved <= 0 then break end
        moved = moved + insert(s, n - moved)
      end
    end
    src.count = src.count - moved
    if src.count <= 0 then inv.slots[fromSlot] = nil end
    return moved
  end
  error("unknown method " .. tostring(method))
end

parallel = { waitForAll = function(...) for _, f in ipairs({ ... }) do f() end end }
os.epoch = function()
  epoch = epoch + 1000
  return epoch
end
os.clock = os.clock or function() return 0 end
sleep = function() end

local util = require("lib.util")
local Index = require("lib.index")
local category = require("lib.category")

local failures, passed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
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

-- The index must describe the simulated inventories exactly.
local function consistent(index)
  local items, used = {}, 0
  for name, inv in pairs(index.invs) do
    local sim = invs[name]
    eq(inv.size, sim.size, name .. " size")
    for s = 1, sim.size do
      local a, b = inv.slots[s], sim.slots[s]
      if (a and not b) or (b and not a) then error(name .. " slot " .. s .. ": index " .. tostring(a and a.key) .. " vs real " .. tostring(b and b.name), 2) end
      if a then
        eq(a.key, util.keyOf(b.name, b.nbt), name .. " slot " .. s .. " key")
        eq(a.count, b.count, name .. " slot " .. s .. " count")
        items[a.key] = (items[a.key] or 0) + b.count
        used = used + 1
      end
    end
  end
  for key, n in pairs(items) do eq(index.items[key] and index.items[key].count, n, key .. " total") end
  for key, it in pairs(index.items) do eq(it.count, items[key] or 0, key .. " indexed total") end
  eq(index.totals.used, used, "used slots")
  local total = 0
  for _, n in pairs(items) do total = total + n end
  eq(index.totals.items, total, "total items")
end

local function fresh()
  invs = {}
  newInv("vault_a", 10)
  newInv("vault_b", 20)
  newInv("chest", 9)
  newInv("out", 9)
  local changes = {}
  local index = Index.new({ storage = { "vault_a", "vault_b" }, onChange = function(c) changes[#changes + 1] = c end })
  return index, changes
end

test("scan", function()
  local index = fresh()
  put("vault_a", 1, "minecraft:cobblestone", 64)
  put("vault_a", 3, "minecraft:cobblestone", 10)
  put("vault_b", 5, "minecraft:ender_pearl", 7)
  index:scanAll()
  consistent(index)
  eq(index:count("minecraft:cobblestone"), 74, "cobble")
  eq(index.totals.slots, 30, "slots")
  eq(index:detail("minecraft:ender_pearl").maxCount, 16, "pearl max from details")
  eq(index:detail("minecraft:ender_pearl").displayName, "D:minecraft:ender_pearl", "display name")
end)

test("deposit stacks onto partials first, then empty slots", function()
  local index, changes = fresh()
  put("vault_a", 3, "minecraft:cobblestone", 10)
  put("vault_b", 1, "minecraft:cobblestone", 60)
  index:scanAll()
  put("chest", 1, "minecraft:cobblestone", 64)
  put("chest", 2, "minecraft:cobblestone", 30)
  put("chest", 4, "minecraft:ender_pearl", 16)
  local moved, byKey, msg = index:deposit("chest")
  eq(moved, 110, "moved")
  eq(byKey["minecraft:cobblestone"], 94, "cobble moved")
  eq(byKey["minecraft:ender_pearl"], 16, "pearls moved")
  eq(msg, nil, "message")
  consistent(index)
  -- the 60 stack (fullest) is topped up first, then the 10 stack, then a new slot
  eq(invs.vault_b.slots[1].count, 64, "fullest partial filled")
  eq(invs.vault_a.slots[3].count, 64, "other partial filled")
  eq(index:count("minecraft:cobblestone"), 164, "total cobble")
  eq(next(invs.chest.slots), nil, "chest emptied")
  eq(#changes > 0, true, "change reported")
end)

test("withdraw takes smallest stacks first and never more than stored", function()
  local index = fresh()
  put("vault_a", 1, "minecraft:cobblestone", 64)
  put("vault_a", 2, "minecraft:cobblestone", 5)
  put("vault_b", 2, "minecraft:cobblestone", 20)
  index:scanAll()
  local moved = index:withdraw("minecraft:cobblestone", 22, "out")
  eq(moved, 22, "moved")
  consistent(index)
  eq(invs.vault_a.slots[2], nil, "5-stack used up")
  eq(invs.vault_b.slots[2].count, 3, "20-stack reduced")
  eq(invs.vault_a.slots[1].count, 64, "full stack untouched")
  moved = index:withdraw("minecraft:cobblestone", 1000, "out")
  eq(moved, 67, "clamped to what is stored")
  eq(index:count("minecraft:cobblestone"), 0, "nothing left")
  consistent(index)
  local m2, why, code = index:withdraw("minecraft:cobblestone", 1, "out")
  eq(m2, 0, "empty")
  eq(code, "refused", "refused")
end)

test("withdraw into a slot and a full target", function()
  local index = fresh()
  put("vault_a", 1, "minecraft:cobblestone", 64)
  put("vault_a", 2, "minecraft:cobblestone", 64)
  index:scanAll()
  eq(index:withdraw("minecraft:cobblestone", 10, "out", 5), 10, "to slot 5")
  eq(invs.out.slots[5].count, 10, "landed in slot 5")
  for s = 1, 9 do put("out", s, "minecraft:ender_pearl", 16) end
  local moved, why = index:withdraw("minecraft:cobblestone", 10, "out")
  eq(moved, 0, "nothing fits")
  eq(why ~= nil, true, "explains")
  consistent(index)
end)

test("storage full leaves items behind and says so", function()
  local index = fresh()
  for s = 1, 10 do put("vault_a", s, "minecraft:dirt", 64) end
  for s = 1, 19 do put("vault_b", s, "minecraft:dirt", 64) end
  index:scanAll()
  put("chest", 1, "minecraft:cobblestone", 64)
  put("chest", 2, "minecraft:cobblestone", 64)
  local moved, byKey, msg = index:deposit("chest")
  eq(moved, 64, "one stack fits")
  eq(msg ~= nil and msg:find("full") ~= nil, true, "message mentions full")
  consistent(index)
  eq(invs.chest.slots[2].count, 64, "second stack left behind")
end)

test("compact merges partial stacks", function()
  local index = fresh()
  put("vault_a", 1, "minecraft:cobblestone", 30)
  put("vault_a", 4, "minecraft:cobblestone", 30)
  put("vault_b", 2, "minecraft:cobblestone", 10)
  put("vault_b", 3, "minecraft:ender_pearl", 8)
  put("vault_b", 9, "minecraft:ender_pearl", 8)
  put("vault_b", 10, "minecraft:diamond_pickaxe", 1)
  put("vault_b", 11, "minecraft:diamond_pickaxe", 1)
  index:scanAll()
  local moves = index:compact()
  eq(moves >= 2, true, "made moves")
  consistent(index)
  local stacks = index:info("minecraft:cobblestone").stacks
  eq(stacks, 2, "cobble in 2 stacks")
  eq(index:info("minecraft:ender_pearl").stacks, 1, "pearls in 1 stack")
  eq(index:info("minecraft:diamond_pickaxe").stacks, 2, "unstackables untouched")
  eq(index:compact(), 0, "nothing more to do")
end)

test("drift is repaired: items taken behind the service's back", function()
  local index = fresh()
  put("vault_a", 1, "minecraft:cobblestone", 64)
  put("vault_a", 2, "minecraft:cobblestone", 40)
  index:scanAll()
  invs.vault_a.slots[2].count = 5 -- a player took 35
  put("vault_a", 7, "minecraft:iron_ingot", 3) -- and dropped something in
  local moved = index:withdraw("minecraft:cobblestone", 40, "out")
  eq(moved, 40, "still got 40 (5 + 35 from the full stack)")
  consistent(index)
  eq(index:count("minecraft:iron_ingot"), 3, "found the new item during the repair")
end)

test("drift is repaired on deposit: a stack filled behind the service's back", function()
  local index = fresh()
  put("vault_a", 1, "minecraft:cobblestone", 10)
  index:scanAll()
  invs.vault_a.slots[1].count = 64 -- a hopper filled it up
  put("chest", 1, "minecraft:cobblestone", 64)
  local moved, byKey, msg = index:deposit("chest")
  eq(moved, 64, "everything stored after the repair")
  eq(msg, nil, "no complaint")
  consistent(index)
  eq(index:count("minecraft:cobblestone"), 128, "128 stored")
  eq(next(invs.chest.slots), nil, "chest emptied")
end)

test("nbt variants are separate kinds, names resolve carefully", function()
  local index = fresh()
  put("vault_a", 1, "minecraft:diamond_pickaxe", 1, "aaaa")
  put("vault_a", 2, "minecraft:diamond_pickaxe", 1, "bbbb")
  put("vault_a", 3, "minecraft:cobblestone", 9)
  index:scanAll()
  eq(index:count("minecraft:diamond_pickaxe"), 2, "name counts both")
  local key, err = index:resolve("minecraft:diamond_pickaxe")
  eq(key, nil, "ambiguous name refused")
  eq(err:find("ambiguous") ~= nil, true, "says ambiguous")
  eq(index:resolve("minecraft:diamond_pickaxe@aaaa"), "minecraft:diamond_pickaxe@aaaa", "exact key")
  eq(index:resolve("cobble"), "minecraft:cobblestone", "partial display name")
  eq(select(2, index:resolve("minecraft:gold_ingot")), "not in storage: minecraft:gold_ingot", "missing")
  local list, total = index:list({ sort = "name" })
  eq(total, 3, "three kinds")
  eq(list[1].key, "minecraft:cobblestone", "sorted by display name")
end)

test("deposit filters: slot, item, count", function()
  local index = fresh()
  index:scanAll()
  put("chest", 1, "minecraft:cobblestone", 64)
  put("chest", 2, "minecraft:dirt", 64)
  put("chest", 3, "minecraft:cobblestone", 64)
  eq((index:deposit("chest", { slot = 2 })), 64, "one slot")
  eq(invs.chest.slots[2], nil, "slot 2 gone")
  eq((index:deposit("chest", { item = "minecraft:cobblestone", count = 70 })), 70, "limited count")
  consistent(index)
  eq(index:count("minecraft:cobblestone"), 70, "70 stored")
  local left = 0
  for _, s in ipairs({ 1, 3 }) do
    if invs.chest.slots[s] then left = left + invs.chest.slots[s].count end
  end
  eq(left, 58, "58 left")
  local m, _, msg, code = index:deposit("vault_a")
  eq(code, "refused", "storage as source refused")
end)

test("inventories can come and go", function()
  local index = fresh()
  put("vault_a", 1, "minecraft:cobblestone", 64)
  index:scanAll()
  newInv("vault_c", 5)
  put("vault_c", 1, "minecraft:cobblestone", 1)
  eq(index:addInventory("vault_c"), true, "added")
  index:scan("vault_c")
  eq(index:count("minecraft:cobblestone"), 65, "counts the new one")
  eq(index.totals.slots, 35, "slots grew")
  index:removeInventory("vault_a")
  eq(index:count("minecraft:cobblestone"), 1, "removed one's items gone")
  eq(index.totals.slots, 25, "slots shrank")
  consistent(index)
end)

test("categories come from creative tabs, tags, stack size and names", function()
  local function cat(detail, overrides) return category.classify(detail, overrides) end
  eq(cat({ name = "minecraft:torch", maxCount = 64, itemGroups = { "minecraft:functional_blocks" } }), "block", "torch")
  eq(cat({ name = "minecraft:redstone", maxCount = 64, itemGroups = { "minecraft:redstone_blocks", "minecraft:ingredients" } }), "resource", "redstone: ingredients wins")
  eq(cat({ name = "minecraft:wheat_seeds", maxCount = 64, itemGroups = { "minecraft:natural_blocks" }, tags = { ["c:seeds"] = true } }), "item", "seeds are items")
  eq(cat({ name = "create:raw_zinc", maxCount = 64, itemGroups = { "create:base" }, tags = { ["c:raw_materials/zinc"] = true } }), "resource", "raw zinc by tag")
  eq(cat({ name = "minecraft:diamond_shovel", maxCount = 1, tags = { ["c:tools"] = true } }), "unstackable", "stack size 1")
  eq(cat({ name = "create:andesite_casing", maxCount = 64, itemGroups = { "create:base" } }), "block", "casing by name")
  eq(cat({ name = "create:brass_ingot", maxCount = 64, itemGroups = { "create:base" } }), "resource", "ingot by name")
  eq(cat({ name = "somemod:weird_thing", maxCount = 64 }), "item", "unknown things are items")
  eq(cat({ name = "create:iron_sheet", maxCount = 64 }, { ["create:iron_sheet"] = "block" }), "block", "config override")
  local index = fresh()
  put("vault_a", 1, "minecraft:cobblestone", 64)
  put("vault_a", 2, "minecraft:iron_ingot", 3)
  put("vault_a", 3, "minecraft:diamond_pickaxe", 1)
  put("vault_a", 4, "minecraft:wheat_seeds", 5)
  put("vault_b", 1, "create:iron_sheet", 7)
  index:scanAll()
  eq(index:detail("minecraft:cobblestone").category, "block", "cobble")
  eq(index:detail("minecraft:iron_ingot").category, "resource", "ingot")
  eq(index:detail("minecraft:diamond_pickaxe").category, "unstackable", "pickaxe")
  eq(index:detail("minecraft:wheat_seeds").category, "item", "seeds")
  eq(index:detail("create:iron_sheet").category, "resource", "sheet by tag")
  local blocks = index:list({ category = "block" })
  eq(#blocks, 1, "one block")
  eq(blocks[1].category, "block", "entry carries its category")
  local _, total = index:list({ category = "resource" })
  eq(total, 2, "two resources")
  eq(select(2, index:list({ category = "all" })), 5, "all")
end)

test("recent lists the items moved last, newest first", function()
  local index = fresh()
  put("vault_a", 1, "minecraft:cobblestone", 64)
  put("vault_a", 2, "minecraft:iron_ingot", 30)
  index:scanAll()
  eq(select(2, index:list({ category = "recent" })), 0, "nothing moved yet")
  index:withdraw("minecraft:cobblestone", 5, "out")
  put("chest", 1, "minecraft:iron_ingot", 4)
  index:deposit("chest")
  local recent = index:list({ category = "recent" })
  eq(#recent, 2, "two recent kinds")
  eq(recent[1].key, "minecraft:iron_ingot", "newest first")
  eq(recent[2].key, "minecraft:cobblestone", "then the older one")
  eq(recent[1].recent > recent[2].recent, true, "carries the times")
  index:withdraw("minecraft:cobblestone", 1, "out")
  eq(index:list({ category = "recent" })[1].key, "minecraft:cobblestone", "moving again puts it first")
end)

print(string.format("%d passed, %d failed (%d simulated peripheral calls)", passed, failures, calls))
if failures > 0 then error("tests failed", 0) end
