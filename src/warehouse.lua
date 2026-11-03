-- warehouse: the storage service. Keeps an exact index of deep storage,
-- drives the access point screens and answers apps (lib.service).
--
--   warehouse              start (moves itself to a background tab)
--   warehouse startup      start on every boot, and put wh/warehouse on the path
--   warehouse setup        configure storage, screens and security, step by step
--   warehouse key          show the key other computers pair with (key new / key disk)
--   warehouse status       what the running service holds
--   warehouse stop         stop the running service
--   warehouse log          show the end of the log

local args = { ... }
local programPath = "/" .. shell.getRunningProgram()
local ROOT = "/" .. fs.getDir(shell.getRunningProgram())
if ROOT == "//" or ROOT == "/." then ROOT = "/" end
local NAME = "warehouse"

package.path = ROOT .. "/?.lua;" .. package.path

local util = require("lib.util")
local config = require("lib.config")
local log = require("lib.log")
local VERSION = require("lib.version")

local DATA = fs.combine(ROOT, "data")
local KEY_PATH = fs.combine(DATA, "secret")

local function usage()
  print(NAME .. " v" .. VERSION .. " - deep storage service")
  print("  " .. NAME .. "            start the service")
  print("  " .. NAME .. " startup    start on every boot")
  print("  " .. NAME .. " setup      configure storage, screens and security")
  print("  " .. NAME .. " key        show the pairing key (key new, key disk)")
  print("  " .. NAME .. " status     what the service holds")
  print("  " .. NAME .. " stop       stop the service")
  print("  " .. NAME .. " log        show the log")
end

local function client()
  local wh = require("api")
  local ok, vault = pcall(wh.connect, { mode = "local", probeTimeout = 2 })
  if not ok then
    printError("The service is not running here. Start it with '" .. NAME .. "'.")
    return nil
  end
  return vault
end

local function loadKey()
  local secure = require("lib.secure")
  return secure.loadKey(KEY_PATH)
end

local function newKey()
  local secure = require("lib.secure")
  local key = secure.newKey()
  secure.saveKey(KEY_PATH, key)
  return key
end

-- Setup wizard helpers. The computer's screen cannot scroll back, so every
-- step gets a fresh screen with just what that step needs, and long lists
-- pause before they run off the top.

local function clearScreen(title)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  if term.isColor() then term.setTextColor(colors.yellow) end
  print(title)
  term.setTextColor(colors.white)
end

-- Waits for Enter (other keys would leave stray characters for the next read()).
local function waitEnter(prompt)
  write(prompt or "Enter to continue")
  while true do
    local _, k = os.pullEvent("key")
    if k == keys.enter then break end
  end
  local _, y = term.getCursorPos()
  term.setCursorPos(1, y)
  term.clearLine()
end

