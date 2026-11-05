// node test/run.cjs [sim] [crafter] [--min]: runs the simulator suites on
// Fengari, with src/ on the module path. No names: every suite.
//   sim      test/sim.lua      the index logic against simulated inventories
//   crafter  test/crafter.lua  the crafter service against a simulated vault, turtle and smelter
//   screen   test/screen.lua   an access point screen against a simulated monitor, chest and service
//   sides    test/sides.lua    the crafter worker choosing its chest sides
//   --min    build the minified files first (node build.cjs --min) and test those, from dist/min/
const path = require("path");
const { execFileSync } = require("child_process");
const fengari = require("fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const SUITES = { sim: "sim.lua", crafter: "crafter.lua", screen: "screen.lua", sides: "sides.lua" };
const slashes = (p) => p.split(path.sep).join("/");
const minify = process.argv.includes("--min");
if (minify) execFileSync(process.execPath, [path.join(__dirname, "..", "build.cjs"), "--min"], { stdio: "inherit" });
const src = slashes(path.join(__dirname, "..", minify ? "dist/min" : "src"));

function runSuite(file) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  lua.lua_getglobal(L, to_luastring("package"));
  lua.lua_pushstring(L, to_luastring(src + "/?.lua;" + src + "/?/init.lua"));
  lua.lua_setfield(L, -2, to_luastring("path"));
  lua.lua_pop(L, 1);
  // __src: where the code under test is, for a suite that loads a file itself.
  lua.lua_pushstring(L, to_luastring(src));
  lua.lua_setglobal(L, to_luastring("__src"));
  const full = slashes(path.join(__dirname, file));
  if (lauxlib.luaL_loadfile(L, to_luastring(full)) !== lua.LUA_OK || lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    console.error(lua.lua_tojsstring(L, -1));
    return 1;
  }
  return 0;
}

const names = process.argv.slice(2).filter((a) => SUITES[a]);
let failed = 0;
for (const name of names.length ? names : Object.keys(SUITES)) {
  console.log("== " + name);
  failed += runSuite(SUITES[name]);
}
process.exit(failed ? 1 : 0);
