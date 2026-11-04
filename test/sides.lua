-- Crafter worker: which sides it takes from and drops into, with a stand-in
-- peripheral API (the sim suite drives the turtle through a stand-in link,
-- so this is the only place worker.lua itself runs). node test/run.cjs sides
local chests  -- [name] = { size, list }
local function chest(size, list) return { size = size, list = list or {} } end
local present = {}
peripheral = {
  isPresent = function(n) return chests[n] ~= nil and present[n] ~= false end,
  hasType = function(n, t) return chests[n] ~= nil and t == "inventory" end,
  getType = function(n) return chests[n] and "minecraft:chest" or nil end,
  call = function(n, m) local c = chests[n] or error("no " .. n) if m == "list" then return c.list elseif m == "size" then return c.size end end,
  getNames = function() return {} end,
}
turtle = {}
fs = { combine = function(a, b) return a .. "/" .. b end, open = function() return nil end }
rednet = {}
os = { getComputerID = function() return 17 end }
package.loaded["lib.secure"] = {}
package.loaded["lib.util"] = { shortName = function(s) return s end, readTable = function() end, writeTable = function() end }
package.loaded["craft.recipes"] = { OUTPUT_SLOT = 16 }
local W = dofile("src/craft/worker.lua")
local function say(...) end
local LOG = { [1] = { name = "minecraft:oak_log", count = 1 } }
local cases = {
  { "names given, input chest filled: found by contents",
    { ["minecraft:chest_26"] = chest(54, LOG), ["minecraft:chest_27"] = chest(54), top = chest(54, LOG), bottom = chest(54) },
    { input = "minecraft:chest_26", output = "minecraft:chest_27", grid = { { name = "minecraft:oak_log" } } }, "top", "bottom" },
  { "names given, both empty (ping): one of each, not front",
    { ["minecraft:chest_26"] = chest(54), ["minecraft:chest_27"] = chest(54), top = chest(54), bottom = chest(54) },
    { input = "minecraft:chest_26", output = "minecraft:chest_27" }, "top", "top", true },
  { "no names (old service): the chest holding the item is the input, the other the output",
    { top = chest(54, LOG), bottom = chest(54) },
    { grid = { { name = "minecraft:oak_log" } } }, "top", "bottom" },
  { "no names, nothing asked for (ping): any chest will do",
    { top = chest(54), bottom = chest(54) }, {}, "top", "bottom" },
  { "names the turtle cannot see (wireless modem): by the item again",
    { top = chest(54), bottom = chest(27, LOG) },
    { input = "minecraft:chest_26", output = "minecraft:chest_27", grid = { { name = "minecraft:oak_log" } } }, "bottom", "top" },
  { "one chest only: both sides are it",
    { bottom = chest(27, LOG) }, { grid = { { name = "minecraft:oak_log" } } }, "bottom", "bottom" },
  { "configured sides with chests and nothing to match: kept",
    { front = chest(27), top = chest(27) }, {}, "front", "front" },
}
local fails = 0
for _, c in ipairs(cases) do
  local name, world, req, wantIn, wantOut, loose = table.unpack(c)
  chests = world
  local s = W.sidesFor({ input = "front", output = "front", say = say }, req)
  local ok = s.input == wantIn and (loose or s.output == wantOut)
  if not ok then fails = fails + 1 end
  print((ok and "  ok - " or "  FAIL - ") .. name .. "  -> " .. s.input .. "/" .. s.output)
end
print(fails == 0 and "all sides cases pass" or (fails .. " failed"))
