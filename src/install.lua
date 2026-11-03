-- install: puts the warehouse folder on this computer from GitHub.
--   wget run https://raw.githubusercontent.com/cheployt-sketch/cc-warehouse/main/src/install.lua
--   wget run <that url> crafter     the same files, then the crafter's next steps
--   wget run <that url> client      the same files, then how to pair an app computer
-- Every program (warehouse, wh, crafter, parcel) lives in /warehouse, so the
-- download is the same; only the advice at the end differs. Existing files
-- are replaced; the config, key, pairing and data are left alone.
local BASE = "https://raw.githubusercontent.com/cheployt-sketch/cc-warehouse/main/src/"
local ROOT = "/warehouse"

local what = ({ ... })[1]
if what ~= "crafter" and what ~= "client" and what ~= "warehouse" then
  what = turtle and "crafter" or "warehouse"
end

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
shell.setPath(shell.path() .. ":" .. ROOT)
print("")
if what == "crafter" and turtle then
  print("This turtle is the crafter's worker. Next:")
  print("  wh pair disk            with the floppy from 'warehouse key disk'")
  print("                          (or wh pair <key>, key from 'warehouse key')")
  print("  crafter worker top bottom   take from the chest above, drop below;")
  print("                          front, top or bottom, one side means both")
  print("  crafter startup         start the worker on every boot")
  print("A crafting table goes on the turtle, the chests it uses on the wired network.")
elseif what == "crafter" then
  print("The crafter runs next to the warehouse service. Next, on this computer:")
  print("  crafter setup turtle=<name> input=<chest> recipeChest=<chest> monitor=<name>")
  print("  crafter startup         start on every boot")
  print("  crafter                 start now, in a tab with its panel")
  print("Then put the worker on the crafty turtle: this installer with 'crafter' there.")
elseif what == "client" then
  print("Next, on this app computer:")
  print("  wh pair <key>           key from 'warehouse key' on the warehouse computer,")
  print("  wh pair disk            or a floppy from 'warehouse key disk'")
  print("Then require(\"/warehouse/api\").connect() in your programs, or 'wh' at the shell.")
else
  print("Next, on this computer:")
  print("  warehouse setup      pick storage, screens and security")
  print("  warehouse startup    start on boot, and put the commands on the path")
  print("  warehouse            start now")
  print("For an app computer or the crafter instead, run this installer there with 'client' or 'crafter'.")
end
