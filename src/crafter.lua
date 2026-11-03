-- crafter: automated crafting on the warehouse. Recipes are laid out in a
-- chest and scanned, and run by a crafty turtle (and your furnaces), with
-- every ingredient taken from the vault and every result put back. A
-- recipe can run always, so many items every so often, a number of times,
-- or make an ordered amount; multi-step recipes (planks, then sticks, then
-- a pickaxe) run as one job. See craft/engine.lua for how.
--
--   crafter                   start (in a background tab, with its control panel)
--   crafter startup           start on every boot
--   crafter ui                the control panel in this tab (the service runs elsewhere)
--   crafter status            the turtle, the smelter and every recipe
--   crafter list              the recipes and their stats
--   crafter scan [smelt]      what the recipe chest holds, as a step
--   crafter add <name> [smelt]   a new recipe from what the recipe chest holds
--   crafter order <recipe> <n>       make n of what the recipe makes
--   crafter run <recipe> [times]     run the recipe that many times
--   crafter stop <recipe>            stop it (orders, run and mode)
--   crafter quit                     stop the service
--   crafter set <recipe> key=value   mode=off|always|rate, count, rateCount, rateSeconds, name
--   crafter setup [key=value ..]     turtle, input, output, recipeChest, smeltIn, smeltOut, monitor, scale, smeltStall
--   crafter worker [in side] [out side]   on the crafty turtle (front, top or bottom)
--
-- Runs on the warehouse computer (it needs the warehouse service there).
-- The dashboard monitor is never one of the warehouse's access screens.

local args = { ... }
local programPath = "/" .. shell.getRunningProgram()
local ROOT = "/" .. fs.getDir(shell.getRunningProgram())
if ROOT == "//" or ROOT == "/." then ROOT = "/" end
local NAME = "crafter"

package.path = ROOT .. "/?.lua;" .. package.path

local util = require("lib.util")
local log = require("lib.log")
local Engine = require("craft.engine")
local Recipes = require("craft.recipes")

local DATA = fs.combine(ROOT, "data/crafter")

local function usage()
  print(NAME .. " - automated crafting on the warehouse")
  print("  " .. NAME .. "            start the service (with its control panel)")
  print("  " .. NAME .. " startup    start on every boot")
  print("  " .. NAME .. " ui         the control panel in this tab")
  print("  " .. NAME .. " status     turtle, smelter and recipes")
  print("  " .. NAME .. " list       the recipes")
  print("  " .. NAME .. " scan [smelt]        what the recipe chest holds, as a step")
  print("  " .. NAME .. " add <name> [smelt]  a new recipe from the recipe chest")
  print("  " .. NAME .. " order <recipe> <n>")
  print("  " .. NAME .. " run <recipe> [times]")
  print("  " .. NAME .. " stop <recipe>")
  print("  " .. NAME .. " quit                stop the service")
  print("  " .. NAME .. " set <recipe> mode=always|rate|off count= rateCount= rateSeconds= name=")
  print("  " .. NAME .. " setup [turtle= input= output= recipeChest= smeltIn= smeltOut= monitor= scale= smeltStall=]")
  print("  " .. NAME .. " worker [in] [out]   on the crafty turtle")
end

-- Talking to the running service (same computer, by events) -----------

local counter = 0
local function ask(op, a, timeout)
  counter = counter + 1
  local id = os.epoch("utc") .. "-" .. counter .. "-" .. math.random(1, 100000)
  os.queueEvent("crafter_request", { id = id, op = op, args = a or {} })
  local timer = os.startTimer(timeout or 5)
  while true do
    local ev, r = os.pullEvent()
    if ev == "crafter_reply" and type(r) == "table" and r.id == id then
      if r.ok then return r.result end
      return nil, r.error
    elseif ev == "timer" and r == timer then
      return nil, "the crafter is not running here (start it with '" .. NAME .. "')"
    end
  end
end

local function must(op, a)
  local r, err = ask(op, a)
  if not r then
    printError(tostring(err))
    return nil
  end
  return r
end

