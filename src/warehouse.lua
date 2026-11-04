-- warehouse: the storage service. Keeps an exact index of deep storage,
-- drives the access point screens and answers apps (lib.service).
--
--   warehouse              start (moves itself to a background tab)
--   warehouse startup      start on every boot, and put wh/warehouse on the path
--   warehouse setup        configure storage, screens and security, step by step
--   warehouse access ...   list, add, change or remove screens while it runs
--   warehouse storage ...  change what counts as storage while it runs
--   warehouse set ...      change presets, lock time, hostname, categories, ...
--   warehouse reload       apply a config file you edited by hand
--   warehouse key          show the key other computers pair with (key new / key disk)
--   warehouse status       what the running service holds
--   warehouse stop         stop the running service
--   warehouse log          show the end of the log
--
-- Every change is applied to the running service at once; the service also
-- notices edits to its config file by itself.

local args = { ... }
local programPath = "/" .. shell.getRunningProgram()
local ROOT = "/" .. fs.getDir(shell.getRunningProgram())
if ROOT == "//" or ROOT == "/." then ROOT = "/" end
local NAME = "warehouse"

package.path = ROOT .. "/?.lua;" .. package.path

local util = require("lib.util")
local config = require("lib.config")
local category = require("lib.category")
local log = require("lib.log")
local VERSION = require("lib.version")

local DATA = fs.combine(ROOT, "data")
local KEY_PATH = fs.combine(DATA, "secret")

local function usage()
  print(NAME .. " v" .. VERSION .. " - deep storage service")
  print("  " .. NAME .. "            start the service")
  print("  " .. NAME .. " startup    start on every boot")
  print("  " .. NAME .. " setup      configure storage, screens and security")
  print("  " .. NAME .. " access     list/add/set/remove screens (live)")
  print("  " .. NAME .. " storage    change what counts as storage (live)")
  print("  " .. NAME .. " set        presets, lock time, hostname, ... (live)")
  print("  " .. NAME .. " reload     apply a hand-edited config")
  print("  " .. NAME .. " ui         the control panel, in this tab")
  print("  " .. NAME .. " key        show the pairing key (key new, key disk)")
  print("  " .. NAME .. " status     what the service holds")
  print("  " .. NAME .. " stop       stop the service")
  print("  " .. NAME .. " log        show the log")
end

-- The running service on this computer, or nil (quietly).
local function quietClient()
  local wh = require("api")
  local ok, vault = pcall(wh.connect, { mode = "local", probeTimeout = 1 })
  if ok then return vault end
  return nil
end

local function client()
  local vault = quietClient()
  if not vault then printError("The service is not running here. Start it with '" .. NAME .. "'.") end
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

-- Config editing -------------------------------------------------------

local LISTS = { presets = "number", stackPresets = "number", types = "string", names = "string", exclude = "string" }
local STRINGS = { pin = true, name = true, hostname = true, chest = true, monitor = true, logLevel = true }

