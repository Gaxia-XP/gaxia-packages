#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────
// tools/packages.mjs — pick which Gaxia packages a game installs
//
// The catalogue is src/ServerStorage/Gaxia_Packages_Server/Packages.lua. Picking
// a package installs it plus every package it Requires (transitively) plus Core.
//
// Usage:
//   node tools/packages.mjs list                       # packages by category
//   node tools/packages.mjs check                      # catalogue matches the source (exit 1 if not)
//   node tools/packages.mjs fix                        # regenerate every Requires list
//   node tools/packages.mjs resolve Data,Pet           # what a pick installs
//   node tools/packages.mjs build --select Data,Pet --out ../MyGame/gaxia
//   node tools/packages.mjs build --preset Default --out ../MyGame/gaxia
//   node tools/packages.mjs build --all --out ../MyGame/gaxia
//
// <out> must be outside this repo and empty or a previous build (--force
// otherwise): build replaces <out>/src and <out>/default.project.json.
//
// `build` writes <out>/src (only the installed modules, same layout as this repo)
// and <out>/default.project.json; then `rojo serve <out>/default.project.json` or
// `rojo build <out>/default.project.json -o Gaxia.rbxm`. Re-run it after
// pulling a new Gaxia version or changing the pick. The pick is recorded on both
// package roots (attribute GaxiaPackages), so the server boots the picked
// services plus every installed package that has Boot = true.
// ─────────────────────────────────────────────────────────────
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const SERVER_DIR = 'src/ServerStorage/Gaxia_Packages_Server'
const REPLICATED_DIR = 'src/ReplicatedStorage/Gaxia_Packages'
const MANIFEST = path.join(ROOT, SERVER_DIR, 'Packages.lua')
// Same exclusions as default.project.json's globIgnorePaths.
const IGNORED = /(\.spec\.luau?|\.test\.luau?|jest\.config\.luau|wally\.toml)$/
export const ATTRIBUTE = 'GaxiaPackages'

// Requires of a variable that are deliberate (not a static dependency):
// file → argument texts. Anything else that does not resolve fails `check`.
const DYNAMIC_REQUIRES = {
  [`${SERVER_DIR}/init.lua`]: ['mod'], // the loader's lazy key lookup
  [`${REPLICATED_DIR}/init.lua`]: ['mod'], // the loader's lazy key lookup
  [`${SERVER_DIR}/AntiCheat/init.lua`]: ['child'], // game-added detector modules
}

// Instance-path prefixes (also the side names used in Packages.lua).
const SIDES = {
  Server: { inst: 'ServerStorage.Gaxia_Packages_Server', dir: SERVER_DIR },
  Replicated: { inst: 'ReplicatedStorage.Gaxia_Packages', dir: REPLICATED_DIR },
}

// ── Packages.lua reader (the table literal subset the catalogue uses) ─────────
export function parseLuauTable(src, from) {
  let i = from
  const err = (m) => { throw new Error(`Packages.lua: ${m} at offset ${i}`) }
  const ws = () => {
    for (;;) {
      while (i < src.length && /\s/.test(src[i])) i++
      if (src.startsWith('--[[', i)) { const e = src.indexOf(']]', i); i = e < 0 ? src.length : e + 2; continue }
      if (src.startsWith('--', i)) { while (i < src.length && src[i] !== '\n') i++; continue }
      return
    }
  }
  const value = () => {
    ws()
    const c = src[i]
    if (c === '{') return table()
    if (c === '"') {
      let s = ''; i++
      while (src[i] !== '"') {
        if (i >= src.length) err('unterminated string')
        if (src[i] === '\\') { i++; s += { n: '\n', t: '\t' }[src[i]] ?? src[i]; i++ } else s += src[i++]
      }
      i++; return s
    }
    const m = /^(true|false|nil|-?\d+(\.\d+)?)/.exec(src.slice(i))
    if (!m) err('unexpected token')
    i += m[0].length
    return m[0] === 'true' ? true : m[0] === 'false' ? false : m[0] === 'nil' ? null : Number(m[0])
  }
  const table = () => {
    i++ // {
    const arr = []; const obj = {}; let isObj = false
    for (;;) {
      ws()
      if (src[i] === '}') { i++; break }
      const key = /^([A-Za-z_]\w*)\s*=/.exec(src.slice(i))
      if (key) { i += key[0].length; obj[key[1]] = value(); isObj = true } else arr.push(value())
      ws()
      if (src[i] === ',' || src[i] === ';') i++
    }
    if (isObj && arr.length) err('mixed table')
    return isObj ? obj : arr
  }
  return { value: value(), end: i }
}

