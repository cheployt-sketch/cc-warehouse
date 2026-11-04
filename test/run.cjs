// node test/run.cjs [sim] [crafter]: runs the simulator suites on Fengari,
// with src/ on the module path. No names: every suite.
//   sim      test/sim.lua      the index logic against simulated inventories
//   crafter  test/crafter.lua  the crafter service against a simulated vault, turtle and smelter
const path = require("path");
const fengari = require("F:/cc-tweaked/cc-control-panel/node_modules/fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const SUITES = { sim: "sim.lua", crafter: "crafter.lua", sides: "sides.lua" };
const slashes = (p) => p.split(path.sep).join("/");
const src = slashes(path.join(__dirname, "..", "src"));

function runSuite(file) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  lua.lua_getglobal(L, to_luastring("package"));
  lua.lua_pushstring(L, to_luastring(src + "/?.lua;" + src + "/?/init.lua"));
  lua.lua_setfield(L, -2, to_luastring("path"));
  lua.lua_pop(L, 1);
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
