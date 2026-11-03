-- wh: the warehouse from the command line. Works on the warehouse computer
-- and, after `wh pair`, on any computer with a modem.
--
--   wh                       status
--   wh items [filter]        what is stored
--   wh count <item>
--   wh get <item> <n> <to> [slot]     out of storage into inventory `to`
--   wh put <from> [slot]              from inventory `from` into storage
--   wh move <from> <slot> <to> [slot] [n]
--   wh compact, rescan [inventory], peripherals, help, watch, stop
--   wh pair <key>, pair disk, unpair

local args = { ... }
local ROOT = "/" .. fs.getDir(shell.getRunningProgram())
package.path = ROOT .. "/?.lua;" .. package.path
local wh = require("api")

local function usage()
  print("wh [status]              what the warehouse holds")
  print("wh items [filter]        stored items (most first)")
  print("wh count <item>")
  print("wh get <item> <n> <to> [slot]")
  print("wh put <from> [slot]")
  print("wh move <from> <slot> <to> [slot] [n]")
  print("wh compact, rescan [inv], peripherals, help, watch, stop")
  print("wh pair <key>, pair disk, unpair   (other computers)")
end

local cmd = args[1] or "status"

if cmd == "pair" then
  local keyS = args[2]
  if keyS == "disk" then
    local h = fs.exists("/disk/warehouse.key") and fs.open("/disk/warehouse.key", "r")
    if not h then
      printError("No /disk/warehouse.key. On the warehouse computer, run 'warehouse key disk' with the floppy in.")
      return
    end
    keyS = h.readAll()
    h.close()
  elseif not keyS then
    write("Warehouse key: ")
    keyS = read()
  end
  local ok, res = pcall(wh.pair, keyS, { hostname = args[3] })
  if not ok then
    printError(tostring(res))
  elseif res then
    print("Paired with warehouse #" .. res.id .. " (" .. tostring(res.hostname) .. "), " .. res.items .. " items stored.")
  else
    print("Key saved. No warehouse answered yet; it will be looked up when an app connects.")
  end
  return
elseif cmd == "unpair" then
  wh.unpair()
  print("Forgot the warehouse key.")
  return
elseif cmd == "usage" or cmd == "-h" or cmd == "--help" then
  usage()
  return
end

local ok, vault = pcall(wh.connect)
if not ok then
  printError(tostring(vault))
  return
end

local function run()
  if cmd == "status" then
    local p = vault.ping()
    local st = vault.stats()
    print(string.format("warehouse #%d (%s) v%s, up %d s", p.id, tostring(p.hostname), p.version, p.uptime))
    print(string.format("%d items of %d kinds in %d/%d slots (%d free)", st.items, st.types, st.used, st.slots, st.free))
    for _, inv in ipairs(st.inventories) do
      print(string.format("  %-28s %5d/%-5d", inv.name, inv.used, inv.size))
    end
  elseif cmd == "items" or cmd == "list" then
    local items, total = vault.items({ filter = args[2], limit = tonumber(args[3]) or 40 })
    for _, it in ipairs(items) do
      print(string.format("%7d  %-24s %s", it.count, it.displayName, it.key))
    end
    if total > #items then print("... " .. total .. " kinds in all; 'wh items <filter> <limit>' shows more") end
    if total == 0 then print("nothing stored" .. (args[2] and " that matches " .. args[2] or "")) end
  elseif cmd == "count" then
    print(vault.count(args[2] or ""))
  elseif cmd == "item" then
    local it = vault.item(args[2] or "")
    print(it.displayName .. " (" .. it.key .. "): " .. it.count .. " in " .. it.stacks .. " stacks, stack size " .. tostring(it.maxCount))
    for _, l in ipairs(it.locations) do print(string.format("  %-28s slot %3d  %d", l.inventory, l.slot, l.count)) end
  elseif cmd == "get" or cmd == "withdraw" then
    local moved, why = vault.withdraw(args[2], tonumber(args[3]), args[4], tonumber(args[5]))
    print("moved " .. moved .. (why and (" (" .. why .. ")") or ""))
  elseif cmd == "put" or cmd == "deposit" then
    local moved, items, why = vault.deposit(args[2], { slot = tonumber(args[3]) })
    print("stored " .. moved .. (why and (" (" .. why .. ")") or ""))
    for key, n in pairs(items) do print("  " .. n .. " x " .. key) end
  elseif cmd == "move" then
    print("moved " .. vault.move(args[2], tonumber(args[3]), args[4], tonumber(args[5]), tonumber(args[6])))
  elseif cmd == "compact" then
    print("compact: " .. vault.compact() .. " moves")
  elseif cmd == "rescan" then
    local st = vault.rescan(args[2])
    print(string.format("%d items of %d kinds in %d/%d slots", st.items, st.types, st.used, st.slots))
  elseif cmd == "peripherals" then
    for _, p in ipairs(vault.peripherals()) do
      print(string.format("%-28s %4d  %-8s %s", p.name, p.size, p.role, p.access or ""))
    end
  elseif cmd == "help" then
    for _, h in ipairs(vault.help()) do
      print(h[1] .. "(" .. h[2] .. ")")
      print("   " .. h[3])
    end
  elseif cmd == "watch" then
    print("Watching for changes (Ctrl+T stops)")
    while true do
      local ev = vault.pullEvent()
      if ev and ev.type == "change" then
        for _, c in ipairs(ev.items) do
          print(string.format("%+6d  %-30s now %d", c.delta, c.key, c.count))
        end
      end
    end
  elseif cmd == "stop" then
    vault.shutdown()
    print("Stopping the service.")
  else
    printError("Unknown command: " .. cmd)
    usage()
  end
end

local ok2, err = pcall(run)
if not ok2 then printError(tostring(err)) end