export function readManifest() {
  const src = fs.readFileSync(MANIFEST, 'utf8')
  const at = src.indexOf('{', src.indexOf('local Packages'))
  return parseLuauTable(src, at).value
}

// ── Source graph ─────────────────────────────────────────────────────────────
// nodes: instance path → file; edges: instance path → instance paths it requires
// (type-only `typeof(require(...))` included: those modules must exist too).
export function readGraph() {
  const nodes = {}
  const walk = (dir, inst) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name)
      if (IGNORED.test(e.name)) continue
      if (e.isDirectory()) {
        const ip = `${inst}.${e.name}`
        const init = ['init.lua', 'init.luau'].map((f) => path.join(p, f)).find((f) => fs.existsSync(f))
        nodes[ip] = init ?? null // null = Folder
        walk(p, ip)
      } else if (/\.luau?$/.test(e.name) && !/^init\.luau?$/.test(e.name)) {
        nodes[`${inst}.${e.name.replace(/\.luau?$/, '')}`] = p
      }
    }
  }
  for (const side of Object.values(SIDES)) {
    const abs = path.join(ROOT, side.dir)
    nodes[side.inst] = path.join(abs, 'init.lua')
    walk(abs, side.inst)
  }
  const resolve = (expr, self, aliases) => {
    expr = expr
      .replace(/:WaitForChild\("([^"]+)"[^)]*\)/g, '.$1')
      .replace(/:FindFirstChild\("([^"]+)"\)/g, '.$1')
      .replace(/\s/g, '')
      .replace(/::.*$/, '')
      .replace(/^game:GetService\("(\w+)"\)/, '$1')
    const parts = expr.split('.')
    let base
    if (parts[0] === 'script') {
      base = self.split('.'); parts.shift()
      while (parts[0] === 'Parent') { base.pop(); parts.shift() }
    } else if (parts[0] === 'ReplicatedStorage' || parts[0] === 'ServerStorage') base = [parts.shift()]
    else if (aliases[parts[0]]) base = aliases[parts.shift()].split('.')
    else return null
    return [...base, ...parts].filter(Boolean).join('.')
  }
  const edges = {}
  const unresolved = []
  for (const [inst, file] of Object.entries(nodes)) {
    if (!file) { edges[inst] = []; continue }
    const src = fs.readFileSync(file, 'utf8').replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, '').replace(/--[^\n]*/g, '')
    const aliases = {}
    // `local X = <path>` where <path> starts at script, a service, or an earlier alias
    const aliasRe = /local\s+(\w+)\s*(?::\s*[\w.?]+\s*)?=\s*((?:script|game:GetService\("\w+"\)|[A-Za-z_]\w*)[\w.:"(), ]*?)\s*(?:::\s*\w+)?\s*$/gm
    for (const m of src.matchAll(aliasRe)) {
      const r = resolve(m[2], inst, aliases)
      if (r) aliases[m[1]] = r
    }
    const out = new Set()
    const dynamicOk = DYNAMIC_REQUIRES[path.relative(ROOT, file).split(path.sep).join('/')] ?? []
    const add = (arg) => {
      const a = arg.trim()
      const r = resolve(a, inst, aliases)
      if (r && r in nodes) out.add(r)
      else if (a !== '...' && !dynamicOk.includes(a)) unresolved.push(`${inst}: require(${a})`)
    }
    // `require(x)`, the vendored `(require :: any)(x)` form, and `pcall(require, x)`
    for (const m of src.matchAll(/(?:\brequire|\(require\s*::\s*any\))\(\s*([^()]*(?:\([^()]*\)[^()]*)*)\)/g)) add(m[1])
    for (const m of src.matchAll(/\bpcall\(\s*require\s*,\s*([^()]*(?:\([^()]*\)[^()]*)*)\)/g)) add(m[1])
    edges[inst] = [...out]
  }
  return { nodes, edges, unresolved }
}

