-- lib.category: which group an item belongs to on the screens, and the
-- colour of each group.
--
--   unstackable  anything with a stack size of 1 (tools, armour, ...)
--   resource     ingredients and raw materials (ingots, dusts, gems, ...)
--   block        placeable blocks
--   item         everything else (food, seeds, arrows, ...)
--   recent       not a group of its own: the items moved most recently
--
-- The creative tabs an item sits in (itemGroups) decide for vanilla and
-- most mods: anything in Ingredients is a resource (redstone sits in both
-- Redstone Blocks and Ingredients), then the block tabs make blocks. Item
-- tags and the item name settle the rest, for mods with one tab for
-- everything. The config can override single items:
-- categories = { ["create:iron_sheet"] = "resource" }.

local util = require("lib.util")

local C = {}

C.ORDER = { "recent", "block", "item", "resource", "unstackable" }
C.LABELS = { all = "All", recent = "Recent", block = "Blocks", item = "Items", resource = "Resources", unstackable = "Unstack" }
C.COLORS = { block = "lightBlue", item = "white", resource = "yellow", unstackable = "magenta", recent = "lime", all = "white" }

local BLOCK_GROUPS = { building_blocks = true, natural_blocks = true, functional_blocks = true, redstone_blocks = true, colored_blocks = true, palettes = true }
local RESOURCE_GROUPS = { ingredients = true, materials = true, resources = true }
local ITEM_GROUPS = { tools_and_utilities = true, combat = true, food_and_drinks = true, spawn_eggs = true }

local RESOURCE_TAGS = {
  "c:ingots", "c:nuggets", "c:dusts", "c:gems", "c:raw_materials", "c:plates", "c:rods", "c:wires", "c:coal", "minecraft:coals",
  "c:leather", "c:string", "c:strings", "c:slimeballs", "c:slime_balls", "c:gunpowder", "c:gunpowders", "c:bones", "c:feathers",
  "c:ender_pearls", "c:crops", "forge:ingots", "forge:nuggets", "forge:dusts", "forge:gems", "forge:plates",
  "forge:rods", "forge:raw_materials", "forge:string", "forge:leather",
}
local ITEM_TAGS = { "c:seeds", "c:foods", "c:tools", "c:armors", "c:buckets", "c:dyes", "c:music_discs", "c:potions", "minecraft:arrows", "forge:seeds", "forge:dyes" }
local BLOCK_TAGS = {
  "minecraft:logs", "minecraft:planks", "minecraft:slabs", "minecraft:stairs", "minecraft:walls", "minecraft:stone_bricks",
  "minecraft:dirt", "minecraft:sand", "minecraft:wool", "minecraft:wool_carpets", "minecraft:leaves", "minecraft:saplings",
  "minecraft:doors", "minecraft:trapdoors", "minecraft:fences", "minecraft:fence_gates", "minecraft:buttons", "minecraft:rails",
  "minecraft:beds", "minecraft:banners", "minecraft:candles", "minecraft:flowers", "minecraft:terracotta", "minecraft:shulker_boxes",
  "minecraft:stone_crafting_materials", "minecraft:anvil", "minecraft:signs",
  "c:storage_blocks", "c:glass_blocks", "c:glass_panes", "c:cobblestones", "c:stones", "c:sands", "c:gravels", "c:ores",
  "c:chests", "c:barrels", "c:bookshelves", "c:concretes", "c:glazed_terracottas", "c:fences", "c:fence_gates",
  "forge:storage_blocks", "forge:glass", "forge:glass_panes", "forge:cobblestone", "forge:stone", "forge:sand", "forge:gravel",
  "forge:ores", "forge:chests",
}

