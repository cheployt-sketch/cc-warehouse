-- craft.worker: the crafty turtle's side of the crafter service, run with
-- `crafter worker` on a turtle with a crafting table. It waits for sealed
-- requests from the service (craft.link), takes the ingredients out of
-- the chest on its input side into its crafting grid, crafts, and drops
-- everything into the chest on its output side, where the vault collects
-- it. It never moves.
--
-- The turtle needs the warehouse key (`wh pair disk` with a floppy from
-- `warehouse key disk`) and a modem: a wired one on the warehouse's
-- network is best, since the service can then switch it on too.
--
-- File: /warehouse/data/crafter.worker (the input and output sides).

local secure = require("lib.secure")
local util = require("lib.util")
local Recipes = require("craft.recipes")

local W = {}

W.PROTOCOL = "crafter"
W.REPLY = "crafter_reply"
W.SIDES = { front = true, top = true, bottom = true }

local SUCK = { front = "suck", top = "suckUp", bottom = "suckDown" }
local DROP = { front = "drop", top = "dropUp", bottom = "dropDown" }

-- Whether an inventory (a chest, say) is on that side of the turtle.
local function hasChest(side)
  if peripheral.hasType then return peripheral.hasType(side, "inventory") or false end
  return peripheral.isPresent(side)
end

-- The input and output chests are both there, or which side lacks one.
local function chests(cfg)
  if not hasChest(cfg.input) then return false, cfg.input end
  if cfg.output ~= cfg.input and not hasChest(cfg.output) then return false, cfg.output end
  return true
end

local function openModems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then rednet.open(name) end
      n = n + 1
    end
  end
  return n
end