// The two package roots: their typeof(require(...)) lines are rewritten on install,
// so they are not dependencies.
const LOADERS = new Set(Object.values(SIDES).map((s) => s.inst))

const toInst = (side, p) => `${SIDES[side].inst}.${p.replaceAll('/', '.')}`
const within = (node, root) => node === root || node.startsWith(root + '.')

// owner(node) → "Core" | package name | undefined (orphan)
export function ownership(manifest, graph) {
  const roots = [] // [instRoot, owner]
  for (const side of Object.keys(SIDES)) for (const p of manifest.Core[side]) roots.push([toInst(side, p), 'Core'])
  for (const pkg of manifest.Packages)
    for (const side of Object.keys(SIDES)) for (const p of pkg[side] ?? []) roots.push([toInst(side, p), pkg.Name])
  const owners = {}
  const problems = []
  for (const [r, who] of roots) if (!(r in graph.nodes)) problems.push(`${who}: path ${r} does not exist`)
  for (const node of Object.keys(graph.nodes)) {
    if (LOADERS.has(node)) { owners[node] = 'Core'; continue }
    // the most specific root wins; two roots of the same length = overlap
    const hits = roots.filter(([r]) => within(node, r)).sort((a, b) => b[0].length - a[0].length)
    if (hits.length === 0) continue
    if (hits.length > 1 && hits[0][0] === hits[1][0]) problems.push(`${node} claimed by both ${hits[0][1]} and ${hits[1][1]}`)
    else if (hits.length > 1 && hits[0][1] !== hits[1][1]) problems.push(`${node}: ${hits[0][1]} claims a module inside ${hits[1][1]}`)
    owners[node] = hits[0][1]
  }
  for (const [node, file] of Object.entries(graph.nodes)) {
    if (file && !owners[node]) problems.push(`${node} is not in Core or any package`)
  }
  return { owners, problems }
}

export function computeRequires(manifest, graph, owners) {
  const req = Object.fromEntries(manifest.Packages.map((p) => [p.Name, new Set()]))
  const coreLeaks = []
  for (const [node, deps] of Object.entries(graph.edges)) {
    if (LOADERS.has(node)) continue
    const who = owners[node]
    for (const d of deps) {
      const to = owners[d]
      if (!to || to === who || to === 'Core') continue
      if (who === 'Core') coreLeaks.push(`Core module ${node} requires ${d} (package ${to})`)
      else if (who) req[who].add(to)
    }
  }
  return { requires: Object.fromEntries(Object.entries(req).map(([k, v]) => [k, [...v].sort()])), coreLeaks }
}

export function closure(manifest, picked) {
  const byName = Object.fromEntries(manifest.Packages.map((p) => [p.Name, p]))
  const unknown = picked.filter((n) => !byName[n])
  const seen = new Set()
  const stack = picked.filter((n) => byName[n])
  while (stack.length) {
    const n = stack.pop()
    if (seen.has(n)) continue
    seen.add(n)
    for (const r of byName[n].Requires) stack.push(r)
  }
  return { installed: manifest.Packages.map((p) => p.Name).filter((n) => seen.has(n)), unknown }
}

// What the server loader boots for a pick: every picked server service, plus every
// installed package with Boot = true. Mirrors pickedBootServices in the loader.
export function bootServices(manifest, picked, installed) {
  return manifest.Packages
    .filter((p) => p.Server?.length && installed.includes(p.Name) && (p.Boot || picked.includes(p.Name)))
    .map((p) => p.Name)
}

// The paths (per side) an install keeps: Core + every installed package.
export function keptPaths(manifest, installed) {
  const kept = { Server: [...manifest.Core.Server], Replicated: [...manifest.Core.Replicated] }
  const set = new Set(installed)
  for (const pkg of manifest.Packages) {
    if (!set.has(pkg.Name)) continue
    for (const side of Object.keys(SIDES)) kept[side].push(...(pkg[side] ?? []))
  }
  return kept
}

const isKept = (kept, p) => kept.some((k) => p === k || p.startsWith(k + '/'))

// Drop each `typeof(require(script.X.Y))` type line whose module is not installed.
// Mirrors plugin/src/PackageSelect.lua pruneTypeLines — keep the two in step.
export function pruneTypeLines(source, keptForSide) {
  return source
    .split('\n')
    .filter((line) => {
      const m = /typeof\(require\(script\.([\w.]+)\)\)/.exec(line)
      if (!m) return true
      return isKept(keptForSide, m[1].replaceAll('.', '/'))
    })
    .join('\n')
}

