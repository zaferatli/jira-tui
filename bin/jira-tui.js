#!/usr/bin/env node
"use strict";

const path = require("path");
const os = require("os");
const fs = require("fs");
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require("fengari");
const { luaopen_js } = require("fengari-interop");

// When the package is installed globally (npm install -g .), __dirname is no
// longer next to the project tree; so we look for .env in several sensible
// places, in order — first match wins:
//   1) current working directory (wherever "jira-tui" was launched)
//   2) ~/.config/jira-tui/.env (recommended persistent location for global installs)
//   3) one/two levels above the package (rapor/.env — when run from the repo)
const envCandidates = [
  path.join(process.cwd(), ".env"),
  path.join(os.homedir(), ".config", "jira-tui", ".env"),
  path.join(__dirname, "..", "..", ".env"),
  path.join(__dirname, "..", ".env"),
];
// Prefer the first candidate that exists AND contains JIRA_BASE_URL, so a
// stray .env in cwd for another purpose (e.g. a mobile project config) does
// not shadow the global Jira settings.
const dotenv = require("dotenv");
const envPath = envCandidates.find((p) => {
  if (!fs.existsSync(p)) return false;
  try {
    return Boolean(dotenv.parse(fs.readFileSync(p)).JIRA_BASE_URL);
  } catch {
    return false;
  }
});
if (envPath) dotenv.config({ path: envPath });

if (!process.env.JIRA_BASE_URL || (!process.env.JIRA_PAT && !process.env.JIRA_USERNAME)) {
  process.stderr.write(
    "jira-tui: Jira credentials not found.\n" +
    "Put a .env file in one of these locations (JIRA_BASE_URL, JIRA_AUTH_MODE,\n" +
    "JIRA_PAT or JIRA_USERNAME/JIRA_PASSWORD):\n" +
    "  - " + path.join(process.cwd(), ".env") + " (current working directory)\n" +
    "  - " + path.join(os.homedir(), ".config", "jira-tui", ".env") + " (global, works from anywhere)\n"
  );
  process.exit(1);
}

// fengari-interop only exposes access via `js.global` (Node's global object);
// Node's `require` is not a field on that object, so we hang it there manually
// for the Fennel side to reach.
global.__jiraTuiRequire = require;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
lauxlib.luaL_requiref(L, to_luastring("js"), luaopen_js, 1);
lua.lua_pop(L, 1);

function luaStringLiteral(value) {
  return "'" + String(value).replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "'";
}

const fennelPath = path.join(__dirname, "..", "vendor", "fennel.lua");
const srcDir = path.join(__dirname, "..", "src");
const mainPath = path.join(srcDir, "main.fnl");

// When calling JS functions from inside Fengari, Lua's `:` (method-call)
// syntax must be used: fengari-interop, when invoking a JS function looked up
// with `.`, swallows the first real argument as JS `this` and does not forward
// the real arguments (see README examples). So on the Fennel side always call
// as `js.global:fn ...`.
// fengari's `io` library (browser-oriented) does not provide `io.open`; so
// instead of relying on fennel’s own `dofile`/`io.open`-based file loading,
// we install a custom searcher that reads .fnl files via Node’s real `fs`
// module (through js interop), then compiles with fennel.compileString and
// runs via Lua’s pure `load()`.
// (`dofile` here is used to load fennel.lua itself, because fengari’s
// `dofile`/`loadfile` do have real fs access under Node; the problem was only
// fennel’s own use of `io.open`.)
const bootstrap = `
local js = require("js")
_G.jsrequire = function(name) return js.global:__jiraTuiRequire(name) end
_G.jsglobal = js.global

local fennel = dofile(${luaStringLiteral(fennelPath)})

local function fnl_readfile(path)
  local fs = jsrequire("fs")
  return fs:readFileSync(path, "utf8")
end

local function fnl_loadstring(source, chunkname)
  local lua_code = assert(fennel.compileString(source, {filename = chunkname}))
  return assert(load(lua_code, "@" .. chunkname))
end

local src_dir = ${luaStringLiteral(srcDir)}

table.insert(package.searchers, function(modname)
  local rel = modname:gsub("%.", "/")
  local candidates = {src_dir .. "/" .. rel .. ".fnl", src_dir .. "/" .. rel .. "/init.fnl"}
  for _, p in ipairs(candidates) do
    local ok, src = pcall(fnl_readfile, p)
    if ok and src then
      return fnl_loadstring(src, p), p
    end
  end
  return nil, "no fennel module found for '" .. modname .. "'"
end)

local main_path = ${luaStringLiteral(mainPath)}
local main_chunk = fnl_loadstring(fnl_readfile(main_path), main_path)
main_chunk()
`;

// blessed's tput.js, when it cannot compile some capabilities defined in the
// system's (modern ncurses) terminfo with its own older parser (e.g. "Setulc"
// for RGB underline color), dumps a noisy error via console.error and falls
// back to its built-in xterm terminfo (harmless fallback; the app still runs
// normally). That compilation happens while the blessed screen is created,
// i.e. inside the synchronous main_chunk() call below. The problem is that
// this console.error output goes to stderr — OUTSIDE the alternate screen
// buffer that blessed takes over: it sits quietly in the normal screen's
// scrollback and only becomes visible after leaving the alternate screen with
// `q` (rmcup). Since application code (src/*.fnl) does not use console/print,
// suppressing console.error for the duration of this sync call is safe.
const originalConsoleError = console.error;
console.error = function () {};
let status;
try {
  status = lauxlib.luaL_dostring(L, to_luastring(bootstrap));
} finally {
  console.error = originalConsoleError;
}
if (status !== lua.LUA_OK) {
  const msg = to_jsstring(lauxlib.luaL_tolstring(L, -1));
  process.stderr.write("jira-tui failed to start:\n" + msg + "\n");
  process.exit(1);
}
