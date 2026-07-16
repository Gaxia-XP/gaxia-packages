#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────
// scaffold.mjs — GaxiaPackages service generator
//
// Generates a new server Lib service from the house template AND patches the
// server init's type export + LIB_KEY_MAP — the exact two-line wiring done by
// hand for every Phase 18–25 service. Stops doc/wiring drift.
//
// Usage:
//   node scaffold.mjs new:service <Name> [Key]        # Name -> <Name>Service.lua, Gaxia.<Key>
//   node scaffold.mjs new:service Quest QuestBoard --dry-run
//
//   <Name>  PascalCase module base (file becomes <Name>Service.lua)
//   [Key]   semantic accessor key (Gaxia.<Key>); defaults to <Name>
//   --dry-run  print planned changes without writing
// ─────────────────────────────────────────────────────────────
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB_DIR = join(HERE, "src/ServerStorage/Gaxia_Packages_Server/Lib");
const INIT = join(HERE, "src/ServerStorage/Gaxia_Packages_Server/init.lua");

const argv = process.argv.slice(2);
const dryRun = argv.includes("--dry-run");
const args = argv.filter((a) => !a.startsWith("--"));
const [command, name, keyArg] = args;

function die(msg) {
  console.error(`✗ ${msg}`);
  process.exit(1);
}

if (command !== "new:service") {
  die(`unknown command '${command ?? ""}'. Use: new:service <Name> [Key]`);
}
if (!name || !/^[A-Z][A-Za-z0-9]*$/.test(name)) {
  die(`<Name> must be PascalCase (got '${name ?? ""}')`);
}
const key = keyArg || name;
if (!/^[A-Z][A-Za-z0-9]*$/.test(key)) {
  die(`[Key] must be PascalCase (got '${key}')`);
}

const moduleName = `${name}Service`;
const filePath = join(LIB_DIR, `${moduleName}.lua`);

// ── 1. Service file from template ──
const template = `--!strict
-- ─────────────────────────────────────────────────────────────
-- ${moduleName}.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/${moduleName}
-- Purpose : TODO — one-paragraph description of what this service owns.
--
-- Access  : Gaxia.${key}  (server)
--   Gaxia.${key}.Example()
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

-- Lazy server access (resolved at call-time; never yields in the module body).
local GaxiaServer: any = nil
local function server(): any
\tif not GaxiaServer then
\t\tGaxiaServer = require(ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init"))
\tend
\treturn GaxiaServer
end

local ${moduleName} = {}

${moduleName}.OnChanged = Signal.new()

-- ── Public API ──

function ${moduleName}.Example(): boolean
\tlocal _ = server -- access Gaxia.Data / Gaxia.Economy etc. via server()
\treturn true
end

return ${moduleName}
`;

// ── 2. Patch init: type export + LIB_KEY_MAP entry (insert before Admin anchors) ──
let init = readFileSync(INIT, "utf8");
const typeAnchor = "\tAdmin       : typeof(require(script.Parent.Lib.AdminCommands)),";
const keymapAnchor = '\tAdmin       = "AdminCommands",';
const typeLine = `\t${key} : typeof(require(script.Parent.Lib.${moduleName})),`;
const keymapLine = `\t${key.padEnd(11)} = "${moduleName}",`;

const problems = [];
if (existsSync(filePath)) problems.push(`file already exists: ${moduleName}.lua`);
if (!init.includes(typeAnchor)) problems.push("type-export anchor (Admin) not found in init.lua");
if (!init.includes(keymapAnchor)) problems.push("LIB_KEY_MAP anchor (Admin) not found in init.lua");
if (new RegExp(`\\b${key}\\s*:\\s*typeof`).test(init)) problems.push(`type key '${key}' already wired`);
if (problems.length) die(problems.join("; "));

const newInit = init
  .replace(typeAnchor, `${typeLine}\n${typeAnchor}`)
  .replace(keymapAnchor, `${keymapLine}\n${keymapAnchor}`);

// ── Apply ──
if (dryRun) {
  console.log(`— DRY RUN —`);
  console.log(`would create  : Lib/${moduleName}.lua  (${template.split("\n").length} lines)`);
  console.log(`would add type: ${typeLine.trim()}`);
  console.log(`would add key : ${keymapLine.trim()}`);
  console.log(`\nnext: node scripts/push_create.mjs "game.ServerStorage.Gaxia_Packages_Server.Lib" "${moduleName}" "ModuleScript" "GaxiaPackages/src/ServerStorage/Gaxia_Packages_Server/Lib/${moduleName}.lua"`);
  process.exit(0);
}

writeFileSync(filePath, template);
writeFileSync(INIT, newInit);
console.log(`✓ created Lib/${moduleName}.lua`);
console.log(`✓ wired Gaxia.${key} (type export + LIB_KEY_MAP) in init.lua`);
console.log(`\nnext:`);
console.log(`  node scripts/push_create.mjs "game.ServerStorage.Gaxia_Packages_Server.Lib" "${moduleName}" "ModuleScript" "GaxiaPackages/src/ServerStorage/Gaxia_Packages_Server/Lib/${moduleName}.lua"`);
console.log(`  node scripts/push_one.mjs "game.ServerStorage.Gaxia_Packages_Server.init" "GaxiaPackages/src/ServerStorage/Gaxia_Packages_Server/init.lua"`);