// Everything wrong with the catalogue (empty = it matches the source). Shared
// with tools/check-architecture.mjs (R12).
export function catalogueProblems() {
  const manifest = readManifest()
  const graph = readGraph()
  const problems = [...graph.unresolved.map((u) => `unresolved ${u}`)]
  const names = new Set()
  for (const p of manifest.Packages) {
    if (names.has(p.Name)) problems.push(`duplicate package ${p.Name}`)
    names.add(p.Name)
    if (!p.Category || !p.Description) problems.push(`${p.Name}: Category and Description are required`)
    if (!(p.Server?.length || p.Replicated?.length)) problems.push(`${p.Name}: no modules`)
    if (!Array.isArray(p.Requires)) problems.push(`${p.Name}: Requires must be a list ({} if none)`)
  }
  for (const [preset, list] of Object.entries(manifest.Presets ?? {}))
    for (const n of list) if (!names.has(n)) problems.push(`preset ${preset}: unknown package ${n}`)
  const { owners, problems: own } = ownership(manifest, graph)
  problems.push(...own)
  const { requires, coreLeaks } = computeRequires(manifest, graph, owners)
  problems.push(...coreLeaks)
  for (const p of manifest.Packages) {
    if (!Array.isArray(p.Requires)) continue
    const want = requires[p.Name].join(', ')
    const got = [...p.Requires].sort().join(', ')
    if (want !== got) problems.push(`${p.Name}.Requires is { ${got} }, the source needs { ${want} } — run: node tools/packages.mjs fix`)
  }
  return { problems, manifest, graph }
}

// ── Commands ─────────────────────────────────────────────────────────────────
function cmdCheck({ quiet } = {}) {
  const { problems, manifest, graph } = catalogueProblems()
  if (problems.length) {
    console.error(problems.map((p) => `✗ ${p}`).join('\n'))
    process.exit(1)
  }
  if (!quiet) console.log(`✓ ${manifest.Packages.length} packages, ${Object.keys(graph.nodes).length} instances, catalogue matches the source`)
}

function cmdFix() {
  const manifest = readManifest()
  const graph = readGraph()
  const { owners, problems } = ownership(manifest, graph)
  if (problems.length) {
    console.error(problems.map((p) => `✗ ${p}`).join('\n'))
    process.exit(1)
  }
  const { requires } = computeRequires(manifest, graph, owners)
  let src = fs.readFileSync(MANIFEST, 'utf8')
  let changed = 0
  const nameRe = (n) => new RegExp(`\\bName\\s*=\\s*"${n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`)
  for (const p of manifest.Packages) {
    // This package's entry runs from its Name to the next entry's Name.
    const m = nameRe(p.Name).exec(src)
    if (!m) throw new Error(`fix: cannot find Name = "${p.Name}" in Packages.lua`)
    const nextName = src.slice(m.index + m[0].length).search(/\bName\s*=/)
    const end = nextName < 0 ? src.length : m.index + m[0].length + nextName
    const reqAt = src.indexOf('Requires = {', m.index)
    if (reqAt < 0 || reqAt > end) throw new Error(`fix: package ${p.Name} has no "Requires = { ... }" — add Requires = {} to it`)
    const close = src.indexOf('}', reqAt)
    const list = requires[p.Name]
    const next = list.length ? `Requires = { ${list.map((n) => `"${n}"`).join(', ')} }` : 'Requires = {}'
    if (src.slice(reqAt, close + 1) !== next) changed++
    src = src.slice(0, reqAt) + next + src.slice(close + 1)
  }
  fs.writeFileSync(MANIFEST, src)
  console.log(`✓ Requires regenerated (${changed} changed)`)
}

const VALUE_FLAGS = new Set(['--select', '--preset', '--from', '--out'])
const BOOL_FLAGS = new Set(['--all', '--force'])

function checkFlags(args) {
  for (let i = 0; i < args.length; i++) {
    const a = args[i]
    if (VALUE_FLAGS.has(a)) {
      if (args[i + 1] === undefined || args[i + 1].startsWith('--')) throw new Error(`${a} needs a value`)
      i++
    } else if (a.startsWith('--') && !BOOL_FLAGS.has(a)) {
      throw new Error(`unknown option ${a}`)
    }
  }
}

