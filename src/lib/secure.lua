-- lib.secure: sealed messages for the network, used by the service and by
-- the client library.
--
-- Anyone in range can read and send on a wireless modem, and the sender ID
-- of a rednet message can be faked. So every request, reply and event is
-- encrypted and authenticated (ChaCha20-Poly1305) with the warehouse key,
-- which only the service and the computers you paired hold. A message also
-- carries the time it was made and a random nonce: the service ignores
-- messages older than WINDOW and nonces it has already accepted, so a
-- recorded request cannot be played back later. All computers in one world
-- share the host's clock (os.epoch "utc"), which makes that check reliable.

local crypto = require("lib.crypto")
local b64 = require("lib.b64")

local S = {}

S.VERSION = 1
S.WINDOW = 30000 -- milliseconds a message stays fresh
S.PROTOCOL = "warehouse" -- rednet protocol of requests (and the hosted name)
S.REPLY_PROTOCOL = "warehouse_reply"
S.EVENT_PROTOCOL = "warehouse_event"
S.MAX_BOX = 512 * 1024 -- largest accepted ciphertext (base64 characters)

function S.newKey() return crypto.random(32) end
function S.encodeKey(key) return b64.encode(key) end

-- Returns the 32-byte key behind its base64 form, or nil.
function S.decodeKey(s)
  if type(s) ~= "string" then return nil end
  local k = b64.decode(s)
  if #k ~= 32 then return nil end
  return k
end

function S.fingerprint(key) return crypto.fingerprint(key) end

local function aad(kind) return "warehouse" .. S.VERSION .. ":" .. kind end

-- Seals a table for the wire. kind: "req", "resp" or "event".
function S.seal(key, kind, body)
  body.t = os.epoch("utc")
  local pt = textutils.serialise(body, { compact = true })
  local nonce = crypto.random(12)
  return { v = S.VERSION, n = b64.encode(nonce), x = b64.encode(crypto.seal(key, nonce, pt, aad(kind))) }
end

-- Forgets nonces that are too old to be accepted anyway.
local function prune(seen, now)
  if seen.__next and seen.__next > now then return end
  seen.__next = now + 5000
  for n, until_ in pairs(seen) do
    if n ~= "__next" and until_ < now then seen[n] = nil end
  end
end

-- Opens a sealed message. Returns the body, or nil and the reason. `seen`
-- is a table of accepted nonces (keep one per key and kind) for replay
-- protection; leave it out for replies, which are matched by request ID.
function S.open(key, kind, msg, seen)
  if type(msg) ~= "table" or msg.v ~= S.VERSION or type(msg.n) ~= "string" or type(msg.x) ~= "string" then
    return nil, "not a sealed message"
  end
  if #msg.x > S.MAX_BOX or #msg.n > 24 then return nil, "message too large" end
  local nonce = b64.decode(msg.n)
  if #nonce ~= 12 then return nil, "bad nonce" end
  local pt = crypto.open(key, nonce, b64.decode(msg.x), aad(kind))
  if not pt then return nil, "wrong key or altered message" end
  local ok, body = pcall(textutils.unserialise, pt)
  if not ok or type(body) ~= "table" then return nil, "bad contents" end
  local now = os.epoch("utc")
  if type(body.t) ~= "number" or math.abs(now - body.t) > S.WINDOW then return nil, "stale message" end
  if seen then
    prune(seen, now)
    if seen[msg.n] then return nil, "replayed message" end
    seen[msg.n] = now + S.WINDOW * 2
  end
  return body
end

-- Key files hold the base64 key on one line.
function S.loadKey(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return S.decodeKey((s:gsub("%s", "")))
end

function S.saveKey(path, key)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(path, "w")
  if not h then return false end
  h.write(S.encodeKey(key))
  h.close()
  return true
end

return S