-- A value typed on the command line, as the config wants it. "" or "-"
-- clears a setting.
local function parseValue(key, v)
  if v == nil or v == "" or v == "-" then return nil end
  if v == "true" then return true end
  if v == "false" then return false end
  if LISTS[key] then
    local out = {}
    for s in v:gmatch("[^,%s]+") do out[#out + 1] = LISTS[key] == "number" and (tonumber(s) or s) or s end
    return out
  end
  if STRINGS[key] then return v end
  return tonumber(v) or v
end

-- Applies key=value words from list[from..] to target.
local function assignments(list, from, target, allowed)
  for i = from, #list do
    local k, v = list[i]:match("^([%w_]+)=(.*)$")
    if not k then return nil, "expected key=value, got " .. list[i] end
    if allowed and not allowed[k] then return nil, "unknown setting: " .. k end
    target[k] = parseValue(k, v)
  end
  return true
end

local function loadForEdit()
  local cfg, err = config.load(ROOT)
  if not cfg then
    printError(err .. ". Fix or delete the file first.")
    return nil
  end
  return cfg
end

local function describeApplied(res)
  local parts = {}
  for _, n in ipairs(res.screens.added) do parts[#parts + 1] = "screen " .. tostring(n) .. " added" end
  for _, n in ipairs(res.screens.updated) do parts[#parts + 1] = "screen " .. tostring(n) .. " changed" end
  for _, n in ipairs(res.screens.removed) do parts[#parts + 1] = "screen " .. tostring(n) .. " removed" end
  for _, n in ipairs(res.storage.added) do parts[#parts + 1] = "storage +" .. n end
  for _, n in ipairs(res.storage.removed) do parts[#parts + 1] = "storage -" .. n end
  for _, n in ipairs(res.notes) do parts[#parts + 1] = n end
  return #parts > 0 and table.concat(parts, ", ") or "nothing else changed"
end

-- Saves the config and has the running service pick it up.
local function saveAndApply(cfg)
  if not config.save(cfg) then
    printError("Could not write " .. cfg.path)
    return
  end
  local vault = quietClient()
  if not vault then
    print("Saved " .. cfg.path .. ". It applies when the service starts.")
    return
  end
  local ok, res = pcall(vault.reload)
  if not ok then
    printError("Saved, but the service could not apply it: " .. tostring(res))
    return
  end
  print("Applied: " .. describeApplied(res) .. ".")
end

local function accessCommand(a)
  local sub = a[2]
  local cfg = loadForEdit()
  if not cfg then return end
  cfg.access = cfg.access or {}
  if sub == nil or sub == "list" then
    if #cfg.access == 0 then
      print("No screens yet. Add one: " .. NAME .. " access add <name> <chest> <monitor> [pin=1234] [scale=0.5]")
      return
    end
    local live = {}
    local vault = quietClient()
    if vault then
      local ok, st = pcall(vault.access)
      if ok then
        for _, s in ipairs(st) do live[s.name or s.monitor] = s end
      end
    end
    for _, ap in ipairs(cfg.access) do
      local s = live[ap.name or ap.monitor]
      local state = ""
      if s then state = s.up and (s.locked and "  up, locked" or "  up") or "  DOWN" end
      print(string.format("%-10s %-20s %-10s%s%s%s", ap.name or "?", ap.chest, ap.monitor,
        ap.pin and " PIN" or "", ap.scale and (" x" .. ap.scale) or "", state))
    end
  elseif sub == "add" then
    local name, chest, monitor = a[3], a[4], a[5]
    if not (name and chest and monitor) then
      printError("usage: " .. NAME .. " access add <name> <chest> <monitor> [pin=..] [scale=..] [lockAfter=..]")
      return
    end
    if config.findAccess(cfg, name) then
      printError("There is already a screen called " .. name)
      return
    end
    local ap = { name = name, chest = chest, monitor = monitor }
    local ok, err = assignments(a, 6, ap, { pin = true, scale = true, lockAfter = true })
    if not ok then
      printError(err)
      return
    end
    cfg.access[#cfg.access + 1] = ap
    saveAndApply(cfg)
  elseif sub == "set" then
    local ap = a[3] and config.findAccess(cfg, a[3])
    if not ap then
      printError("No screen called " .. tostring(a[3]))
      return
    end
    local ok, err = assignments(a, 4, ap, { name = true, chest = true, monitor = true, pin = true, scale = true, lockAfter = true })
    if not ok then
      printError(err)
      return
    end
    saveAndApply(cfg)
  elseif sub == "remove" then
    local ap, i = a[3] and config.findAccess(cfg, a[3])
    if not ap then
      printError("No screen called " .. tostring(a[3]))
      return
    end
    table.remove(cfg.access, i)
    saveAndApply(cfg)
  else
    printError("usage: " .. NAME .. " access [list, add <name> <chest> <monitor> [key=value ..], set <name> key=value .., remove <name>]")
    print("keys: name chest monitor pin scale lockAfter   (pin= removes the PIN)")
  end
end

local function storageCommand(a)
  local sub = a[2]
  local cfg = loadForEdit()
  if not cfg then return end
  local function without(list, name)
    local out = {}
    for _, n in ipairs(list or {}) do
      if n ~= name then out[#out + 1] = n end
    end
    return out
  end
  local function with(list, name)
    local out = without(list, name)
    out[#out + 1] = name
    return out
  end
  local function show()
    print("Storage types: " .. table.concat(cfg.storage.types or {}, ", "))
    if #(cfg.storage.names or {}) > 0 then print("Also storage:  " .. table.concat(cfg.storage.names, ", ")) end
    if #(cfg.storage.exclude or {}) > 0 then print("Never storage: " .. table.concat(cfg.storage.exclude, ", ")) end
    local now = config.storageNames(cfg)
    print("Storage now:   " .. (#now > 0 and table.concat(now, ", ") or "nothing"))
  end
  local name = a[3]
  if sub == nil or sub == "list" then
    show()
    return
  elseif sub == "types" and name then
    cfg.storage.types = parseValue("types", name) or {}
  elseif sub == "add" and name then
    cfg.storage.names = with(cfg.storage.names, name)
    cfg.storage.exclude = without(cfg.storage.exclude, name)
  elseif sub == "remove" and name then
    cfg.storage.names = without(cfg.storage.names, name)
  elseif sub == "exclude" and name then
    cfg.storage.exclude = with(cfg.storage.exclude, name)
    cfg.storage.names = without(cfg.storage.names, name)
  elseif sub == "include" and name then
    cfg.storage.exclude = without(cfg.storage.exclude, name)
  else
    printError("usage: " .. NAME .. " storage [list, types <type,type>, add <inventory>, remove <inventory>, exclude <inventory>, include <inventory>]")
    return
  end
  show()
  saveAndApply(cfg)
end

local function setCommand(a)
  local cfg = loadForEdit()
  if not cfg then return end
  if #a < 2 then
    print(string.format("presets=%s stackPresets=%s", table.concat(cfg.presets, ","), table.concat(cfg.stackPresets, ",")))
    print(string.format("lockAfter=%s rescanSeconds=%s hostname=%s rednet=%s logLevel=%s",
      tostring(cfg.lockAfter), tostring(cfg.rescanSeconds), tostring(cfg.hostname), tostring(cfg.rednet), tostring(cfg.logLevel)))
    local n = 0
    for item, cat in pairs(cfg.categories or {}) do
      print("category " .. item .. " = " .. tostring(cat))
      n = n + 1
    end
    print("Change with: " .. NAME .. " set key=value ..   or   " .. NAME .. " set category <item> <block, item, resource, unstackable or ->")
    return
  end
  if a[2] == "category" then
    local item, cat = a[3], a[4]
    if not item or not (cat == "-" or category.valid(cat)) then
      printError("usage: " .. NAME .. " set category <item name> <block, item, resource, unstackable or ->")
      return
    end
    cfg.categories = cfg.categories or {}
    cfg.categories[item] = cat ~= "-" and cat or nil
    saveAndApply(cfg)
    return
  end
  local ok, err = assignments(a, 2, cfg, { presets = true, stackPresets = true, lockAfter = true, rescanSeconds = true, hostname = true, rednet = true, logLevel = true })
  if not ok then
    printError(err)
    return
  end
  saveAndApply(cfg)
end

-- Setup wizard ---------------------------------------------------------
-- The computer's screen cannot scroll back, so every step gets a fresh
-- screen with just what that step needs, and long lists pause before they
-- run off the top.

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

local function setup()
  local cfg = config.load(ROOT) or config.defaultsFor(ROOT)
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
  cfg.storage.types = parseValue("types", askLine("Storage types (comma separated)", table.concat(cfg.storage.types, ","))) or {}
  local extra = askLine("Extra storage inventories by name, or '-' for none", #cfg.storage.names > 0 and table.concat(cfg.storage.names, ",") or "-")
  cfg.storage.names = parseValue("names", extra) or {}
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
  print("")
  print("Storage: " .. table.concat(config.storageNames(cfg), ", "))
  for _, ap in ipairs(cfg.access) do
    print("Screen " .. ap.name .. ": " .. ap.chest .. " + " .. ap.monitor .. (ap.pin and " (PIN)" or ""))
  end
  print("")
  saveAndApply(cfg)
  if not quietClient() then print("Start with '" .. NAME .. "'. '" .. NAME .. " startup' starts it on every boot.") end
  print("Later changes: '" .. NAME .. " access', '" .. NAME .. " storage', '" .. NAME .. " set' apply at once.")
end

-- Other commands -------------------------------------------------------

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

-- The service -----------------------------------------------------------

-- Background work: applies config file edits, re-reads storage now and
-- then, and picks up inventories appearing or disappearing. Waiting on
-- the service drops events meant for this coroutine, so an overdue check
-- also runs on any other timer.
local function maintenance(service)
  local CHECK = 2
  local timer = os.startTimer(CHECK)
  local nextCheck = os.clock() + CHECK
  local rescanDue = os.clock() + (tonumber(service.cfg.rescanSeconds) or 0)
  local i = 0
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and (a == timer or os.clock() >= nextCheck) then
      timer = os.startTimer(CHECK)
      nextCheck = os.clock() + CHECK
      local m = config.modified(ROOT)
      if m ~= service.configSeen then
        service.configSeen = m
        local ok, res = service:request("reload")
        if not ok then log.warn("config changed but could not be applied: " .. tostring(res)) end
      end
      local period = tonumber(service.cfg.rescanSeconds) or 0
      if period > 0 and os.clock() >= rescanDue then
        rescanDue = os.clock() + period
        service:request("rediscover")
        local order = service.index.order
        if #order > 0 then
          i = i % #order + 1
          service:request("rescan", { inventory = order[i] })
        end
      end
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      service:request("rediscover")
    end
  end
end

local function runService()
  local Index = require("lib.index")
  local Service = require("lib.service")
  local transport = require("lib.transport")
  local Runner = require("lib.runner")

  local cfg, err = config.load(ROOT)
  if not cfg then
    cfg = config.defaultsFor(ROOT)
    log.setup({ path = fs.combine(DATA, "log"), level = cfg.logLevel })
    log.error(err .. "; running with defaults until the file is fixed")
  else
    log.setup({ path = fs.combine(DATA, "log"), level = cfg.logLevel })
    if not cfg.exists then log.warn("no config at " .. cfg.path .. "; run '" .. NAME .. " setup' (serving every create:item_vault for now)") end
  end

  local itemsPath = fs.combine(DATA, "items")
  local recentPath = fs.combine(DATA, "recent")
  local changedPath = fs.combine(DATA, "changed")
  local index = Index.new({
    storage = config.storageNames(cfg),
    details = util.readTable(itemsPath) or {},
    onDetails = function(d) util.writeTable(itemsPath, d) end,
    recent = util.readTable(recentPath) or {},
    onRecent = function(r) util.writeTable(recentPath, r) end,
    changed = util.readTable(changedPath) or {},
    onChanged = function(c) util.writeTable(changedPath, c) end,
    categories = cfg.categories,
    log = log.warn,
  })
  log.info("reading " .. #index.order .. " storage inventories, " .. index.totals.slots .. " slots")
  index:scanAll()
  log.info(string.format("%d items of %d kinds in %d/%d slots", index.totals.items, util.size(index.items), index.totals.used, index.totals.slots))

  local key = loadKey()
  if not key then
    log.info("making the warehouse key (see '" .. NAME .. " key')")
    key = newKey()
  end
  local runner = Runner.new()
  local service = Service.new({ index = index, cfg = cfg, log = log, root = ROOT, runner = runner, key = key })
  runner:add("worker", function() service:runWorker() end)
  runner:add("local", function() transport.runLocal(service) end)
  if cfg.rednet ~= false then service:startRednet() end
  service:applyScreens()
  service:applyStats()
  runner:add("maintenance", function() maintenance(service) end)
  -- Apps hosted inside the service run in their own task; a failure in one
  -- is logged and retried, and never takes the service down.
  local function hosted(name, body)
    runner:add(name, function()
      sleep(0.5)
      while true do
        local ok, err = pcall(body)
        if ok then break end
        if tostring(err):find("Terminated") then error(err, 0) end
        log.error(name .. " failed: " .. tostring(err) .. "; starting it again in 10 s")
        sleep(10)
      end
      while true do os.pullEvent("warehouse_never") end
    end)
  end
  -- The Parcel Service (see parcel.lua).
  if cfg.parcels ~= false then
    hosted("parcels", function()
      local wh = require("api")
      local Parcel = require("parcel")
      local vault = wh.connect({ mode = "local", probeTimeout = 3 })
      local p = Parcel.new({ vault = vault, root = ROOT, log = log.info })
      service.parcel = p -- the stat screens read its tasks and stats
      p:run()
    end)
  end
  -- The control panel, drawn in this tab (the log still goes to its file).
  if cfg.console ~= false and term.isColor() then
    log.echo = false
    local tabTerm = term.current()
    hosted("console", function()
      local wh = require("api")
      local ok, vault = pcall(wh.connect, { mode = "local", probeTimeout = 3, timeout = 4 })
      local Console = require("console")
      local con = Console.new({ vault = ok and vault or nil, root = ROOT, target = tabTerm })
      service.console = con
      con:run()
    end)
  end
  runner:run(function() return service.stopping end)
  return service.stopping
end

local cmd = args[1]
if cmd == "help" or cmd == "-h" or cmd == "--help" then
  usage()
elseif cmd == "setup" then
  setup()
elseif cmd == "access" or cmd == "screens" then
  accessCommand(args)
elseif cmd == "storage" then
  storageCommand(args)
elseif cmd == "set" then
  setCommand(args)
elseif cmd == "reload" then
  local vault = client()
  if vault then
    local ok, res = pcall(vault.reload)
    if ok then print("Applied: " .. describeApplied(res) .. ".") else printError(tostring(res)) end
  end
elseif cmd == "ui" or cmd == "console" or cmd == "panel" then
  local Console = require("console")
  local wh = require("api")
  local ok, vault = pcall(wh.connect, { mode = "local", probeTimeout = 1.5, timeout = 4 })
  local con = Console.new({ vault = ok and vault or nil, root = ROOT, standalone = true })
  con:run()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
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
    if quietClient() then
      print("The service is already running.")
      return
    end
  end
  if multishell and shell.openTab and not inTab and not foreground and multishell.getCurrent() == multishell.getFocus() then
    local tab = shell.openTab(programPath, "--tab")
    if tab then
      multishell.setTitle(tab, NAME)
      local cfg = config.load(ROOT)
      if cfg and cfg.console ~= false and term.isColor() then
        multishell.setFocus(tab)
        print(NAME .. " started in tab " .. tab .. " with the control panel. Click the shell tab to come back here.")
      else
        print(NAME .. " started in tab " .. tab .. ". '" .. NAME .. " status' shows what it holds.")
      end
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