function parseSelection(args, manifest) {
  checkFlags(args)
  const sel = []
  const at = (flag) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined }
  if (args.includes('--all')) sel.push(...manifest.Packages.map((p) => p.Name))
  const preset = at('--preset')
  if (preset) {
    if (!manifest.Presets[preset]) throw new Error(`unknown preset ${preset} (have: ${Object.keys(manifest.Presets).join(', ')})`)
    sel.push(...manifest.Presets[preset])
  }
  const list = at('--select')
  if (list) sel.push(...list.split(',').map((s) => s.trim()).filter(Boolean))
  const file = at('--from')
  if (file) {
    const data = JSON.parse(fs.readFileSync(file, 'utf8'))
    if (!Array.isArray(data?.packages) || data.packages.some((n) => typeof n !== 'string'))
      throw new Error(`${file} must be { "packages": [ "Name", ... ] }`)
    sel.push(...data.packages)
  }
  return [...new Set(sel)]
}

function cmdResolve(args) {
  const manifest = readManifest()
  const picked = args[0] && !args[0].startsWith('--')
    ? args[0].split(',').map((s) => s.trim()).filter(Boolean)
    : parseSelection(args, manifest)
  const { installed, unknown } = closure(manifest, picked)
  if (unknown.length) { console.error(`✗ unknown package(s): ${unknown.join(', ')}`); process.exit(1) }
  const extra = installed.filter((n) => !picked.includes(n))
  console.log(`picked (${picked.length}): ${picked.join(', ')}`)
  console.log(`also installed as dependencies (${extra.length}): ${extra.join(', ') || '—'}`)
  console.log(`start at boot: ${bootServices(manifest, picked, installed).join(', ') || '—'}`)
}

function copyTree(from, to) {
  const st = fs.statSync(from)
  if (st.isDirectory()) {
    fs.mkdirSync(to, { recursive: true })
    for (const e of fs.readdirSync(from)) if (!IGNORED.test(e)) copyTree(path.join(from, e), path.join(to, e))
  } else {
    fs.mkdirSync(path.dirname(to), { recursive: true })
    fs.copyFileSync(from, to)
  }
}

function moduleFile(dir, p) {
  const base = path.join(ROOT, dir, p)
  for (const c of [base, `${base}.lua`, `${base}.luau`]) if (fs.existsSync(c)) return c
  throw new Error(`no file for ${dir}/${p}`)
}