-- The service's side of that: ops the command line, the control panel
-- app and tests use.
local function serveLocal(engine, screen, console)
  local ops = {}
  ops.ping = function() return { name = "crafter", recipes = #engine.recipes } end
  ops.status = function() return engine:status() end
  ops.list = function() return engine:status().recipes end
  ops.recipe = function(a)
    local rec = engine:get(a.id or a.recipe)
    return { recipe = rec, summary = engine:summary(rec) }
  end
  ops.order = function(a)
    local rec = engine:get(a.id or a.recipe)
    engine:order(rec.id, a.count)
    return engine:summary(rec)
  end
  ops.run = function(a)
    local rec = engine:get(a.id or a.recipe)
    engine:runTimes(rec.id, a.times or a.count)
    return engine:summary(rec)
  end
  ops.stop = function(a)
    local rec = engine:get(a.id or a.recipe)
    engine:stop(rec.id)
    return engine:summary(rec)
  end
  ops.set = function(a)
    local rec = engine:get(a.id or a.recipe)
    engine:set(rec.id, a)
    return engine:summary(rec)
  end
  ops.scan = function(a)
    local step, err = engine:scan(a.kind)
    if not step then error(err, 0) end
    return step
  end
  -- A new recipe whose first step is what the recipe chest holds.
  ops.add = function(a)
    if type(a.name) ~= "string" or a.name == "" then error("give the recipe a name", 0) end
    if engine:find(a.name) then error("there is already a recipe called " .. a.name, 0) end
    local step, err = engine:scan(a.kind)
    if not step then error(err, 0) end
    local rec = engine:add({ name = a.name, steps = { step } })
    return { recipe = rec, summary = engine:summary(rec), step = Recipes.describe(step) }
  end
  ops.shutdown = function()
    os.queueEvent("crafter_stop")
    return true
  end
  ops["debug.screen"] = function() return screen and screen:screenLines() or nil end
  ops["debug.touch"] = function(a)
    os.queueEvent("crafter_touch", screen and screen.monitor, tonumber(a.x), tonumber(a.y))
    return true
  end
  ops["debug.console"] = function() return console and console:screenLines() or nil end
  ops["debug.click"] = function(a)
    os.queueEvent("crafter_click", tonumber(a.x), tonumber(a.y))
    return true
  end
  while true do
    local _, req = os.pullEvent("crafter_request")
    if type(req) == "table" and type(req.op) == "string" then
      local op = ops[req.op]
      local ok, res
      if op then ok, res = pcall(op, type(req.args) == "table" and req.args or {}) else ok, res = false, "unknown op: " .. req.op end
      if ok then
        os.queueEvent("crafter_reply", { id = req.id, ok = true, result = res })
      else
        os.queueEvent("crafter_reply", { id = req.id, ok = false, error = tostring(res):gsub("^[^%s:]+:%d+: ", "") })
      end
    end
  end
end

-- Commands ---------------------------------------------------------------

local function assignments(list, from, allowed)
  local out = {}
  for i = from, #list do
    local k, v = list[i]:match("^([%w_]+)=(.*)$")
    if not k then return nil, "expected key=value, got " .. list[i] end
    if allowed and not allowed[k] then return nil, "unknown setting: " .. k end
    out[k] = v
  end
  return out
end

local function printStatus(st)
  local t = st.turtle
  print("turtle: " .. tostring(t.state) .. (t.id and (" #" .. t.id) or "") .. (t.msg and (" (" .. t.msg .. ")") or ""))
  print("smelter: " .. (st.smelter.set and (st.smelter.items .. " items caught") or "not set up"))
  if #st.recipes == 0 then
    print("No recipes yet. Lay one out in the recipe chest and scan it on the control panel.")
    return
  end
  for _, s in ipairs(st.recipes) do
    print(string.format("%-4s %-16s %-7s made %-6d %s", s.id, s.name, s.mode, s.made, s.text))
  end
end

local function setupCommand(a)
  local cfg = Engine.loadConfig(ROOT)
  if #a < 2 then
    for _, k in ipairs({ "turtle", "input", "output", "recipeChest", "smeltIn", "smeltOut", "monitor", "scale", "smeltStall" }) do
      print(string.format("%-12s %s", k, tostring(cfg[k])))
    end
    print("Change with: " .. NAME .. " setup key=value ..   ('-' clears a setting)")
    return
  end
  local vals, err = assignments(a, 2, { turtle = true, input = true, output = true, recipeChest = true, smeltIn = true, smeltOut = true, monitor = true, scale = true, smeltStall = true })
  if not vals then
    printError(err)
    return
  end
  for k, v in pairs(vals) do
    if v == "" or v == "-" then
      cfg[k] = nil
    elseif k == "scale" or k == "smeltStall" or k == "turtle" then
      cfg[k] = tonumber(v) or v
    else
      cfg[k] = v
    end
  end
  if not Engine.saveConfig(ROOT, cfg) then
    printError("Could not write " .. Engine.configPath(ROOT))
    return
  end
  print("Saved. The running service applies it within a few seconds.")
end

local function install()
  local path = "/startup/crafter.lua"
  local h = fs.open(path, "w")
  h.writeLine("-- Added by crafter")
  h.writeLine("shell.setPath(shell.path() .. \":" .. ROOT .. "\")")
  if turtle then
    -- A turtle is the worker, with the sides it was last started with.
    local wcfg = util.readTable(fs.combine(ROOT, "data/crafter.worker")) or {}
    local sides = wcfg.input and (string.format(", %q", wcfg.input) .. (wcfg.output and wcfg.output ~= wcfg.input and string.format(", %q", wcfg.output) or "")) or ""
    h.writeLine("shell.run(" .. string.format("%q", programPath) .. ", \"worker\"" .. sides .. ")")
  else
    h.writeLine("shell.run(" .. string.format("%q", programPath) .. ")")
  end
  h.close()
  shell.setPath(shell.path() .. ":" .. ROOT)
  if turtle then
    print("The worker now starts on boot (" .. path .. ").")
  else
    print("The crafter now starts on boot (" .. path .. "), and 'crafter' works from any directory.")
  end
end

local function worker(a)
  local secure = require("lib.secure")
  local Worker = require("craft.worker")
  local key
  local cred = util.readTable(fs.combine(ROOT, "data/client"))
  if cred and cred.key then key = secure.decodeKey(cred.key) end
  if not key then key = secure.loadKey(fs.combine(ROOT, "data/secret")) end
  if not key then
    printError("This turtle is not paired with the warehouse. Run 'warehouse key disk' on the warehouse computer and 'wh pair disk' here, with a floppy.")
    return
  end
  local ok, err = pcall(Worker.run, { root = ROOT, key = key, input = a[2], output = a[3] })
  if not ok and not tostring(err):find("Terminated") then printError(tostring(err)) end
end

-- The service ------------------------------------------------------------

local function runService()
  local wh = require("api")
  local secure = require("lib.secure")
  local Link = require("craft.link")
  local Screen = require("craft.screen")
  local Console = require("craft.console")

  log.setup({ path = fs.combine(DATA, "log"), level = "info", echo = not term.isColor() })
  local vault
  while not vault do
    local ok, v = pcall(wh.connect, { mode = "local", probeTimeout = 3, timeout = 15 })
    if ok then
      vault = v
    else
      print("Waiting for the warehouse service on this computer...")
      sleep(5)
    end
  end
  local key = secure.loadKey(fs.combine(ROOT, "data/secret"))
  if not key then log.warn("no warehouse key yet (the warehouse makes one when it starts): the turtle cannot be reached until then") end
  local cfg = Engine.loadConfig(ROOT)
  local link = Link.new({ key = key, turtle = cfg.turtle, log = log.info })
  local engine = Engine.new({
    vault = vault, root = ROOT, log = log.info, link = link, cfg = cfg,
    onChange = function() os.queueEvent("crafter_changed") end,
  })
  local screen = Screen.new({ engine = engine, vault = vault, cfg = cfg, log = log.info })
  local console
  if term.isColor() then
    console = Console.new({
      engine = engine, vault = vault, root = ROOT, target = term.current(), log = log.info,
      onConfig = function(c) screen:reconfigure(c) end,
    })
  end
  -- Edits to the config file (crafter setup ...) are applied as they come.
  local function watchConfig()
    local function mtime()
      local p = Engine.configPath(ROOT)
      if not fs.exists(p) then return nil end
      local ok, attr = pcall(fs.attributes, p)
      return ok and attr and attr.modified or 0
    end
    local seen = mtime()
    while true do
      sleep(2)
      local m = mtime()
      if m ~= seen then
        seen = m
        local c = Engine.loadConfig(ROOT)
        engine:reconfigure(c)
        screen:reconfigure(c)
        if console then console.setup = nil end
        log.info("setup file changed; applied")
      end
    end
  end
  local tasks = {
    function() engine:run() end,
    function() screen:run() end,
    function() serveLocal(engine, screen, console) end,
    watchConfig,
    function()
      os.pullEvent("crafter_stop")
      engine:saveState(true)
      log.info("stopped")
      if screen.mon then pcall(screen.mon.clear) end
    end,
  }
  if console then
    tasks[#tasks + 1] = function()
      console:run()
      error("Terminated", 0)
    end
  else
    tasks[#tasks + 1] = function() while true do os.pullEvent("crafter_never") end end
  end
  parallel.waitForAny(table.unpack(tasks))
end

local cmd = args[1]
if cmd == "help" or cmd == "-h" or cmd == "--help" then
  usage()
elseif cmd == "status" then
  local st = must("status")
  if st then printStatus(st) end
elseif cmd == "list" then
  local st = must("status")
  if st then
    for _, s in ipairs(st.recipes) do
      print(string.format("%-4s %-16s %-7s %s", s.id, s.name, s.mode, s.text))
      print(string.format("     makes %s; made %d in %d runs, %d crafts, %d smelted, %d errors", tostring(s.result), s.made, s.runs, s.crafts, s.smelted, s.errors))
    end
    if #st.recipes == 0 then print("No recipes yet.") end
  end
elseif cmd == "scan" then
  local step = must("scan", { kind = args[2] })
  if step then
    print(Recipes.describe(step))
    if not step.result then print("(no result in slot 9: the crafter learns it by crafting once)") end
  end
elseif cmd == "add" then
  if not args[2] then
    printError("usage: " .. NAME .. " add <name> [smelt]   (lay the step out in the recipe chest first)")
  else
    local r = must("add", { name = args[2], kind = args[3] })
    if r then print("Recipe " .. r.recipe.name .. " (" .. r.recipe.id .. "): " .. r.step .. "; " .. r.summary.text) end
  end
elseif cmd == "order" then
  if not (args[2] and tonumber(args[3])) then
    printError("usage: " .. NAME .. " order <recipe> <n>")
  else
    local s = must("order", { recipe = args[2], count = tonumber(args[3]) })
    if s then print("Ordered " .. args[3] .. " x " .. tostring(s.result) .. " from " .. s.name .. ": " .. s.text) end
  end
elseif cmd == "run" then
  if not args[2] then
    printError("usage: " .. NAME .. " run <recipe> [times]")
  else
    local s = must("run", { recipe = args[2], times = tonumber(args[3]) })
    if s then print("Running " .. s.name .. ": " .. s.text) end
  end
elseif cmd == "stop" then
  if not args[2] then
    printError("usage: " .. NAME .. " stop <recipe>")
  else
    local s = must("stop", { recipe = args[2] })
    if s then print("Stopped " .. s.name) end
  end
elseif cmd == "quit" then
  if must("shutdown") then print("Stopping the crafter.") end
elseif cmd == "set" then
  local vals, err = args[2] and assignments(args, 3, { mode = true, count = true, rateCount = true, rateSeconds = true, name = true })
  if not vals then
    printError(err or ("usage: " .. NAME .. " set <recipe> mode=always|rate|off count=N rateCount=N rateSeconds=N name=X"))
  else
    vals.recipe = args[2]
    local s = must("set", vals)
    if s then print(s.name .. ": mode " .. s.mode .. ", " .. s.text) end
  end
elseif cmd == "setup" then
  setupCommand(args)
elseif cmd == "startup" then
  install()
elseif cmd == "worker" then
  worker(args)
elseif cmd == "ui" then
  if ask("ping") then
    printError("The crafter runs in another tab with its panel; click that tab.")
  else
    printError("The crafter is not running here. Start it with '" .. NAME .. "'.")
  end
elseif cmd == nil or cmd == "run-here" or cmd == "--tab" then
  local inTab = args[#args] == "--tab"
  if not inTab and cmd ~= "run-here" then
    if ask("ping", nil, 2) then
      print("The crafter is already running.")
      return
    end
  end
  if multishell and shell.openTab and not inTab and cmd ~= "run-here" and multishell.getCurrent() == multishell.getFocus() then
    local tab = shell.openTab(programPath, "--tab")
    if tab then
      -- The new tab is not focused: at boot, a focused tab would make the
      -- programs started after it (the warehouse) run inside the shell.
      multishell.setTitle(tab, NAME)
      print(NAME .. " started in tab " .. tab .. " with its control panel: click that tab to use it.")
      return
    end
  end
  if multishell then multishell.setTitle(multishell.getCurrent(), NAME) end
  term.clear()
  term.setCursorPos(1, 1)
  while true do
    local ok, err = pcall(runService)
    if not ok then
      if tostring(err):find("Terminated") then
        log.info("stopped")
        break
      end
      log.error("crafter crashed: " .. tostring(err) .. "; restarting in 5 s")
      sleep(5)
    else
      break
    end
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
else
  printError("Unknown command: " .. tostring(cmd))
  usage()
end
