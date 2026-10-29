#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────
// scaffold.mjs — add a framework service with everything wired
//
// Creates Lib/<Name>Service.lua from the house template (side-effect-free body,
// typed Signal, Lifecycle.Define last) and wires it everywhere the framework
// needs it, so `node tools/check-architecture.mjs --complete` passes right away:
//   • Types.ServiceName                         (the name Features accepts)
//   • init.lua LIB_KEY_MAP + GaxiaServerPackage  (GaxiaServer.<Key>, typed)
//   • Packages.lua                              (its own package, Requires generated)
//   • playbooks/api/<Key>.md                    (regenerated API reference)
//
// Usage:
//   node scaffold.mjs new:service <Name> [Key] [--boot] [--category "<Category>"] [--description "<text>"] [--dry-run]
//
//   <Name>       PascalCase module base: the file becomes Lib/<Name>Service.lua
//   [Key]        GaxiaServer.<Key> and the package name (default: <Name>)
//   --boot       the service has work to do before its first call (player hooks,
//                remotes, loops): it starts at server boot whenever installed
//   --category   picker category (default "Game services")
//   --dry-run    print what would change, write nothing
//
// Game code (not the framework) never needs this: put game logic in your own
// Scripts / ModuleScripts (see playbooks/).
// ─────────────────────────────────────────────────────────────
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const SERVER = join(HERE, 'src/ServerStorage/Gaxia_Packages_Server')
const LIB_DIR = join(SERVER, 'Lib')
const INIT = join(SERVER, 'init.lua')
const TYPES = join(SERVER, 'Types.lua')
const PACKAGES = join(SERVER, 'Packages.lua')

const argv = process.argv.slice(2)
const valueOf = (f) => { const i = argv.indexOf(f); return i >= 0 ? argv[i + 1] : undefined }
const dryRun = argv.includes('--dry-run')
const boot = argv.includes('--boot')
const category = valueOf('--category') ?? 'Game services'
const description = valueOf('--description') ?? 'TODO: one line on what this service does.'
const positional = argv.filter((a, i) => !a.startsWith('--') && !['--category', '--description'].includes(argv[i - 1]))
const [command, name, keyArg] = positional

function die(msg) {
  console.error(`✗ ${msg}`)
  process.exit(1)
}

if (command !== 'new:service') die(`unknown command '${command ?? ''}'. Use: node scaffold.mjs new:service <Name> [Key] [--boot] [--category "..."] [--dry-run]`)
if (!name || !/^[A-Z][A-Za-z0-9]*$/.test(name)) die(`<Name> must be PascalCase (got '${name ?? ''}')`)
const key = keyArg || name
if (!/^[A-Z][A-Za-z0-9]*$/.test(key)) die(`[Key] must be PascalCase (got '${key}')`)
if (/["\\]/.test(category) || /["\\]/.test(description)) die('--category / --description must not contain quotes or backslashes')

const moduleName = `${name}Service`
const filePath = join(LIB_DIR, `${moduleName}.lua`)

// ── 1. The service module ──
const template = `--!strict
-- ─────────────────────────────────────────────────────────────
-- ${moduleName}.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/${moduleName}
-- Purpose : ${description}
--
-- Access  : GaxiaServer.${key}  (server)
--   GaxiaServer.${key}.Example(player)
--
-- Lifecycle: the module body only defines things; ${boot ? 'Init wires the player hooks (it starts at boot whenever installed).' : 'it starts the first time it is used.'}
-- ─────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies (static requires only; see playbooks/framework) ──
local Shared    = ReplicatedStorage.Gaxia_Packages.Shared
local Signal    = require(Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)

local ${moduleName} = {}

-- (player, value) whenever Example changes a player's value
${moduleName}.OnChanged = Signal.new() :: Signal.Signal<Player, number>

-- ── State ──
local values: { [Player]: number } = {}

-- ── Public API ──

-- Adds 1 to the player's value and returns the new value.
function ${moduleName}.Example(player: Player): number
\tlocal value = (values[player] or 0) + 1
\tvalues[player] = value
\t${moduleName}.OnChanged:Fire(player, value)
\treturn value
end

-- ── Lifecycle ──

local function onPlayerRemoving(player: Player): ()
\tvalues[player] = nil
end

Lifecycle.Define(${moduleName}, {
\tName = "${key}",
\tNeeds = {},
\t-- Sync, must not yield. Connect events here, never in the module body.
\tInit = function()
\t\tPlayers.PlayerRemoving:Connect(onPlayerRemoving)
\tend,
})

return ${moduleName}
`

