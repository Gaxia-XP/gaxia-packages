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
//   --json out.json    write the full report as JSON
//   --quiet            do not list prints
//   --no-studio        RunService:IsStudio() returns false (default: true, like Studio Play)
//   --datastore M      ok (default) | fail | studio-off: make every DataStore call error
//   --http             HttpService.HttpEnabled = true (requests return an empty 200)
//   --signals M        deferred (default, Roblox's default) | immediate
//   --bare             do not include the framework (only --game)
//   --timeout MS       real-time limit (default 60000)
//
// Exit code: 0 = no errors and no hangs; 1 = the game has errors or hangs;
// 2 = the harness itself failed (shown as HARNESS ERROR — not your game's fault).
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

function modelJsonNode(obj, name) {
  const node = { n: obj.Name || name, c: obj.ClassName || 'Folder', k: [] }
  if (obj.Properties) node.p = obj.Properties
  if (obj.Attributes) node.a = obj.Attributes
  for (const c of obj.Children || []) node.k.push(modelJsonNode(c, c.Name))
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
      return applyMeta({ n, c: cls, s: fs.readFileSync(file, 'utf8') }, readMeta(file.replace(re, '.meta.json')))
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
    if (init) { node.c = cls; node.s = fs.readFileSync(path.join(dir, init.name), 'utf8'); break }
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

// Overlay a game directory (one folder per service) on the tree.
export function overlayGame(tree, gameDir, notes = []) {
  if (!fs.existsSync(gameDir)) throw new Error(`--game folder not found: ${gameDir}`)
  if (fs.existsSync(path.join(gameDir, 'default.project.json')) && !SERVICE_DIRS.has(path.basename(gameDir)))
    notes.push(`--game ${gameDir} has a default.project.json: --game reads only its service folders; to run that Rojo project use --build ${gameDir}`)
  for (const e of fs.readdirSync(gameDir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    if (!e.isDirectory()) continue
    if (!SERVICE_DIRS.has(e.name)) { notes.push(`--game: ignored folder ${e.name} (not a service name)`); continue }
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

// Run the harness. Returns the report object (see summarize()).
export async function runGame(opts = {}) {
  const notes = []
  let cleanup = () => {}
  let tree
  let label = 'framework (full install)'
  if (opts.bare) {
    tree = { n: 'DataModel', c: 'DataModel', k: [] }
    label = 'no framework'
  } else if (opts.packages) {
    const b = buildPackages(opts.packages)
    cleanup = b.cleanup
    tree = readProject(path.join(b.dir, 'default.project.json'), notes)
    label = `packages ${opts.packages}`
  } else if (opts.build) {
    const proj = path.join(path.resolve(opts.build), 'default.project.json')
    if (!fs.existsSync(proj)) throw new Error(`--build: no default.project.json in ${opts.build}`)
    tree = readProject(proj, notes)
    label = `build ${opts.build}`
  } else {
    tree = readProject(path.join(ROOT, 'default.project.json'), notes)
  }
  if (opts.game) {
    overlayGame(tree, path.resolve(opts.game), notes)
    label += ` + game ${opts.game}`
  }
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'gaxia-harness-'))
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
    httpEnabled: opts.http ?? false,
    signalBehavior: opts.signals ?? 'deferred',
  }))
  const report = { label, options: { players: opts.players ?? 1, seconds: opts.seconds ?? 10, scenario: opts.scenario }, errors: [], warnings: [], prints: [], hangs: [], kicks: [], notes: [...notes], harness: [], scenarioErrors: [], scenario: [], scripts: [], records: [], repeats: [], end: null }
  try {
    await new Promise((resolve) => {
      let child
      try {
        child = spawn(findLune(), ['run', path.join(HARNESS, 'main.luau'), treeFile, optFile], { cwd: ROOT, env: { ...process.env, TZ: 'UTC' } })
      } catch (e) {
        report.harness.push({ message: `could not start lune: ${e.message}` })
        return resolve()
      }
      let buf = ''
      let stderr = ''
      let timedOut = false
      const timer = setTimeout(() => {
        // Roblox stops a script that runs ~10 s without yielding ("Script timeout").
        // The harness cannot stop one thread, so the run ends here.
        timedOut = true
        const last = report.scripts[report.scripts.length - 1]
        report.errors.push({
          world: last?.world ?? '?', time: last?.time ?? 0, context: 'timeout',
          message: `Script timeout: exhausted allowed execution time — some code ran ${(opts.timeout ?? 60000) / 1000} s of real time without yielding (a loop with no task.wait?). The run stopped here.${last ? ` Last script started: ${last.name}.` : ''}`,
        })
        child.kill('SIGKILL')
      }, opts.timeout ?? 60000)
      const onLine = (line) => {
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
          case 'repeat': report.repeats.push(ev); break
          case 'end': report.end = ev; break
          default: report.records.push(ev)
        }
      }
      let spawnFailed = false
      child.on('error', (e) => {
        spawnFailed = true
        report.harness.push({ message: e.code === 'ENOENT' ? 'lune is not installed or not on PATH. Install it with `rokit install` (rokit.toml lists lune) or from https://github.com/lune-org/lune/releases (0.10.x), or set LUNE=/path/to/lune' : `lune failed to start: ${e.message}` })
      })
      child.stdout.on('data', (d) => {
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
  } finally {
    fs.rmSync(work, { recursive: true, force: true })
    cleanup()
  }
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
  report.warnings = collapse(report.warnings, (e) => e.text, 'warn')
  report.prints = collapse(report.prints, (e) => e.text, 'print')
  report.harness = report.harness.filter((h) => !h.soft || report.end === null)
  report.exitCode = report.harness.length || report.scenarioErrors.length ? 2 : report.errors.length || report.hangs.length ? 1 : 0
  return report
}

// ── summary ──────────────────────────────────────────────────────────────────
function where(err) {
  const m = /^([A-Za-z_][\w. -]*?):(\d+): /.exec(err.message)
  if (m) return `${m[1]}:${m[2]}`
  const first = (err.trace || '').split('\n')[0]
  return first ? first.replace(/ .*$/, '') : '(no script location)'
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
  out.push('')
  out.push(`RESULT: ${n(report.errors.length, 'error')}, ${n(report.hangs.length, 'hang')}, ${n(report.warnings.length, 'warning')} → exit ${report.exitCode}`)
  if (report.errors.length) {
    out.push('')
    out.push(`ERRORS (${report.errors.length}) — these would be red in Studio's Output:`)
    report.errors.forEach((e, i) => {
      const loc = where(e)
      const msg = e.message.startsWith(loc + ': ') ? e.message.slice(loc.length + 2) : e.message
      out.push(`  ${i + 1}. [${e.world}] ${loc} — ${msg}${e.count > 1 ? `  (x${e.count})` : ''}${e.context ? `  [during ${e.context}]` : ''}`)
      for (const line of (e.trace || '').split('\n').filter(Boolean).slice(0, 8)) out.push(`       at ${line}`)
    })
  }
  if (report.warnings.length) {
    out.push('')
    out.push(`WARNINGS (${report.warnings.length}):`)
    for (const w of report.warnings.slice(0, 40)) {
      out.push(`  - [${w.world}] ${w.text}${w.count > 1 ? `  (x${w.count})` : ''}${w.source ? `  (${w.source})` : ''}`)
      for (const line of (w.trace || '').split('\n').filter(Boolean).slice(0, 3)) out.push(`       at ${line}`)
    }
    if (report.warnings.length > 40) out.push(`  … ${report.warnings.length - 40} more (see --json)`)
  }
  if (report.hangs.length) {
    out.push('')
    out.push(`HANGS (${report.hangs.length}) — threads still waiting at the end, forever in Roblox too:`)
    for (const h of report.hangs) {
      out.push(`  - [${h.world}] ${h.text} (waiting since ${Number(h.since ?? 0).toFixed(1)} s)`)
      for (const line of (h.trace || '').split('\n').filter(Boolean).slice(0, 4)) out.push(`       at ${line}`)
    }
  }
  if (report.kicks.length) {
    out.push('')
    out.push(`KICKS (${report.kicks.length}):`)
    for (const k of report.kicks) out.push(`  - ${k.player} kicked by ${k.by}: "${k.message}"${k.trace ? `  at ${k.trace.split('\n')[0]}` : ''}`)
  }
  out.push('')
  const remotes = Object.values(report.end?.remotes ?? {}).reduce((a, b) => a + b, 0)
  out.push(`COUNTS: ${n(c.prints ?? report.prints.length, 'print')} · ${n(remotes, 'remote call')} · ${n(c.dataStoreCalls ?? 0, 'DataStore call')} · ${n(report.kicks.length, 'kick')} · ${n(report.scripts.length, 'script')} started`)
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
    out.push('')
    out.push(`PRINTS (${c.prints ?? report.prints.length}${report.prints.length > 60 ? ', first 60 shown' : ''}; hide with --quiet):`)
    for (const p of report.prints.slice(0, 60)) out.push(`  ${Number(p.time).toFixed(2)}s [${p.world}] ${p.text}${p.count > 1 ? `  (x${p.count})` : ''}`)
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
  if (o.dataStore && !['ok', 'fail', 'studio-off'].includes(o.dataStore)) throw new Error('--datastore must be ok, fail or studio-off')
  return o
}

async function main() {
  let o
  try { o = parseArgs(process.argv.slice(2)) } catch (e) { console.error(`✗ ${e.message}`); process.exit(2) }
  if (o.help) {
    const src = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8')
    console.log(src.split('\n').filter((l) => l.startsWith('//')).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'))
    return
  }
  if (o.selfTest) process.exit(await selfTest())
  let report
  try {
    report = await runGame(o)
  } catch (e) {
    console.error(e instanceof UsageError || /not found|does not exist|no default\.project\.json/.test(e.message) ? `✗ ${e.message}` : `HARNESS ERROR: ${e.stack || e.message}`)
    process.exit(2)
  }
  if (o.json) fs.writeFileSync(o.json, JSON.stringify(report, null, 2) + '\n')
  console.log(summarize(report, { quiet: o.quiet }))
  process.exit(report.exitCode)
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) main()
