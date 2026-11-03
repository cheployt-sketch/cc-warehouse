-- lib.b64: Base64 for putting binary keys and ciphertext into modem messages.
-- CC's Lua has no bitwise operators, so this uses plain arithmetic.

local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local enc, dec = {}, {}
for i = 1, 64 do
  local c = CHARS:sub(i, i)
  enc[i - 1] = c
  dec[c:byte()] = i - 1
end

local function encode(s)
  local out, n = {}, 0
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    n = n + 1
    out[n] = enc[math.floor(v / 262144)] .. enc[math.floor(v / 4096) % 64]
      .. (b and enc[math.floor(v / 64) % 64] or "=") .. (c and enc[v % 64] or "=")
    if n % 4096 == 0 then out = { table.concat(out) } n = 1 end
  end
  return table.concat(out)
end

-- Never errors: characters outside the alphabet are ignored, so hostile
-- input can only produce wrong bytes, which the caller's checks then reject.
local function decode(s)
  s = s:gsub("[^A-Za-z0-9%+/]", "")
  local out, n = {}, 0
  for i = 1, #s, 4 do
    local a, b, c, d = s:byte(i, i + 3)
    local v = dec[a] * 262144 + (b and dec[b] or 0) * 4096
      + (c and dec[c] or 0) * 64 + (d and dec[d] or 0)
    local b1, b2, b3 = math.floor(v / 65536), math.floor(v / 256) % 256, v % 256
    n = n + 1
    if d then out[n] = string.char(b1, b2, b3)
    elseif c then out[n] = string.char(b1, b2)
    elseif b then out[n] = string.char(b1)
    else out[n] = "" end
    if n % 4096 == 0 then out = { table.concat(out) } n = 1 end
  end
  return table.concat(out)
end

return { encode = encode, decode = decode }
