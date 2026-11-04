// publish: builds dist/warehouse.lua and puts it in a secret GitHub gist, so
// that one wget line installs the warehouse without the repository being
// public. Needs the GitHub CLI (`gh auth login` with the gist scope).
//   node publish.cjs
// The gist's id is kept in gists.json; the first run creates the gist and
// writes the file, later runs update the same gist, so the URL never changes.
// The packed file knows that URL (data/source on every computer it installs),
// which is how the crafter sends its turtle for the same build. A
// manifest.json goes next to it, { warehouse = { build, sum, url } } (build:
// what an installed folder's data/build says; sum: the fingerprint of
// warehouse.lua itself, checked after downloading), which the Control
// Panel's Updates screen reads to see whether the warehouse computer is
// behind (its publish.mjs reads this gist's id from gists.json here).
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const FILE = path.join(__dirname, "dist", "warehouse.lua");
const IDS = path.join(__dirname, "gists.json");

const ids = fs.existsSync(IDS) ? JSON.parse(fs.readFileSync(IDS, "utf8")) : {};
const gh = (args) => execFileSync("gh", args, { encoding: "utf8" }).trim();
const user = gh(["api", "user", "-q", ".login"]);

// 1. The gist must exist before the build, because the packed file carries
//    its own URL. A missing one is created with a stand-in.
fs.mkdirSync(path.dirname(FILE), { recursive: true });
if (!ids.warehouse) {
  fs.writeFileSync(FILE, "-- warehouse.lua: being published\n");
  const url = gh(["gist", "create", "--desc", "warehouse.lua: cc-warehouse in one file (built by build.cjs)", FILE]);
  ids.warehouse = url.split("/").pop();
  fs.writeFileSync(IDS, JSON.stringify(ids, null, 2) + "\n");
  console.log("created gist " + ids.warehouse + " (id saved in gists.json; commit it)");
}
const url = `https://gist.githubusercontent.com/${user}/${ids.warehouse}/raw/warehouse.lua`;

// 2. Build with the URL in it, and upload.
process.env.WAREHOUSE_SOURCE = url;
const { appver, packed, BUILD } = require(path.join(__dirname, "build.cjs"));
fs.writeFileSync(FILE, packed);
const build = BUILD, sum = appver(packed);
gh(["gist", "edit", ids.warehouse, "-f", "warehouse.lua", FILE]);
console.log("uploaded warehouse.lua to gist " + ids.warehouse);

// 3. The manifest next to it.
const manifest = { warehouse: { build, sum, url }, publishedAt: new Date().toISOString() };
const mpath = path.join(__dirname, "dist", "manifest.json");
fs.writeFileSync(mpath, JSON.stringify(manifest, null, 2) + "\n");
const has = gh(["gist", "view", ids.warehouse, "--files"]).split(/\r?\n/).includes("manifest.json");
if (has) gh(["gist", "edit", ids.warehouse, "-f", "manifest.json", mpath]); else gh(["gist", "edit", ids.warehouse, "-a", mpath]);
console.log("manifest.json " + (has ? "updated" : "added") + " (build " + build + ", file " + sum + ")");
console.log("");
console.log("In game:");
console.log(`  wget run ${url}`);
console.log("  ... add 'crafter' or 'client' after the URL for those computers.");
