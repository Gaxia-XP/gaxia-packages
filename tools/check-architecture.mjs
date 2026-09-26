#!/usr/bin/env node
// tools/check-architecture.mjs — enforce the Gaxia service architecture rules.
//
// Usage:
//   node tools/check-architecture.mjs                 # every framework file + key sync
//   node tools/check-architecture.mjs <file.lua> ...  # only these files (no key sync)
//   node tools/check-architecture.mjs --complete      # also require every Lib service to Define
//
// Needs the `luau-ast` binary (from https://github.com/luau-lang/luau/releases) on
// PATH, or set LUAU_AST=/path/to/luau-ast. No npm dependencies.
//
// Rules (see MANUAL §4 "Architecture"):
//   R1  no framework module requires a loader (Gaxia_Packages / Gaxia_Packages_Server)
//   R2  no `SharedPkg`, no `server()` helper, no `require(...) :: any`
//   R3  require arguments are static paths (no FindFirstChild/WaitForChild/variables)
//   R4  Lib/ and AntiCheat/ module bodies have no side effects (move them to Init/Start)
//   R5  Lifecycle.Define(...) is the last statement before `return`
//   R6  no `require` inside functions in Lib/ and AntiCheat/ (except the allow-list)
//   R7  keep-lazy modules are never required at the top of Lib/ and AntiCheat/ modules
//   R8  no `(Config.X or {})` — index typed Config sections directly
//   R9  Types.ServiceName = Define names; ModuleKey = loader keys = GaxiaServerPackage fields
//   R10 Define Needs are top-level required module locals
//   R11 (--complete) every Lib service module calls Lifecycle.Define

import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const AST_BIN = process.env.LUAU_AST || 'luau-ast'
const SERVER = 'src/ServerStorage/Gaxia_Packages_Server'
const SHARED = 'src/ReplicatedStorage/Gaxia_Packages'

// Third-party / deprecated modules this tool does not police.
const EXEMPT = [
  /\/Lib\/DataManager\/ProfileService\.lua$/,
  /\/Shared\/(Promise|Signal|Trove|Spring)\.lua$/,
  /\/Shared\/(Janitor|Component)\//,
  /\/Shared\/(Maid|ComponentLegacy)\.lua$/,
]
// Lib modules that are framework utilities, not services (no Define required).
const LIB_UTILITIES = new Set(['ServiceLifecycle', 'EffectiveConfig'])
// Nested requires that are deliberately lazy: [file suffix, require-arg regex].
const LAZY_ALLOW = [
  [/\/AntiCheat\/init\.lua$/, /^script\.\w+$/], // DETECTORS table closures
  [/\/Lib\/DataManager\/init\.lua$/, /ProfileService$/], // loads on first profile load
]
// Never required at the top of a Lib/AntiCheat module (side effects or deprecated).
const KEEP_LAZY = /(ProfileService|PerformanceMonitor|Maid|Janitor|ComponentLegacy|ReplicatedState)$/
// Calls allowed at module top level (pure: they create values, not effects).
const PURE_GLOBAL_CALLS = new Set(['require', 'setmetatable', 'typeof', 'type', 'tostring', 'tonumber', 'select', 'newproxy', 'assert'])
const PURE_NAMESPACES = new Set(['table', 'math', 'string', 'utf8', 'buffer', 'bit32', 'Vector3', 'Vector2', 'CFrame', 'Color3',
  'UDim', 'UDim2', 'NumberRange', 'NumberSequence', 'NumberSequenceKeypoint', 'ColorSequence', 'ColorSequenceKeypoint',
  'TweenInfo', 'Random', 'OverlapParams', 'RaycastParams', 'BrickColor', 'Rect', 'Region3', 'PhysicalProperties', 'Font',
  'DateTime', 'Enum', 'os'])
const PURE_METHODS = new Set(['GetService', 'IsServer', 'IsClient', 'IsStudio', 'IsRunning', 'FindFirstChild', 'FindFirstChildOfClass', 'IsA', 'GetAttribute'])

const violations = []
const report = (file, loc, rule, msg) => {
  const line = loc ? Number(String(loc).split(',')[0]) + 1 : 0
  violations.push(`${file}:${line}: [${rule}] ${msg}`)
}

function listFiles(dir) {
  const out = []
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name)
      if (e.isDirectory()) walk(p)
      else if (/\.luau?$/.test(e.name)) out.push(path.relative(ROOT, p))
    }
  }
  if (fs.existsSync(path.join(ROOT, dir))) walk(path.join(ROOT, dir))
  return out
}

