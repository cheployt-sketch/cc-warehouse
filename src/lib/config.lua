-- lib.config: the service's configuration file and the roles of the
-- inventories on the network.
local util = require("lib.util")

local C = {}

C.defaults = {
  -- Deep storage. Every inventory on the network whose peripheral type is in
  -- `types` is storage, plus the ones in `names`, minus `exclude` and the
  -- access point chests.
  storage = { types = { "create:item_vault" }, names = {}, exclude = {} },
  -- Access points: { name = "Main", chest = "minecraft:chest_0",
  -- monitor = "monitor_0", scale = 1, pin = "1234", lockAfter = 120 }.
  -- Leave scale out to pick it automatically (0.5 on small monitors, 1
  -- otherwise). Without a pin the screen never locks; with one it locks
  -- again lockAfter seconds after the last tap (0: only when Lock is tapped).
  access = {},
  -- Relock time for access points that have a pin but no lockAfter of their own.
  lockAfter = 120,
  -- Item categories the screens could not work out by themselves:
  -- categories = { ["create:iron_sheet"] = "resource" }
  -- (block, item, resource or unstackable).
  categories = {},
  -- Quantity presets in the amount dialog: plain counts, and multiples of a stack.
  presets = { 1, 4, 8, 16, 32 },
  stackPresets = { 1, 2, 4, 8, 16 },
  -- Seconds between background re-reads of one storage inventory, to notice
  -- changes made behind the service's back (hoppers, players). 0 disables.
  rescanSeconds = 60,
  -- Serve apps on other computers over rednet (opens every attached modem).
  rednet = true,
  hostname = "vault",
  logLevel = "info",
}

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

-- The defaults, as a config of their own (used when the file is missing or
-- cannot be read).
function C.defaultsFor(root)
  local cfg = copy(C.defaults)
  cfg.path = fs.combine(root, "config")
  cfg.exists = false
  return cfg
end

-- Loads the config file over the defaults. Returns nil and a reason when
-- the file exists but cannot be read (half-written, or a typo), so that a
-- running service keeps its current settings instead of losing them.
function C.load(root)
  local path = fs.combine(root, "config")
  local cfg = copy(C.defaults)
  local file
  if fs.exists(path) then
    file = util.readTable(path)
    if not file then return nil, "cannot read " .. path .. " (not a valid Lua table)" end
    for k, v in pairs(file) do
      if k == "storage" and type(v) == "table" then
        for k2, v2 in pairs(v) do cfg.storage[k2] = v2 end
      else
        cfg[k] = v
      end
    end
  end
  cfg.path = path
  cfg.exists = file ~= nil
  return cfg
end

-- When the config file last changed (ms), or nil when it does not exist.
function C.modified(root)
  local path = fs.combine(root, "config")
  if not fs.exists(path) then return nil end
  local ok, attr = pcall(fs.attributes, path)
  if ok and type(attr) == "table" then return attr.modified or attr.modification or 0 end
  return 0
end

-- The access point with this name (or monitor), and its position.
function C.findAccess(cfg, name)
  for i, ap in ipairs(cfg.access or {}) do
    if ap.name == name or ap.monitor == name then return ap, i end
  end
  return nil
end

function C.save(cfg)
  local out = {}
  for k, v in pairs(cfg) do
    if k ~= "path" and k ~= "exists" then out[k] = v end
  end
  return util.writeTable(cfg.path, out)
end

-- Every inventory on the network with its role: "storage", "access"
-- (an access point chest), "excluded" or "free" (anything apps may use).
function C.peripherals(cfg)
  local access, exclude, names = {}, {}, {}
  for _, ap in ipairs(cfg.access or {}) do access[ap.chest] = ap.name or ap.monitor end
  for _, n in ipairs(cfg.storage.exclude or {}) do exclude[n] = true end
  for _, n in ipairs(cfg.storage.names or {}) do names[n] = true end
  local list = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "inventory") then
      local ptype = peripheral.getType(name)
      local role = "free"
      if access[name] then
        role = "access"
      elseif exclude[name] then
        role = "excluded"
      elseif names[name] then
        role = "storage"
      else
        for _, t in ipairs(cfg.storage.types or {}) do
          if ptype == t or peripheral.hasType(name, t) then
            role = "storage"
            break
          end
        end
      end
      local ok, size = pcall(peripheral.call, name, "size")
      list[#list + 1] = { name = name, type = ptype, size = ok and size or 0, role = role, access = access[name] }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

function C.storageNames(cfg)
  local out = {}
  for _, p in ipairs(C.peripherals(cfg)) do
    if p.role == "storage" then out[#out + 1] = p.name end
  end
  return out
end

function C.monitors()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "monitor") then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

return C
