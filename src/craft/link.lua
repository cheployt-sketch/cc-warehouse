-- craft.link: the crafter service's line to its crafty turtle.
--
-- Turtles are not inventories on a wired network, so the turtle takes its
-- ingredients out of a chest the vault fills, crafts, and drops the result
-- into a chest the vault empties. What it should take and craft comes over
-- rednet, sealed with the warehouse key like every other message between
-- the warehouse's computers (the turtle is paired with `wh pair disk`), on
-- protocol "crafter"; the turtle answers on "crafter_reply". The turtle
-- runs `crafter worker` (craft.worker).
--
-- The turtle is named by its peripheral name on the wired network
-- ("turtle_2": then it can be switched on from here too), by its computer
-- ID, or not at all, in which case the first turtle on the network, or the
-- one answering `rednet.lookup("crafter")`, is used.

local secure = require("lib.secure")

local L = {}
L.__index = L

L.PROTOCOL = "crafter"
L.REPLY = "crafter_reply"
L.TIMEOUT = 20 -- seconds to wait for a craft to be done

local counter = 0
local function newId()
  counter = counter + 1
  return os.epoch("utc") .. "-" .. counter .. "-" .. math.random(1, 1000000)
end

-- opts: key (the warehouse key), turtle (name, ID or nil), log(msg)
function L.new(opts)
  local self = setmetatable({}, L)
  self.key = opts.key
  self.turtle = opts.turtle
  self.log = opts.log or function() end
  self.id = nil
  return self
end

function L:setTurtle(turtle)
  if turtle ~= self.turtle then
    self.turtle = turtle
    self.id = nil
  end
end

function L:openModems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      if not rednet.isOpen(name) then rednet.open(name) end
      n = n + 1
    end
  end
  return n
end

-- The turtle's peripheral name on the network, if it is there.
function L:peripheralName()
  if type(self.turtle) == "string" and self.turtle ~= "" then
    if peripheral.isPresent(self.turtle) and peripheral.hasType(self.turtle, "turtle") then return self.turtle end
    return nil
  end
  if self.turtle == nil then
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.hasType(name, "turtle") then return name end
    end
  end
  return nil
end

-- Finds the turtle's computer ID, switching it on when it is off and on
-- the network. Returns the ID, or nil and why.
function L:resolve()
  if type(self.turtle) == "number" then
    self.id = self.turtle
    return self.id
  end
  local name = self:peripheralName()
  if name then
    local ok, id = pcall(peripheral.call, name, "getID")
    if ok and type(id) == "number" then
      local on, isOn = pcall(peripheral.call, name, "isOn")
      if on and not isOn then
        pcall(peripheral.call, name, "turnOn")
        self.log("turtle " .. name .. " (#" .. id .. ") was off; switched it on")
      end
      self.id = id
      self.name = name
      return id
    end
    return nil, "cannot read " .. name
  end
  if type(self.turtle) == "string" and self.turtle ~= "" then return nil, self.turtle .. " is not on the network" end
  if self:openModems() == 0 then return nil, "no modem" end
  local ok, id = pcall(rednet.lookup, L.PROTOCOL)
  if ok and type(id) == "number" then
    self.id = id
    return id
  end
  return nil, "no crafting turtle found (name one in the setup, or run 'crafter worker' on it)"
end

-- Sends a sealed request and waits for its sealed reply. Returns the
-- reply body, or nil and why.
function L:request(body, timeout)
  if not self.key then return nil, "no warehouse key" end
  if not self.id then
    local id, err = self:resolve()
    if not id then return nil, err end
  end
  if self:openModems() == 0 then return nil, "no modem" end
  body.id = newId()
  local ok, err = pcall(rednet.send, self.id, secure.seal(self.key, "crafter", body), L.PROTOCOL)
  if not ok then return nil, tostring(err) end
  local timer = os.startTimer(timeout or L.TIMEOUT)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rednet_message" and a == self.id and c == L.REPLY then
      local reply = secure.open(self.key, "crafter_reply", b)
      if reply and reply.id == body.id then return reply end
    elseif ev == "timer" and a == timer then
      return nil, "turtle #" .. tostring(self.id) .. " did not answer"
    end
  end
end

-- Is the turtle there, and can it craft? Returns its answer
-- { crafty, fuel, free, label }, or nil and why.
-- input and output: the service's chest names, so the turtle can tell
-- which of its sides they are on.
function L:ping(input, output)
  local r, err = self:request({ op = "ping", input = input, output = output }, 5)
  if not r then return nil, err end
  if not r.crafty then return nil, "turtle #" .. tostring(self.id) .. " has no crafting table" end
  if r.chest == false then return nil, "turtle #" .. tostring(self.id) .. " has no chest on its " .. tostring(r.missing) .. " side" end
  return r
end

-- Asks for `limit` crafts of a grid: { { slot = turtle slot, name = item id,
-- count = items in the slot }, ... } in the order the items lie in the
-- input chest. Returns the reply ({ ok, made, result = { name, nbt,
-- displayName, maxCount }, error, dropped }), or nil and why.
function L:craft(grid, limit, timeout, input, output)
  return self:request({ op = "craft", grid = grid, limit = limit, input = input, output = output }, timeout or L.TIMEOUT)
end

-- Tells the turtle to fetch warehouse.lua from url, check that it is
-- `build`, install it and reboot. Returns its answer, or nil and why.
function L:update(url, build)
  return self:request({ op = "update", url = url, build = build }, 90)
end

-- Makes the turtle drop everything it holds into its output chest.
function L:clear(input, output)
  return self:request({ op = "clear", input = input, output = output }, 10)
end

return L