-- Prints lines, pausing whenever the screen would overflow (keeping
-- `reserve` rows free below for the prompt that follows).
local function printLines(lines, reserve)
  local w, h = term.getSize()
  local used = 0
  for _, line in ipairs(lines) do
    local rows = math.max(1, math.ceil(#line / w))
    if used + rows > h - (reserve or 2) - 1 then
      waitEnter("-- Enter for more --")
      term.clear()
      term.setCursorPos(1, 1)
      used = 0
    end
    print(line)
    used = used + rows
  end
end

local function askLine(prompt, default)
  write(prompt .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local s = read()
  if s == nil then return default end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return default end
  return s
end

local function yesNo(prompt, default)
  local s = askLine(prompt .. (default and " (Y/n)" or " (y/N)"), nil)
  if s == nil then return default end
  s = s:lower()
  if s == "y" or s == "yes" then return true end
  if s == "n" or s == "no" then return false end
  return default
end

local function list(t)
  local out = {}
  for s in tostring(t or ""):gmatch("[^,%s]+") do out[#out + 1] = s end
  return out
end

local function setup()
  local cfg = config.load(ROOT)
  local STEPS = 4

  -- 1. what is on the network
  clearScreen("Warehouse setup 1/" .. STEPS .. ": the network")
  local inventories = config.peripherals(cfg)
  if #inventories == 0 then
    printError("No inventories found. Connect vaults and chests with network cable and wired modems, and right-click the modems to turn them on.")
    return
  end
  local lines = { "Inventories reachable from this computer:" }
  for i, p in ipairs(inventories) do lines[#lines + 1] = string.format("%2d. %-24s %4d  %s", i, p.name, p.size, p.role) end
  local monitors = config.monitors()
  lines[#lines + 1] = "Monitors: " .. (#monitors > 0 and table.concat(monitors, ", ") or "none")
  printLines(lines, 2)
  print("")
  waitEnter("Enter to continue")

  -- 2. storage
  clearScreen("Warehouse setup 2/" .. STEPS .. ": deep storage")
  print("Storage is every inventory whose peripheral type is in the list, plus any names you add. Access point chests are never storage.")
  print("")
  print("Storage now: " .. (#config.storageNames(cfg) > 0 and table.concat(config.storageNames(cfg), ", ") or "nothing"))
  print("")
  cfg.storage.types = list(askLine("Storage types (comma separated)", table.concat(cfg.storage.types, ",")))
  local extra = askLine("Extra storage inventories by name, or '-' for none", #cfg.storage.names > 0 and table.concat(cfg.storage.names, ",") or "-")
  cfg.storage.names = extra == "-" and {} or list(extra)
  print("")
  print("Storage will be: " .. (#config.storageNames(cfg) > 0 and table.concat(config.storageNames(cfg), ", ") or "nothing (check the types)"))
  waitEnter("Enter to continue")

  -- 3. security
  clearScreen("Warehouse setup 3/" .. STEPS .. ": security")
  print("On a server, a PIN keeps strangers from emptying the vault from a screen. In a single-player world you can skip it: screens then never lock.")
  print("")
  local usePin = yesNo("Protect the screens with a PIN?", false)
  local relock = 0
  if usePin then
    print("")
    print("A screen can lock again by itself after some time without taps, or only when its Lock button is tapped.")
    relock = tonumber(askLine("Seconds until a screen locks again (0: only via the Lock button)", tostring(cfg.lockAfter or 120))) or 120
  end
  cfg.lockAfter = relock

  -- 4. access points
  local candidates = {}
  for _, p in ipairs(inventories) do
    if p.role ~= "storage" then candidates[#candidates + 1] = p end
  end
  if #candidates == 0 then candidates = inventories end
  cfg.access = {}
  while true do
    local n = #cfg.access + 1
    clearScreen("Warehouse setup 4/" .. STEPS .. ": access point " .. n)
    print("An access point is a chest and a monitor on the network.")
    local shown = {}
    for i, p in ipairs(candidates) do shown[#shown + 1] = string.format("  chest %d: %s", i, p.name) end
    for i, m in ipairs(monitors) do shown[#shown + 1] = string.format("  monitor %d: %s", i, m) end
    printLines(shown, 6)
    print("")
    local name = askLine("Name (blank to finish)", n == 1 and "Main" or nil)
    if not name then break end
    local function pick(prompt, options)
      local s = askLine(prompt)
      if not s then return nil end
      local k = tonumber(s)
      if k and options[k] then return type(options[k]) == "table" and options[k].name or options[k] end
      return s
    end
    local chest = pick("Chest (number or name)", candidates)
    local monitor = pick("Monitor (number or name)", monitors)
    if not chest or not monitor then
      print("Skipped: an access point needs both a chest and a monitor.")
      waitEnter("Enter to continue")
    else
      local ap = { name = name, chest = chest, monitor = monitor }
      ap.scale = tonumber(askLine("Monitor text scale (0.5 small, 1 normal, blank: automatic)", nil) or "")
      if usePin then
        ap.pin = askLine("PIN for this screen (digits)", nil)
        ap.lockAfter = relock
      end
      cfg.access[n] = ap
      if not yesNo("Add another access point?", false) then break end
    end
  end

  clearScreen("Warehouse setup: done")
  cfg.hostname = askLine("Name of this warehouse on the network", cfg.hostname)
  config.save(cfg)
  print("")
  print("Saved " .. cfg.path)
  print("Storage: " .. table.concat(config.storageNames(cfg), ", "))
  for _, ap in ipairs(cfg.access) do
    print("Screen " .. ap.name .. ": " .. ap.chest .. " + " .. ap.monitor .. (ap.pin and " (PIN)" or ""))
  end
  print("")
  print("Start with '" .. NAME .. "'. '" .. NAME .. " startup' starts it on every boot.")
  if client() then print("The service is running: run '" .. NAME .. " stop' and start it again to use the new settings.") end
end

local function showKey(sub)
  local secure = require("lib.secure")
  local key = loadKey()
  if sub == "new" or not key then
    if key then
      print("Making a new key. Computers paired with the old one must run 'wh pair' again.")
    else
      print("Making the warehouse key.")
    end
    key = newKey()
    if sub == "new" then
      print("Restart the service for the new key to be used.")
    end
  end
  if sub == "disk" then
    if not fs.exists("/disk") then
      printError("No floppy disk in a drive attached to this computer.")
      return
    end
    secure.saveKey("/disk/warehouse.key", key)
    print("Written to /disk/warehouse.key. On an app computer with the disk, run: wh pair disk")
    return
  end
  print("Warehouse key (fingerprint " .. secure.fingerprint(key) .. "):")
  print(secure.encodeKey(key))
  print("")
  print("On another computer: wh pair <key>   (or 'warehouse key disk' + 'wh pair disk')")
  print("Anyone holding this key can use the warehouse, so share it only with your own computers.")
end

local function status()
  local vault = client()
  if not vault then return end
  local p = vault.ping()
  local st = vault.stats()
  print(string.format("warehouse v%s on #%d (%s), up %d s", p.version, p.id, p.hostname, p.uptime))
  print(string.format("%d items of %d kinds in %d/%d slots (%d free)", st.items, st.types, st.used, st.slots, st.free))
  for _, inv in ipairs(st.inventories) do
    print(string.format("  %-30s %4d/%-4d", inv.name, inv.used, inv.size))
  end
  for _, ap in ipairs(vault.access()) do
    print(string.format("  screen %-12s %s %s%s", ap.name, ap.monitor, ap.up and "up" or "DOWN", ap.locked and ", locked" or ""))
  end
end

local function showLog()
  local path = fs.combine(DATA, "log")
  if not fs.exists(path) then
    print("No log yet.")
    return
  end
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  local lines = {}
  for line in s:gmatch("[^\n]+") do lines[#lines + 1] = line end
  for i = math.max(1, #lines - 15), #lines do print(lines[i]) end
end

local function install()
  local path = "/startup/warehouse.lua"
  local h = fs.open(path, "w")
  h.writeLine("-- Added by warehouse")
  h.writeLine("shell.setPath(shell.path() .. \":" .. ROOT .. "\")")
  h.writeLine("shell.run(" .. string.format("%q", programPath) .. ")")
  h.close()
  shell.setPath(shell.path() .. ":" .. ROOT)
  print("The service now starts on boot (" .. path .. "), and 'wh' and 'warehouse' work from any directory.")
end

-- The service itself.
local function runService()
  local Index = require("lib.index")
  local Service = require("lib.service")
  local transport = require("lib.transport")
  local Access = require("lib.access")

  local cfg = config.load(ROOT)
  log.setup({ path = fs.combine(DATA, "log"), level = cfg.logLevel })
  if not cfg.exists then log.warn("no config at " .. cfg.path .. "; run '" .. NAME .. " setup' (serving every create:item_vault for now)") end

  local itemsPath = fs.combine(DATA, "items")
  local recentPath = fs.combine(DATA, "recent")
  local index = Index.new({
    storage = config.storageNames(cfg),
    details = util.readTable(itemsPath) or {},
    onDetails = function(d) util.writeTable(itemsPath, d) end,
    recent = util.readTable(recentPath) or {},
    onRecent = function(r) util.writeTable(recentPath, r) end,
    categories = cfg.categories,
    log = log.warn,
  })
  log.info("reading " .. #index.order .. " storage inventories, " .. index.totals.slots .. " slots")
  index:scanAll()
  log.info(string.format("%d items of %d kinds in %d/%d slots", index.totals.items, util.size(index.items), index.totals.used, index.totals.slots))

  local service = Service.new({ index = index, cfg = cfg, log = log, root = ROOT })
  local tasks = {
    function() service:runWorker() end,
    function() transport.runLocal(service) end,
    function() os.pullEvent("warehouse_stop") end,
  }
  if cfg.rednet ~= false then
    local key = loadKey()
    if not key then
      log.info("making the warehouse key (see '" .. NAME .. " key')")
      key = newKey()
    end
    tasks[#tasks + 1] = function() transport.runRednet(service, cfg, key) end
  end
  for i, apCfg in ipairs(cfg.access or {}) do
    local ap = Access.new(service, apCfg, cfg)
    service.access[i] = ap
    if apCfg.name then service.access[apCfg.name] = ap end
    tasks[#tasks + 1] = function() ap:run() end
  end
  tasks[#tasks + 1] = function()
    -- Background re-reads. Waiting on the service drops events meant for
    -- this coroutine, so an overdue pass runs on any event, not only on
    -- its own timer.
    local period = tonumber(cfg.rescanSeconds) or 0
    local due = period > 0 and (os.clock() + period) or math.huge
    local timer = period > 0 and os.startTimer(period) or nil
    local i = 0
    while true do
      local ev, a = os.pullEvent()
      if (ev == "timer" and a == timer) or os.clock() >= due then
        service:request("rediscover")
        if #index.order > 0 then
          i = i % #index.order + 1
          service:request("rescan", { inventory = index.order[i] })
        end
        if period > 0 then
          timer = os.startTimer(period)
          due = os.clock() + period
        end
      elseif ev == "peripheral" or ev == "peripheral_detach" then
        service:request("rediscover")
      end
    end
  end
  parallel.waitForAny(table.unpack(tasks))
  return service.stopping
end

local cmd = args[1]
if cmd == "help" or cmd == "-h" or cmd == "--help" then
  usage()
elseif cmd == "setup" then
  setup()
elseif cmd == "key" then
  showKey(args[2])
elseif cmd == "status" then
  status()
elseif cmd == "log" then
  showLog()
elseif cmd == "startup" then
  install()
elseif cmd == "stop" then
  local vault = client()
  if vault then
    vault.shutdown()
    print("Stopping.")
  end
elseif cmd == nil or cmd == "run" or cmd == "--tab" then
  local inTab = args[#args] == "--tab"
  local foreground = cmd == "run"
  if not inTab and not foreground then
    local wh = require("api")
    local ok = pcall(wh.connect, { mode = "local", probeTimeout = 1.5 })
    if ok then
      print("The service is already running.")
      return
    end
  end
  if multishell and shell.openTab and not inTab and not foreground and multishell.getCurrent() == multishell.getFocus() then
    local tab = shell.openTab(programPath, "--tab")
    if tab then
      multishell.setTitle(tab, NAME)
      print(NAME .. " started in tab " .. tab .. ". '" .. NAME .. " status' shows what it holds.")
      return
    end
  end
  if multishell then multishell.setTitle(multishell.getCurrent(), NAME) end
  term.clear()
  term.setCursorPos(1, 1)
  print(NAME .. " v" .. VERSION .. " starting (Ctrl+T stops it)")
  while true do
    local ok, stopped = pcall(runService)
    pcall(rednet.unhost, "warehouse")
    if ok and stopped then
      log.info("stopped")
      break
    elseif not ok then
      if tostring(stopped):find("Terminated") then
        log.info("terminated")
        break
      end
      log.error("service crashed: " .. tostring(stopped) .. "; restarting in 3 s")
      sleep(3)
    else
      log.warn("service ended unexpectedly; restarting in 3 s")
      sleep(3)
    end
  end
else
  printError("Unknown command: " .. tostring(cmd))
  usage()
end
