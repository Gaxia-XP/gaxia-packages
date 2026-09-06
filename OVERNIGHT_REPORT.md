# Overnight Report — Direct open-source package APIs

Status: SUCCESS · ✅0 merged · ⏸1 parked · ❌0 final tests fail
2026-09-02 18:03:59 +07:00 · branch: `codex/oss-library-migration`

## Scope

Replace worthwhile custom libraries with open-source community packages. Direct
upstream APIs are preferred; compatibility wrappers are not required when they
add complexity. Do not push.

## Where it stands

- Parked locally in commit `99c7a6a` because the change updates dependencies
  and intentionally changes public contracts.
- `Gaxia.Spring` now resolves directly to `sleitnick/spring@1.0.0`. The removed
  source and upstream package have the identical Git blob hash
  `25eabef7497ff10065b18991b3ed9186229001d5`.
- `Gaxia.Guard` now resolves directly to `osyrisrblx/t@3.1.1`.
- `Gaxia.Util.Table`, `Gaxia.Maid`, `ComponentLegacy`, and `GaxiaServer.Zone`
  now expose TableUtil, Janitor, Component, and ZonePlus directly.
- `DataManager` uses ProfileStore's production reconciliation and consumes the
  immutable TableUtil result for test profiles.
- `MANUAL.md`, `CHANGELOG.md`, smoke coverage, dependency pins, and license
  notices were updated for the direct APIs.
- Kept `Serializer` because `sleitnick/ser` does not support its nested JSON and
  Roblox datatype contract. Kept `ReplicatedState` because official Replica is
  not published under a trusted first-party Wally namespace. Kept `NetService`
  because it owns validation, rate limiting, and AntiCheat reporting beyond
  Comm. Kept the command stack because Cmdr would not replace the custom roles,
  audit, panel, and moderation controls without a large security-sensitive
  rewrite. Promise remains the approved community snapshot.
- Nothing was merged or pushed, following the user's explicit instruction.
  The local branch is four commits ahead of its upstream tracking branch before
  this report commit.

## Checks

- ✅ `wally install`
- ✅ targeted `stylua --check`
- ✅ targeted `selene`: 0 errors; one pre-existing warning at
  `DataManager/init.lua:20` for unused `ServerScriptService`
- ✅ `rojo build default.project.json`
- ✅ `rojo build plugin.project.json`
- ✅ `scripts/test-oss-dependencies.ps1`: `[OSS_SMOKE] PASS`
- ✅ `git diff --check`
- ✅ outsider review traced public aliases, PetService Guard validation,
  DataManager reconciliation, and deprecated aliases; no blocker found
- ℹ️ The first expanded smoke attempt failed because the test required the
  server package root from a client-context CLI script: `Cannot require server
  package from the client.` The test now requires the Zone module directly;
  the bounded retry passed.

## Breaking API notes

- Guard uses upstream names and semantics, including `numberConstrained`,
  `Instance`, strict arrays, and `t.any(nil) == false`.
- Table uses upstream immutable operations (`Copy`, `Assign`, `Some`, `Sample`,
  `Flat`); former Gaxia-only names and mutating behavior are gone.
- Maid is Janitor directly (`Add`, `Cleanup`); `GiveTask` and `DoCleaning` are
  gone.
- Zone is ZonePlus directly (`new`, `playerEntered`, `playerExited`,
  `getPlayers`, `destroy`); the named-zone registry is gone.
- ComponentLegacy is Component directly; the former `Bind` API is gone.

## Next step

    git checkout codex/oss-library-migration && git diff upstream/codex/oss-library-migration...HEAD

→ Review all local-only OSS migration commits and their intentional public API
changes. Push only when explicitly desired.

## Continue with

- `start-work` — resume implementation if a rejected high-risk migration is
  deliberately scoped as a separate project.
- `scrutinize` — re-review the full branch before deciding to push or merge.
