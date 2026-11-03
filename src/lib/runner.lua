-- lib.runner: runs named coroutines side by side, like parallel, but tasks
-- can be added and removed while it runs. The service uses it so screens
-- can come and go when the config changes, without a restart.
--
-- Events go to every task, except that a task waiting with an event filter
-- (what os.pullEvent yields) only gets matching events, as in CraftOS.

local R = {}
R.__index = R

function R.new()
  return setmetatable({ tasks = {}, order = {} }, R)
end

-- Adds (or replaces) a task. It starts at the next turn of the loop.
function R:add(name, fn)
  self:remove(name)
  self.tasks[name] = { name = name, co = coroutine.create(fn), filter = nil, started = false }
  self.order[#self.order + 1] = name
end

function R:remove(name)
  if not self.tasks[name] then return end
  self.tasks[name] = nil
  for i, n in ipairs(self.order) do
    if n == name then
      table.remove(self.order, i)
      break
    end
  end
end

function R:has(name) return self.tasks[name] ~= nil end

function R:names()
  return { table.unpack(self.order) }
end

local function step(self, t, ...)
  local ok, param = coroutine.resume(t.co, ...)
  if not ok then error(t.name .. ": " .. tostring(param), 0) end
  t.filter = param
  t.started = true
  if coroutine.status(t.co) == "dead" then self:remove(t.name) end
end

-- Runs until a task raises an error (raised again here) or stopWhen()
-- returns true, which is checked after every event.
function R:run(stopWhen)
  while true do
    for _, name in ipairs(self:names()) do
      local t = self.tasks[name]
      if t and not t.started then step(self, t) end
    end
    if stopWhen and stopWhen() then return end
    local ev = table.pack(os.pullEventRaw())
    for _, name in ipairs(self:names()) do
      local t = self.tasks[name]
      if t and t.started and (t.filter == nil or t.filter == ev[1] or ev[1] == "terminate") then
        step(self, t, table.unpack(ev, 1, ev.n))
      end
    end
    if stopWhen and stopWhen() then return end
  end
end

return R
