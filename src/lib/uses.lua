-- lib.uses: what every inventory and monitor on the network is used for,
-- read from the files on this computer: the warehouse config (storage and
-- the access points), the Parcel tasks and the crafter's setup. The
-- pickers on the control panels show it, free ones first, so a chest a
-- task or the crafter already works with is never taken for free.

local util = require("lib.util")
local config = require("lib.config")

local U = {}

-- The crafter's settings that name a chest or a monitor (its config file
-- is craft.engine's; reading it here keeps the engine out of the
-- warehouse panel).
local CRAFTER = {
  { "input", "crafter input" }, { "output", "crafter output" }, { "recipeChest", "crafter recipes" },
  { "smeltIn", "crafter smelter in" }, { "smeltOut", "crafter smelter out" }, { "monitor", "crafter monitor" },
}

-- name -> list of { kind = "screen" | "parcel" | "crafter", what, text }.
-- cfg is the warehouse config (loaded from root when nil).
function U.gather(root, cfg)
  cfg = cfg or config.load(root) or config.defaultsFor(root)
  local uses = {}
  local function add(name, kind, what)
    if type(name) ~= "string" or name == "" then return end
    uses[name] = uses[name] or {}
    local list = uses[name]
    list[#list + 1] = { kind = kind, what = what, text = kind .. " " .. what }
  end
  for _, ap in ipairs(cfg.access or {}) do
    add(ap.chest, "screen", tostring(ap.name or ap.monitor))
    add(ap.monitor, "screen", tostring(ap.name or ap.monitor))
  end
  local parcels = util.readTable(fs.combine(root, "parcels")) or {}
  for _, t in ipairs(parcels.tasks or {}) do add(t.inventory, "parcel", tostring(t.name or t.id)) end
  local crafter = util.readTable(fs.combine(root, "data/crafter/config")) or {}
  for _, c in ipairs(CRAFTER) do add(crafter[c[1]], "crafter", c[2]:sub(9)) end
  return uses
end

local function joined(list)
  local parts = {}
  for _, u in ipairs(list) do parts[#parts + 1] = u.text end
  return table.concat(parts, ", ")
end

-- The screen (access point) that uses a thing, if one does.
local function screenOf(list)
  for _, u in ipairs(list) do
    if u.kind == "screen" then return u.what end
  end
  return nil
end

-- The inventories for a picker, from the service's `peripherals` list
-- (name, size, role): { name, size, role, uses, screen, busy, text },
-- free ones first, then those in use, then storage; by name within.
function U.inventories(root, cfg, peripherals)
  local uses = U.gather(root, cfg)
  local rows = {}
  for _, p in ipairs(peripherals or {}) do
    local list = uses[p.name] or {}
    local rank, text
    if p.role == "storage" then
      rank, text = 3, "storage" .. (#list > 0 and (", " .. joined(list)) or "")
    elseif #list > 0 then
      rank, text = 2, joined(list)
    elseif p.role == "excluded" then
      rank, text = 1, "free (not storage)"
    else
      rank, text = 1, "free"
    end
    rows[#rows + 1] = { name = p.name, size = p.size, role = p.role, uses = list, screen = screenOf(list), busy = rank > 1, rank = rank, text = text }
  end
  table.sort(rows, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.name < b.name
  end)
  return rows
end

-- The monitors on the network for a picker: { name, uses, screen, busy,
-- text }, free ones first.
function U.monitors(root, cfg)
  local uses = U.gather(root, cfg)
  local rows = {}
  for _, name in ipairs(config.monitors()) do
    local list = uses[name] or {}
    rows[#rows + 1] = { name = name, uses = list, screen = screenOf(list), busy = #list > 0, text = #list > 0 and joined(list) or "free" }
  end
  table.sort(rows, function(a, b)
    if a.busy ~= b.busy then return not a.busy end
    return a.name < b.name
  end)
  return rows
end

-- One picker line: the name, the size (for inventories) and the uses.
function U.line(r)
  if r.size then return util.fit(r.name, 22) .. util.rfit(r.size, 4) .. " " .. r.text end
  return util.fit(r.name, 22) .. " " .. r.text
end

return U
