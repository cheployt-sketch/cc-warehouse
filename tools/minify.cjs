// Minifying Lua for the computers: luamin strips comments and whitespace and
// shortens local names, which makes a file about 40% smaller. Its output is
// one line, so this puts every statement on a line of its own (a newline
// costs the same byte as luamin's separator) and records which line of the
// readable source each one came from. An error at lib/index.lua:57 in game
// is then looked up with `node build.cjs where lib/index.lua:57`.
//
// cc-control-panel/tools/minify.mjs is the same code; keep the two in step.
const luamin = require("luamin");
const luaparse = require("luaparse");

const PARSE = { luaVersion: "5.2", ranges: true, locations: true, scope: false, comments: false };

// Every statement in the chunk, in a fixed walk order, so the readable and
// the minified parse can be lined up one to one.
function statements(ast) {
  const out = [];
  const walk = (node) => {
    if (Array.isArray(node)) {
      for (const n of node) walk(n);
      return;
    }
    if (!node || typeof node !== "object" || !node.type) return;
    if (node.type.endsWith("Statement") || (node.type === "FunctionDeclaration" && node.identifier)) out.push(node);
    for (const [key, value] of Object.entries(node)) {
      if (key !== "type" && key !== "loc" && key !== "range") walk(value);
    }
  };
  walk(ast.body);
  return out;
}

/**
 * Minifies Lua source. Returns { code, lines }: lines is a list of
 * [lineInCode, lineInSource] pairs, one per statement, in line order.
 */
function minifyLua(src) {
  const min = luamin.minify(src);
  const from = statements(luaparse.parse(src, PARSE));
  const to = statements(luaparse.parse(min, PARSE));
  if (from.length !== to.length) throw new Error(`minify: ${from.length} statements before, ${to.length} after`);
  const starts = to
    .map((s, i) => {
      if (s.type !== from[i].type) throw new Error(`minify: statement ${i} is a ${from[i].type} before and a ${s.type} after`);
      return { at: s.range[0], line: from[i].loc.start.line };
    })
    .sort((a, b) => a.at - b.at);
  let code = "", last = 0, line = 1;
  const lines = [];
  for (const s of starts) {
    if (s.at > last) {
      let piece = min.slice(last, s.at);
      if (piece.endsWith(" ")) piece = piece.slice(0, -1);
      code += piece + "\n";
      line += (piece.match(/\n/g) || []).length + 1;
      last = s.at;
    } else if (s.at < last) {
      continue;
    }
    lines.push([line, s.line]);
  }
  code += min.slice(last);
  return { code, lines };
}

/**
 * The source line behind a line of a minified file, from its map
 * ({ lines: [[lineInCode, lineInSource], ...] }), or null.
 */
function locate(map, outLine) {
  let found = null;
  for (const [out, src] of map.lines) {
    if (out > outLine) break;
    found = src;
  }
  return found;
}

module.exports = { minifyLua, locate };
