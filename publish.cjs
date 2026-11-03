// publish: builds dist/warehouse.lua and puts it in a secret GitHub gist, so
// that one wget line installs the warehouse without the repository being
// public. Needs the GitHub CLI (`gh auth login` with the gist scope).
//   node publish.cjs
// The gist's id is kept in gists.json; the first run creates the gist and
// writes the file, later runs update the same gist, so the URL never changes.
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const FILE = path.join(__dirname, "dist", "warehouse.lua");
const IDS = path.join(__dirname, "gists.json");

execFileSync("node", [path.join(__dirname, "build.cjs")], { stdio: "inherit" });

const ids = fs.existsSync(IDS) ? JSON.parse(fs.readFileSync(IDS, "utf8")) : {};
const gh = (args) => execFileSync("gh", args, { encoding: "utf8" }).trim();
const user = gh(["api", "user", "-q", ".login"]);

if (ids.warehouse) {
  gh(["gist", "edit", ids.warehouse, "-f", "warehouse.lua", FILE]);
  console.log("updated gist " + ids.warehouse);
} else {
  const url = gh(["gist", "create", "--desc", "warehouse.lua: cc-warehouse in one file (built by build.cjs)", FILE]);
  ids.warehouse = url.split("/").pop();
  fs.writeFileSync(IDS, JSON.stringify(ids, null, 2) + "\n");
  console.log("created gist " + ids.warehouse + " (id saved in gists.json; commit it)");
}
console.log("");
console.log("In game:");
console.log(`  wget run https://gist.githubusercontent.com/${user}/${ids.warehouse}/raw/warehouse.lua`);
console.log("  ... add 'crafter' or 'client' after the URL for those computers.");
