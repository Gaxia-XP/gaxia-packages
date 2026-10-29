#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────
// tools/run-game.mjs — run a Gaxia game headlessly and see what Studio Play
// would show: runtime errors (with the script, line and stack), warnings,
// prints, hangs (threads that wait forever) and kicks.
//
// It simulates a Roblox server plus one client per player under Lune
// (tools/harness/, Luau). Time is simulated: a 10 s run takes about a second.
//
// Usage (from the repo root):
//   node tools/run-game.mjs                          # the framework alone (full install)
//   node tools/run-game.mjs --game <dir>             # framework + your game scripts
//   node tools/run-game.mjs --packages Data,Economy  # only these packages (+ what they need); all = every one
//   node tools/run-game.mjs --build <dir>            # a tree from `packages.mjs build --out <dir>`
//                                                    # (any folder with a default.project.json)
//   node tools/run-game.mjs --self-test              # prove the harness catches bugs
//
// <dir> for --game mirrors the Explorer, one folder per service:
//   <dir>/ServerScriptService/CoinShop.server.lua       → Script
//   <dir>/StarterPlayer/StarterPlayerScripts/Hud.client.lua → LocalScript
//   <dir>/ServerStorage/GameModules/Catalog.lua          → ModuleScript (folders → Folder)
//   <dir>/ReplicatedStorage/..., Workspace/..., StarterGui/...
//
// Options:
//   --players N        players that join (default 1)
//   --seconds S        simulated seconds after they join (default 10)
//   --scenario f.lua   custom steps instead of the default (see tools/harness/README.md)
//                      tools/harness/scenarios/click-all.lua = default run + click every button
//   --json out.json    write the full report as JSON
//   --quiet            do not list prints
//   --no-studio        RunService:IsStudio() returns false (default: true, like Studio Play)
//   --datastore M      ok (default) | fail | studio-off: make every DataStore call error
//   --memorystore M    ok (default) | fail: make every MemoryStore call error
//                      (an unpublished place, or Studio API access off)
//   --http             HttpService.HttpEnabled = true (requests return an empty 200)
//   --signals M        deferred (default, Roblox's default) | immediate
//   --bare             do not include the framework (only --game)
//   --timeout MS       stop when no progress is seen for MS ms of real time
//                      (default 60000; a loop that never yields)
//
// Exit code: 0 = no errors and no hangs (the only pass);
// 1 = the game has errors or hangs, or none/part of your --game code ran (GAME LAYOUT);
// 2 = HARNESS ERROR (the harness itself failed — not your game's fault),
//     SCENARIO ERROR (your --scenario file failed), or a bad command line.
// ─────────────────────────────────────────────────────────────
import { spawn, execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const HARNESS = path.join(ROOT, 'tools', 'harness')
const SERVICE_DIRS = new Set(['Workspace', 'Players', 'Lighting', 'ReplicatedFirst', 'ReplicatedStorage', 'ServerScriptService', 'ServerStorage',
  'StarterGui', 'StarterPack', 'StarterPlayer', 'Teams', 'SoundService', 'Chat', 'TextChatService', 'LocalizationService', 'TestService'])

// ── project → tree ───────────────────────────────────────────────────────────
// Node format read by tools/harness/main.luau:
//   { n: name, c: className, s: source?, p: properties?, a: attributes?, t: tags?, k: children? }
const globToRegex = (g) => new RegExp('^' + g.split('**/').map((part) => part.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '[^/]*')).join('(?:.*/)?') + '$')

function readMeta(file) {
  if (!fs.existsSync(file)) return null
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch (e) { throw new Error(`${file}: ${e.message}`) }
}

function applyMeta(node, meta) {
  if (!meta) return node
  if (meta.className) node.c = meta.className
  if (meta.properties) node.p = { ...(node.p || {}), ...meta.properties }
  if (meta.attributes) node.a = { ...(node.a || {}), ...meta.attributes }
  return node
}

// .model.json: Rojo 7 keys (className, properties, attributes, children, name) or
// the older capitalised ones (ClassName, Properties, Children, Name).
function modelJsonNode(obj, name) {
  const node = { n: obj.name || obj.Name || name, c: obj.className || obj.ClassName || 'Folder', k: [] }
  const props = obj.properties || obj.Properties
  if (props) {
    node.p = { ...props }
    if (node.p.Attributes && typeof node.p.Attributes === 'object') { node.a = node.p.Attributes; delete node.p.Attributes }
  }
  const attrs = obj.attributes || obj.Attributes
  if (attrs) node.a = { ...(node.a || {}), ...attrs }
  for (const c of obj.children || obj.Children || []) node.k.push(modelJsonNode(c, c.name || c.Name || c.className || c.ClassName))
  return node
}

const SCRIPT_EXT = [
  [/\.server\.luau?$/, 'Script'],
  [/\.client\.luau?$/, 'LocalScript'],
  [/\.luau?$/, 'ModuleScript'],
]

