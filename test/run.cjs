// node test/run.cjs: runs test/sim.lua (the index logic against simulated
// inventories) on Fengari, with src/ on the module path.
const path = require("path");
const fengari = require("F:/cc-tweaked/cc-control-panel/node_modules/fengari");
const { lua, lauxlib, lualib, to_luastring } = fengari;

const slashes = (p) => p.split(path.sep).join("/");
const src = slashes(path.join(__dirname, "..", "src"));
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
lua.lua_getglobal(L, to_luastring("package"));
lua.lua_pushstring(L, to_luastring(src + "/?.lua;" + src + "/?/init.lua"));
lua.lua_setfield(L, -2, to_luastring("path"));
lua.lua_pop(L, 1);
const file = slashes(path.join(__dirname, "sim.lua"));
if (lauxlib.luaL_loadfile(L, to_luastring(file)) !== lua.LUA_OK || lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
  console.error(lua.lua_tojsstring(L, -1));
  process.exit(1);
}
