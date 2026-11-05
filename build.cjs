// build: packs the warehouse folder (the files in src/files.txt) into one
// file, dist/warehouse.lua, that writes the folder out when run in game:
//   wget run <url of warehouse.lua> [crafter|client]
// and writes dist/manifest.json, which publish.cjs uploads next to it for
// the Control Panel's Updates screen.
//   node build.cjs          readable files
//   node build.cjs --min    minified files (about 40% smaller; what gets published),
//                           with dist/maps/<file>.map.json for each and the minified
//                           tree in dist/min/ (node test/run.cjs --min tests it)
//   node build.cjs where lib/index.lua:57   the source line behind a minified line
// The URL the installer records in data/source (so the crafter can send its
// turtle for the same build) comes from WAREHOUSE_SOURCE; publish.cjs sets it.
const fs = require("fs");
const path = require("path");
const { minifyLua, locate } = require("./tools/minify.cjs");

const SRC = path.join(__dirname, "src");
const DIST = path.join(__dirname, "dist");
const read = (rel) => fs.readFileSync(path.join(SRC, rel), "utf8").replace(/\r\n/g, "\n"); // CRLF checkouts: CC wants LF
const VERSION = read("lib/version.lua").match(/"([^"]+)"/)[1];

// The same fingerprint as the Control Panel's cp.appver: the panel compares
// the one a computer's /warehouse/data/build holds with the manifest's.
function appver(code) {
  const TWO32 = 2 ** 32;
  let a = 5381, b = 0;
  const buf = Buffer.isBuffer(code) ? code : Buffer.from(code, "utf8");
  for (let i = 0; i < buf.length; i++) {
    a = (a * 33 + buf[i]) % TWO32;
    b = (b * 31 + buf[i] + i + 1) % TWO32;
  }
  const hex8 = (n) => n.toString(16).padStart(8, "0");
  return hex8(a) + hex8(b).slice(0, 4) + "-" + buf.length;
}

// A long-bracket level that does not occur in the text.
function bracket(text) {
  for (let n = 1; n < 20; n++) {
    if (!text.includes("]" + "=".repeat(n) + "]")) return n;
  }
  throw new Error("no usable long bracket");
}

// The installer: every file as a long string, then the code that writes
// them. Returns { packed, build, files, maps }: files is what goes on the
// computer, maps the minified files' line maps.
function build({ minify = false, source = "" } = {}) {
  const list = read("files.txt").split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  const files = {}, maps = {};
  for (const rel of list) {
    let text = read(rel);
    if (minify && rel.endsWith(".lua")) {
      const r = minifyLua(text);
      text = r.code;
      maps[rel] = r.lines;
    }
    files[rel] = text;
  }
  // The build: a fingerprint of every file, written to data/build on install.
  const BUILD = appver(list.map((rel) => rel + "\n" + files[rel]).join("\0"));

  let out = `-- warehouse.lua: the whole warehouse folder in one file, built by build.cjs
-- from src/files.txt${minify ? " (minified; node build.cjs where <file>:<line> finds the source line)" : ""}. Run it to install or update /warehouse:
--   wget run <this file's url>            the warehouse computer
--   wget run <this file's url> crafter    the crafter (a turtle gets the worker's steps)
--   wget run <this file's url> client     an app computer that only pairs
-- Existing files are replaced; the config, key, pairing and data are left alone.
local ROOT = "/warehouse"
local FILES = {}
`;
  for (const rel of list) {
    const eq = "=".repeat(bracket(files[rel]));
    // A newline right after the opening bracket is dropped by Lua, so add one.
    out += `FILES[${JSON.stringify(rel)}] = [${eq}[\n${files[rel]}]${eq}]\n`;
  }
  out += `local BUILD = ${JSON.stringify(BUILD)}\n`;
  out += `local SOURCE = ${JSON.stringify(source)}\n`;
  out += INSTALLER;
  return { packed: out, build: BUILD, files, maps };
}

const INSTALLER = `
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
do
  local dir = fs.combine(ROOT, "data")
  if not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(fs.combine(dir, "build"), "w")
  h.write(BUILD)
  h.close()
  if SOURCE ~= "" then
    h = fs.open(fs.combine(dir, "source"), "w")
    h.write(SOURCE)
    h.close()
  end
end
print(#names .. " files installed in " .. ROOT .. " (build " .. BUILD .. ")")
shell.setPath(shell.path() .. ":" .. ROOT)
print("")
if what == "crafter" and turtle then
  print("This turtle is the crafter's worker. Next:")
  print("  wh pair disk            with the floppy from 'warehouse key disk'")
  print("                          (or wh pair <key>, key from 'warehouse key')")
  print("  crafter worker          it finds the service's chests among the ones")
  print("                          in front of, above and below it")
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

// `node build.cjs where lib/index.lua:57`: the source line behind a line of a minified file.
function where(ref) {
  const m = /^(.+?):(\d+)$/.exec(ref);
  if (!m) throw new Error("expected <file>:<line>, for example lib/index.lua:57");
  const rel = m[1].replace(/\\/g, "/").replace(/^\/?warehouse\//, "");
  const mapPath = path.join(DIST, "maps", rel + ".map.json");
  if (!fs.existsSync(mapPath)) throw new Error(`no map for ${rel}: run node build.cjs --min first`);
  const line = locate(JSON.parse(fs.readFileSync(mapPath, "utf8")), Number(m[2]));
  return line == null ? "before the first statement" : `src/${rel}:${line}`;
}

// Writes a build to dist/: warehouse.lua, manifest.json (build: what an
// installed folder's data/build says; sum: the fingerprint of warehouse.lua
// itself, checked after downloading) and, when minified, the maps and the
// minified tree. Returns the manifest.
function writeDist(r, minify) {
  fs.mkdirSync(DIST, { recursive: true });
  fs.writeFileSync(path.join(DIST, "warehouse.lua"), r.packed);
  const manifest = {
    version: VERSION,
    minified: minify,
    builtAt: new Date().toISOString(),
    warehouse: { build: r.build, sum: appver(r.packed), version: VERSION, file: "warehouse.lua" },
  };
  fs.writeFileSync(path.join(DIST, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  if (minify) {
    for (const [rel, lines] of Object.entries(r.maps)) {
      const p = path.join(DIST, "maps", rel + ".map.json");
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, JSON.stringify({ lines }));
    }
    for (const [rel, text] of Object.entries(r.files)) {
      const p = path.join(DIST, "min", rel);
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, text);
    }
  }
  return manifest;
}

function main() {
  const args = process.argv.slice(2);
  if (args[0] === "where") return console.log(where(args[1] ?? ""));
  const minify = args.includes("--min");
  const r = build({ minify, source: process.env.WAREHOUSE_SOURCE || "" });
  writeDist(r, minify);
  const total = Object.values(r.files).reduce((n, t) => n + t.length, 0);
  console.log(`dist/warehouse.lua: ${Object.keys(r.files).length} files, ${(total / 1024).toFixed(1)} KiB of code${minify ? " (minified)" : ""}, ${(r.packed.length / 1024).toFixed(1)} KiB packed, build ${r.build}`);
}

module.exports = { appver, build, writeDist };
if (require.main === module) main();
