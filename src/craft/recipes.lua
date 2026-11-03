-- craft.recipes: what a recipe is, how one is read off a chest, and how an
-- order is turned into work (the crafter service's model, no I/O but the
-- recipe file).
--
-- A recipe is a list of steps, run in order; each step is a craft or a
-- smelt. Items between steps go through the vault: a step takes its
-- ingredients out of storage and its results go back in, so the next step
-- finds them there. A recipe looks like this:
--
--   { id = "r1", name = "Pickaxe", mode = "off",       -- off, always, rate
--     count = 1,                                       -- "Run" = this many runs
--     rateCount = 64, rateSeconds = 600,               -- for mode "rate"
--     steps = {
--       { kind = "craft", grid = { [1] = { key, name, displayName, slot } ... [9] },
--         result = { key, name, displayName, count, maxCount } },  -- nil until learned
--       { kind = "smelt", input = { key, name, displayName, slot }, result = ... },
--     } }
--
-- grid holds the 3x3 crafting grid, cell 1 top left, 9 bottom right, one
-- item per cell per craft, as in a crafting table. A step's result is what
-- one craft (or one smelted item) gives; it comes from the chest when the
-- recipe is laid out with the result in it, and is learned by doing one
-- craft otherwise.

local util = require("lib.util")

local R = {}

-- Where the grid sits in the recipe chest: the top left 3x3 of a 27-slot
-- chest, with the result in the top right corner (slot 9). A 9-slot
-- inventory (a dropper) is the grid itself.
R.CELL_SLOTS = { 1, 2, 3, 10, 11, 12, 19, 20, 21 }
R.RESULT_SLOT = 9
-- The same cells in a turtle's 4x4 inventory (turtle.craft uses the top
-- left 3x3).
R.TURTLE_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
R.OUTPUT_SLOT = 16 -- where the turtle puts what it crafted
R.FREE_SLOTS = 7 -- turtle slots outside the grid, for results
R.MODES = { "off", "always", "rate" }

function R.turtleSlot(cell) return R.TURTLE_SLOTS[cell] end

-- The chest slots that hold the grid cells, and the result slot, for an
-- inventory of `size` slots.
function R.cellSlots(size)
  size = tonumber(size) or 27
  if size >= 27 then return R.CELL_SLOTS, R.RESULT_SLOT end
  local cells = {}
  for i = 1, math.min(9, size) do cells[i] = i end
  return cells, nil
end

-- Reads a step off an inventory listing (the `inventory` op's result:
-- { size, items = { { slot, key, name, nbt, count } } }). details(key)
-- gives { displayName, maxCount }. kind: "craft" or "smelt". Returns the
-- step, or nil and why.
function R.scan(inv, details, kind)
  kind = kind == "smelt" and "smelt" or "craft"
  local bySlot = {}
  for _, it in ipairs(inv.items or {}) do bySlot[it.slot] = it end
  local cells, resultSlot = R.cellSlots(inv.size)
  local function entry(it)
    local d = details(it.key) or {}
    return { key = it.key, name = it.name, displayName = d.displayName or util.titleCase(it.name), slot = it.slot }
  end
  local step = { kind = kind }
  local n = 0
  if kind == "craft" then
    step.grid = {}
    for cell, slot in ipairs(cells) do
      local it = bySlot[slot]
      if it then
        step.grid[cell] = entry(it)
        n = n + 1
      end
    end
    if n == 0 then return nil, "nothing in the 3x3 (top left of the chest)" end
  else
    for _, slot in ipairs(cells) do
      local it = bySlot[slot]
      if it then
        if step.input and step.input.key ~= it.key then return nil, "a smelt step takes one kind of item; the grid holds several" end
        step.input = step.input or entry(it)
        n = n + 1
      end
    end
    if not step.input then return nil, "put the item to smelt in the 3x3 (top left of the chest)" end
  end
  local res = resultSlot and bySlot[resultSlot]
  if res then
    local d = details(res.key) or {}
    step.result = { key = res.key, name = res.name, displayName = d.displayName or util.titleCase(res.name), count = res.count, maxCount = d.maxCount or 64 }
  end
  return step
end

