-- watch: prints every change in storage as it happens. Shows how an app
-- can react to events instead of polling.
--
--   watch

local wh = require("/warehouse/api")

local vault = wh.connect()
local st = vault.stats()
print(string.format("%d items of %d kinds, %d%% full. Waiting for changes (Ctrl+T stops)", st.items, st.types, st.slots > 0 and math.floor(st.used / st.slots * 100) or 0))
while true do
  local ev = vault.pullEvent()
  if ev and ev.type == "change" then
    for _, c in ipairs(ev.items) do
      print(string.format("%+6d  %-32s now %d", c.delta, c.key, c.count))
    end
  end
end