function fileNode(file, name, notes) {
  const base = path.basename(file)
  for (const [re, cls] of SCRIPT_EXT) {
    if (re.test(base)) {
      const n = name ?? base.replace(re, '')
      return applyMeta({ n, c: cls, s: fs.readFileSync(file, 'utf8'), f: file }, readMeta(file.replace(re, '.meta.json')))
    }
  }
  if (base.endsWith('.model.json')) return modelJsonNode(JSON.parse(fs.readFileSync(file, 'utf8')), name ?? base.replace(/\.model\.json$/, ''))
  if (base.endsWith('.json') && !base.endsWith('.meta.json') && !base.endsWith('.project.json')) {
    const text = fs.readFileSync(file, 'utf8')
    return { n: name ?? base.replace(/\.json$/, ''), c: 'ModuleScript', s: `return game:GetService("HttpService"):JSONDecode([==[${text}]==])` }
  }
  if (base.endsWith('.txt')) return { n: name ?? base.replace(/\.txt$/, ''), c: 'StringValue', p: { Value: fs.readFileSync(file, 'utf8') } }
  if (/\.rbxmx?$/.test(base)) { notes.push(`harness cannot load binary/XML model files: ${file}`); return null }
  return null
}

function dirNode(dir, name, ignore, notes) {
  const entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
  let node = { n: name, c: 'Folder', k: [] }
  for (const [re, cls] of SCRIPT_EXT) {
    const init = entries.find((e) => e.isFile() && re.test(e.name) && e.name.replace(re, '') === 'init')
    if (init) { node.c = cls; node.s = fs.readFileSync(path.join(dir, init.name), 'utf8'); node.f = path.join(dir, init.name); break }
  }
  applyMeta(node, readMeta(path.join(dir, 'init.meta.json')))
  for (const e of entries) {
    const p = path.join(dir, e.name)
    const rel = p.split(path.sep).join('/')
    if (ignore.some((re) => re.test(rel) || re.test(e.name))) continue
    if (e.isDirectory()) node.k.push(dirNode(p, e.name, ignore, notes))
    else if (/^init\.(server\.|client\.)?luau?$/.test(e.name) || e.name.endsWith('.meta.json') || e.name === 'init.meta.json') continue
    else {
      const child = fileNode(p, undefined, notes)
      if (child) node.k.push(child)
    }
  }
  return node
}

function pathNode(p, name, ignore, notes) {
  if (!fs.existsSync(p)) throw new Error(`project path does not exist: ${p}`)
  return fs.statSync(p).isDirectory() ? dirNode(p, name, ignore, notes) : fileNode(p, name, notes)
}

function projectNode(spec, name, dir, ignore, notes) {
  let node = { n: name, k: [] }
  if (spec.$path) {
    const from = pathNode(path.resolve(dir, spec.$path), name, ignore, notes)
    if (from) node = { ...from, n: name }
  }
  if (spec.$className) node.c = spec.$className
  if (spec.$properties) node.p = { ...(node.p || {}), ...spec.$properties }
  if (spec.$attributes) node.a = { ...(node.a || {}), ...spec.$attributes }
  if (spec.$tags) node.t = spec.$tags
  for (const [k, v] of Object.entries(spec)) {
    if (k.startsWith('$')) continue
    node.k = (node.k || []).filter((c) => c.n !== k)
    node.k.push(projectNode(v, k, dir, ignore, notes))
  }
  return node
}

export function readProject(projectFile, notes = []) {
  const proj = JSON.parse(fs.readFileSync(projectFile, 'utf8'))
  const ignore = (proj.globIgnorePaths || []).map(globToRegex)
  return projectNode(proj.tree, 'DataModel', path.dirname(projectFile), ignore, notes)
}

function mergeInto(parent, overlay) {
  parent.k = parent.k || []
  const existing = parent.k.find((c) => c.n === overlay.n)
  if (existing && overlay.c === 'Folder' && overlay.s === undefined && existing.s === undefined) {
    for (const c of overlay.k || []) mergeInto(existing, c)
    return
  }
  parent.k = parent.k.filter((c) => c !== existing)
  parent.k.push(overlay)
}

// Levenshtein distance, for "did you mean ServerScriptService?"
function editDistance(a, b) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)])
  for (let j = 1; j <= b.length; j++) d[0][j] = j
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++) d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1))
  return d[a.length][b.length]
}
function closestService(name) {
  const lower = name.toLowerCase()
  for (const s of SERVICE_DIRS) if (s.toLowerCase() === lower) return s
  if (['starterplayerscripts', 'startercharacterscripts'].includes(lower)) return `StarterPlayer/${lower === 'starterplayerscripts' ? 'StarterPlayerScripts' : 'StarterCharacterScripts'}`
  let best = null
  let bestD = Infinity
  for (const s of SERVICE_DIRS) {
    const dist = editDistance(lower, s.toLowerCase())
    if (dist < bestD) { bestD = dist; best = s }
  }
  return bestD <= Math.max(3, Math.floor(name.length / 4)) ? best : null
}

// Every Script / LocalScript / ModuleScript node that came from a file under `dir`.
function scriptNodes(node, dir, out = [], trail = []) {
  const here = [...trail, node.n]
  if (node.f && node.f.startsWith(dir + path.sep) && ['Script', 'LocalScript', 'ModuleScript'].includes(node.c)) out.push({ cls: node.c, file: node.f, path: here.join('.') })
  for (const c of node.k || []) scriptNodes(c, dir, out, here)
  return out
}

