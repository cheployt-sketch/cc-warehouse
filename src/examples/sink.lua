-- sink: everything put into a chest is stored a moment later. Point a
-- hopper line, a farm or a sorter at that chest and it never fills up.
--
--   sink <inventory name> [seconds between checks]
--
-- Run it on the warehouse computer, or on any paired computer with a modem.
-- The chest must be on the warehouse's wired network (wh peripherals lists
-- what is there).

local wh = require("/warehouse/api")

local chest, every = ..., nil
every = tonumber(every) or 2
if not chest then
  print("usage: sink <inventory name> [seconds]")
  return
end

local vault = wh.connect()
print("Storing whatever lands in " .. chest .. " (Ctrl+T stops)")
while true do
  local ok, moved, items, message = pcall(vault.deposit, chest)
  if not ok then
    printError(tostring(moved))
    sleep(10)
  else
    if moved > 0 then
      for key, n in pairs(items) do print("stored " .. n .. " x " .. key) end
    end
    if message and message ~= "nothing to store" then printError(message) end
    sleep(every)
  end
end
