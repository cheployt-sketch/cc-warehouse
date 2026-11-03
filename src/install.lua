-- install: puts the warehouse on this computer from GitHub.
--   wget run https://raw.githubusercontent.com/cheployt-sketch/cc-warehouse/main/src/install.lua
-- Downloads every file listed in files.txt into /warehouse (existing files
-- are replaced; the config, key and data are left alone), then explains the
-- next steps.
local BASE = "https://raw.githubusercontent.com/cheployt-sketch/cc-warehouse/main/src/"
local ROOT = "/warehouse"

if not http then
  printError("HTTP is turned off in this world's ComputerCraft config.")
  return
end

local function fetch(path)
  local res, err = http.get(BASE .. path, nil, true)
  if not res then return nil, err end
  local body = res.readAll()
  res.close()
  return body
end

print("Fetching the file list...")
local list, err = fetch("files.txt")
if not list then
  printError("Could not download: " .. tostring(err))
  printError("If the repository is private, make it public or copy the folder another way.")
  return
end

local files = {}
for line in list:gmatch("[^\r\n]+") do
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line ~= "" and not line:match("^#") then files[#files + 1] = line end
end

local done, failed = 0, {}
for i, path in ipairs(files) do
  local body, e = fetch(path)
  if body then
    local target = fs.combine(ROOT, path)
    local dir = fs.getDir(target)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local h = fs.open(target, "wb")
    h.write(body)
    h.close()
    done = done + 1
    term.setCursorPos(1, select(2, term.getCursorPos()))
    term.clearLine()
    write(string.format("%d/%d %s", i, #files, path))
  else
    failed[#failed + 1] = path .. " (" .. tostring(e) .. ")"
  end
end
print("")
print(done .. " files installed in " .. ROOT)
for _, f in ipairs(failed) do printError("failed: " .. f) end
if #failed > 0 then return end
print("")
print("Next, on this computer:")
print("  warehouse setup      pick storage, screens and security")
print("  warehouse startup    start on boot, and put the commands on the path")
print("  warehouse            start now")
print("For an app computer instead: wh pair <key>  (key from 'warehouse key' on the warehouse).")
