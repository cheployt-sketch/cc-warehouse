-- lib.crypto: the primitives the network protocol needs, on top of
-- ccryptolib: ChaCha20-Poly1305 authenticated encryption, BLAKE3 hashing and
-- a seeded random generator.

local config = require "ccryptolib.config"
-- ccryptolib can hand work to a "cryptographic accelerator" peripheral,
-- including random number generation. Anyone who can attach a peripheral
-- could then feed us predictable randomness, so never use one.
config.usePeripherals(false)

local aead = require "ccryptolib.aead"
local blake3 = require "ccryptolib.blake3"
local random = require "ccryptolib.random"
local util = require "ccryptolib.util"

local M = {}

local seeded = false

-- Seeds the random generator from VM timing noise (about half a second).
function M.init()
  if seeded then return end
  random.initWithTiming()
  random.mix(tostring(os.getComputerID()) .. "|" .. tostring(os.epoch("utc")) .. "|" .. tostring({}))
  seeded = true
end

function M.random(n)
  M.init()
  return random.random(n)
end

function M.hash(s, n) return blake3.digest(s, n) end

-- Constant-time comparison.
function M.equal(a, b)
  return type(a) == "string" and type(b) == "string" and #a == #b and util.compare(a, b)
end

M.hex = util.toHex

-- A short public identifier for a key, so two computers can check they hold
-- the same one without showing it.
function M.fingerprint(key) return util.toHex(blake3.digest(key, 4)) end

-- Authenticated encryption: returns ciphertext .. 16-byte tag.
function M.seal(key, nonce, msg, aad)
  local ct, tag = aead.encrypt(key, nonce, msg, aad)
  return ct .. tag
end

-- Returns the plaintext, or nil if the box was forged or altered.
function M.open(key, nonce, box, aad)
  if type(box) ~= "string" or #box < 16 then return nil end
  return aead.decrypt(key, nonce, box:sub(-16), box:sub(1, -17), aad)
end

return M