// Overlay a game directory (one folder per service) on the tree. Layout mistakes
// (code that would never run) go to `layout`; they make the run fail.
export function overlayGame(tree, gameDir, notes = [], layout = []) {
  if (!fs.existsSync(gameDir)) throw new UsageError(`--game folder not found: ${gameDir}`)
  if (!fs.statSync(gameDir).isDirectory()) throw new UsageError(`--game must be a folder (one sub-folder per service, e.g. <dir>/ServerScriptService), not a file: ${gameDir}`)
  if (fs.existsSync(path.join(gameDir, 'default.project.json')) && !SERVICE_DIRS.has(path.basename(gameDir)))
    notes.push(`--game ${gameDir} has a default.project.json: --game reads only its service folders; to run that Rojo project use --build ${gameDir}`)
  const base = path.basename(gameDir)
  if (SERVICE_DIRS.has(base) || closestService(base)?.startsWith('StarterPlayer/'))
    layout.push(`--game points at the service folder "${base}" itself: pass its parent folder (--game ${path.dirname(gameDir)}), which holds one folder per service`)
  for (const e of fs.readdirSync(gameDir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    if (!e.isDirectory()) {
      // Only stray code fails the run; notes next to it (PACKAGES.txt, README.md,
      // *.json, ...) are not game code and are ignored silently.
      if (/\.luau?$/.test(e.name))
        layout.push(`file ${e.name} at the top of --game was ignored: put it in a service folder, e.g. ServerScriptService/${e.name.replace(/(\.server|\.client)?\.luau?$/, '.server.lua')} (server) or StarterPlayer/StarterPlayerScripts/${e.name.replace(/(\.server|\.client)?\.luau?$/, '.client.lua')} (client)`)
      continue
    }
    if (e.name.startsWith('.')) continue
    if (!SERVICE_DIRS.has(e.name)) {
      const near = closestService(e.name)
      layout.push(`folder ${e.name} was ignored: it is not a service name${near ? ` — did you mean ${near}?` : ''} (folders: ${[...SERVICE_DIRS].join(', ')})`)
      continue
    }
    const node = dirNode(path.join(gameDir, e.name), e.name, [], notes)
    let svc = tree.k.find((c) => c.n === e.name)
    if (!svc) { svc = { n: e.name, c: e.name, k: [] }; tree.k.push(svc) }
    for (const c of node.k) mergeInto(svc, c)
  }
  return tree
}

// ── lune ─────────────────────────────────────────────────────────────────────
function findLune() {
  if (process.env.LUNE) return process.env.LUNE
  return 'lune'
}

export class UsageError extends Error {}

function buildPackages(list) {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'gaxia-run-'))
  const dir = path.join(out, 'gaxia')
  const pick = list === 'all' ? ['--all'] : ['--select', list]
  try {
    execFileSync(process.execPath, [path.join(ROOT, 'tools', 'packages.mjs'), 'build', ...pick, '--out', dir], { stdio: 'pipe' })
  } catch (e) {
    fs.rmSync(out, { recursive: true, force: true })
    throw new UsageError(`--packages ${list}: ${(e.stderr?.toString() || e.message).trim()} (see: node tools/packages.mjs list)`)
  }
  return { dir, cleanup: () => fs.rmSync(out, { recursive: true, force: true }) }
}

// Temp dirs and the lune child of runs in progress, cleaned on Ctrl-C / SIGTERM.
const live = new Set()
let signalsHooked = false
function hookSignals() {
  if (signalsHooked) return
  signalsHooked = true
  for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
    process.on(sig, () => {
      for (const r of live) { try { r.child?.kill('SIGKILL') } catch {} try { r.cleanup() } catch {} }
      process.exit(code)
    })
  }
}

// Run the harness. Returns the report object (see summarize()).
export async function runGame(opts = {}) {
  hookSignals()
  const notes = []
  const layout = []
  const run = { child: null, cleanups: [], cleanup() { for (const f of this.cleanups.splice(0)) f() } }
  live.add(run)
  try {
    return await runGameInner(opts, notes, layout, run)
  } finally {
    run.cleanup()
    live.delete(run)
  }
}