function parse(file) {
  const json = execFileSync(AST_BIN, [path.join(ROOT, file)], { maxBuffer: 256 * 1024 * 1024 }).toString()
  return JSON.parse(json).root
}

// Readable text for simple expressions (paths, calls) — used for require arguments.
function text(e) {
  if (!e) return '?'
  switch (e.type) {
    case 'AstExprGlobal': return e.global
    case 'AstExprLocal': return e.local.name
    case 'AstExprIndexName': return `${text(e.expr)}${e.op || '.'}${e.index}`
    case 'AstExprConstantString': return JSON.stringify(e.value)
    case 'AstExprCall': return `${text(e.func)}(${e.args.map(text).join(', ')})`
    case 'AstExprTypeAssertion': return `${text(e.expr)} :: <type>`
    case 'AstExprGroup': return `(${text(e.expr)})`
    default: return `<${e.type}>`
  }
}

// Walk every node; visitor(node, insideFunction).
function walk(node, visitor, inFn = false) {
  if (!node || typeof node !== 'object') return
  if (Array.isArray(node)) { for (const n of node) walk(n, visitor, inFn); return }
  if (node.type) visitor(node, inFn)
  const nowInFn = inFn || node.type === 'AstExprFunction'
  for (const [k, v] of Object.entries(node)) {
    if (k === 'location' || k === 'local' || k === 'luauType' || k === 'annotation') continue
    if (v && typeof v === 'object') walk(v, visitor, nowInFn)
  }
}

const isRequireCall = (e) => e && e.type === 'AstExprCall' && e.func.type === 'AstExprGlobal' && e.func.global === 'require'
const isDefineCall = (e) => e && e.type === 'AstExprCall' && e.func.type === 'AstExprIndexName' && e.func.index === 'Define'

// Top-level purity: may this expression run at require time?
function isPure(e, requiredLocals) {
  if (!e) return true
  switch (e.type) {
    case 'AstExprConstantNil': case 'AstExprConstantBool': case 'AstExprConstantNumber': case 'AstExprConstantString':
    case 'AstExprLocal': case 'AstExprGlobal': case 'AstExprVarargs': case 'AstExprFunction':
      return true
    case 'AstExprIndexName': return isPure(e.expr, requiredLocals)
    case 'AstExprIndexExpr': return isPure(e.expr, requiredLocals) && isPure(e.index, requiredLocals)
    case 'AstExprGroup': case 'AstExprTypeAssertion': return isPure(e.expr, requiredLocals)
    case 'AstExprUnary': return isPure(e.expr, requiredLocals)
    case 'AstExprBinary': return isPure(e.left, requiredLocals) && isPure(e.right, requiredLocals)
    case 'AstExprIfElse': return isPure(e.condition, requiredLocals) && isPure(e.trueExpr, requiredLocals) && isPure(e.falseExpr, requiredLocals)
    case 'AstExprInterpString': return (e.expressions || []).every((x) => isPure(x, requiredLocals))
    case 'AstExprTable': return (e.items || []).every((it) => isPure(it.key, requiredLocals) && isPure(it.value, requiredLocals))
    case 'AstExprCall': {
      if (!e.args.every((a) => isPure(a, requiredLocals))) return false
      const f = e.func
      if (f.type === 'AstExprGlobal') return PURE_GLOBAL_CALLS.has(f.global)
      if (f.type === 'AstExprIndexName') {
        if (f.op === ':') return PURE_METHODS.has(f.index) && isPure(f.expr, requiredLocals)
        const base = f.expr
        if (base.type === 'AstExprGlobal' && PURE_NAMESPACES.has(base.global)) return !(base.global === 'Instance')
        // Constructors of required modules: Signal.new(), Trove.new(), Pool.new(...)
        if (base.type === 'AstExprLocal' && requiredLocals.has(base.local.name) && f.index === 'new') return true
      }
      return false
    }
    default: return false
  }
}