function cmdBuild(args) {
  cmdCheck({ quiet: true })
  const manifest = readManifest()
  const picked = parseSelection(args, manifest)
  const outIdx = args.indexOf('--out')
  if (outIdx < 0 || !args[outIdx + 1]) throw new Error('build needs --out <dir>')
  if (picked.length === 0) console.warn('! nothing picked: installing Core only')
  const { installed, unknown } = closure(manifest, picked)
  if (unknown.length) throw new Error(`unknown package(s): ${unknown.join(', ')}`)
  const out = path.resolve(args[outIdx + 1])
  // Never write into this repo, and only replace a directory that is empty or a
  // previous build (it has gaxia-packages.json) — `build` deletes <out>/src.
  const rel = path.relative(ROOT, out)
  if (rel === '' || !rel.startsWith('..') && !path.isAbsolute(rel)) throw new Error(`--out must be outside the Gaxia repo (${out})`)
  if (path.relative(out, ROOT) === '' || !path.relative(out, ROOT).startsWith('..')) throw new Error(`--out must not contain the Gaxia repo (${out})`)
  const isPrevious = fs.existsSync(path.join(out, 'gaxia-packages.json'))
  const isEmpty = !fs.existsSync(out) || fs.readdirSync(out).length === 0
  if (!isPrevious && !isEmpty && !args.includes('--force'))
    throw new Error(`${out} is not empty and is not a previous build (no gaxia-packages.json). Use an empty directory such as ${path.join(out, 'gaxia')}, or --force to replace its src/ and default.project.json`)
  const srcOut = path.join(out, 'src')
  if (fs.existsSync(srcOut)) fs.rmSync(srcOut, { recursive: true })
  const kept = keptPaths(manifest, installed)

  for (const [side, { dir }] of Object.entries(SIDES)) {
    const to = path.join(srcOut, path.relative('src', dir))
    fs.mkdirSync(to, { recursive: true })
    for (const p of kept[side]) {
      const from = moduleFile(dir, p)
      copyTree(from, path.join(to, path.relative(path.join(ROOT, dir), from)))
    }
    // Folders stay even when nothing in them is installed (the loaders expect Lib,
    // Shared, Client, Client/UI); the Companion's prune keeps them the same way.
    const folders = (rel) => {
      for (const e of fs.readdirSync(path.join(ROOT, dir, rel), { withFileTypes: true })) {
        const sub = path.join(rel, e.name)
        if (!e.isDirectory() || IGNORED.test(e.name)) continue
        if (['init.lua', 'init.luau'].some((f) => fs.existsSync(path.join(ROOT, dir, sub, f)))) continue // a module
        fs.mkdirSync(path.join(to, sub), { recursive: true })
        folders(sub)
      }
    }
    folders('')
    const loader = path.join(ROOT, dir, 'init.lua')
    fs.writeFileSync(path.join(to, 'init.lua'), pruneTypeLines(fs.readFileSync(loader, 'utf8'), kept[side]))
  }
  for (const f of ['ServerScriptService/Gaxia_ServerBootstrap.server.lua', 'StarterPlayer/StarterPlayerScripts/Gaxia_ClientBootstrap.client.lua']) {
    fs.mkdirSync(path.dirname(path.join(srcOut, f)), { recursive: true })
    fs.copyFileSync(path.join(ROOT, 'src', f), path.join(srcOut, f))
  }

  const project = JSON.parse(fs.readFileSync(path.join(ROOT, 'default.project.json'), 'utf8'))
  const pick = picked.filter((n) => installed.includes(n)).join(',')
  // The package roots belong to this build: Rojo removes modules a previous,
  // bigger install left in the place instead of keeping them.
  for (const node of [project.tree.ReplicatedStorage.Gaxia_Packages, project.tree.ServerStorage.Gaxia_Packages_Server]) {
    node.$attributes = { [ATTRIBUTE]: pick }
    node.$ignoreUnknownInstances = false
  }
  fs.writeFileSync(path.join(out, 'default.project.json'), JSON.stringify(project, null, 2) + '\n')
  fs.writeFileSync(path.join(out, 'gaxia-packages.json'), JSON.stringify({ packages: picked }, null, 2) + '\n')

  const extra = installed.filter((n) => !picked.includes(n))
  console.log(`✓ ${out}`)
  console.log(`  picked: ${picked.join(', ') || '—'}`)
  console.log(`  + dependencies: ${extra.join(', ') || '—'}`)
  console.log(`  rojo serve ${path.relative(process.cwd(), path.join(out, 'default.project.json'))}`)
  console.log(`  (re-run with --from ${path.relative(process.cwd(), path.join(out, 'gaxia-packages.json'))} to rebuild the same pick)`)
}

function cmdList() {
  const manifest = readManifest()
  let cat = ''
  for (const p of manifest.Packages) {
    if (p.Category !== cat) { cat = p.Category; console.log(`\n${cat}`) }
    const req = p.Requires.length ? `  (needs ${p.Requires.join(', ')})` : ''
    console.log(`  ${p.Boot ? '●' : ' '} ${p.Name.padEnd(26)} ${p.Description}${req}`)
  }
  console.log('\n● starts at server boot whenever installed; other services start at boot when picked, else on first use')
}

const isMain = process.argv[1] && fs.realpathSync(path.resolve(process.argv[1])) === fs.realpathSync(fileURLToPath(import.meta.url))
if (isMain) {
  const [cmd, ...args] = process.argv.slice(2)
  try {
    if (cmd === 'check') cmdCheck()
    else if (cmd === 'fix') cmdFix()
    else if (cmd === 'list') cmdList()
    else if (cmd === 'resolve') cmdResolve(args)
    else if (cmd === 'build') cmdBuild(args)
    else {
      console.error('usage: node tools/packages.mjs <list|check|fix|resolve|build> …  (see the header of this file)')
      process.exit(2)
    }
  } catch (e) {
    console.error(`✗ ${e.message}`)
    process.exit(1)
  }
}
