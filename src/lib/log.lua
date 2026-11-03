-- lib.log: prints to the service's tab and appends to a capped log file.
local L = { path = nil, max = 64 * 1024, level = "info", echo = true }
local levels = { debug = 1, info = 2, warn = 3, error = 4 }

function L.setup(opts)
  L.path = opts.path
  L.level = levels[opts.level] and opts.level or "info"
  L.echo = opts.echo ~= false
end

local function write(level, msg)
  if levels[level] < levels[L.level] then return end
  local line = string.format("[%s] %s %s", os.date("%H:%M:%S"), level:upper(), tostring(msg))
  if L.echo then print(line) end
  if L.path then
    if fs.exists(L.path) and fs.getSize(L.path) > L.max then
      local h = fs.open(L.path, "r")
      local s = h.readAll()
      h.close()
      h = fs.open(L.path, "w")
      h.write(s:sub(-math.floor(L.max / 2)))
      h.close()
    end
    local h = fs.open(L.path, "a")
    if h then
      h.writeLine(line)
      h.close()
    end
  end
end

function L.debug(msg) write("debug", msg) end
function L.info(msg) write("info", msg) end
function L.warn(msg) write("warn", msg) end
function L.error(msg) write("error", msg) end

return L