function checkFile(file, ctx) {
  let root
  try { root = parse(file) } catch (err) { report(file, null, 'PARSE', String(err.message || err).split('\n')[0]); return }
  const isLibOrAC = file.includes('/Lib/') || file.includes('/AntiCheat/')
  const isDetector = file.includes('/AntiCheat/') && !file.endsWith('/AntiCheat/init.lua')
  const requiredLocals = new Set()
  let defineName = null

  // R1–R3, R6, R8 over the whole tree
  walk(root, (n, inFn) => {
    if (n.type === 'AstStatLocal') {
      for (const v of n.vars) if (v.name === 'SharedPkg') report(file, n.location, 'R2', '`SharedPkg` — require the Shared module you need directly')
    }
    if (n.type === 'AstStatLocalFunction' && n.name && n.name.name === 'server') report(file, n.location, 'R2', '`server()` loader helper — require the service module directly')
    if (n.type === 'AstExprTypeAssertion' && isRequireCall(n.expr) && n.annotation && /any/.test(JSON.stringify(n.annotation))) {
      report(file, n.location, 'R2', '`require(...) :: any` erases the module type')
    }
    if (isRequireCall(n)) {
      const arg = n.args[0]
      const t = text(arg)
      if (/Gaxia_Packages(_Server)?("?\)?)?$/.test(t) || /WaitForChild\("Gaxia_Packages(_Server)?"\)$/.test(t)) {
        report(file, n.location, 'R1', `requires a loader (${t}) — require the module itself`)
      } else if (!arg || arg.type !== 'AstExprIndexName' && !(arg.type === 'AstExprGlobal' && arg.global === 'script')) {
        report(file, n.location, 'R3', `require argument is not a static path: ${t}`)
      } else if (/:(WaitForChild|FindFirstChild)/.test(t)) {
        report(file, n.location, 'R3', `require through ${t} — use a static path (script.Parent.X)`)
      }
      if (inFn && isLibOrAC && !LAZY_ALLOW.some(([f, a]) => f.test(file) && a.test(t))) {
        report(file, n.location, 'R6', `require inside a function (${t}) — require it at the top of the module`)
      }
      if (!inFn && isLibOrAC && KEEP_LAZY.test(t)) report(file, n.location, 'R7', `${t} must not be required at the top of this module`)
    }
    if (n.type === 'AstExprBinary' && n.op === 'Or' && n.right && n.right.type === 'AstExprTable' && (n.right.items || []).length === 0
        && /^Config\./.test(text(n.left))) {
      report(file, n.location, 'R8', `\`${text(n.left)} or {}\` — index the typed Config section directly`)
    }
  })

  // top-level statements: R4, R5, R10
  const body = root.body
  for (const st of body) {
    if (st.type === 'AstStatLocal') {
      st.values.forEach((v, i) => {
        const inner = v.type === 'AstExprTypeAssertion' ? v.expr : v
        if (isRequireCall(inner) && st.vars[i]) requiredLocals.add(st.vars[i].name)
      })
    }
  }
  if (!isLibOrAC) return
  body.forEach((st, idx) => {
    const last = idx === body.length - 1
    switch (st.type) {
      case 'AstStatLocal':
        for (const v of st.values) if (!isPure(v, requiredLocals)) report(file, st.location, 'R4', `top-level ${text(v)} runs at require time — move it into Init/Start`)
        break
      case 'AstStatAssign':
        for (const v of st.values) if (!isPure(v, requiredLocals)) report(file, st.location, 'R4', `top-level ${text(v)} runs at require time — move it into Init/Start`)
        break
      case 'AstStatFunction': case 'AstStatLocalFunction': case 'AstStatTypeAlias': case 'AstStatTypeFunction':
        break
      case 'AstStatReturn':
        if (!last) report(file, st.location, 'R4', 'top-level return before the end of the module')
        break
      case 'AstStatExpr':
        if (isDefineCall(st.expr)) {
          if (isDetector) report(file, st.location, 'R5', 'detectors are registered by the orchestrator; do not Define them')
          const nextIsReturn = body[idx + 1] && body[idx + 1].type === 'AstStatReturn' && idx + 1 === body.length - 1
          if (!nextIsReturn) report(file, st.location, 'R5', 'Lifecycle.Define must be the last statement before `return`')
          const spec = st.expr.args[1]
          if (spec && spec.type === 'AstExprTable') {
            for (const it of spec.items) {
              const key = it.key && it.key.type === 'AstExprConstantString' ? it.key.value : null
              if (key === 'Name' && it.value.type === 'AstExprConstantString') defineName = it.value.value
              if (key === 'Needs') {
                if (it.value.type !== 'AstExprTable') report(file, it.value.location, 'R10', 'Needs must be a table literal of module locals')
                else for (const need of it.value.items) {
                  const v = need.value
                  if (!(v.type === 'AstExprLocal' && requiredLocals.has(v.local.name))) report(file, v.location, 'R10', `Need ${text(v)} is not a top-level required module local`)
                }
              }
            }
          }
        } else {
          report(file, st.location, 'R4', `top-level ${text(st.expr)} runs at require time — move it into Init/Start`)
        }
        break
      default:
        report(file, st.location, 'R4', `top-level ${st.type.replace('AstStat', '')} statement runs at require time — move it into Init/Start`)
    }
  })
  if (defineName) ctx.defineNames.set(defineName, file)
  const base = path.basename(file).replace(/\.luau?$/, '')
  const moduleName = base === 'init' ? path.basename(path.dirname(file)) : base
  if (ctx.complete && file.includes('/Lib/') && !LIB_UTILITIES.has(moduleName) && !defineName && !file.includes('/Lib/DataManager/ProfileService')) {
    report(file, null, 'R11', `${moduleName} is a Lib service but never calls Lifecycle.Define`)
  }
}

function unionMembers(src, typeName) {
  const m = src.match(new RegExp(`export type ${typeName}\\s*=([\\s\\S]*?)\\n\\n`))
  return m ? new Set([...m[1].matchAll(/"([A-Za-z0-9]+)"/g)].map((x) => x[1])) : new Set()
}

function checkSync(ctx) {
  const types = fs.readFileSync(path.join(ROOT, SERVER, 'Types.lua'), 'utf8')
  const loader = fs.readFileSync(path.join(ROOT, SERVER, 'init.lua'), 'utf8')
  const serviceNames = unionMembers(types, 'ServiceName')
  const moduleKeys = new Set([...serviceNames, ...unionMembers(types, 'ModuleKey')])
  const mapKeys = (name) => {
    const m = loader.match(new RegExp(`local ${name}\\s*:[^=]*=\\s*\\{([\\s\\S]*?)\\n\\}`))
    return m ? [...m[1].matchAll(/^\s*([A-Za-z0-9]+)\s*=/gm)].map((x) => x[1]) : []
  }
  const loaderKeys = new Set([...mapKeys('LIB_KEY_MAP'), ...mapKeys('ROOT_KEY_MAP')])
  const typeBlock = loader.match(/export type GaxiaServerPackage = \{([\s\S]*?)\n\}/)
  const typeFields = new Set(typeBlock ? [...typeBlock[1].matchAll(/^\s*([A-Za-z0-9]+)\s*:/gm)].map((x) => x[1]) : [])
  for (const f of ['Shared', 'Config', 'VERSION', 'Boot', 'IsEnabled']) typeFields.delete(f)
  const diff = (a, b) => [...a].filter((x) => !b.has(x))
  const file = `${SERVER}/Types.lua`
  for (const k of diff(moduleKeys, loaderKeys)) report(file, null, 'R9', `ModuleKey "${k}" has no loader key (LIB_KEY_MAP/ROOT_KEY_MAP)`)
  for (const k of diff(loaderKeys, moduleKeys)) report(file, null, 'R9', `loader key "${k}" is missing from Types.ServiceName/ModuleKey`)
  for (const k of diff(loaderKeys, typeFields)) report(`${SERVER}/init.lua`, null, 'R9', `loader key "${k}" is missing from GaxiaServerPackage`)
  for (const k of diff(typeFields, loaderKeys)) report(`${SERVER}/init.lua`, null, 'R9', `GaxiaServerPackage field "${k}" has no loader key`)
  for (const [name, f] of ctx.defineNames) if (!serviceNames.has(name)) report(f, null, 'R9', `Define Name "${name}" is not in Types.ServiceName`)
  if (ctx.complete) for (const k of serviceNames) if (!ctx.defineNames.has(k)) report(file, null, 'R9', `ServiceName "${k}" has no module that Defines it`)
}

const args = process.argv.slice(2)
const complete = args.includes('--complete')
const explicit = args.filter((a) => !a.startsWith('--')).map((f) => path.relative(ROOT, path.resolve(f)))
const ctx = { complete, defineNames: new Map() }
const files = explicit.length ? explicit : [
  ...listFiles(`${SERVER}/Lib`), ...listFiles(`${SERVER}/AntiCheat`),
  ...listFiles(`${SHARED}/Shared`), ...listFiles(`${SHARED}/Client`),
]
for (const f of files) if (!EXEMPT.some((re) => re.test(f))) checkFile(f, ctx)
if (!explicit.length) checkSync(ctx)

for (const v of violations) console.log(v)
console.log(`check-architecture: ${files.length} files, ${violations.length} violation(s)`)
process.exit(violations.length ? 1 : 0)
