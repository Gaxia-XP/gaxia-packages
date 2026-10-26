#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────
// tools/check-playbooks.mjs — the playbooks must be right, or agents copy bugs
//
// Checks AGENTS.md and every playbook under playbooks/ (not the generated
// playbooks/api/, not TEMPLATE.md):
//   1. every ```lua block starts with a location line (see below) and every
//      block is type-checked in --!strict mode against the real framework
//      with luau-lsp (both type solvers with --v2);
//   2. every `GaxiaServer.X.Y` / `Gaxia.X.Y` named in the text exists
//      (checked against the generated API reference);
//   3. every relative link points at a file that exists.
//
// Location line — the first line of every ```lua block:
//   -- Script: ServerScriptService/CoinShop                     (server Script)
//   -- LocalScript: StarterPlayer/StarterPlayerScripts/ShopUI    (client LocalScript)
//   -- ModuleScript: ServerStorage/GameModules/ShopCatalog       (ModuleScript)
//   -- fragment                                                  (a piece of a
//      script shown on its own: not type-checked — keep these rare and short)
// A path may appear only once per playbook. Blocks of one playbook are checked
// together, so a LocalScript can require a ModuleScript shown in the same file.
//
// Usage:
//   node tools/check-playbooks.mjs                    # everything
//   node tools/check-playbooks.mjs playbooks/x.md     # only these files
//   node tools/check-playbooks.mjs --v2               # also LuauSolverV2
//   node tools/check-playbooks.mjs --no-types         # skip luau-lsp (2 and 3 only)
//   node tools/check-playbooks.mjs --emit <dir>       # also write each playbook's
//        game tree (framework + its scripts + default.project.json) to <dir>/<name>/
//
// Needs (unless --no-types): `rojo` and `luau-lsp` on PATH (or ROJO / LUAU_LSP)
// and the Roblox definitions file (ROBLOX_DEFS, default ./globalTypes.d.luau):
//   curl -LO https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
// ─────────────────────────────────────────────────────────────
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { generate } from './gen-api.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const args = process.argv.slice(2)
const flag = (f) => args.includes(f)
const valueOf = (f) => { const i = args.indexOf(f); return i >= 0 ? args[i + 1] : undefined }
const ROJO = process.env.ROJO || 'rojo'
const LUAU_LSP = process.env.LUAU_LSP || 'luau-lsp'
const DEFS = process.env.ROBLOX_DEFS || path.join(ROOT, 'globalTypes.d.luau')

// ── which markdown files ─────────────────────────────────────────────────────
function listMarkdown() {
  const out = [path.join(ROOT, 'AGENTS.md')]
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name)
      if (e.isDirectory()) { if (e.name !== 'api') walk(p) } else if (e.name.endsWith('.md') && e.name !== 'TEMPLATE.md') out.push(p)
    }
  }
  if (fs.existsSync(path.join(ROOT, 'playbooks'))) walk(path.join(ROOT, 'playbooks'))
  return out.filter((f) => fs.existsSync(f))
}
const explicit = args.filter((a, i) => !a.startsWith('--') && args[i - 1] !== '--emit').map((f) => path.resolve(f))
const files = explicit.length ? explicit : listMarkdown()

