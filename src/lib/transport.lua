-- lib.transport: how requests reach the service.
--
-- Local: programs on the warehouse computer queue a "warehouse_request"
-- event carrying the request table and get a "warehouse_reply" event back.
-- Nothing on the same computer can be kept out anyway (it could drive the
-- peripherals itself), so this needs no key.
--
-- Rednet: computers you paired send sealed requests (lib.secure) with the
-- warehouse key on protocol "warehouse" and get sealed replies on
-- "warehouse_reply". Everything else is dropped.

local secure = require("lib.secure")

local T = {}

function T.runLocal(service)
  while true do
    local _, req = os.pullEvent("warehouse_request")
    if type(req) == "table" then
      req.transport = "local"
      service:submit(req, function(resp) os.queueEvent("warehouse_reply", resp) end)
    end
  end
end

-- Opens every attached modem for rednet. Returns how many.
function T.openModems()
  local n = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      rednet.open(name)
      n = n + 1
    end
  end
  return n
end

function T.runRednet(service, key)
  local log = service.log
  if T.openModems() == 0 then
    log.warn("no modem attached: apps on other computers cannot reach this warehouse")
    while true do os.pullEvent("warehouse_never") end
  end
  local ok, err = pcall(rednet.host, secure.PROTOCOL, service.cfg.hostname or "vault")
  if not ok then log.warn("rednet.host failed: " .. tostring(err)) end
  service.sendEvent = function(id, ev)
    local ok2, e = pcall(rednet.send, id, secure.seal(key, "event", { event = ev }), secure.EVENT_PROTOCOL)
    if not ok2 then log.warn("event to #" .. tostring(id) .. ": " .. tostring(e)) end
  end
  local seen = {}
  while true do
    local sender, msg = rednet.receive(secure.PROTOCOL)
    local body, why = secure.open(key, "req", msg, seen)
    if body and type(body.op) == "string" then
      body.transport = "rednet"
      body.sender = type(body.from) == "number" and body.from or sender
      local to = body.sender
      service:submit(body, function(resp)
        rednet.send(to, secure.seal(key, "resp", resp), secure.REPLY_PROTOCOL)
      end)
    elseif not body then
      log.debug("dropped a message from #" .. tostring(sender) .. ": " .. tostring(why))
    end
  end
end

return T