async function runGameInner(opts, notes, layout, run) {
  let tree
  let label = 'framework (full install)'
  if (opts.bare) {
    tree = { n: 'DataModel', c: 'DataModel', k: [] }
    label = 'no framework'
  } else if (opts.packages) {
    const b = buildPackages(opts.packages)
    run.cleanups.push(b.cleanup)
    tree = readProject(path.join(b.dir, 'default.project.json'), notes)
    label = `packages ${opts.packages}`
  } else if (opts.build) {
    const proj = path.join(path.resolve(opts.build), 'default.project.json')
    if (!fs.existsSync(proj)) throw new UsageError(`--build: no default.project.json in ${opts.build}`)
    tree = readProject(proj, notes)
    label = `build ${opts.build}`
  } else {
    tree = readProject(path.join(ROOT, 'default.project.json'), notes)
  }
  const gameDir = opts.game ? path.resolve(opts.game) : null
  if (gameDir) {
    overlayGame(tree, gameDir, notes, layout)
    label += ` + game ${opts.game}`
  }
  const gameScripts = gameDir ? (tree.k || []).flatMap((svc) => scriptNodes(svc, gameDir)) : []
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'gaxia-harness-'))
  run.cleanups.push(() => fs.rmSync(work, { recursive: true, force: true }))
  const treeFile = path.join(work, 'tree.json')
  const optFile = path.join(work, 'options.json')
  fs.writeFileSync(treeFile, JSON.stringify(tree))
  fs.writeFileSync(optFile, JSON.stringify({
    harnessDir: HARNESS,
    players: opts.players ?? 1,
    seconds: opts.seconds ?? 10,
    studio: opts.studio ?? true,
    scenarioFile: opts.scenario ? path.resolve(opts.scenario) : undefined,
    seed: opts.seed ?? 1,
    dataStore: opts.dataStore ?? 'ok',
    memoryStore: opts.memoryStore ?? 'ok',
    httpEnabled: opts.http ?? false,
    signalBehavior: opts.signals ?? 'deferred',
  }))
  const report = { label, options: { players: opts.players ?? 1, seconds: opts.seconds ?? 10, scenario: opts.scenario }, errors: [], warnings: [], prints: [], hangs: [], kicks: [], notes: [...notes], layout: [...layout], harness: [], scenarioErrors: [], scenario: [], scripts: [], required: [], records: [], repeats: [], files: {}, end: null }
  // tree path ("ServerScriptService.CoinShop") → source file, to print the file to edit
  const walk = (node, trail) => {
    const here = trail ? `${trail}.${node.n}` : node.n
    if (node.f) report.files[here] = node.f
    for (const c of node.k || []) walk(c, here)
  }
  for (const svc of tree.k || []) walk(svc, '')
  const timeoutMs = opts.timeout ?? 60000
  await new Promise((resolve) => {
    let child
    try {
      child = spawn(findLune(), ['run', path.join(HARNESS, 'main.luau'), treeFile, optFile], { cwd: ROOT, env: { ...process.env, TZ: 'UTC' } })
      run.child = child
    } catch (e) {
      report.harness.push({ message: `could not start lune: ${e.message}` })
      return resolve()
    }
    let buf = ''
    let stderr = ''
    let timedOut = false
    let lastRun = null // "world|script" of the thread running now (from @@R lines)
    let lastTick = 0
    let timer = null
    const onTimeout = () => {
      // Roblox stops a script that runs ~10 s without yielding ("Script timeout").
      // The harness cannot stop one thread, so the run ends here.
      timedOut = true
      const [world, script] = lastRun ? lastRun.split('|') : ['?', '?']
      const known = script && script !== '?' && script !== 'engine'
      report.errors.push({
        world: world === '-' || !world ? '?' : world, time: lastTick, context: 'timeout', source: known ? script : undefined,
        message: `Script timeout: exhausted allowed execution time — ${known ? `${script} (in ${world})` : 'some code'} ran ${timeoutMs / 1000} s of real time without yielding, at about ${lastTick} s of simulated time (a loop with no task.wait?). The run stopped here.${known ? '' : ' The harness could not tell which script it was.'}`,
      })
      child.kill('SIGKILL')
    }
    const arm = () => { clearTimeout(timer); timer = setTimeout(onTimeout, timeoutMs) }
    arm()
    const onLine = (line) => {
      if (line.startsWith('@@R ')) { lastRun = line.slice(4); return }
      if (line.startsWith('@@T ')) { lastTick = Number(line.slice(4)); return }
      if (!line.startsWith('@@EV ')) { if (line.trim()) report.harness.push({ message: `stdout: ${line}`, soft: true }); return }
      let ev
      try { ev = JSON.parse(line.slice(5)) } catch { report.harness.push({ message: `bad event line: ${line.slice(0, 200)}` }); return }
      switch (ev.t) {
        case 'error': report.errors.push(ev); break
        case 'warn': report.warnings.push(ev); break
        case 'print': report.prints.push(ev); break
        case 'hang': report.hangs.push(ev); break
        case 'kick': report.kicks.push(ev); break
        case 'note': report.notes.push(ev.text); break
        case 'harness': report.harness.push(ev); break
        case 'scenarioError': report.scenarioErrors.push(ev); break
        case 'scenario': report.scenario.push(ev); break
        case 'script': report.scripts.push(ev); break
        case 'required': report.required.push(ev); break
        case 'repeat': report.repeats.push(ev); break
        case 'end': report.end = ev; break
        default: report.records.push(ev)
      }
    }
    let spawnFailed = false
    child.on('error', (e) => {
      spawnFailed = true
      report.harness.push({ message: e.code === 'ENOENT' ? 'lune is not installed or not on PATH. Install it with `rokit install` (rokit.toml lists lune) or from https://github.com/lune-org/lune/releases (0.10.x), or set LUNE=/path/to/lune' : `lune failed to start: ${e.message}`, lune: 'missing' })
    })
    child.stdout.on('data', (d) => {
      arm() // any output is progress: the watchdog only fires after timeoutMs of silence
      buf += d.toString()
      let i
      while ((i = buf.indexOf('\n')) >= 0) { onLine(buf.slice(0, i)); buf = buf.slice(i + 1) }
    })
    child.stderr.on('data', (d) => { stderr += d.toString() })
    child.on('close', (code) => {
      clearTimeout(timer)
      if (buf) onLine(buf)
      if (!report.end && !timedOut && !spawnFailed) report.harness.push({ message: `the harness stopped before the end (exit ${code})${stderr ? ':\n' + stderr.trim().split('\n').slice(0, 30).join('\n') : ''}` })
      resolve()
    })
  })
  // one entry per identical line (same world + text), with how many times it happened
  const collapse = (list, keyOf, kind) => {
    const byKey = new Map()
    for (const e of list) {
      const k = `${e.world}\u0000${keyOf(e)}`
      const first = byKey.get(k)
      if (first) first.count = (first.count ?? 1) + 1
      else { e.count = 1; byKey.set(k, e) }
    }
    for (const r of report.repeats) {
      if (r.kind !== kind) continue
      const first = byKey.get(`${r.world}\u0000${r.text}`)
      if (first) first.count = r.count
    }
    return [...byKey.values()]
  }
  report.errors = collapse(report.errors, (e) => `${e.message}\u0000${e.trace ?? ''}`, 'error')
  // then one entry per script line (an error whose text changes every frame — a
  // timestamp, a counter — is still one bug)
  const byLine = new Map()
  report.errors = report.errors.filter((e) => {
    const loc = where(e)
    if (!/:\d+$/.test(loc)) return true
    const k = `${e.world}\u0000${loc}`
    const first = byLine.get(k)
    if (!first) { byLine.set(k, e); return true }
    first.count = (first.count ?? 1) + (e.count ?? 1)
    first.variants = (first.variants ?? 1) + 1
    return false
  })
  report.warnings = collapse(report.warnings, (e) => e.text, 'warn')
  const warnBy = new Map()
  report.warnings = report.warnings.filter((w) => {
    const at = traceLoc((w.trace || '').split('\n')[0])
    if (!at) return true
    const k = `${w.world}\u0000${at}`
    const first = warnBy.get(k)
    if (!first) { warnBy.set(k, w); return true }
    first.count = (first.count ?? 1) + (w.count ?? 1)
    first.variants = (first.variants ?? 1) + 1
    return false
  })
  report.prints = collapse(report.prints, (e) => e.text, 'print')
  // hangs at the same line (200 WaitForChild calls in one loop) are one entry
  const hangBy = new Map()
  report.hangs = report.hangs.filter((h) => {
    const at = (h.trace || '').split('\n')[0]
    if (!at) return true
    const k = `${h.world}\u0000${h.kind}\u0000${at}`
    const first = hangBy.get(k)
    if (!first) { hangBy.set(k, h); h.count = 1; return true }
    first.count += 1
    return false
  })
  report.harness = report.harness.filter((h) => !h.soft || report.end === null)
  // Did the --game code run at all?
  if (gameDir && !report.harness.length && !report.scenarioErrors.length) {
    const started = new Set(report.scripts.map((s) => s.file).filter(Boolean))
    const required = new Set(report.required.map((r) => r.file))
    const runnable = gameScripts.filter((g) => g.cls !== 'ModuleScript')
    const rel = (f) => path.relative(gameDir, f).split(path.sep).join('/')
    for (const g of gameScripts) {
      if (g.cls !== 'ModuleScript' || required.has(g.file)) continue
      const parentPath = g.path.split('.').slice(0, -1).join('.')
      if (/^(ServerScriptService|StarterPlayer\.StarterPlayerScripts|StarterPlayer\.StarterCharacterScripts|StarterGui|Workspace)$/.test(parentPath))
        report.layout.push(`${rel(g.file)} is a ModuleScript (no .server/.client in its name) and nothing required it, so it never ran: name it ${path.basename(g.file).replace(/\.luau?$/, '')}${parentPath.startsWith('ServerScriptService') || parentPath === 'Workspace' ? '.server.lua' : '.client.lua'} if it is a script`)
    }
    if (!gameScripts.length) report.layout.push(`none of your --game code ran: no .server.lua / .client.lua / .lua file was found in its service folders (server scripts: ServerScriptService/X.server.lua, client scripts: StarterPlayer/StarterPlayerScripts/X.client.lua)`)
    else if (runnable.length && !runnable.some((g) => started.has(g.file))) report.layout.push(`none of your --game scripts ran (${runnable.length} found, 0 started): server scripts go in ServerScriptService/X.server.lua, client scripts in StarterPlayer/StarterPlayerScripts/X.client.lua`)
    else if (!runnable.length && !required.size) report.layout.push(`none of your --game code ran: it has only ModuleScripts (X.lua) and nothing required them; a script that runs by itself must be named X.server.lua (server) or X.client.lua (client)`)
  }
  report.exitCode = report.harness.length || report.scenarioErrors.length ? 2 : report.errors.length || report.hangs.length || report.layout.length ? 1 : 0
  return report
}

