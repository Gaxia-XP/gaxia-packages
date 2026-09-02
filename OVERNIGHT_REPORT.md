# Overnight Report — OSS dependency migration

Status: READY FOR HUMAN REVIEW · ✅ Studio smoke passed · ⏸ 1 branch · ❌ 2 baseline checks fail

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
- **Why parked:** the change introduces dependency and lock files and removes
  large vendored source bodies. Those were stop-list changes for unattended work;
  the follow-up resolved Promise compatibility and passed the Studio smoke test.
- The original independent scrutiny verdict was **safe to park/push, not safe to
  merge**. Follow-up scrutiny now recommends shipping the branch for human
  dependency/lockfile review after resolving the Promise blocker.

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
- Replaced vendored Comm, Component, Janitor, Signal, and Trove bodies with small
  compatibility modules. Wally Comm also restores the Option dependency missing
  from the previous vendored tree.
- Preserved the existing upstream Promise snapshot byte-for-byte at public path
  `Gaxia.Promise`; the published Wally release predates its scheduler and
  `finally` fixes.
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
- ✅ Full `git diff --check` — exit 0 after rebuilding the distributable with the
  compatibility Promise snapshot.
- ✅ Static scan found no repository-owned Maid consumers outside the deprecated
  facade.
- ✅ Independent review traced root loader → compatibility module → Wally alias →
  `_Index` package for both the default and plugin payloads.
- ✅ `scripts/test-oss-dependencies.ps1` — exit 0 against Roblox Studio
  0.736.0.7361346 with `[OSS_SMOKE] PASS`.

Failing or unavailable:

- ❌ `stylua --check src` — exit 1 from repository-wide pre-existing formatting
  drift. The focused compatibility-module check passes; formatting unrelated
  files was deliberately avoided.
- ❌ `selene src` — exit 1 with **0 errors, 112 warnings, 0 parse errors**. The
  baseline was 0 errors, 112 warnings, and 1 parse error, so this migration adds
  no lint errors and removes the bundled-test parse failure.
- ⚠️ The new smoke test covers dependency/public-path behavior but does not
  exercise full gameplay flows for Cutscene, Dialog, Effects, anti-cheat guards,
  or Zone.

## Resolved: Promise compatibility

The old vendored Promise was not the published 4.0.0 release. It matched upstream
post-tag commit `031d429c82ee458a849e79fa523523bd349d7695`, which uses
`task.defer`/`task.delay` and contains a later `finally` propagation fix. Wally's
published `evaera/promise@4.0.0` uses the older Heartbeat-based scheduler and has
different sub-frame delay behavior.

`Gaxia.Promise` now retains that exact source snapshot (Git blob
`dc82ad5682221814ee58daa89b31e30f31a87ebd`). Wally-managed dependencies share
the official 4.0.0 package. Both versions duck-type Promise objects; the Studio
smoke test verifies adoption in both directions and Janitor cancellation across
the two copies, plus `defer`, `delay`, and the later `finally` error behavior.

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

The Studio dependency smoke test and final scrutiny now pass. Review the branch's
dependency/lockfile diff, then merge when approved.

## Continue with

- Review the dependency/lockfile and the generated model in the pull request.
- Merge only after that human review; no implementation handoff remains.

## Follow-up — 2026-09-02

The compatibility choice is now resolved without a public behavior break:
`Gaxia.Promise` retains the existing upstream snapshot at
`031d429c82ee458a849e79fa523523bd349d7695`. Wally-managed libraries continue
to share the official 4.0.0 release, and a Studio CLI smoke test covers
cross-copy adoption/cancellation and Janitor interop. The test passed against
Roblox Studio 0.736.0.7361346, and final scrutiny found no introduced blocker;
this supersedes the Promise blocker above.
