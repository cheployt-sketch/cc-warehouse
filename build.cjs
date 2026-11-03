// build: packs everything install.lua would download into one file,
// dist/warehouse.lua, that writes the folder out when run in game:
//   wget run <url of warehouse.lua> [crafter|client]
// so the whole warehouse can be fetched from a single secret gist without
// making the repository public. The file list is src/files.txt.
const fs = require("fs");
const path = require("path");

const SRC = path.join(__dirname, "src");
const OUT = path.join(__dirname, "dist", "warehouse.lua");

const list = fs.readFileSync(path.join(SRC, "files.txt"), "utf8")
  .split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));

// A long-bracket level that does not occur in the text.
function bracket(text) {
  for (let n = 1; n < 20; n++) {
    const close = "]" + "=".repeat(n) + "]";
    if (!text.includes(close)) return n;
  }
  throw new Error("no usable long bracket");
}

let out = `-- warehouse.lua: the whole warehouse folder in one file, built by build.cjs
-- from src/files.txt. Run it to install or update /warehouse:
--   wget run <this file's url>            the warehouse computer
--   wget run <this file's url> crafter    the crafter (a turtle gets the worker's steps)
--   wget run <this file's url> client     an app computer that only pairs
-- Existing files are replaced; the config, key, pairing and data are left alone.
local ROOT = "/warehouse"
local FILES = {}
`;
let total = 0;
for (const rel of list) {
  // Git may check files out with CRLF on Windows; CC wants LF.
  const text = fs.readFileSync(path.join(SRC, rel), "utf8").replace(/\r\n/g, "\n");
  const n = bracket(text);
  const eq = "=".repeat(n);
  // A newline right after the opening bracket is dropped by Lua, so add one.
  out += `FILES[${JSON.stringify(rel)}] = [${eq}[\n${text}]${eq}]\n`;
  total += text.length;
}
out += `
local what = ({ ... })[1]
if what ~= "crafter" and what ~= "client" and what ~= "warehouse" then
  what = turtle and "crafter" or "warehouse"
end

local names = {}
for name in pairs(FILES) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
  local target = fs.combine(ROOT, name)
  local dir = fs.getDir(target)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(target, "w")
  h.write(FILES[name])
  h.close()
end
print(#names .. " files installed in " .. ROOT)
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
  print("Then put the worker on the crafty turtle: run this file there with 'crafter'.")
elseif what == "client" then
  print("Next, on this app computer:")
  print("  wh pair <key>           key from 'warehouse key' on the warehouse computer,")
  print("  wh pair disk            or a floppy from 'warehouse key disk'")
  print("Then require(\\"/warehouse/api\\").connect() in your programs, or 'wh' at the shell.")
else
  print("Next, on this computer:")
  print("  warehouse setup      pick storage, screens and security")
  print("  warehouse startup    start on boot, and put the commands on the path")
  print("  warehouse            start now")
  print("For an app computer or the crafter instead, run this file there with 'client' or 'crafter'.")
end
`;
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, out);
console.log(`dist/warehouse.lua: ${list.length} files, ${(total / 1024).toFixed(1)} KiB of source, ${(out.length / 1024).toFixed(1)} KiB packed`);
