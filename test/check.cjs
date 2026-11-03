// node test/check.cjs [dir]: compiles every Lua file under a directory (default src) with Fengari (syntax only) and
// flags Lua 5.3-only operators that CC:Tweaked (Lua 5.2) rejects.
const fs = require("fs");
const path = require("path");
const fengari = require("F:/cc-tweaked/cc-control-panel/node_modules/fengari");
const { lua, lauxlib, to_luastring } = fengari;

function check52(file, src) {
  const code = src
    .replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, "")
    .replace(/\[(=*)\[[\s\S]*?\]\1\]/g, '""')
    .replace(/"(?:[^"\\n]|\.)*"|'(?:[^'\\n]|\.)*'/g, '""')
    .replace(/--[^\n]*/g, "");
  const bad = code.match(/\/\/|<<|>>|[&|]|~(?!=)/);
  if (bad) return `'${bad[0]}' is Lua 5.3 syntax`;
  const seen = new Map();
  for (const m of code.matchAll(/^\s*function\s+([\w.]+)[.:](\w+)\s*\(/gm)) {
    const key = `${m[1]}.${m[2]}`;
    if (seen.has(key)) return `${key} is defined twice`;
    seen.set(key, true);
  }
  return null;
}

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out); else if (p.endsWith(".lua")) out.push(p);
  }
  return out;
}

let bad = 0;
for (const file of walk(process.argv[2] || path.join(__dirname, "..", "src"), [])) {
  const src = fs.readFileSync(file, "utf8");
  const L = lauxlib.luaL_newstate();
  const st = lauxlib.luaL_loadbuffer(L, to_luastring(src), to_luastring("@" + file));
  if (st !== lua.LUA_OK) { bad++; console.log("SYNTAX " + lua.lua_tojsstring(L, -1)); continue; }
  if (!file.includes("ccryptolib")) {
    const e = check52(file, src);
    if (e) { bad++; console.log("5.2  " + file + ": " + e); }
  }
}
console.log(bad ? `${bad} problem(s)` : "all files compile");