-- The distinct ingredients of a step: { { key, name, displayName, cells } }.
function R.ingredients(step)
  local out, byKey = {}, {}
  if step.kind == "smelt" then
    if step.input then out[1] = { key = step.input.key, name = step.input.name, displayName = step.input.displayName, cells = 1 } end
    return out
  end
  for cell = 1, 9 do
    local it = step.grid and step.grid[cell]
    if it then
      local e = byKey[it.key]
      if not e then
        e = { key = it.key, name = it.name, displayName = it.displayName, cells = 0 }
        byKey[it.key] = e
        out[#out + 1] = e
      end
      e.cells = e.cells + 1
    end
  end
  return out
end

-- A step in a few words: "Craft 1 Oak Log -> 4 Oak Planks".
function R.describe(step)
  local parts = {}
  for _, ing in ipairs(R.ingredients(step)) do parts[#parts + 1] = ing.cells .. " " .. ing.displayName end
  local s = (step.kind == "smelt" and "Smelt " or "Craft ") .. table.concat(parts, " + ")
  if step.result then
    s = s .. " -> " .. step.result.count .. " " .. step.result.displayName
  else
    s = s .. " -> ? (not learned yet)"
  end
  return s
end

-- Which step has no result yet, or nil.
function R.unlearned(recipe)
  for i, step in ipairs(recipe.steps or {}) do
    if not step.result then return i end
  end
  return nil
end

function R.lastResult(recipe)
  local last = recipe.steps and recipe.steps[#recipe.steps]
  return last and last.result or nil
end

-- How many crafts of a step one turtle round can do: every ingredient
-- cell gets one stack at most, and the results must fit the turtle's free
-- slots. details(key) -> { maxCount }.
function R.maxBatch(step, details)
  if step.kind ~= "craft" then return math.huge end
  local n = 64
  for _, ing in ipairs(R.ingredients(step)) do
    local d = details(ing.key)
    n = math.min(n, (d and d.maxCount) or 64)
  end
  if step.result then
    n = math.min(n, math.max(1, math.floor(R.FREE_SLOTS * (step.result.maxCount or 64) / math.max(1, step.result.count))))
  end
  return math.max(1, n)
end

-- Turns an order for `want` items of the recipe's final result into the
-- number of operations each step must do, last step first: a step only
-- makes what later steps need and the vault doesn't already hold; the
-- final step makes everything that was ordered. stock(key) -> how many
-- the vault holds. Returns { ops = { [i] = n }, need = { key = n },
-- produced = { key = n } } or nil and why.
function R.plan(recipe, want, stock)
  local steps = recipe.steps or {}
  if #steps == 0 then return nil, "the recipe has no steps" end
  local i = R.unlearned(recipe)
  if i then return nil, "step " .. i .. " has no result yet" end
  local ops, need, produced = {}, {}, {}
  for k = #steps, 1, -1 do
    local step = steps[k]
    local r = step.result
    local units
    if k == #steps then
      units = want
    else
      units = math.max(0, (need[r.key] or 0) - (stock(r.key) or 0))
    end
    local n = math.ceil(units / math.max(1, r.count))
    ops[k] = n
    produced[r.key] = (produced[r.key] or 0) + n * r.count
    for _, ing in ipairs(R.ingredients(step)) do
      need[ing.key] = (need[ing.key] or 0) + n * ing.cells
    end
  end
  return { ops = ops, need = need, produced = produced }
end

-- What the vault must supply for a plan: need minus what the steps make.
function R.external(plan)
  local out = {}
  for key, n in pairs(plan.need) do
    local short = n - (plan.produced[key] or 0)
    if short > 0 then out[key] = short end
  end
  return out
end

-- The recipe file ------------------------------------------------------

function R.path(root) return fs.combine(root, "data/crafter/recipes") end

function R.load(root)
  local t = util.readTable(R.path(root))
  local list = t and t.recipes or {}
  for i, rec in ipairs(list) do
    rec.id = rec.id or ("r" .. i)
    rec.name = rec.name or rec.id
    rec.steps = rec.steps or {}
    rec.mode = rec.mode or "off"
    rec.count = tonumber(rec.count) or 1
  end
  return list
end

function R.save(root, list)
  return util.writeTable(R.path(root), { recipes = list })
end

function R.newId(list)
  local n = 0
  for _, rec in ipairs(list or {}) do
    local k = tonumber(tostring(rec.id):match("^r(%d+)$"))
    if k and k > n then n = k end
  end
  return "r" .. (n + 1)
end

-- A recipe by id, or by name (exact, then case-insensitive). Returns the
-- recipe and its position.
function R.find(list, which)
  if which == nil then return nil end
  which = tostring(which)
  for i, rec in ipairs(list) do
    if rec.id == which or rec.name == which then return rec, i end
  end
  for i, rec in ipairs(list) do
    if tostring(rec.name):lower() == which:lower() then return rec, i end
  end
  return nil
end

function R.validMode(mode)
  for _, m in ipairs(R.MODES) do
    if m == mode then return true end
  end
  return false
end

return R