// ── summary ──────────────────────────────────────────────────────────────────
// "Script.Name:12" from a trace line ("Script.Name:12 function f"); names may hold spaces.
export function traceLoc(line) {
  const m = /^(.+?:\d+)(?: |$)/.exec(line || '')
  return m ? m[1] : null
}
function where(err) {
  if (err.source) return err.source
  // the location is "<full name>:<line>: " at the start of the first line; a full
  // name can hold spaces, brackets and non-ASCII letters, but not ": "
  const m = /^([^\n]+?):(\d+): /.exec(err.message)
  if (m && !m[1].includes(': ')) return `${m[1]}:${m[2]}`
  return traceLoc((err.trace || '').split('\n')[0]) ?? '(no script location)'
}

// Runtime names of copied scripts → where they live in Studio / on disk.
//   Players.<p>.PlayerScripts.X → StarterPlayer.StarterPlayerScripts.X
//   Players.<p>.PlayerGui.X     → StarterGui.X
//   Players.<p>.Backpack.X      → StarterPack.X
//   Workspace.<p>.X             → StarterPlayer.StarterCharacterScripts.X
export function studioPath(loc) {
  return loc
    .replace(/^Players\.[^.]+\.PlayerScripts\./, 'StarterPlayer.StarterPlayerScripts.')
    .replace(/^Players\.[^.]+\.PlayerGui\./, 'StarterGui.')
    .replace(/^Players\.[^.]+\.Backpack\./, 'StarterPack.')
    .replace(/^Workspace\.Player\d+\./, 'StarterPlayer.StarterCharacterScripts.')
}
export function fileOf(report, loc) {
  if (!loc) return null
  const name = loc.replace(/:\d+$/, '')
  const f = report.files?.[name] ?? report.files?.[studioPath(name)]
  if (!f) return null
  const rel = path.relative(process.cwd(), f)
  return rel.startsWith('..') ? f : rel
}

