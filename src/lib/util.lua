-- lib.util: small helpers shared by the service, its screens and the CLI.
local U = {}

-- An item key names one stackable kind of item: "minecraft:cobblestone", or
-- "minecraft:diamond_pickaxe@<nbt hash>" for items that carry NBT.
function U.keyOf(name, nbt)
  if nbt and nbt ~= "" then return name .. "@" .. nbt end
  return name
end

function U.splitKey(key)
  local name, nbt = key:match("^(.-)@(.+)$")
  if name then return name, nbt end
  return key, nil
end

-- "minecraft:polished_deepslate" -> "polished_deepslate"
function U.shortName(name)
  return (name:gsub("^[^:]+:", ""))
end

-- "minecraft:polished_deepslate" -> "Polished Deepslate"
function U.titleCase(name)
  local s = U.shortName(name):gsub("_", " ")
  return (s:gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
end

-- A count that fits in `width` characters: 12345 -> "12345", 123456 -> "123k".
function U.fmtCount(n, width)
  width = width or 6
  n = math.floor(n)
  local s = tostring(n)
  if #s <= width then return s end
  if n >= 1000000 then
    s = string.format("%.1fM", n / 1000000)
    if #s > width then s = math.floor(n / 1000000) .. "M" end
    return s
  end
  return math.floor(n / 1000) .. "k"
end

-- Pads or cuts s to exactly w characters.
function U.fit(s, w)
  s = tostring(s)
  if w <= 0 then return "" end
  if #s > w then return s:sub(1, w) end
  return s .. string.rep(" ", w - #s)
end

function U.rfit(s, w)
  s = tostring(s)
  if w <= 0 then return "" end
  if #s > w then return s:sub(1, w) end
  return string.rep(" ", w - #s) .. s
end

function U.center(s, w)
  s = tostring(s)
  if w <= 0 then return "" end
  if #s >= w then return s:sub(1, w) end
  local left = math.floor((w - #s) / 2)
  return string.rep(" ", left) .. s .. string.rep(" ", w - #s - left)
end

function U.size(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function U.clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

-- Case-insensitive plain-text search.
function U.contains(hay, needle)
  if needle == nil or needle == "" then return true end
  return tostring(hay):lower():find(tostring(needle):lower(), 1, true) ~= nil
end

-- Reads a table written by writeTable. Returns nil when missing or broken.
function U.readTable(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  local t = textutils.unserialise(s)
  if type(t) ~= "table" then return nil end
  return t
end

-- Writes a table so that a crash mid-write never leaves a broken file.
function U.writeTable(path, t)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local tmp = path .. ".tmp"
  local h = fs.open(tmp, "w")
  if not h then return false end
  h.write(textutils.serialise(t))
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

return U
