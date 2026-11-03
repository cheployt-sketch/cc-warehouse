-- stock: keeps a chest topped up with an item from storage, like a
-- requester. Useful in front of a furnace line, a crafter or a farm.
--
--   stock <inventory name> <item> <count> [seconds between checks]
--
-- Example: stock minecraft:chest_1 minecraft:coal 64
-- The chest must be on the warehouse's wired network.

local wh = require("/warehouse/api")

local chest, item, want, every = ...
want = tonumber(want)
every = tonumber(every) or 5
if not (chest and item and want) then
  print("usage: stock <inventory name> <item> <count> [seconds]")
  return
end

local vault = wh.connect()
local key = vault.item(item).key -- fails early with a clear message if the item is not stored
print("Keeping " .. want .. " x " .. key .. " in " .. chest .. " (Ctrl+T stops)")
while true do
  local have = 0
  for _, it in pairs(peripheral.call(chest, "list")) do
    if it.name == key or (it.name .. "@" .. tostring(it.nbt)) == key then have = have + it.count end
  end
  if have < want then
    local ok, moved, why = pcall(vault.withdraw, key, want - have, chest)
    if not ok then
      printError(tostring(moved))
    elseif moved > 0 then
      print("added " .. moved .. (why and (" (" .. why .. ")") or ""))
    elseif why then
      print(why)
    end
  end
  sleep(every)
end