// Framework scripts (the loaders, their modules and the bootstrap Scripts). An error
// located in one is usually caused by the game code that called it: point at that.
export const FRAMEWORK = /^(ReplicatedStorage\.Gaxia_Packages|ServerStorage\.Gaxia_Packages_Server|ServerScriptService\.Gaxia_ServerBootstrap|Players\.[^.]+\.PlayerScripts\.Gaxia_ClientBootstrap)\b/
function isFramework(loc) { return FRAMEWORK.test(loc) }
function gameFrame(trace) {
  for (const line of (trace || '').split('\n')) {
    const loc = traceLoc(line)
    if (loc && !isFramework(loc)) return loc
  }
  return null
}

export function summarize(report, { quiet = false } = {}) {
  const out = []
  const n = (x, word) => `${x} ${word}${x === 1 ? '' : 's'}`
  const c = report.end?.counts ?? {}
  out.push(`Gaxia harness — ${report.label} — ${report.options.scenario ? `scenario ${report.options.scenario}` : `${n(report.options.players, 'player')}, ${report.options.seconds} s after join`} (simulated time)`)
  if (report.harness.length) {
    out.push('')
    out.push(`HARNESS ERROR (${report.harness.length}) — the harness itself failed; this is NOT an error in the game:`)
    for (const h of report.harness) out.push(`  ! ${h.message.split('\n').join('\n    ')}`)
  }
  if (report.scenarioErrors.length) {
    out.push('')
    out.push('SCENARIO ERROR — your --scenario file failed (fix the scenario; this is not a game error):')
    for (const e of report.scenarioErrors) out.push(`  ! ${e.message.split('\n').join('\n    ')}`)
  }
  const layout = report.layout ?? []
  if (layout.length) {
    out.push('')
    out.push(`GAME LAYOUT (${layout.length}) — part or all of your --game code did not run (fix the folders / file names):`)
    for (const l of layout) out.push(`  ! ${l}`)
  }
  out.push('')
  if (report.harness.length) out.push(`RESULT: HARNESS ERROR → exit ${report.exitCode} (nothing was checked; the counts below mean nothing)`)
  else if (report.scenarioErrors.length) out.push(`RESULT: SCENARIO ERROR → exit ${report.exitCode} (${n(report.errors.length, 'error')}, ${n(report.hangs.length, 'hang')} before it stopped)`)
  else out.push(`RESULT: ${n(report.errors.length, 'error')}, ${n(report.hangs.length, 'hang')}, ${n(report.warnings.length, 'warning')}${layout.length ? `, ${n(layout.length, 'layout problem')}` : ''} → exit ${report.exitCode}`)
  const MAX = 20
  if (report.errors.length) {
    out.push('')
    out.push(`ERRORS (${report.errors.length}${report.errors.length > MAX ? `, first ${MAX} shown` : ''}) — these would be red in Studio's Output:`)
    report.errors.slice(0, MAX).forEach((e, i) => {
      const loc = where(e)
      const msg = e.message.startsWith(loc + ': ') ? e.message.slice(loc.length + 2) : e.message
      const times = e.variants > 1 ? `  (x${e.count} at this line, messages differ)` : e.count > 1 ? `  (x${e.count})` : ''
      out.push(`  ${i + 1}. [${e.world}] ${loc} — ${msg}${times}${e.context ? `  [during ${e.context}]` : ''}`)
      const mine = isFramework(loc) ? gameFrame(e.trace) : null
      if (mine) out.push(`     your code: ${mine}  (the error is raised inside Gaxia, but this line called it)`)
      const file = fileOf(report, mine ?? loc)
      if (file) out.push(`     file: ${file}`)
      for (const line of (e.trace || '').split('\n').filter(Boolean).slice(0, 8)) out.push(`       at ${line}`)
    })
    if (report.errors.length > MAX) out.push(`  … ${report.errors.length - MAX} more (see --json)`)
  }
  if (report.warnings.length) {
    out.push('')
    out.push(`WARNINGS (${report.warnings.length}):`)
    for (const w of report.warnings.slice(0, 40)) {
      out.push(`  - [${w.world}] ${w.text}${w.variants > 1 ? `  (x${w.count} at this line, texts differ)` : w.count > 1 ? `  (x${w.count})` : ''}${w.source ? `  (${w.source})` : ''}`)
      for (const line of (w.trace || '').split('\n').filter(Boolean).slice(0, 3)) out.push(`       at ${line}`)
    }
    if (report.warnings.length > 40) out.push(`  … ${report.warnings.length - 40} more (see --json)`)
  }
  if (report.hangs.length) {
    out.push('')
    out.push(`HANGS (${report.hangs.length}${report.hangs.length > MAX ? `, first ${MAX} shown` : ''}) — threads still waiting at the end, forever in Roblox too:`)
    for (const h of report.hangs.slice(0, MAX)) {
      out.push(`  - [${h.world}] ${h.text} (waiting since ${Number(h.since ?? 0).toFixed(1)} s)${h.count > 1 ? `  (x${h.count} threads waiting at this line)` : ''}`)
      const lines = (h.trace || '').split('\n').filter(Boolean)
      const file = fileOf(report, traceLoc(lines.find((l) => !isFramework(traceLoc(l) ?? '')) ?? lines[0]))
      if (file) out.push(`     file: ${file}`)
      for (const line of lines.slice(0, 4)) out.push(`       at ${line}`)
    }
    if (report.hangs.length > MAX) out.push(`  … ${report.hangs.length - MAX} more (see --json)`)
  }
  if (report.kicks.length) {
    out.push('')
    out.push(`KICKS (${report.kicks.length}):`)
    for (const k of report.kicks) out.push(`  - ${k.player} kicked by ${k.by}: "${k.message}"${k.trace ? `  at ${k.trace.split('\n')[0]}` : ''}`)
  }
  out.push('')
  const remotes = Object.values(report.end?.remotes ?? {}).reduce((a, b) => a + b, 0)
  if (!report.harness.length) out.push(`COUNTS: ${n(c.prints ?? report.prints.length, 'print')} · ${n(remotes, 'remote call')} · ${n(c.dataStoreCalls ?? 0, 'DataStore call')} · ${n(report.kicks.length, 'kick')} · ${n(report.scripts.length, 'script')} started`)
  const purchases = report.records.filter((r) => r.t === 'purchase')
  if (purchases.length) out.push(`PURCHASES: ${purchases.map((p) => `${p.player} product ${p.productId} → ${p.result}`).join('; ')}`)
  if (report.scenario.length) {
    out.push('')
    out.push('SCENARIO LOG:')
    for (const s of report.scenario) out.push(`  ${Number(s.time).toFixed(2)}s  ${s.text}`)
  }
  if (report.notes.length) {
    out.push('')
    out.push(`UNMODELED (${report.notes.length}) — the harness only stubs these; check them in Studio if they matter:`)
    for (const note of report.notes.slice(0, 30)) out.push(`  ~ ${note}`)
    if (report.notes.length > 30) out.push(`  … ${report.notes.length - 30} more (see --json)`)
  }
  if (!quiet && report.prints.length) {
    // When the game prints anything, the framework's own boot prints are noise: hide them.
    const fromGame = report.prints.filter((p) => !isFramework(p.source ?? ''))
    const shown = fromGame.length ? fromGame : report.prints
    const hidden = report.prints.length - shown.length
    out.push('')
    out.push(`PRINTS (${shown.length}${shown.length > 60 ? ', first 60 shown' : ''}${hidden ? `; ${hidden} Gaxia boot print(s) hidden, see --json` : ''}; hide with --quiet):`)
    for (const p of shown.slice(0, 60)) out.push(`  ${Number(p.time).toFixed(2)}s [${p.world}] ${p.text}${p.count > 1 ? `  (x${p.count})` : ''}`)
  }
  return out.join('\n')
}