// ── 2. Wiring ──
const problems = []
if (existsSync(filePath)) problems.push(`file already exists: Lib/${moduleName}.lua`)

let types = readFileSync(TYPES, 'utf8')
const unionRe = /(export type ServiceName =[\s\S]*?)(\n\n|\n--)/
const union = unionRe.exec(types)
if (!union) problems.push('Types.ServiceName not found')
else if (new RegExp(`"${key}"`).test(union[1])) problems.push(`"${key}" is already a Types.ServiceName`)
else types = types.replace(unionRe, (_, body, tail) => `${body}\n\t| "${key}"${tail}`)

let init = readFileSync(INIT, 'utf8')
const typeAnchor = '\t-- ── AntiCheat orchestrator (the init ModuleScript, not the folder) ──'
if (!init.includes(typeAnchor)) problems.push('GaxiaServerPackage anchor (AntiCheat orchestrator comment) not found in init.lua')
if (new RegExp(`\\n\\t${key}\\s*:\\s*typeof`).test(init)) problems.push(`GaxiaServer.${key} is already typed in init.lua`)
const mapRe = /(local LIB_KEY_MAP : \{ \[string\]: string \} = \{[\s\S]*?)(\n\})/
if (!mapRe.test(init)) problems.push('LIB_KEY_MAP not found in init.lua')
if (new RegExp(`\\n\\t${key}\\s*=\\s*"`).test(init)) problems.push(`"${key}" is already in LIB_KEY_MAP`)
init = init
  .replace(typeAnchor, `\t${key} : typeof(require(script.Lib.${moduleName})),\n\n${typeAnchor}`)
  .replace(mapRe, (_, body, tail) => `${body}\n\t${key.padEnd(11)} = "${moduleName}",${tail}`)

let packages = readFileSync(PACKAGES, 'utf8')
const pkgAnchor = '\t\t-- ── Client systems ───────────────────────────────────'
if (!packages.includes(pkgAnchor)) problems.push('Packages.lua anchor ("-- ── Client systems") not found')
if (new RegExp(`Name = "${key}"`).test(packages)) problems.push(`package "${key}" already exists in Packages.lua`)
const entry = [
  '\t\t{',
  `\t\t\tName = "${key}", Category = "${category}",${boot ? ' Boot = true,' : ''}`,
  `\t\t\tDescription = "${description}",`,
  `\t\t\tServer = { "Lib/${moduleName}" },`,
  '\t\t\tRequires = {},',
  '\t\t},',
  '',
].join('\n')
packages = packages.replace(pkgAnchor, `${entry}${pkgAnchor}`)

if (problems.length) die(problems.join('\n✗ '))

if (dryRun) {
  console.log('— DRY RUN (nothing written) —')
  console.log(`would create : src/ServerStorage/Gaxia_Packages_Server/Lib/${moduleName}.lua`)
  console.log(`would add    : Types.ServiceName | "${key}"`)
  console.log(`would add    : init.lua  LIB_KEY_MAP ${key} = "${moduleName}"  +  GaxiaServerPackage.${key}`)
  console.log(`would add    : Packages.lua package "${key}" (${category}${boot ? ', Boot' : ''})`)
  process.exit(0)
}

writeFileSync(filePath, template)
writeFileSync(TYPES, types)
writeFileSync(INIT, init)
writeFileSync(PACKAGES, packages)
for (const tool of [['tools/packages.mjs', 'fix'], ['tools/gen-api.mjs']]) {
  execFileSync(process.execPath, [join(HERE, tool[0]), ...tool.slice(1)], { stdio: 'inherit', cwd: HERE })
}
console.log(`✓ created Lib/${moduleName}.lua`)
console.log(`✓ wired GaxiaServer.${key}: Types.ServiceName, LIB_KEY_MAP, GaxiaServerPackage, Packages.lua, playbooks/api/${key}.md`)
console.log('\nnext:')
console.log(`  1. replace Example with the real API in Lib/${moduleName}.lua (keep the body side-effect free)`)
console.log('  2. if you require another service, add it to Needs only if its Init must run first')
console.log('  3. node tools/packages.mjs fix && node tools/gen-api.mjs')
console.log('  4. LUAU_AST=<path to luau-ast> node tools/check-architecture.mjs --complete')