local BLOCK_SUFFIX = {
  "_block", "_ore", "_log", "_wood", "_stem", "_hyphae", "_planks", "_slab", "_stairs", "_wall", "_bricks", "_tiles", "_fence", "_gate",
  "_door", "_trapdoor", "_glass", "_pane", "_wool", "_carpet", "_concrete", "_concrete_powder", "_terracotta", "_leaves", "_sapling",
  "_sand", "_sandstone", "stone", "_dirt", "dirt", "gravel", "_ice", "_snow", "_mud", "_moss", "_nylium", "_roots", "_mushroom", "_fungus",
  "_casing", "_pipe", "_cogwheel", "_shaft", "_frame", "_tank", "_chest", "_barrel", "_furnace", "_table", "_lamp", "_torch", "_bed",
  "_sign", "_rail", "_piston", "_chute", "_funnel", "_depot", "_basin", "_bearing", "_press", "_mixer", "_saw", "_drill", "_pump",
  "_valve", "_wheel", "_gearbox", "_tunnel", "_crate", "_vault", "_shelf", "_bookshelf", "_lantern", "_campfire", "_anvil", "_hopper",
  "_dropper", "_dispenser", "_observer", "_lever", "_button", "_bars", "_chain", "_ladder", "_scaffolding", "_cauldron",
}
local RESOURCE_SUFFIX = {
  "_ingot", "_nugget", "_dust", "_gem", "_sheet", "_plate", "_rod", "_wire", "_shard", "_crystal", "_scrap", "_ball", "_powder",
  "_fragment", "_chip", "_pellet", "_alloy", "_coal", "_quartz", "_pearl", "_tear", "_membrane", "_hide", "_sac", "_meal", "_cream",
}
local RESOURCE_NAMES = {
  coal = true, charcoal = true, diamond = true, emerald = true, redstone = true, lapis_lazuli = true, quartz = true, flint = true,
  stick = true, string = true, leather = true, feather = true, bone = true, gunpowder = true, blaze_rod = true, brick = true,
  nether_brick = true, clay_ball = true, glowstone_dust = true, prismarine_shard = true, prismarine_crystals = true, nether_star = true,
  paper = true, sugar = true, bone_meal = true, ink_sac = true, glow_ink_sac = true, honeycomb = true, slime_ball = true, ender_pearl = true,
  ghast_tear = true, phantom_membrane = true, rabbit_hide = true, amethyst_shard = true, echo_shard = true, netherite_scrap = true,
  wheat = true, kelp = true, bamboo = true, sugar_cane = true, cactus = true, andesite_alloy = true,
}

local function startsWith(s, prefix) return s:sub(1, #prefix) == prefix end

local function tagMatches(tags, list)
  if type(tags) ~= "table" then return false end
  for tag in pairs(tags) do
    for _, want in ipairs(list) do
      if tag == want or startsWith(tag, want .. "/") then return true end
    end
  end
  return false
end

-- The creative tabs as a set of short ids ("building_blocks") and labels.
local function groupSet(groups)
  local set = {}
  if type(groups) ~= "table" then return set end
  for _, g in ipairs(groups) do
    local id = type(g) == "table" and tostring(g.id or "") or tostring(g)
    set[id:gsub("^[^:]+:", ""):lower()] = true
    if type(g) == "table" and g.displayName then
      local label = tostring(g.displayName):lower()
      if label:find("block", 1, true) or label:find("palette", 1, true) then set.building_blocks = true end
      if label:find("ingredient", 1, true) or label:find("material", 1, true) then set.ingredients = true end
    end
  end
  return set
end

local function anyOf(set, wanted)
  for k in pairs(set) do
    if wanted[k] then return true end
  end
  return false
end

-- Blocks that no tab or tag gives away, by the start of their name
-- (ComputerCraft's peripherals, for one).
local BLOCK_PREFIX = { "monitor_", "computer_", "turtle_", "wired_modem", "wireless_modem", "ender_modem", "disk_drive", "printer", "speaker", "cable" }

local function nameKind(name)
  local short = util.shortName(name):lower()
  if RESOURCE_NAMES[short] or startsWith(short, "raw_") then return "resource" end
  for _, p in ipairs(BLOCK_PREFIX) do
    if startsWith(short, p) then return "block" end
  end
  for _, s in ipairs(RESOURCE_SUFFIX) do
    if short:sub(-#s) == s then return "resource" end
  end
  for _, s in ipairs(BLOCK_SUFFIX) do
    if short:sub(-#s) == s then return "block" end
  end
  return nil
end

function C.valid(cat)
  return cat == "block" or cat == "item" or cat == "resource" or cat == "unstackable"
end

-- detail: the cached item detail (name, maxCount, itemGroups, tags).
-- overrides: item name -> category, from the config.
function C.classify(detail, overrides)
  local name = detail.name or ""
  if overrides and C.valid(overrides[name]) then return overrides[name] end
  if (tonumber(detail.maxCount) or 64) <= 1 then return "unstackable" end
  local groups = groupSet(detail.itemGroups)
  if anyOf(groups, RESOURCE_GROUPS) then return "resource" end
  if tagMatches(detail.tags, RESOURCE_TAGS) then return "resource" end
  if tagMatches(detail.tags, ITEM_TAGS) then return "item" end
  if anyOf(groups, BLOCK_GROUPS) then return "block" end
  if tagMatches(detail.tags, BLOCK_TAGS) then return "block" end
  if anyOf(groups, ITEM_GROUPS) then return "item" end
  return nameKind(name) or "item"
end

return C