// ── self-test ────────────────────────────────────────────────────────────────
async function selfTest() {
  const dir = path.join(HARNESS, 'tests')
  const cases = fs.readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name).sort()
  let failed = 0
  for (const name of cases) {
    const caseDir = path.join(dir, name)
    const expect = JSON.parse(fs.readFileSync(path.join(caseDir, 'expect.json'), 'utf8'))
    const report = await runGame({
      bare: expect.framework === false,
      packages: expect.packages,
      game: fs.existsSync(path.join(caseDir, 'game')) ? path.join(caseDir, 'game') : undefined,
      scenario: fs.existsSync(path.join(caseDir, 'scenario.lua')) ? path.join(caseDir, 'scenario.lua') : undefined,
      players: expect.players,
      seconds: expect.seconds,
    })
    const problems = []
    const has = (list, field, want) => list.some((x) => String(x[field] ?? '').includes(want.contains) && (!want.world || x.world === want.world))
    if (expect.exit !== undefined && report.exitCode !== expect.exit) problems.push(`exit ${report.exitCode}, expected ${expect.exit}`)
    if (expect.errorCount !== undefined && report.errors.length !== expect.errorCount) problems.push(`${report.errors.length} errors, expected ${expect.errorCount}`)
    if (expect.hangCount !== undefined && report.hangs.length !== expect.hangCount) problems.push(`${report.hangs.length} hangs, expected ${expect.hangCount}`)
    if (expect.kicks !== undefined && report.kicks.length !== expect.kicks) problems.push(`${report.kicks.length} kicks, expected ${expect.kicks}`)
    for (const want of expect.errors ?? []) if (!has(report.errors, 'message', want)) problems.push(`no error containing "${want.contains}"${want.world ? ` in ${want.world}` : ''}`)
    for (const want of expect.errorTrace ?? []) if (!report.errors.some((e) => (e.trace ?? '').includes(want))) problems.push(`no error traceback containing "${want}"`)
    for (const want of expect.hangs ?? []) if (!has(report.hangs, 'text', want)) problems.push(`no hang containing "${want.contains}"`)
    for (const want of expect.warnings ?? []) if (!has(report.warnings, 'text', want)) problems.push(`no warning containing "${want.contains}"`)
    for (const want of expect.prints ?? []) if (!has(report.prints, 'text', want)) problems.push(`no print containing "${want.contains}"`)
    for (const want of expect.kickMessages ?? []) if (!report.kicks.some((k) => k.message.includes(want))) problems.push(`no kick with message "${want}"`)
    const text = summarize(report, { quiet: true })
    for (const want of expect.summary ?? []) if (!text.includes(want)) problems.push(`summary has no "${want}"`)
    for (const bad of expect.summaryNot ?? []) if (text.includes(bad)) problems.push(`summary has "${bad}" (it should not)`)
    for (const bad of expect.notPrints ?? []) if (report.prints.some((x) => String(x.text ?? '').includes(bad))) problems.push(`a print contains "${bad}" (it should not)`)
    if (report.harness.length) problems.push(`HARNESS ERROR: ${report.harness.map((h) => h.message).join(' | ').slice(0, 500)}`)
    if (problems.length) {
      failed++
      console.log(`✗ ${name} — ${expect.description ?? ''}`)
      for (const p of problems) console.log(`    ${p}`)
      console.log(summarize(report, { quiet: true }).split('\n').map((l) => '    | ' + l).join('\n'))
    } else {
      console.log(`✓ ${name} — ${expect.description ?? ''}`)
    }
  }
  console.log(`self-test: ${cases.length - failed}/${cases.length} passed`)
  return failed ? 1 : 0
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const o = {}
  const val = (i) => { if (argv[i + 1] === undefined) throw new Error(`${argv[i]} needs a value`); return argv[i + 1] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    switch (a) {
      case '--game': o.game = val(i); i++; break
      case '--build': o.build = val(i); i++; break
      case '--packages': o.packages = val(i); i++; break
      case '--players': o.players = Number(val(i)); i++; break
      case '--seconds': o.seconds = Number(val(i)); i++; break
      case '--scenario': o.scenario = val(i); i++; break
      case '--json': o.json = val(i); i++; break
      case '--datastore': o.dataStore = val(i); i++; break
      case '--memorystore': o.memoryStore = val(i); i++; break
      case '--signals': o.signals = val(i); i++; break
      case '--timeout': o.timeout = Number(val(i)); i++; break
      case '--seed': o.seed = Number(val(i)); i++; break
      case '--quiet': o.quiet = true; break
      case '--studio': o.studio = true; break
      case '--no-studio': o.studio = false; break
      case '--http': o.http = true; break
      case '--bare': o.bare = true; break
      case '--self-test': o.selfTest = true; break
      case '-h': case '--help': o.help = true; break
      default: throw new Error(`unknown option ${a} (see --help)`)
    }
  }
  if (o.build && o.packages) throw new Error('use --build or --packages, not both')
  if (o.bare && (o.packages !== undefined || o.build)) throw new Error('--bare runs without the framework: do not combine it with --packages or --build')
  if (o.dataStore && !['ok', 'fail', 'studio-off'].includes(o.dataStore)) throw new Error('--datastore must be ok, fail or studio-off')
  if (o.memoryStore && !['ok', 'fail'].includes(o.memoryStore)) throw new Error('--memorystore must be ok or fail')
  if (o.signals !== undefined && !['deferred', 'immediate'].includes(o.signals)) throw new Error('--signals must be deferred or immediate')
  if (o.packages !== undefined && !o.packages.split(',').some((x) => x.trim())) throw new Error('--packages needs package names (comma separated, or all); see node tools/packages.mjs list')
  if (o.players !== undefined && !(Number.isInteger(o.players) && o.players >= 1)) throw new Error('--players must be a whole number, 1 or more')
  if (o.seconds !== undefined && !(Number.isFinite(o.seconds) && o.seconds >= 0)) throw new Error('--seconds must be a number, 0 or more')
  if (o.timeout !== undefined && !(Number.isFinite(o.timeout) && o.timeout > 0)) throw new Error('--timeout must be a number of milliseconds, more than 0')
  if (o.seed !== undefined && !Number.isFinite(o.seed)) throw new Error('--seed must be a number')
  if (o.game !== undefined && !fs.existsSync(o.game)) throw new Error(`--game folder not found: ${o.game}`)
  if (o.game !== undefined && !fs.statSync(o.game).isDirectory()) throw new Error(`--game must be a folder (one sub-folder per service, e.g. <dir>/ServerScriptService), not a file: ${o.game}`)
  if (o.scenario !== undefined && !fs.existsSync(o.scenario)) throw new Error(`--scenario file not found: ${o.scenario}`)
  if (o.json !== undefined) {
    const dir = path.dirname(path.resolve(o.json))
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) throw new Error(`--json: folder ${dir} does not exist`)
  }
  if (o.scenario && (o.players !== undefined || o.seconds !== undefined))
    o.warnings = ['note: --players / --seconds are ignored with --scenario (the scenario decides who joins and how long it runs)']
  return o
}

async function main() {
  let o
  try { o = parseArgs(process.argv.slice(2)) } catch (e) { console.error(`✗ ${e.message}`); process.exit(2) }
  if (o.help) {
    const src = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8')
    // Only the header comment at the top of this file.
    const lines = src.split('\n').filter((l, i) => !(i === 0 && l.startsWith('#!')))
    const end = lines.findIndex((l) => !l.startsWith('//'))
    console.log(lines.slice(0, end < 0 ? lines.length : end).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'))
    return
  }
  if (o.selfTest) process.exit(await selfTest())
  for (const w of o.warnings ?? []) console.error(w)
  let report
  try {
    report = await runGame(o)
  } catch (e) {
    console.error(e instanceof UsageError || /not found|does not exist|no default\.project\.json/.test(e.message) ? `✗ ${e.message}` : `HARNESS ERROR: ${e.stack || e.message}`)
    process.exit(2)
  }
  console.log(summarize(report, { quiet: o.quiet }))
  if (o.json) {
    try {
      fs.writeFileSync(o.json, JSON.stringify(report, null, 2) + '\n')
    } catch (e) {
      console.error(`✗ cannot write --json file: ${e.message}`)
      process.exit(2)
    }
  }
  process.exit(report.exitCode)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main()
