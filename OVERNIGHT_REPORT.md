# Overnight Report — OSS dependency migration

Status: PARTIAL · ✅ 0 merged · ⏸ 1 parked · ❌ 3 full-repository checks fail

2026-09-01 09:44:20 +07:00 · branch: `codex/oss-library-migration`

## Scope

Replace locally copied or custom shared utilities with maintained open-source
packages where compatibility can be preserved. This unattended pass was kept to
dependency management, compatibility paths, cleanup consumers, build wiring,
and independently reviewed dead vendored files. Persistence, network protocol
design, and unrelated runtime bugs were intentionally left alone.

## Where it stands

- **Merged:** none.
- **Parked:** `codex/oss-library-migration` at implementation commit
  `56f6930e4b7d8b39d61cc41bf43ce853d14968a1`.
- **Why parked:** the change introduces dependency and lock files, removes large
  vendored source bodies, and changes Promise scheduling semantics. Those are
  stop-list changes for unattended work and require a Roblox Studio smoke test
  plus an explicit compatibility decision before merge.
- The independent scrutiny verdict is **safe to park/push, not safe to merge**.

## Delivered on the parked branch

- Added Wally 0.3.2 to Rokit/Aftman and committed `wally.toml` plus `wally.lock`.
- Pinned direct packages:
  - `sleitnick/comm@1.0.1`
  - `sleitnick/component@2.4.8`
  - `howmanysmall/janitor@1.18.3` (exact)
  - `evaera/promise@4.0.0`
  - `sleitnick/signal@2.0.3`
  - `sleitnick/trove@1.8.0`
- Locked transitive packages: `howmanysmall/typed-promise@4.0.6`,
  `sleitnick/option@1.0.5`, and `sleitnick/symbol@2.0.1`.
- Replaced vendored Comm, Component, Janitor, Promise, Signal, and Trove bodies
  with small compatibility modules, so existing paths such as `Gaxia.Comm` and
  `Gaxia.Promise` remain available. Wally Comm also restores the Option dependency
  missing from the previous vendored tree.
- Preserved the existing local `Symbol` implementation because its callable and
  `.new` public API is incompatible with the upstream Symbol package.
- Preserved `Gaxia.ComponentLegacy` after review proved that the loader's exact
  child fallback makes it a lazy public path.
- Reimplemented deprecated `Gaxia.Maid` as a Janitor-backed, LIFO-compatible
  facade and migrated all repository-owned Maid consumers to Janitor.
- Added package mappings to both Rojo projects, excluded package test sources,
  rebuilt `build/GaxiaPackages.rbxmx`, documented installation, and added
  `THIRD_PARTY_NOTICES.md` for the new dependency graph.
- Removed only replaced vendored implementation/helper/test files. They remain
  recoverable from the parent commit `f7fdc1e` and Git history.

## Checks

Passing:

- ✅ `wally install` — exit 0 from the committed lock graph.
- ✅ `rojo build default.project.json --output build/GaxiaPackages.rbxmx` — exit 0.
- ✅ `rojo build plugin.project.json --output <temporary artifact>` — exit 0;
  the temporary artifact was inspected and removed afterward.
- ✅ Both builds contain the compatibility modules, Wally aliases, Comm,
  ComponentLegacy, and Packages; package test/config sources are excluded.
- ✅ StyLua check for every new/replaced compatibility module — exit 0.
- ✅ `git diff --check -- . ':!build/GaxiaPackages.rbxmx'` — exit 0.
- ✅ Static scan found no repository-owned Maid consumers outside the deprecated
  facade.
- ✅ Independent review traced root loader → compatibility module → Wally alias →
  `_Index` package for both the default and plugin payloads.

Failing or unavailable:

- ❌ `stylua --check src` — exit 1 from repository-wide pre-existing formatting
  drift. The focused compatibility-module check passes; formatting unrelated
  files was deliberately avoided.
- ❌ `selene src` — exit 1 with **0 errors, 112 warnings, 0 parse errors**. The
  baseline was 0 errors, 112 warnings, and 1 parse error, so this migration adds
  no lint errors and removes the bundled-test parse failure.
- ❌ Full `git diff --check` — exit 1 only for blank lines containing tabs inside
  the Rojo-generated `build/GaxiaPackages.rbxmx`, originating in Wally package
  source embedded as XML. All non-generated changed files pass.
- ⚠️ No automated Roblox runtime/Studio test runner exists in the repository, so
  Cutscene, Dialog, Effects, anti-cheat guard, Zone, and Promise timing flows were
  not executed.

## Merge blocker: Promise compatibility

The old vendored Promise was not the published 4.0.0 release. It matched upstream
post-tag commit `031d429c82ee458a849e79fa523523bd349d7695`, which uses
`task.defer`/`task.delay` and contains a later `finally` propagation fix. Wally's
published `evaera/promise@4.0.0` uses the older Heartbeat-based scheduler and has
different sub-frame delay behavior.

The current graph intentionally uses one canonical Wally Promise instance across
Gaxia, Janitor, Component, and Comm, avoiding cross-package Promise identity
problems. Before merge, choose one of these explicitly:

1. Accept the published 4.0.0 behavior as a breaking change, bump/version it as
   appropriate, and add Studio tests for defer/delay/timeout/cancellation and the
   dialog/cutscene flows.
2. Publish the exact post-tag snapshot as an internal Wally package and pin that
   package everywhere to preserve the old scheduling behavior.

## Pre-existing follow-ups found by scrutiny

- Shared/server `autoTagDescendants` currently starts at `script.Parent`, so it
  tags broader storage trees than the documentation claims. This predates and is
  not newly activated by the migration.
- Cutscene double-destroy and Dialog promise-settlement holes also predate this
  migration.
- The repository's existing Apache-2.0 ProfileService copy is not yet covered by
  a sidecar notice. Also attach `THIRD_PARTY_NOTICES.md` when distributing the
  model/plugin because Markdown files are not embedded by Rojo.

## Next step

```powershell
git fetch upstream
git switch --track upstream/codex/oss-library-migration
rokit install
wally install
rojo build default.project.json --output build/GaxiaPackages.rbxmx
rojo build plugin.project.json --output GaxiaCompanion.rbxmx
```

Then run the Studio smoke cases listed above and make the Promise compatibility
decision. Merge only after those pass and the dependency/lockfile review is
approved.

## Continue with

- `start-work`: resume implementation after selecting the Promise strategy.
- `scrutinize`: repeat the independent goal/trace/verify review after any Promise
  compatibility change and before merge.
