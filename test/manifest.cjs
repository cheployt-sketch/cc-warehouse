// node test/manifest.cjs: writes src/files.txt, the list build.cjs packs into warehouse.lua.
const fs = require("fs");
const path = require("path");
const src = path.join(__dirname, "..", "src");
const out = [];
(function walk(dir, rel) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const r = rel ? rel + "/" + e.name : e.name;
    if (e.isDirectory()) walk(path.join(dir, e.name), r);
    else if (r !== "files.txt") out.push(r);
  }
})(src, "");
fs.writeFileSync(path.join(src, "files.txt"), "# the warehouse folder: what build.cjs packs into warehouse.lua and installs into /warehouse\n" + out.join("\n") + "\n");
console.log(out.length + " files listed");
