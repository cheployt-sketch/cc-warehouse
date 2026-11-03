-- craft.engine: the crafter service's scheduler. It turns orders into
-- work, one small unit at a time, taking turns between recipes:
--
--   - A craft unit is one turtle round: the ingredients for up to a stack
--     of crafts go from the vault into the turtle's input chest, in grid
--     order; the turtle takes them, crafts, and drops everything into its
--     output chest; the vault stores that. The step's result lands in the
--     vault, where the next step takes it from.
--   - A smelt unit feeds the smelter's input chest from the vault and
--     notes what came out of its finish chest, which the engine empties
--     into the vault every few seconds whether a smelt is running or not.
--   - A learn unit crafts (or smelts) once to find out what a step makes,
--     for steps laid out without their result.
--
-- Each recipe runs on its own terms: mode "always" keeps making one round
-- after another, "rate" orders rateCount items every rateSeconds, and an
-- order or a "run N times" from the UI, the panel or the command line
-- queues work in any mode. Orders are planned backwards from the final
-- item (craft.recipes): intermediate steps make only what the vault lacks.
--
-- Files: /warehouse/data/crafter/config (the setup), recipes (the
-- recipes), state (orders in progress and stats). A reboot picks up where
-- it was: an unfinished turtle round is done again, and whatever the
-- turtle or its chests still hold is stored when it is reached again.

local util = require("lib.util")
local Recipes = require("craft.recipes")

local E = {}
E.__index = E

E.TICK = 1 -- seconds between passes when nothing is going on
E.BUSY = 0.25 -- seconds between passes while work is being done
E.RETRY = 10 -- seconds before a turtle that did not answer is asked again
E.COLLECT = 3 -- seconds between looks at the smelter's finish chest
E.SAVE_EVERY = 10 -- seconds between saves of stats that only ticked