// ── known API names (from the generated reference) ───────────────────────────
function knownNames() {
  const pages = generate()
  const names = new Set(['GaxiaServer', 'Gaxia'])
  const add = (dotted) => {
    const parts = dotted.split(/[.:]/)
    for (let i = 1; i <= parts.length; i++) names.add(parts.slice(0, i).join('.'))
  }
  const index = pages['INDEX.md']
  for (const line of index.split('\n')) {
    const m = /^((?:GaxiaServer|Gaxia)[\w.:]*?)(?:\(|\s*:|<|$)/.exec(line.trim())
    if (m) add(m[1].replace(/:/g, '.'))
  }
  for (const text of Object.values(pages)) {
    for (const m of text.matchAll(/^## `((?:GaxiaServer|Gaxia)\.[\w.]+)`/gm)) add(m[1])
  }
  // Fields, signals and types are listed under each module heading.
  for (const text of Object.values(pages)) {
    let current = null
    for (const line of text.split('\n')) {
      const h = /^## `((?:GaxiaServer|Gaxia)\.[\w.]+)`/.exec(line)
      if (h) { current = h[1]; continue }
      if (!current) continue
      const leaf = current.split('.').pop()
      const f = new RegExp(`^- \`${leaf}[.:]([A-Za-z_]\\w*)`).exec(line)
      if (f) add(`${current}.${f[1]}`)
    }
  }
  // Loader members that are not modules.
  for (const extra of ['GaxiaServer.Boot', 'GaxiaServer.IsEnabled', 'GaxiaServer.IsInstalled', 'GaxiaServer.VERSION', 'GaxiaServer.Shared', 'GaxiaServer.Config',
    'Gaxia.IsInstalled', 'Gaxia.VERSION', 'Gaxia.Tween', 'Gaxia.UI', 'Gaxia.Util', 'Gaxia.Logger', 'Gaxia.Constants']) add(extra)
  return names
}

// ── parse a playbook ─────────────────────────────────────────────────────────
const LOCATION = /^--\s*(Script|LocalScript|ModuleScript):\s*([A-Za-z][\w/ .-]*?)\s*$/
const SERVICES = new Set(['ServerScriptService', 'ServerStorage', 'ReplicatedStorage', 'ReplicatedFirst', 'StarterPlayer', 'StarterGui', 'Workspace'])

function parseBlocks(md) {
  const lines = md.split('\n')
  const blocks = []
  let inFence = null
  for (let i = 0; i < lines.length; i++) {
    const fence = /^(\s*)```(\w*)/.exec(lines[i])
    if (fence && inFence === null) {
      inFence = { lang: fence[2], start: i + 1, body: [] }
    } else if (inFence && /^\s*```\s*$/.test(lines[i])) {
      if (inFence.lang === 'lua' || inFence.lang === 'luau') blocks.push({ ...inFence, text: inFence.body.join('\n') })
      inFence = null
    } else if (inFence) {
      inFence.body.push(lines[i])
    }
  }
  return blocks
}

const problems = []
const warnings = []
const report = (file, line, msg) => problems.push(`${path.relative(ROOT, file)}:${line}: ${msg}`)

// ── 1. prose checks ──────────────────────────────────────────────────────────
const names = knownNames()
for (const file of files) {
  const md = fs.readFileSync(file, 'utf8')
  const lines = md.split('\n')
  let inFence = false
  lines.forEach((line, i) => {
    if (/^\s*```/.test(line)) { inFence = !inFence; return }
    // links
    for (const m of line.matchAll(/\]\(([^)#\s]+)(#[^)]*)?\)/g)) {
      const target = m[1]
      if (/^[a-z]+:/.test(target)) continue
      if (!fs.existsSync(path.resolve(path.dirname(file), target))) report(file, i + 1, `broken link: ${target}`)
    }
    // API names in inline code (outside fences)
    if (inFence) return
    for (const m of line.matchAll(/`([^`]+)`/g)) {
      for (const ref of m[1].matchAll(/\b((?:GaxiaServer|Gaxia)(?:\.[A-Za-z_]\w*)+)/g)) {
        const name = ref[1]
        // GaxiaServer.Config.<Section>.<field…>: the section must exist; fields are data.
        const cfg = /^GaxiaServer\.Config\.(\w+)/.exec(name)
        if (cfg && names.has(`GaxiaServer.Config.${cfg[1]}`)) continue
        if (!names.has(name)) report(file, i + 1, `unknown API name \`${name}\` (not in playbooks/api — check the spelling in playbooks/api/INDEX.md)`)
      }
    }
  })
}

// ── 2. code blocks: location lines, duplicates, type check ───────────────────
function scriptFile(kind, dmPath) {
  const ext = kind === 'Script' ? '.server.lua' : kind === 'LocalScript' ? '.client.lua' : '.lua'
  return dmPath + ext
}

function buildTree(file, blocks, dir) {
  // Framework + this playbook's scripts, as a Rojo project.
  fs.rmSync(dir, { recursive: true, force: true })
  fs.mkdirSync(dir, { recursive: true })
  fs.cpSync(path.join(ROOT, 'src'), path.join(dir, 'src'), { recursive: true })
  const project = JSON.parse(fs.readFileSync(path.join(ROOT, 'default.project.json'), 'utf8'))
  const placed = []
  for (const b of blocks) {
    const rel = path.join('game', scriptFile(b.kind, b.dmPath))
    const abs = path.join(dir, rel)
    fs.mkdirSync(path.dirname(abs), { recursive: true })
    const header = /^\s*--!(strict|nonstrict|nocheck)/.test(b.text) ? '' : '--!strict\n'
    fs.writeFileSync(abs, header + b.text + '\n')
    b.offset = header ? 1 : 0
    b.abs = abs
    // project node
    const segs = b.dmPath.split('/')
    let node = project.tree
    segs.forEach((seg, k) => {
      if (k === segs.length - 1) { node[seg] = { $path: rel }; return }
      if (!node[seg]) node[seg] = k === 0 ? { $className: seg, $ignoreUnknownInstances: true } : { $className: 'Folder' }
      node = node[seg]
    })
    placed.push(b)
  }
  fs.writeFileSync(path.join(dir, 'default.project.json'), JSON.stringify(project, null, 2))
  return placed
}

function typeCheck(file, placed, dir, v2) {
  const sm = path.join(dir, 'sourcemap.json')
  execFileSync(ROJO, ['sourcemap', 'default.project.json', '-o', sm], { cwd: dir, stdio: 'pipe' })
  const lspArgs = ['analyze', '--platform=roblox', `--sourcemap=${sm}`, `--definitions=@roblox=${DEFS}`]
  if (v2) lspArgs.push('--flag:LuauSolverV2=true')
  let out = ''
  try {
    out = execFileSync(LUAU_LSP, [...lspArgs, ...placed.map((b) => b.abs)], { cwd: dir, stdio: 'pipe', maxBuffer: 64 << 20 }).toString()
  } catch (e) {
    out = (e.stdout?.toString() ?? '') + (e.stderr?.toString() ?? '')
  }
  // A diagnostic's message can span several lines: join the continuation lines.
  const entries = []
  for (const line of out.split('\n')) {
    if (/^(.+?\.lua)(?: \[[^\]]*\])?\((\d+),(\d+)\): (\w+): /.test(line.trim())) entries.push(line.trim())
    else if (entries.length && line.trim() && !/^\[(INFO|WARN)\]/.test(line)) entries[entries.length - 1] += ' ' + line.trim()
  }
  for (const line of entries) {
    // errors: <abs> [game/...](l,c): TypeError: msg     lints: <rel>(l,c): Lint: msg
    const m = /^(.+?\.lua)(?: \[[^\]]*\])?\((\d+),(\d+)\): (\w+): (.*)$/.exec(line)
    if (!m) continue
    const target = path.resolve(dir, m[1])
    const b = placed.find((x) => x.abs === target)
    if (!b) continue
    const mdLine = b.start + 1 + Number(m[2]) - 1 - b.offset
    const tag = v2 ? ' [LuauSolverV2]' : ''
    const msg = m[5].length > 400 ? m[5].slice(0, 397) + '...' : m[5]
    if (m[4] === 'TypeError' || m[4] === 'SyntaxError') report(file, mdLine, `${m[4]}${tag}: ${msg}`)
    else warnings.push(`${path.relative(ROOT, file)}:${mdLine}: ${m[4]}: ${m[5]}`)
  }
}

if (!flag('--no-types') && !fs.existsSync(DEFS)) {
  console.error(`✗ Roblox definitions not found at ${DEFS} — set ROBLOX_DEFS or download globalTypes.d.luau (see the header of this file)`)
  process.exit(2)
}

let checkedBlocks = 0
let fragments = 0
const emitDir = valueOf('--emit')
for (const file of files) {
  const md = fs.readFileSync(file, 'utf8')
  const blocks = parseBlocks(md)
  const typed = []
  const seen = new Map()
  for (const b of blocks) {
    const first = b.text.split('\n')[0].trim()
    if (/^--\s*fragment\b/.test(first)) { fragments++; continue }
    const loc = LOCATION.exec(first)
    if (!loc) { report(file, b.start + 1, 'a ```lua block must start with "-- Script: <path>", "-- LocalScript: <path>", "-- ModuleScript: <path>" or "-- fragment"'); continue }
    const dmPath = loc[2].trim()
    if (!SERVICES.has(dmPath.split('/')[0])) { report(file, b.start + 1, `location must start with a service (${[...SERVICES].join(', ')}): ${dmPath}`); continue }
    if (seen.has(dmPath)) { report(file, b.start + 1, `${dmPath} is already shown at line ${seen.get(dmPath)} — one block per script (give the new one its own name, or mark a partial edit "-- fragment")`); continue }
    seen.set(dmPath, b.start + 1)
    typed.push({ ...b, kind: loc[1], dmPath })
  }
  checkedBlocks += typed.length
  if (!typed.length) continue
  const rel = path.relative(ROOT, file)
  const name = (rel.startsWith('..') ? path.basename(file) : rel).replace(/[\\/]/g, '_').replace(/\.md$/, '')
  if (!flag('--no-types') || emitDir) {
    const dir = emitDir ? path.join(path.resolve(emitDir), name) : fs.mkdtempSync(path.join(os.tmpdir(), 'gaxia-playbook-'))
    const placed = buildTree(file, typed, dir)
    if (!flag('--no-types')) {
      typeCheck(file, placed, dir, false)
      if (flag('--v2')) typeCheck(file, placed, dir, true)
    }
    if (!emitDir) fs.rmSync(dir, { recursive: true, force: true })
  }
}

for (const w of warnings) console.log(`  warn ${w}`)
for (const p of problems) console.log(`✗ ${p}`)
console.log(`check-playbooks: ${files.length} file(s), ${checkedBlocks} code block(s) type-checked${flag('--no-types') ? ' (types skipped)' : ''}, ${fragments} fragment(s), ${problems.length} problem(s)`)
process.exit(problems.length ? 1 : 0)
