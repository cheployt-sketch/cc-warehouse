-- test/screen.lua: an access point screen (lib.access) against a simulated
-- monitor, chest, vault and service (run with node test/run.cjs screen),
-- plus the pickers' knowledge of what is in use (lib.uses). Where it
-- matters here the simulation behaves like CraftOS: reading an inventory
-- and asking the service yield, and a coroutine that waits on them misses
-- the events that arrive meanwhile; timers fire in order; the monitor is a
-- window whose lines (text and colours) can be read back.

---------------------------------------------------------------------------
-- CraftOS stand-ins
---------------------------------------------------------------------------
colors = {}
do
  local names = { "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray", "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black" }
  for i, n in ipairs(names) do colors[n] = 2 ^ (i - 1) end
end
local HEX = "0123456789abcdef"
local function hex(c)
  local n = 0
  while 2 ^ n < c do n = n + 1 end
  return HEX:sub(n + 1, n + 1)
end
keys = { backspace = 14, delete = 211, left = 203, right = 205, home = 199, ["end"] = 207, enter = 28, tab = 15, escape = 1 }

-- A terminal buffer: what window.create gives, and what a monitor is.
local function newBuffer(w, h)
  local lines = {}
  local t = { cx = 1, cy = 1, fg = colors.white, bg = colors.black }
  local function fill()
    for y = 1, h do lines[y] = { text = string.rep(" ", w), fg = string.rep(hex(t.fg), w), bg = string.rep(hex(t.bg), w) } end
  end
  fill()
  function t.getSize() return w, h end
  function t.isColor() return true end
  function t.isColour() return true end
  function t.setVisible() end
  function t.setTextScale() end
  function t.setCursorBlink() end
  function t.setCursorPos(x, y) t.cx, t.cy = x, y end
  function t.getCursorPos() return t.cx, t.cy end
  function t.setTextColor(c) t.fg = c end
  function t.setBackgroundColor(c) t.bg = c end
  t.setTextColour, t.setBackgroundColour = t.setTextColor, t.setBackgroundColor
  function t.clear() fill() end
  function t.write(s)
    s = tostring(s)
    local x, y = t.cx, t.cy
    t.cx = t.cx + #s
    if y < 1 or y > h then return end
    local from = 1
    if x < 1 then
      from = 2 - x
      x = 1
    end
    local part = s:sub(from, from + (w - x))
    if #part == 0 then return end
    local L = lines[y]
    L.text = L.text:sub(1, x - 1) .. part .. L.text:sub(x + #part)
    L.fg = L.fg:sub(1, x - 1) .. string.rep(hex(t.fg), #part) .. L.fg:sub(x + #part)
    L.bg = L.bg:sub(1, x - 1) .. string.rep(hex(t.bg), #part) .. L.bg:sub(x + #part)
  end
  function t.getLine(y)
    local L = lines[y]
    return L.text, L.fg, L.bg
  end
  return t
end
window = { create = function(parent, x, y, w, h) return newBuffer(w, h) end }

-- The clock, timers and the event queue.
local sim = {}
local function resetSim()
  sim.clock, sim.queue, sim.timers, sim.nextTimer = 0, {}, {}, 0
  sim.pending = 0 -- peripheral tasks that finish at the next step
  sim.running = false -- while the screen coroutine runs (peripheral calls then yield)
  sim.reading = nil -- the inventory being read right now
  sim.holdService = false -- the service answers only when the test says so
  sim.serviceWaiting = false
end
resetSim()
os.clock = function() return sim.clock end
os.epoch = function() return 1700000000000 + math.floor(sim.clock * 1000) end
os.startTimer = function(s)
  sim.nextTimer = sim.nextTimer + 1
  sim.timers[#sim.timers + 1] = { at = sim.clock + s, id = sim.nextTimer }
  return sim.nextTimer
end
os.queueEvent = function(...) sim.queue[#sim.queue + 1] = table.pack(...) end
os.pullEvent = function(filter) return coroutine.yield(filter) end
os.pullEventRaw = os.pullEvent
sleep = function(s)
  local t = os.startTimer(s)
  repeat local _, id = os.pullEvent("timer") until id == t
end

-- parallel, as CraftOS does it: every coroutine gets the events its filter
-- lets through.
local function runParallel(fns, stopWhenOne)
  local cos, filters, living = {}, {}, #fns
  for i, fn in ipairs(fns) do cos[i] = coroutine.create(fn) end
  local ev = { n = 0 }
  while true do
    for i, co in ipairs(cos) do
      if coroutine.status(co) ~= "dead" and (filters[i] == nil or filters[i] == ev[1] or ev[1] == "terminate") then
        local ok, f = coroutine.resume(co, table.unpack(ev, 1, ev.n))
        if not ok then error(f, 0) end
        filters[i] = f
        if coroutine.status(co) == "dead" then
          living = living - 1
          if stopWhenOne or living == 0 then return i end
        end
      end
    end
    ev = table.pack(coroutine.yield())
  end
end
parallel = {
  waitForAny = function(...) return runParallel({ ... }, true) end,
  waitForAll = function(...) return runParallel({ ... }, false) end,
}

-- Files, for lib.uses.
local files = {}
local function combine(...)
  local parts = {}
  for _, p in ipairs({ ... }) do
    for seg in tostring(p):gmatch("[^/]+") do parts[#parts + 1] = seg end
  end
  return table.concat(parts, "/")
end
fs = {
  combine = function(a, b) return combine(a, b) end,
  exists = function(p) return files[combine(p)] ~= nil end,
  getDir = function(p) p = combine(p) return p:match("^(.*)/[^/]*$") or "" end,
  makeDir = function() end,
  delete = function(p) files[combine(p)] = nil end,
  move = function(a, b) files[combine(b)] = files[combine(a)] files[combine(a)] = nil end,
  open = function(p, mode)
    p = combine(p)
    if mode == "r" then
      if not files[p] then return nil end
      local s = files[p]
      return { readAll = function() return s end, close = function() end }
    end
    local buf = ""
    return { write = function(s) buf = buf .. s end, close = function() files[p] = buf end }
  end,
}
local function ser(v)
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
textutils = {
  serialise = ser,
  unserialise = function(s)
    local fn = load("return " .. s, "=ser", "t", {})
    if not fn then return nil end
    local ok, v = pcall(fn)
    return ok and v or nil
  end,
}

-- Inventories and monitors on the network. Inventory methods take a tick:
-- inside the screen they yield on "task_complete", as CC's main-thread
-- methods do, and the coroutine misses whatever arrives meanwhile.
local MAX = { ["minecraft:ender_pearl"] = 16 }
local function maxOf(name) return MAX[name] or 64 end
local invs, monitors = {}, {}
local function newInv(name, size) invs[name] = { size = size, slots = {} } end
local function stock(inv, name, count)
  local slots = invs[inv].slots
  local s = 1
  while count > 0 do
    while slots[s] do s = s + 1 end
    local n = math.min(count, maxOf(name))
    slots[s] = { name = name, count = n }
    count = count - n
  end
end
local function countIn(inv, name)
  local n = 0
  for _, it in pairs(invs[inv].slots) do
    if it.name == name then n = n + it.count end
  end
  return n
end
local function tick(name)
  if not sim.running then return end
  sim.pending = sim.pending + 1
  sim.reading = name
  coroutine.yield("task_complete")
  sim.reading = nil
end

peripheral = {}
function peripheral.wrap(name) return monitors[name] end
function peripheral.getNames()
  local out = {}
  for n in pairs(invs) do out[#out + 1] = n end
  for n in pairs(monitors) do out[#out + 1] = n end
  table.sort(out)
  return out
end
function peripheral.hasType(name, ptype)
  if ptype == "monitor" then return monitors[name] ~= nil end
  if ptype == "inventory" then return invs[name] ~= nil end
  return false
end
function peripheral.getType(name) return monitors[name] and "monitor" or (invs[name] and "minecraft:chest") or nil end
function peripheral.call(name, method, ...)
  local inv = invs[name]
  if not inv then error("No peripheral named " .. tostring(name)) end
  tick(name)
  if method == "size" then
    return inv.size
  elseif method == "list" then
    local out = {}
    for s, it in pairs(inv.slots) do out[s] = { name = it.name, count = it.count } end
    return out
  elseif method == "getItemDetail" then
    local it = inv.slots[(...)]
    if not it then return nil end
    return { name = it.name, count = it.count, displayName = require("lib.util").titleCase(it.name), maxCount = maxOf(it.name) }
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
        if d.name ~= src.name then return 0 end
        local m = math.min(maxOf(src.name) - d.count, cnt)
        if m <= 0 then return 0 end
        d.count = d.count + m
        return m
      end
      local m = math.min(maxOf(src.name), cnt)
      dst.slots[slot] = { name = src.name, count = m }
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

---------------------------------------------------------------------------
-- The scheduler: delivers events to the screen's coroutine as the
-- computer would, dropping those its filter does not let through.
---------------------------------------------------------------------------
local main, filter
local function deliver(ev)
  if not main or coroutine.status(main) == "dead" then return end
  if filter == nil or filter == ev[1] then
    sim.running = true
    local ok, f = coroutine.resume(main, table.unpack(ev, 1, ev.n))
    sim.running = false
    if not ok then error(f, 0) end
    filter = f
  end
end

-- One step: the next queued event, else a finished peripheral task, else
-- the next timer (moving the clock there, unless past `limit`). Returns
-- false when nothing is due.
local function pump(limit)
  if #sim.queue > 0 then
    deliver(table.remove(sim.queue, 1))
    return true
  end
  if sim.pending > 0 then
    sim.pending = 0
    deliver({ "task_complete", n = 1 })
    return true
  end
  local best
  for i, t in ipairs(sim.timers) do
    if not best or t.at < sim.timers[best].at then best = i end
  end
  if not best or (limit and sim.timers[best].at > limit) then return false end
  local t = table.remove(sim.timers, best)
  sim.clock = math.max(sim.clock, t.at)
  deliver({ "timer", t.id, n = 2 })
  return true
end

-- Runs what is due now: queued events and finished tasks, no clock.
local function settle()
  for _ = 1, 1000 do
    if #sim.queue == 0 and sim.pending == 0 then return end
    pump()
  end
  error("the screen never settles")
end

-- Lets `seconds` pass.
local function run(seconds)
  local until_ = sim.clock + seconds
  for _ = 1, 10000 do
    if not pump(until_) then
      sim.clock = until_
      return
    end
  end
  error("runaway")
end

---------------------------------------------------------------------------
-- The screen under test
---------------------------------------------------------------------------
local util = require("lib.util")
local Index = require("lib.index")
local Access = require("lib.access")
local Uses = require("lib.uses")

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

local function check(cond, what, detail)
  if not cond then error((what or "check") .. (detail and (": " .. tostring(detail)) or ""), 2) end
end

-- A screen on a fresh network: a vault with `stock`, an empty chest and a
-- monitor (29x26 unless w and h say otherwise), running until drawn.
local function newScreen(opts)
  opts = opts or {}
  resetSim()
  invs, monitors = {}, {}
  newInv("vault", 54)
  newInv("chest", 27)
  for name, n in pairs(opts.stock or {}) do stock("vault", name, n) end
  monitors.monitor_0 = newBuffer(opts.w or 29, opts.h or 26)
  local index = Index.new({ storage = { "vault" } })
  index:scanAll()
  local service = { index = index, log = { warn = function() end, info = function() end } }
  -- Like lib.service: the op is done elsewhere and this coroutine waits on
  -- "warehouse_done", missing what arrives meanwhile.
  function service:request(op, args)
    local ok, res
    if op == "withdraw" then
      local moved, msg = index:withdraw(args.item, args.count, args.to, args.toSlot)
      ok, res = true, { moved = moved, message = msg }
    elseif op == "deposit" then
      local moved, items, msg = index:deposit(args.from, { slot = args.slot })
      ok, res = true, { moved = moved, items = items, message = msg }
    else
      ok, res = false, "unknown op: " .. tostring(op)
    end
    if sim.holdService then
      sim.serviceWaiting = true
      os.pullEvent("warehouse_done")
      sim.serviceWaiting = false
    end
    return ok, res
  end
  local ap = Access.new(service, { name = "Main", chest = "chest", monitor = "monitor_0" }, { presets = { 1, 4, 8, 16, 32 }, stackPresets = { 1, 2, 4, 8, 16 } })
  main = coroutine.create(function() ap:run() end)
  filter = nil
  deliver({ n = 0 })
  settle()
  check(ap.ok, "the screen attached")
  return ap, index
end

-- Where text first appears on the screen (x, y), looking from row `fromY`.
local function findText(ap, text, fromY)
  local lines = ap.ui:lines()
  for y = fromY or 1, #lines do
    local x = lines[y]:find(text, 1, true)
    if x then return x, y end
  end
  return nil
end
local function findRow(ap, text, fromY) return select(2, findText(ap, text, fromY)) end
local function bgAt(ap, x, y)
  local _, _, bg = ap.ui.win.getLine(y)
  return bg:sub(x, x)
end
local function tap(ap, x, y)
  os.queueEvent("monitor_touch", "monitor_0", x, y)
  settle()
end
local function tapText(ap, text, fromY)
  local x, y = findText(ap, text, fromY)
  check(x, "nothing on screen says " .. text)
  tap(ap, x, y)
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------
test("tapping an item opens the amount panel and highlights its row until it closes", function()
  local ap = newScreen({ stock = { ["minecraft:cobblestone"] = 200, ["minecraft:iron_ingot"] = 30 } })
  local y = findRow(ap, "Cobblestone")
  check(y, "cobblestone listed")
  eq(bgAt(ap, 1, y), hex(colors.black), "a plain row before the tap")
  tap(ap, 2, y)
  check(ap.dialog and ap.dialog.key == "minecraft:cobblestone", "the panel is open for it")
  check(findRow(ap, "In storage: 200  stack 64"), "the panel says what is there")
  eq(bgAt(ap, 1, y), hex(colors.blue), "its row is highlighted")
  eq(bgAt(ap, 29, y), hex(colors.blue), "all the way to the count")
  eq(bgAt(ap, 1, findRow(ap, "Iron Ingot")), hex(colors.black), "the others are not")
  check(not findRow(ap, "Stack"), "there is no Stack button any more")
  check(findRow(ap, "Get stack"), "Get stack is there")
  tapText(ap, "Cancel")
  check(ap.dialog == nil, "Cancel closes it")
  eq(bgAt(ap, 1, y), hex(colors.black), "and the highlight goes")
end)

test("amount buttons move items at once; Get stack moves a stack, or the number typed on the pad", function()
  local ap = newScreen({ stock = { ["minecraft:cobblestone"] = 500 } })
  tap(ap, 2, findRow(ap, "Cobblestone"))
  tapText(ap, " 16 ")
  eq(countIn("chest", "minecraft:cobblestone"), 16, "16 in the chest right away")
  check(ap.dialog == nil, "the panel closed")
  check(findRow(ap, "Got 16 Cobblestone"), "and the header says so")
  check(findRow(ap, "16 Cobblestone", 2), "the chest panel lists them")
  tap(ap, 2, findRow(ap, "Cobblestone", 2))
  tapText(ap, "Get stack")
  eq(countIn("chest", "minecraft:cobblestone"), 80, "a stack more")
  tap(ap, 2, findRow(ap, "Cobblestone", 2))
  local _, ay = findText(ap, "Amount:")
  local kx, ky = findText(ap, "7", ay + 1)
  tap(ap, kx, ky)
  eq(ap.dialog.amount, "7", "typed on the pad")
  check(findText(ap, "Get 7"), "Get now names the amount")
  tapText(ap, "Get 7")
  eq(countIn("chest", "minecraft:cobblestone"), 87, "seven more")
  eq(countIn("vault", "minecraft:cobblestone"), 413, "out of the vault")
end)

test("a tap that arrives while the chest is being read is not lost", function()
  local ap = newScreen({ stock = { ["minecraft:cobblestone"] = 10 } })
  for _ = 1, 100 do
    if sim.reading == "chest" then break end
    pump()
  end
  eq(sim.reading, "chest", "the work coroutine is inside a chest read")
  local x, y = findText(ap, "Recent")
  os.queueEvent("monitor_touch", "monitor_0", x, y)
  settle()
  eq(ap.category, "recent", "the tap landed meanwhile")
  eq(sim.reading, nil, "and the read finished")
  run(5)
  eq(ap.category, "recent", "still there after the polls")
end)

test("the Recent tab lists the last moved item first, whatever the sort button says; automation does not count", function()
  local ap, index = newScreen({ stock = { ["minecraft:cobblestone"] = 300, ["minecraft:iron_ingot"] = 20, ["minecraft:dirt"] = 100 } })
  index:withdraw("minecraft:cobblestone", 1, "chest")
  sim.clock = sim.clock + 1
  index:withdraw("minecraft:iron_ingot", 1, "chest")
  os.queueEvent("warehouse_event", { type = "change" })
  settle()
  tapText(ap, "Recent")
  check(findRow(ap, "Iron Ingot") < findRow(ap, "Cobblestone"), "newest first")
  check(not findRow(ap, "Dirt"), "untouched items are not recent")
  check(findText(ap, "New"), "the sort button says New")
  sim.clock = sim.clock + 1
  index:withdraw("minecraft:dirt", 1, "chest", nil, { recent = false })
  os.queueEvent("warehouse_event", { type = "change" })
  settle()
  check(not findRow(ap, "Dirt"), "a move by automation does not show under New")
  tapText(ap, "New")
  check(findText(ap, "Lst"), "the button now says Lst")
  check(findRow(ap, "Dirt") < findRow(ap, "Iron Ingot"), "Lst lists every change, newest first")
  tapText(ap, "Lst")
  check(findText(ap, "New") and not findRow(ap, "Dirt"), "and back to New")
  tapText(ap, "All")
  check(findText(ap, "Qty"), "the sort button is back on All")
  tapText(ap, "Qty")
  check(findText(ap, "A-Z"), "and switches")
end)

test("the search keyboard has keys big enough to hit, two rows high on a tall screen", function()
  local ap = newScreen({ stock = { ["minecraft:cobblestone"] = 10 } })
  tapText(ap, "Search...")
  check(ap.keyboard, "keyboard open")
  local x, y = findText(ap, "q")
  check(x, "a q key")
  tap(ap, x + 1, y)
  eq(ap.search, "q", "the second column of the key counts")
  tap(ap, x + 2, y)
  eq(ap.search, "qq", "so does the gap after it")
  check(findRow(ap, "qq_"), "the search box shows it")
  tapText(ap, "clear")
  eq(ap.search, "", "cleared")
  local ap2 = newScreen({ stock = { ["minecraft:cobblestone"] = 10 }, w = 57, h = 52 })
  tapText(ap2, "Search...")
  local x2, y2 = findText(ap2, "z")
  check(x2, "a z key on the wide screen")
  tap(ap2, x2, y2 + 1)
  eq(ap2.search, "z", "the row below the letter is still the key")
  tapText(ap2, "OK")
  check(not ap2.keyboard, "OK closes the keyboard")
end)

test("a tapped key lights up for a moment", function()
  local ap = newScreen({ stock = { ["minecraft:cobblestone"] = 10 } })
  tapText(ap, "Search...")
  local x, y = findText(ap, "q")
  eq(bgAt(ap, x, y), hex(colors.gray), "a key is gray")
  tap(ap, x, y)
  eq(bgAt(ap, x, y), hex(colors.white), "lit right after the tap")
  eq(ap.search, "q", "and it typed")
  run(0.3)
  eq(bgAt(ap, x, y), hex(colors.gray), "back to normal once the flash is over")
  local cx, cy = findText(ap, "clear")
  tap(ap, cx, cy)
  eq(bgAt(ap, cx, cy), hex(colors.white), "buttons light up too")
  run(0.3)
  eq(bgAt(ap, cx, cy), hex(colors.gray), "and go back")
end)

test("while a move is in flight the screen stays live but refuses a second move", function()
  local ap = newScreen({ stock = { ["minecraft:cobblestone"] = 500 } })
  sim.holdService = true
  tap(ap, 2, findRow(ap, "Cobblestone"))
  tapText(ap, " 16 ")
  check(sim.serviceWaiting, "the request is waiting on the service")
  check(ap.busy, "the screen knows")
  check(findRow(ap, "Working..."), "and says so")
  tapText(ap, "All")
  check(findRow(ap, "Still busy with the last tap"), "a second move is refused")
  tapText(ap, "Recent")
  eq(ap.category, "recent", "other taps still work")
  sim.holdService = false
  os.queueEvent("warehouse_done")
  settle()
  check(not ap.busy, "free again once the service answered")
  eq(countIn("chest", "minecraft:cobblestone"), 16, "only the first move happened")
  check(findRow(ap, "Got 16 Cobblestone"), "and was reported")
end)

test("putting things in the chest shows the chest panel; its store button puts them away", function()
  local ap = newScreen({ stock = { ["minecraft:cobblestone"] = 10 } })
  stock("chest", "minecraft:iron_ingot", 5)
  run(1)
  check(findRow(ap, "Chest: 5 items"), "the chest panel appeared by itself")
  local y = findRow(ap, "5 Iron Ingot")
  check(y, "with the stack")
  tap(ap, 29, y)
  eq(countIn("chest", "minecraft:iron_ingot"), 0, "stored")
  eq(countIn("vault", "minecraft:iron_ingot"), 5, "in the vault")
  check(findRow(ap, "Stored 5 Iron Ingot"), "and reported")
  check(findRow(ap, "Iron Ingot"), "it is in the list now")
end)

test("a stat screen draws a fill gauge, big digits and charts, and a tap turns the page", function()
  local ap, index = newScreen({ stock = { ["minecraft:cobblestone"] = 300, ["minecraft:iron_ingot"] = 20, ["minecraft:dirt"] = 100 } })
  local Stats = require("lib.stats")
  local service = ap.service
  service.cfg = { access = { { name = "Main", chest = "chest", monitor = "monitor_0" } }, rednet = true, hostname = "wh" }
  service.access, service.started, service.version = { ap }, 0, "0.1.0"
  local col = Stats.Collector.new({ index = index, root = "/warehouse", parcel = function() return nil end })
  for i = 1, 30 do col.points[i] = { t = i * 60000, items = 400 + i * 4, used = 7, slots = 54, inn = i % 3 == 0 and 12 or 0, out = i % 5 == 0 and 7 or 0 } end
  monitors.monitor_1 = newBuffer(29, 19)
  local sc = Stats.Screen.new(service, { name = "Stats", monitor = "monitor_1", show = { "fill", "items", "flow", "top" } }, col)
  main = coroutine.create(function() sc:run() end)
  filter = nil
  deliver({ n = 0 })
  settle()
  check(sc.ok, "attached")
  local st = index:stats()
  local pct = math.floor(st.used / st.slots * 100 + 0.5)
  local lines = sc.ui:lines()
  check(lines[1]:find("Storage " .. pct .. "% full", 1, true), "the fill title", lines[1])
  check(lines[3]:find(st.used .. "/" .. st.slots .. " slots", 1, true), "the slots line", lines[3])
  check(lines[4]:find("vault", 1, true), "a row per storage inventory", lines[4])
  local itemsRow
  for i, l in ipairs(lines) do
    if l:find("Items in storage", 1, true) then itemsRow = i end
  end
  check(itemsRow, "the items panel is on page 1")
  local _, _, bg = sc.ui.win.getLine(itemsRow + 1)
  check(bg:find(hex(colors.lightBlue), 1, true), "big digits are drawn as coloured cells")
  check(lines[19]:find("tap for more", 1, true) and lines[19]:find("1/2", 1, true), "two pages", lines[19])
  os.queueEvent("monitor_touch", "monitor_1", 5, 5)
  settle()
  lines = sc.ui:lines()
  check(lines[19]:find("2/2", 1, true), "page 2 after a tap", lines[19])
  check(lines[1]:find("Items over time", 1, true), "the chart is on page 2", lines[1])
  _, _, bg = sc.ui.win.getLine(7)
  check(bg:sub(29, 29) == hex(colors.lightBlue), "the newest column reaches the bottom row of the chart")
  check(lines[8]:find("over 30 min", 1, true), "the axis says how long the chart covers", lines[8])
  local topRow
  for i, l in ipairs(lines) do
    if l:find("Top items", 1, true) then topRow = i end
  end
  check(topRow and lines[topRow + 1]:find("Cobblestone", 1, true), "top items, biggest first")
  os.queueEvent("monitor_touch", "monitor_1", 5, 5)
  settle()
  check(sc.ui:lines()[19]:find("1/2", 1, true), "and round to page 1")
  local vals, per = Stats.series(col.points, "items", 10, "last")
  eq(#vals, 10, "ten columns")
  eq(per, 180, "three minutes each")
  eq(vals[10], 520, "the newest value last")
  eq(Stats.series(col.points, "inn", 10, "sum")[10], 12, "sums of what moved in")
  eq(Stats.grew({ { cm = 10 }, { cm = 14 }, { cm = 20 } }, "cm", 120), 10, "growth over the last two points")
end)

test("the pickers know what each inventory and monitor is used for, free ones first", function()
  files["warehouse/parcels"] = textutils.serialise({ tasks = { { id = "t1", name = "Farm", inventory = "minecraft:chest_3" } } })
  files["warehouse/data/crafter/config"] = textutils.serialise({ input = "minecraft:chest_4", monitor = "monitor_2" })
  local cfg = { access = { { name = "Main", chest = "minecraft:chest_0", monitor = "monitor_0" } } }
  local peripherals = {
    { name = "minecraft:chest_0", size = 27, role = "access" }, { name = "minecraft:chest_3", size = 27, role = "free" },
    { name = "minecraft:chest_4", size = 54, role = "free" }, { name = "minecraft:chest_9", size = 27, role = "free" },
    { name = "create:item_vault_0", size = 80, role = "storage" }, { name = "minecraft:barrel_1", size = 27, role = "excluded" },
  }
  local rows = Uses.inventories("/warehouse", cfg, peripherals)
  local order = {}
  for i, r in ipairs(rows) do order[i] = r.name end
  eq(table.concat(order, " "), "minecraft:barrel_1 minecraft:chest_9 minecraft:chest_0 minecraft:chest_3 minecraft:chest_4 create:item_vault_0", "free first, then in use, then storage")
  eq(rows[1].text, "free (not storage)", "excluded is free for apps")
  eq(rows[2].text, "free", "free")
  eq(rows[3].text, "screen Main", "an access chest")
  eq(rows[3].screen, "Main", "and whose")
  eq(rows[4].text, "parcel Farm", "a Parcel task by name")
  eq(rows[5].text, "crafter input", "the crafter")
  eq(rows[6].text, "storage", "storage")
  check(not rows[2].busy and rows[3].busy and rows[6].busy, "busy flags")
  check(Uses.line(rows[4]):find("parcel Farm", 1, true), "a picker line says so")
  invs, monitors = {}, { monitor_2 = true, monitor_0 = true, monitor_5 = true }
  local mons = Uses.monitors("/warehouse", cfg)
  eq(mons[1].name .. " " .. mons[1].text, "monitor_5 free", "the free monitor first")
  eq(mons[2].name .. " " .. mons[2].text, "monitor_0 screen Main", "then the screen")
  eq(mons[3].name .. " " .. mons[3].text, "monitor_2 crafter monitor", "and the dashboard")
  eq(mons[2].screen, "Main", "the screen is named")
  eq(mons[3].screen, nil, "the dashboard monitor is no screen")
end)

print(string.format("%d passed, %d failed", passed, failures))
if failures > 0 then error("tests failed", 0) end