E.defaults = {
  turtle = nil, -- the crafty turtle: its name on the network, or its ID
  input = nil, -- the chest the turtle takes ingredients from
  output = nil, -- the chest the turtle drops results into (default: input)
  recipeChest = nil, -- where recipes are laid out
  smeltIn = nil, -- the smelter's input chest (hoppers take from it)
  smeltOut = nil, -- the smelter's finish chest (hoppers fill it)
  monitor = nil, -- the dashboard monitor (never an access point's)
  scale = nil, -- its text scale (blank: automatic)
  smeltStall = 300, -- seconds without anything out of the smelter before a smelt counts as stalled
}

E.KEYS = { "turtle", "input", "output", "recipeChest", "smeltIn", "smeltOut", "monitor", "scale", "smeltStall" }

function E.configPath(root) return fs.combine(root, "data/crafter/config") end
function E.statePath(root) return fs.combine(root, "data/crafter/state") end

function E.loadConfig(root)
  local cfg = {}
  for k, v in pairs(E.defaults) do cfg[k] = v end
  for k, v in pairs(util.readTable(E.configPath(root)) or {}) do cfg[k] = v end
  cfg.smeltStall = tonumber(cfg.smeltStall) or 300
  return cfg
end

function E.saveConfig(root, cfg)
  local out = {}
  for _, k in ipairs(E.KEYS) do out[k] = cfg[k] end
  return util.writeTable(E.configPath(root), out)
end

-- opts: vault (the client library), root, log(msg), link (craft.link),
-- cfg, onChange() (called when something visible changed), clock(),
-- epoch() (for tests).
function E.new(opts)
  local self = setmetatable({}, E)
  self.vault = opts.vault
  self.root = opts.root
  self.log = opts.log or function() end
  self.link = opts.link
  self.cfg = opts.cfg or E.loadConfig(opts.root)
  self.onChange = opts.onChange
  self.clock = opts.clock or os.clock
  self.epoch = opts.epoch or function() return os.epoch("utc") end
  self.recipes = Recipes.load(self.root)
  self.state = util.readTable(E.statePath(self.root)) or {}
  self.state.recipes = self.state.recipes or {}
  self.turtle = { state = "unknown", at = -1000 }
  self.smelter = { items = 0 }
  self.rr = 0
  self.detailsCache = {}
  self.collectedAt = -1000
  self.savedAt = 0
  self.dirty = false
  return self
end

function E:changed()
  self.dirty = true
  if self.onChange then self.onChange() end
end

-- The run state and stats of a recipe (kept across reboots).
function E:stateOf(id)
  local st = self.state.recipes[id]
  if not st then
    st = { pending = { items = 0, runs = 0 }, stats = { runs = 0, made = 0, crafts = 0, smelted = 0, errors = 0, behind = 0 } }
    self.state.recipes[id] = st
  end
  st.pending = st.pending or { items = 0, runs = 0 }
  st.stats = st.stats or { runs = 0, made = 0, crafts = 0, smelted = 0, errors = 0, behind = 0 }
  return st
end

function E:saveState(force)
  if not self.dirty and not force then return end
  local now = self.clock()
  if not force and now - self.savedAt < E.SAVE_EVERY and not self.urgent then return end
  self.dirty, self.urgent = false, false
  self.savedAt = now
  -- Only recipes that still exist.
  local keep = {}
  for _, rec in ipairs(self.recipes) do keep[rec.id] = self.state.recipes[rec.id] end
  self.state.recipes = keep
  util.writeTable(E.statePath(self.root), self.state)
end

function E:saveRecipes()
  Recipes.save(self.root, self.recipes)
  self:changed()
end

-- Item details, asked for once per kind.
function E:details(key)
  local d = self.detailsCache[key]
  if d then return d end
  local ok, res = pcall(self.vault.details, key)
  d = ok and type(res) == "table" and res or { displayName = util.titleCase((util.splitKey(key))), maxCount = 64, guessed = true }
  if not d.guessed then self.detailsCache[key] = d end
  return d
end

function E:count(key)
  local ok, n = pcall(self.vault.count, key)
  if ok and type(n) == "number" then return n end
  return 0
end

-- Empties an inventory into the vault. Returns moved, items, message.
function E:deposit(name)
  local ok, moved, items, msg = pcall(self.vault.deposit, name)
  if not ok then return 0, {}, tostring(moved) end
  if msg == "nothing to store" then msg = nil end
  return moved, items or {}, msg
end

-- Empties a chest into the vault and says whether it is empty now.
function E:clearChest(name)
  local _, _, msg = self:deposit(name)
  local ok, inv = pcall(self.vault.inventory, name)
  if not ok then return false, "cannot read " .. name end
  if (inv.total or 0) > 0 then return false, msg or (name .. " cannot be emptied") end
  return true
end

-- Recipes ----------------------------------------------------------------

function E:find(which)
  return Recipes.find(self.recipes, which)
end

function E:get(which)
  local rec = self:find(which)
  if not rec then error("no recipe called " .. tostring(which), 0) end
  return rec
end

function E:add(rec)
  rec.id = Recipes.newId(self.recipes)
  rec.name = rec.name and rec.name ~= "" and rec.name or rec.id
  rec.mode = Recipes.validMode(rec.mode) and rec.mode or "off"
  rec.steps = rec.steps or {}
  rec.count = tonumber(rec.count) or 1
  self.recipes[#self.recipes + 1] = rec
  self:stateOf(rec.id)
  self:saveRecipes()
  self.log("recipe " .. rec.name .. " added")
  return rec
end

-- Replaces a recipe's definition (from the UI). A changed step list
-- cancels its run; a cleared problem lets it go again.
function E:update(id, rec)
  local old, i = self:find(id)
  if not old then error("no recipe called " .. tostring(id), 0) end
  rec.id = old.id
  rec.mode = Recipes.validMode(rec.mode) and rec.mode or "off"
  rec.count = tonumber(rec.count) or 1
  self.recipes[i] = rec
  local st = self:stateOf(rec.id)
  if textutils.serialise(rec.steps) ~= textutils.serialise(old.steps) then
    if st.run and st.run.made > 0 then st.stats.made = st.stats.made + st.run.made end
    st.run, st.learn = nil, nil
  end
  st.problem = nil
  if rec.mode ~= "rate" then st.rateDue = nil end
  self:saveRecipes()
  self:saveState(true)
  return rec
end

function E:remove(id)
  local rec, i = self:find(id)
  if not rec then error("no recipe called " .. tostring(id), 0) end
  table.remove(self.recipes, i)
  self.state.recipes[rec.id] = nil
  self:saveRecipes()
  self:saveState(true)
  self.log("recipe " .. rec.name .. " removed")
end

-- Orders `items` of the recipe's final result.
function E:order(id, items)
  local rec = self:get(id)
  items = math.floor(tonumber(items) or 0)
  if items < 1 then error("order how many?", 0) end
  local st = self:stateOf(rec.id)
  st.pending.items = st.pending.items + items
  st.problem = nil
  self.log("order: " .. items .. " x " .. rec.name)
  self:wake()
  return st.pending
end

-- Runs the recipe `times` times (its final step that often).
function E:runTimes(id, times)
  local rec = self:get(id)
  times = math.floor(tonumber(times) or rec.count or 1)
  if times < 1 then error("run how many times?", 0) end
  local st = self:stateOf(rec.id)
  st.pending.runs = st.pending.runs + times
  st.problem = nil
  self.log("run " .. times .. " x " .. rec.name)
  self:wake()
  return st.pending
end

-- Stops everything about a recipe: its orders, its run, and its mode.
function E:stop(id)
  local rec = self:get(id)
  local st = self:stateOf(rec.id)
  if st.run and st.run.made > 0 then st.stats.made = st.stats.made + st.run.made end
  st.pending.items, st.pending.runs = 0, 0
  st.run, st.learn, st.waiting = nil, nil, nil
  if rec.mode ~= "off" then
    rec.mode = "off"
    self:saveRecipes()
  end
  self.log("stopped " .. rec.name)
  self:saveState(true)
  self:changed()
end

function E:setMode(id, mode)
  local rec = self:get(id)
  if not Recipes.validMode(mode) then error("mode must be off, always or rate", 0) end
  rec.mode = mode
  local st = self:stateOf(rec.id)
  st.problem = nil
  if mode ~= "rate" then st.rateDue = nil end
  self:saveRecipes()
  self:wake()
  return rec
end

-- Changes settings: mode, count, rateCount, rateSeconds, name.
function E:set(id, fields)
  local rec = self:get(id)
  if fields.mode ~= nil then
    if not Recipes.validMode(fields.mode) then error("mode must be off, always or rate", 0) end
    rec.mode = fields.mode
  end
  if fields.name ~= nil and fields.name ~= "" then
    local other = self:find(fields.name)
    if other and other ~= rec then error("there is already a recipe called " .. fields.name, 0) end
    rec.name = tostring(fields.name)
  end
  for _, k in ipairs({ "count", "rateCount", "rateSeconds" }) do
    if fields[k] ~= nil then
      local n = math.floor(tonumber(fields[k]) or 0)
      if n < 1 then error(k .. " must be a positive number", 0) end
      rec[k] = n
    end
  end
  local st = self:stateOf(rec.id)
  st.problem = nil
  if rec.mode ~= "rate" then st.rateDue = nil end
  self:saveRecipes()
  self:wake()
  return rec
end

function E:wake()
  self:changed()
  os.queueEvent("crafter_wake")
end

-- Reads the recipe chest as a step. kind: "craft" or "smelt".
function E:scan(kind)
  local chest = self.cfg.recipeChest
  if not chest or chest == "" then return nil, "no recipe chest set (Setup)" end
  local ok, inv = pcall(self.vault.inventory, chest)
  if not ok then return nil, "cannot read " .. chest .. ": " .. tostring(inv) end
  local function details(key)
    local d = self:details(key)
    if d.guessed then
      -- Not stored: ask the chest itself (we are on the warehouse computer).
      for _, it in ipairs(inv.items) do
        if it.key == key then
          local ok2, real = pcall(peripheral.call, chest, "getItemDetail", it.slot)
          if ok2 and type(real) == "table" then
            d = { displayName = real.displayName, maxCount = real.maxCount or 64 }
            self.detailsCache[key] = d
          end
          break
        end
      end
    end
    return d
  end
  return Recipes.scan(inv, details, kind)
end

-- The turtle --------------------------------------------------------------

function E:turtleLost(why)
  if self.turtle.state ~= "away" or self.turtle.msg ~= why then
    self.log("turtle: " .. tostring(why))
    self:changed()
  end
  self.turtle.state, self.turtle.msg, self.turtle.at = "away", why, self.clock()
end

-- Is the turtle there and able to craft? Asked again every RETRY seconds
-- while it is not. On first contact it drops whatever it still holds.
function E:turtleReady()
  if self.turtle.state == "ready" then return true end
  if not self.link then
    self.turtle.msg = "no turtle"
    return false
  end
  if self.clock() - self.turtle.at < E.RETRY then return false end
  self.turtle.at = self.clock()
  self.link:setTurtle(self.cfg.turtle)
  local r, err = self.link:ping()
  if not r then
    self:turtleLost(err)
    return false
  end
  self.turtle = { state = "ready", at = self.clock(), id = self.link.id, label = r.label, fuel = r.fuel, input = r.input, output = r.output }
  self.log("turtle #" .. tostring(self.link.id) .. " ready" .. (r.label and (" (" .. r.label .. ")") or ""))
  if (r.free or 16) < 16 then
    self.link:clear()
    if self.cfg.output then self:deposit(self.cfg.output) end
  end
  self:changed()
  return true
end

-- Work -------------------------------------------------------------------

-- Mode "rate": every rateSeconds, an order for rateCount items, unless
-- the recipe is still busy with the last one (then it is counted as
-- behind rather than piled up).
function E:ratePeriod(rec, st)
  if rec.mode ~= "rate" then
    st.rateDue = nil
    return
  end
  local now = self.epoch()
  local every = math.max(1, tonumber(rec.rateSeconds) or 600) * 1000
  if not st.rateDue then st.rateDue = now end
  if now < st.rateDue then return end
  st.rateDue = now + every
  if st.run or st.pending.items + st.pending.runs > 0 then
    st.stats.behind = (st.stats.behind or 0) + 1
  else
    st.pending.items = st.pending.items + math.max(1, tonumber(rec.rateCount) or 1)
  end
  self:changed()
end

-- How many items a recipe should make next, from its orders and mode.
function E:wanted(rec, st)
  local last = Recipes.lastResult(rec)
  if not last then return 0 end
  local w = st.pending.items + st.pending.runs * last.count
  if rec.mode == "always" and w == 0 then
    local step = rec.steps[#rec.steps]
    w = Recipes.maxBatch(step, function(k) return self:details(k) end) * last.count
    if w == math.huge then w = 64 end
  end
  return w
end

function E:fail(rec, st, msg)
  st.problem = msg
  if st.run and st.run.made > 0 then st.stats.made = st.stats.made + st.run.made end
  st.run, st.learn, st.waiting = nil, nil, nil
  st.stats.errors = (st.stats.errors or 0) + 1
  st.stats.lastMessage = msg
  self.log(rec.name .. ": " .. msg)
  self.urgent = true
  self:changed()
end

function E:finishRun(rec, st)
  local run = st.run
  st.stats.runs = st.stats.runs + 1
  st.stats.made = st.stats.made + (run.made or 0)
  st.stats.lastRun = self.epoch()
  st.stats.lastMessage = nil
  st.run = nil
  self.log(rec.name .. ": made " .. tostring(run.made or 0))
  self.urgent = true
  self:changed()
end

-- Moves a run past the steps that are done. Returns true when the run
-- finished.
function E:advance(rec, st)
  local run = st.run
  while run.step <= #rec.steps and run.done[run.step] >= (run.ops[run.step] or 0) do run.step = run.step + 1 end
  if run.step > #rec.steps then
    self:finishRun(rec, st)
    return true
  end
  return false
end

-- One unit of work for a recipe. Returns true when something was done.
function E:unit(rec, st)
  if st.problem then return false end
  if #rec.steps == 0 then return false end
  local li = Recipes.unlearned(rec)
  if li then return self:learn(rec, st, li) end
  st.learn = nil
  self:ratePeriod(rec, st)
  if not st.run then
    local w = self:wanted(rec, st)
    if w <= 0 then
      st.waiting = nil
      return false
    end
    local plan, err = Recipes.plan(rec, w, function(key) return self:count(key) end)
    if not plan then
      self:fail(rec, st, err)
      return true
    end
    st.run = { want = w, ops = plan.ops, done = {}, step = 1, startedAt = self.epoch(), made = 0 }
    for i = 1, #rec.steps do st.run.done[i] = 0 end
    st.pending.items, st.pending.runs = 0, 0
    self.log(rec.name .. ": making " .. w .. " x " .. Recipes.lastResult(rec).displayName)
    self:changed()
  end
  if self:advance(rec, st) then return true end
  local step = rec.steps[st.run.step]
  local did
  if step.kind == "smelt" then did = self:smeltUnit(rec, st, step) else did = self:craftBatch(rec, st, step, false) end
  if st.run and not st.problem then self:advance(rec, st) end
  return did
end

-- Learns what step `i` makes: a craft step by crafting once, a smelt step
-- by smelting one item and watching the finish chest.
function E:learn(rec, st, i)
  local step = rec.steps[i]
  if step.kind == "craft" then
    st.learn = { step = i }
    return self:craftBatch(rec, st, step, true)
  end
  if not self.cfg.smeltIn or not self.cfg.smeltOut then
    st.waiting = "setup: smelter chests not set"
    return false
  end
  for _, other in ipairs(self.recipes) do
    local ost = other ~= rec and self.state.recipes[other.id]
    if ost and ((ost.run and other.steps[ost.run.step] and other.steps[ost.run.step].kind == "smelt") or (ost.learn and other.steps[ost.learn.step] and other.steps[ost.learn.step].kind == "smelt")) then
      st.waiting = "waiting for the smelter (" .. other.name .. " uses it)"
      return false
    end
  end
  if not st.learn or st.learn.step ~= i then st.learn = { step = i, since = self.clock() } end
  local l = st.learn
  if not l.fed then
    local n = self:supply(step.input, 1, self.cfg.smeltIn, nil, true)
    if n < 1 then
      st.waiting = "learn: waiting for " .. step.input.displayName
      return false
    end
    l.fed = true
    l.since = self.clock()
    st.waiting = "learning step " .. i .. ": smelting one " .. step.input.displayName
    self:changed()
    return true
  end
  if self.clock() - l.since > self.cfg.smeltStall then
    self:fail(rec, st, "step " .. i .. ": nothing came out of the smelter in " .. math.floor(self.cfg.smeltStall) .. " s")
    return true
  end
  return false
end

-- Puts `n` of an item into an inventory (slot `slot` or anywhere) from the
-- vault, or, when learning, from the recipe chest where it was laid out.
-- Returns how many got there.
function E:supply(item, n, to, slot, learning)
  local moved = 0
  if self:count(item.key) > 0 then
    local ok, m = pcall(self.vault.withdraw, item.key, n, to, slot)
    if ok and type(m) == "number" then moved = m end
  end
  if moved < n and learning and self.cfg.recipeChest then
    -- The recipe chest: the cell it was scanned from first, then wherever it lies now.
    local chest = self.cfg.recipeChest
    if item.slot then
      local ok, m = pcall(self.vault.move, chest, item.slot, to, slot, n - moved)
      if ok and type(m) == "number" then moved = moved + m end
    end
    if moved < n then
      local ok, inv = pcall(self.vault.inventory, chest)
      for _, it in ipairs(ok and type(inv) == "table" and inv.items or {}) do
        if moved >= n then break end
        if it.key == item.key and it.slot ~= item.slot then
          local ok2, m = pcall(self.vault.move, chest, it.slot, to, slot, n - moved)
          if ok2 and type(m) == "number" then moved = moved + m end
        end
      end
    end
  end
  return moved
end

-- One turtle round of a craft step (one craft when learning).
function E:craftBatch(rec, st, step, learning)
  local cfg = self.cfg
  local run = st.run
  if not cfg.input or cfg.input == "" then
    st.waiting = "setup: the turtle's input chest is not set"
    return false
  end
  local output = cfg.output or cfg.input
  if not self:turtleReady() then
    st.waiting = tostring(self.turtle.msg or "turtle not ready")
    return false
  end
  local ok, why = self:clearChest(cfg.input)
  if ok and output ~= cfg.input then ok, why = self:clearChest(output) end
  if not ok then
    st.waiting = why
    return false
  end
  local cells = {}
  for cell = 1, 9 do
    if step.grid[cell] then cells[#cells + 1] = { cell = cell, item = step.grid[cell] } end
  end
  local n = learning and 1 or math.min(run.ops[run.step] - run.done[run.step], Recipes.maxBatch(step, function(k) return self:details(k) end))
  local short
  for _, ing in ipairs(Recipes.ingredients(step)) do
    local can = math.floor(self:count(ing.key) / ing.cells)
    if learning and can < 1 then can = 1 end -- the recipe chest may still hold it
    if can < n then n = can end
    if can < 1 and not short then short = ing end
  end
  if n < 1 then
    st.waiting = (learning and "learn: " or "") .. "waiting for " .. (short and short.displayName or "ingredients")
    return false
  end
  local moved, actual = {}, n
  for _, c in ipairs(cells) do
    local m = self:supply(c.item, n, cfg.input, c.cell, learning)
    moved[c.cell] = m
    if m < actual then actual = m end
  end
  if actual < n then
    -- Short of something after all: even the stacks out, or give up.
    for _, c in ipairs(cells) do
      if moved[c.cell] > actual then pcall(self.vault.deposit, cfg.input, { slot = c.cell, count = moved[c.cell] - actual }) end
    end
    n = actual
  end
  if n < 1 then
    self:deposit(cfg.input)
    local missing = "ingredients"
    for _, c in ipairs(cells) do
      if moved[c.cell] < 1 then
        missing = c.item.displayName
        break
      end
    end
    st.waiting = (learning and "learn: " or "") .. "waiting for " .. missing
    return false
  end
  st.waiting = learning and ("learning step " .. (st.learn and st.learn.step or "?")) or nil
  local grid = {}
  for _, c in ipairs(cells) do grid[#grid + 1] = { slot = Recipes.turtleSlot(c.cell), name = c.item.name, count = n } end
  local reply, err = self.link:craft(grid, n)
  if not reply then
    self:turtleLost(err)
    self:deposit(cfg.input)
    st.waiting = tostring(err)
    return false
  end
  if not reply.ok then
    self:deposit(output)
    if output ~= cfg.input then self:deposit(cfg.input) end
    local i = learning and st.learn.step or run.step
    self:fail(rec, st, "step " .. i .. ": " .. tostring(reply.error))
    return true
  end
  local made = tonumber(reply.made) or 0
  if not step.result then
    if made < 1 or not reply.result then
      self:deposit(output)
      self:fail(rec, st, "step " .. tostring(st.learn and st.learn.step) .. ": the craft made nothing")
      return true
    end
    local r = reply.result
    step.result = { key = util.keyOf(r.name, r.nbt), name = r.name, displayName = r.displayName or util.titleCase(r.name), count = made, maxCount = r.maxCount or 64 }
    self.detailsCache[step.result.key] = { displayName = step.result.displayName, maxCount = step.result.maxCount }
    self.log(rec.name .. ": step " .. tostring(st.learn and st.learn.step) .. " makes " .. made .. " x " .. step.result.displayName)
    st.learn = nil
    st.waiting = nil
    self:saveRecipes()
  end
  local opsDone = math.floor(made / math.max(1, step.result.count))
  if run and not learning then
    if opsDone < 1 then
      self:deposit(output)
      self:fail(rec, st, "step " .. run.step .. ": the craft made nothing")
      return true
    end
    run.done[run.step] = run.done[run.step] + opsDone
  end
  st.stats.crafts = (st.stats.crafts or 0) + opsDone
  local _, items, msg = self:deposit(output)
  if output ~= cfg.input then self:deposit(cfg.input) end
  if run and not learning and run.step == #rec.steps then run.made = run.made + (items[step.result.key] or 0) end
  st.waiting = msg
  if #(reply.left or {}) > 0 then st.waiting = "the turtle could not drop everything (output chest full?)" end
  self:changed()
  return true
end

-- One pass at a smelt step: feed the smelter what it still needs. What
-- comes out is credited by collectSmelter.
function E:smeltUnit(rec, st, step)
  local cfg = self.cfg
  if not cfg.smeltIn or not cfg.smeltOut then
    st.waiting = "setup: smelter chests not set"
    return false
  end
  local run = st.run
  local s = run.smelt
  if not s or s.step ~= run.step then
    s = { step = run.step, fed = 0, got = 0, lastAt = self.clock() }
    run.smelt = s
  end
  local need = run.ops[run.step]
  local did = false
  if s.fed < need then
    local avail = self:count(step.input.key)
    if avail < 1 then
      if s.fed == 0 then st.waiting = "waiting for " .. step.input.displayName end
    else
      local ok, m = pcall(self.vault.withdraw, step.input.key, math.min(need - s.fed, avail), cfg.smeltIn)
      if ok and type(m) == "number" and m > 0 then
        s.fed = s.fed + m
        did = true
        st.waiting = nil
      end
    end
  end
  if s.got >= need * math.max(1, step.result.count) then
    run.done[run.step] = need
    run.smelt = nil
    st.stats.smelted = (st.stats.smelted or 0) + need
    st.waiting = nil
    self:changed()
    return true
  end
  if not st.waiting and self.clock() - s.lastAt > cfg.smeltStall then
    st.waiting = "smelter: nothing came out for " .. math.floor((self.clock() - s.lastAt) / 60) .. " min"
  end
  if did then self:changed() end
  return did
end

-- Empties the smelter's finish chest into the vault and credits what came
-- out to the recipe smelting it (or learning from it).
function E:collectSmelter()
  local cfg = self.cfg
  if not cfg.smeltOut or cfg.smeltOut == "" then return end
  if self.clock() - self.collectedAt < E.COLLECT then return end
  self.collectedAt = self.clock()
  local moved, items, msg = self:deposit(cfg.smeltOut)
  if moved <= 0 then
    if msg then self.smelter.msg = msg end
    return
  end
  self.smelter.items = self.smelter.items + moved
  self.smelter.lastAt = self.epoch()
  self.smelter.msg = msg
  for key, n in pairs(items) do
    local credited = false
    for _, rec in ipairs(self.recipes) do
      local st = self.state.recipes[rec.id]
      local run = st and st.run
      local step = run and rec.steps[run.step]
      if step and step.kind == "smelt" and step.result and step.result.key == key and run.smelt and run.smelt.step == run.step then
        run.smelt.got = run.smelt.got + n
        run.smelt.lastAt = self.clock()
        if run.step == #rec.steps then run.made = run.made + n end
        credited = true
        break
      end
    end
    if not credited then
      for _, rec in ipairs(self.recipes) do
        local st = self.state.recipes[rec.id]
        local step = st and st.learn and rec.steps[st.learn.step]
        if step and step.kind == "smelt" and not step.result and st.learn.fed and key ~= step.input.key then
          local d = self:details(key)
          step.result = { key = key, name = (util.splitKey(key)), displayName = d.displayName, count = 1, maxCount = d.maxCount or 64 }
          self.log(rec.name .. ": step " .. st.learn.step .. " makes " .. step.result.displayName)
          st.learn, st.waiting = nil, nil
          self:saveRecipes()
          break
        end
      end
    end
  end
  self:changed()
end

-- Keeps the turtle's state current while nothing needs it: asked again
-- every RETRY seconds while away, and every HEARTBEAT seconds while ready.
E.HEARTBEAT = 60

function E:checkTurtle()
  if not self.link then return end
  local now = self.clock()
  if self.turtle.state ~= "ready" then
    self:turtleReady()
  elseif now - self.turtle.at >= E.HEARTBEAT then
    self.turtle.at = now
    self.link:setTurtle(self.cfg.turtle)
    local r, err = self.link:ping()
    if not r then self:turtleLost(err) end
  end
end

-- One scheduler pass: the turtle, the smelter's finish chest, then one
-- unit of work for the next recipe that has some. Returns true when work
-- was done.
function E:tick()
  self:checkTurtle()
  self:collectSmelter()
  local list = self.recipes
  local worked = false
  if #list > 0 then
    for _ = 1, #list do
      self.rr = self.rr % #list + 1
      local rec = list[self.rr]
      if rec then
        local st = self:stateOf(rec.id)
        local ok, did = pcall(self.unit, self, rec, st)
        if not ok then
          local msg = tostring(did):gsub("^[^%s:]+:%d+: ", "")
          if st.waiting ~= msg then self.log(rec.name .. ": " .. msg) end
          st.waiting = msg
          self:changed()
        elseif did then
          worked = true
          break
        end
      end
    end
  end
  self:saveState()
  return worked
end

-- Runs forever: a pass, then a short wait (shorter while busy), cut short
-- by a "crafter_wake" event from an order.
function E:run()
  self.log("crafter: " .. #self.recipes .. " recipe(s)")
  while true do
    local did = false
    local ok, err = pcall(function() did = self:tick() end)
    if not ok then
      if tostring(err):find("Terminated") then error(err, 0) end
      self.log("crafter error: " .. tostring(err))
      sleep(5)
    end
    local timer = os.startTimer(did and E.BUSY or E.TICK)
    while true do
      local ev, a = os.pullEvent()
      if (ev == "timer" and a == timer) or ev == "crafter_wake" then break end
    end
  end
end

-- Takes new settings while running. The turtle is looked up again, the
-- monitor is the dashboard's business.
function E:reconfigure(cfg)
  self.cfg = cfg
  self.turtle = { state = "unknown", at = -1000 }
  if self.link then self.link:setTurtle(cfg.turtle) end
  self:changed()
end

-- What the UIs show ------------------------------------------------------

-- A recipe's state in a few words: idle, running, waiting, learning,
-- problem.
function E:summary(rec)
  local st = self:stateOf(rec.id)
  local s = {
    id = rec.id, name = rec.name, mode = rec.mode, count = rec.count, rateCount = rec.rateCount, rateSeconds = rec.rateSeconds,
    steps = #rec.steps, pending = st.pending.items + st.pending.runs * ((Recipes.lastResult(rec) or {}).count or 1),
    runs = st.stats.runs, made = st.stats.made + (st.run and st.run.made or 0), crafts = st.stats.crafts, smelted = st.stats.smelted,
    errors = st.stats.errors, behind = st.stats.behind, lastRun = st.stats.lastRun, lastMessage = st.stats.lastMessage,
  }
  local last = Recipes.lastResult(rec)
  if last then s.result = last.displayName end
  local li = Recipes.unlearned(rec)
  if st.problem then
    s.state, s.text = "problem", st.problem
  elseif #rec.steps == 0 then
    s.state, s.text = "idle", "no steps"
  elseif li then
    s.state, s.text = "learning", st.waiting or ("step " .. li .. " not learned yet")
  elseif st.run then
    local run = st.run
    local step = rec.steps[run.step]
    local text
    if not step then
      text = "finishing"
    elseif step.kind == "smelt" then
      local sm = run.smelt or { got = 0 }
      text = string.format("smelting %d/%d", sm.got, run.ops[run.step] * math.max(1, step.result.count))
    else
      text = string.format("crafting %d/%d", run.done[run.step], run.ops[run.step])
    end
    if #rec.steps > 1 then text = "step " .. math.min(run.step, #rec.steps) .. "/" .. #rec.steps .. ": " .. text end
    if st.waiting then
      s.state, s.text = "waiting", st.waiting
      s.progress = text
    else
      s.state, s.text = "running", text
    end
    s.want = run.want
  elseif st.waiting then
    s.state, s.text = "waiting", st.waiting
  elseif s.pending > 0 then
    s.state, s.text = "queued", s.pending .. " ordered"
  elseif rec.mode == "always" then
    s.state, s.text = "idle", "always on"
  elseif rec.mode == "rate" then
    local due = st.rateDue and math.max(0, math.floor((st.rateDue - self.epoch()) / 1000)) or 0
    s.state, s.text = "idle", string.format("%d every %ds, next in %ds", rec.rateCount or 1, rec.rateSeconds or 600, due)
  else
    s.state, s.text = "idle", "idle"
  end
  return s
end

function E:status()
  local list = {}
  for _, rec in ipairs(self.recipes) do list[#list + 1] = self:summary(rec) end
  local active = 0
  for _, s in ipairs(list) do
    if s.state == "running" or s.state == "waiting" or s.state == "learning" then active = active + 1 end
  end
  return {
    recipes = list, active = active,
    turtle = { state = self.turtle.state, msg = self.turtle.msg, id = self.turtle.id, label = self.turtle.label },
    smelter = { set = self.cfg.smeltIn ~= nil and self.cfg.smeltOut ~= nil, items = self.smelter.items, lastAt = self.smelter.lastAt, msg = self.smelter.msg },
    cfg = { turtle = self.cfg.turtle, input = self.cfg.input, output = self.cfg.output, recipeChest = self.cfg.recipeChest, smeltIn = self.cfg.smeltIn, smeltOut = self.cfg.smeltOut, monitor = self.cfg.monitor },
  }
end

return E