-- Drops what every slot holds into the output chest. Returns what was
-- dropped ({ { name, count } }) and what could not be (chest full).
local function dropAll(side)
  local dropped, left = {}, {}
  local drop = turtle[DROP[side]]
  for slot = 1, 16 do
    local n = turtle.getItemCount(slot)
    if n > 0 then
      local it = turtle.getItemDetail(slot)
      turtle.select(slot)
      local tries = 0
      while turtle.getItemCount(slot) > 0 and tries < 4 do
        if not drop() then break end
        tries = tries + 1
      end
      local rest = turtle.getItemCount(slot)
      if it then
        if n - rest > 0 then dropped[#dropped + 1] = { name = it.name, count = n - rest } end
        if rest > 0 then left[#left + 1] = { name = it.name, count = rest, slot = slot } end
      end
    end
  end
  turtle.select(1)
  return dropped, left
end

local function holding()
  local n = 0
  for slot = 1, 16 do n = n + turtle.getItemCount(slot) end
  return n
end

-- Takes `count` of the next items in the input chest into `slot`.
local function take(side, slot, count)
  local suck = turtle[SUCK[side]]
  turtle.select(slot)
  local tries = 0
  while turtle.getItemCount(slot) < count and tries < 8 do
    if not suck(count - turtle.getItemCount(slot)) then break end
    tries = tries + 1
  end
  return turtle.getItemCount(slot)
end

-- The craft function. CraftOS binds turtle.craft when it boots or when a
-- program equips the table; a table equipped by hand in the turtle's screen
-- only shows up as a "workbench" peripheral until then, so look for that too.
local function crafter()
  if turtle.craft then return turtle.craft end
  for _, side in ipairs({ "left", "right" }) do
    if peripheral.getType(side) == "workbench" then
      return function(limit) return peripheral.call(side, "craft", limit) end
    end
  end
end

-- One craft request: { grid = { { slot, name, count } }, limit }.
local function craft(cfg, req)
  local doCraft = crafter()
  if not doCraft then return { ok = false, error = "no crafting table on this turtle" } end
  local ok, side = chests(cfg)
  if not ok then return { ok = false, error = "no chest on the " .. side .. " side of the turtle" } end
  if holding() > 0 then dropAll(cfg.output) end
  for _, g in ipairs(req.grid or {}) do
    local got = take(cfg.input, g.slot, g.count)
    local it = turtle.getItemDetail(g.slot)
    if got ~= g.count or not it or it.name ~= g.name then
      local dropped = dropAll(cfg.output)
      return { ok = false, dropped = dropped,
        error = string.format("slot %d: expected %d %s, got %d %s", g.slot, g.count, util.shortName(g.name), got, it and util.shortName(it.name) or "nothing") }
    end
  end
  turtle.select(Recipes.OUTPUT_SLOT)
  local ok, why = doCraft(req.limit or 64)
  if not ok then
    local dropped = dropAll(cfg.output)
    return { ok = false, error = tostring(why or "no matching recipe"), dropped = dropped }
  end
  local out = turtle.getItemDetail(Recipes.OUTPUT_SLOT, true)
  local made = 0
  if out then
    for slot = 1, 16 do
      local it = turtle.getItemDetail(slot)
      if it and it.name == out.name and it.nbt == out.nbt then made = made + it.count end
    end
  end
  local dropped, left = dropAll(cfg.output)
  local reply = { ok = true, made = made, dropped = dropped }
  if out then reply.result = { name = out.name, nbt = out.nbt, displayName = out.displayName, maxCount = out.maxCount } end
  if #left > 0 then reply.left = left end
  return reply
end

local function handle(cfg, req)
  if req.op == "ping" then
    local free = 0
    for slot = 1, 16 do
      if turtle.getItemCount(slot) == 0 then free = free + 1 end
    end
    local chest, missing = chests(cfg)
    return { ok = true, crafty = crafter() ~= nil, chest = chest, missing = missing, fuel = turtle.getFuelLevel(), free = free, label = os.getComputerLabel(), input = cfg.input, output = cfg.output }
  elseif req.op == "clear" then
    local dropped, left = dropAll(cfg.output)
    return { ok = true, dropped = dropped, left = #left > 0 and left or nil }
  elseif req.op == "craft" then
    return craft(cfg, req)
  end
  return { ok = false, error = "unknown op: " .. tostring(req.op) }
end

function W.configPath(root) return fs.combine(root, "data/crafter.worker") end

-- Runs forever. opts: root (the warehouse folder), key (the warehouse
-- key), input and output (sides: front, top or bottom), print(msg).
function W.run(opts)
  local say = opts.print or print
  if not turtle then error("crafter worker runs on a turtle", 0) end
  local cfg = util.readTable(W.configPath(opts.root)) or {}
  if W.SIDES[opts.input] then
    -- Sides given on the command line replace the saved ones; one side means both.
    cfg.input = opts.input
    cfg.output = W.SIDES[opts.output] and opts.output or opts.input
  else
    cfg.input = W.SIDES[cfg.input] and cfg.input or "front"
    cfg.output = W.SIDES[cfg.output] and cfg.output or cfg.input
  end
  util.writeTable(W.configPath(opts.root), { input = cfg.input, output = cfg.output })
  if openModems() == 0 then error("no modem on this turtle", 0) end
  pcall(rednet.host, W.PROTOCOL, "crafter" .. os.getComputerID())
  if not crafter() then say("No crafting table on this turtle: it answers, but cannot craft.") end
  local chest, missing = chests(cfg)
  if not chest then say("No chest on the " .. missing .. " side: it answers, but cannot craft until there is one.") end
  say("Crafting from the " .. cfg.input .. " chest into the " .. cfg.output .. " chest (Ctrl+T stops)")
  local seen = {}
  local n = 0
  while true do
    local sender, msg = rednet.receive(W.PROTOCOL)
    local body, why = secure.open(opts.key, "crafter", msg, seen)
    if body and type(body.op) == "string" then
      local ok, reply = pcall(handle, cfg, body)
      if not ok then reply = { ok = false, error = tostring(reply) } end
      reply.id = body.id
      rednet.send(sender, secure.seal(opts.key, "crafter_reply", reply), W.REPLY)
      if body.op == "craft" then
        n = n + 1
        if reply.ok then
          say(string.format("#%d: %d x %s", n, reply.made, reply.result and util.shortName(reply.result.name) or "?"))
        else
          say("#" .. n .. ": " .. tostring(reply.error))
        end
      end
    elseif not body then
      say("dropped a message from #" .. tostring(sender) .. ": " .. tostring(why))
    end
  end
end

return W
