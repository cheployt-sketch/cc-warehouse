-- parcels: the Parcel Service on its own (the warehouse service hosts it
-- by default; run this on another computer, or with `parcels = false`).
--
--   parcels            run the tasks in /warehouse/parcels (Ctrl+T stops)
--   parcels list       show the tasks and their stats
--   parcels run <id>   run one task now (while the service hosts it)

local ROOT = "/" .. fs.getDir(shell.getRunningProgram())
package.path = ROOT .. "/?.lua;" .. package.path
local Parcel = require("parcel")
local wh = require("api")

local cmd, arg = ...
if cmd == "list" then
  local cfg = Parcel.loadConfig(ROOT)
  local stats = Parcel.loadStats(ROOT)
  if #(cfg.tasks or {}) == 0 then
    print("No parcel tasks. Add them on the control panel (Parcels page) or in " .. Parcel.configPath(ROOT))
    return
  end
  for _, t in ipairs(cfg.tasks) do
    local s = stats[t.id] or {}
    print(string.format("%-4s %-12s %-8s %-20s %s%s", t.id, tostring(t.name), t.kind, tostring(t.inventory), t.enabled == false and "off" or ("every " .. tostring(t.interval) .. "s"), t.folder and ("  [" .. t.folder .. "]") or ""))
    print("     items: " .. Parcel.formatItems(t.kind, t.items))
    print(string.format("     runs %d, moved %d, errors %d%s", s.runs or 0, s.moved or 0, s.errors or 0, s.lastMessage and (", last: " .. s.lastMessage) or ""))
  end
  return
elseif cmd == "run" then
  if not arg then
    print("usage: parcels run <task id>")
    return
  end
  os.queueEvent("parcel_run", arg)
  print("Asked the hosted parcel service to run " .. arg .. " now.")
  return
elseif cmd then
  print("usage: parcels [list, run <id>]")
  return
end

local vault = wh.connect()
local p = Parcel.new({ vault = vault, root = ROOT, log = print })
print("Parcel service running from " .. Parcel.configPath(ROOT) .. " (Ctrl+T stops)")
p:run()
