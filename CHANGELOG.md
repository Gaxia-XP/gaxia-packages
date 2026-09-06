# Changelog — GaxiaPackages

All notable changes to the GaxiaPackages in-game framework. Runtime version is
exposed as `Gaxia.VERSION` (shared) and `GaxiaServer.VERSION` (server).

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/);
this framework uses a single rolling version until a public release cut.

## Unreleased

### Added — Central, Prompt, and Observers
- Added `Gaxia.Central`, a named priority scheduler based on the
  `CentralManager` prototype from the Studio place, with deterministic task
  lifecycle and cleanup.
- Added client-only `Gaxia.Prompt` for tracking, highlighting, and manually
  holding the current `ProximityPrompt` without leaking prompt connections.
- Added `Gaxia.Observers` as a direct alias of the MIT-licensed
  `sleitnick/observers@1.0.0` Wally package. The unused Studio-only helpers
  (`observeAllAttributes`, `observeAncestry`, `observeChildren`,
  `observeClass`, and `observeDescendants`) are intentionally not retained;
  consumers use the upstream API directly.

### Changed — NetService payload obfuscation
- `NetService` now wraps event and function arguments in a per-player,
  per-message XOR-obfuscated envelope in both directions. Public `NetService`
  calls remain unchanged, malformed envelopes are dropped and reported to
  AntiCheat, payload decoding has depth, node, and argument-count limits, and
  logical Remote names are represented by hashed identifiers on the wire.
- This is intentionally a deterrent against basic RemoteSpy use, not client
  authentication or cryptographic security; server validation and rate limits
  remain authoritative.

### Added — safe enforcement and exclusive C2S gateway
- Added `AntiCheatEnforcement` as the sole automatic-action owner. It defaults
  to observe mode; client reports and client-liveness signals are telemetry
  only, while only reviewed server/trap hard evidence (or an explicitly added
  trusted transport source) is eligible after an explicit switch to enforce mode.
- Added bounded `NetProtocol` validation, replay windows, request-id caching,
  per-RPC concurrency, rejection codes, and server-only RPC metrics.
- Migrated Settings, Command, Pet, Friend, Party, Guild, Admin, client reports,
  and heartbeats to definition-based Net RPCs. The old raw inbound handlers and
  ineffective `RemoteRateLimiter` were removed.
- Added `RemoteTrap` honeypot/wrong-direction observation and a static audit
  that permits C2S listeners only in NetService and the reviewed trap.

### Changed — open-source dependencies are pinned with Wally
- `Signal`, `Janitor`, `Trove`, `Component`, and `Comm` now resolve
  through compatibility modules into the versions pinned by `wally.lock`.
- `GaxiaServer.Zone` now resolves directly to the pinned ZonePlus 3.2.0 API;
  the former named-zone registry facade was removed.
- `DataManager` now uses the server-only ProfileStore 1.0.3 package instead of
  a bundled ProfileService copy. Store names, keys, schema reconciliation,
  manual saves, and the public DataManager API remain unchanged.
- `Gaxia.Promise` keeps the existing upstream post-tag snapshot at commit
  `031d429c82ee458a849e79fa523523bd349d7695` because the published Wally
  release has older scheduler and `finally` behavior. Wally-managed libraries
  share the official `evaera/promise@4.0.0` dependency separately.
- `Gaxia.Symbol` now resolves directly to the pinned community
  `sleitnick/symbol@2.0.1` package; its callable `Symbol("Name")` API is unchanged.
- `Gaxia.Spring` now resolves directly to the pinned community
  `sleitnick/spring@1.0.0` package. The removed local copy was identical to that
  upstream implementation, so its runtime API and behavior are unchanged.
- `Gaxia.Util.Table` now resolves directly to the pinned community
  `sleitnick/table-util@1.2.1` API. Former Gaxia-only method names and mutating
  behavior were removed; `DataManager` now consumes immutable reconciliation
  correctly.
- `Gaxia.Guard` now resolves directly to the pinned community
  `osyrisrblx/t@3.1.1` package. Consumers use the upstream API directly
  (`numberConstrained`, `Instance`, strict array validation, and `t.any`
  semantics) instead of the former Gaxia-specific aliases.
- `Gaxia.Maid` is now a deprecated direct alias of `Gaxia.Janitor`; the former
  Maid-specific method names and LIFO facade were removed.
- Replaced the incomplete vendored `Comm` copy with its upstream Wally package,
  including the missing `Option` dependency. `ComponentLegacy` is now a
  deprecated direct alias of the upstream Component package.
- Builds now require `wally install`. Both the distributable model and
  Companion plugin include the generated shared and server package trees.
- Added an isolated Roblox Studio CLI smoke test for synchronous package aliases,
  ZonePlus/ProfileStore mounts, AntiCheat journaling, NetProtocol bounds/replay/cache,
  Net registration lifecycle, and the deprecated Maid-to-Janitor alias. Async signal,
  ProfileStore-session, and scheduler behavior remains a multi-client integration test.

### Added — Pet Coins multiplier wired into the Idle & Quest faucets
`PetService.GetCoinMultiplier` (built in the Pet MVP) was previously **dead** — no
faucet consumed it, so equipped pets had no in-game effect. The two **generated**
coin faucets now apply it:
- **`IdleService.Collect`** — coin idle income × multiplier, re-clamped to the
  configured `cap` (**ceiling** policy; `cap` is `math.huge` when unset → plain
  multiply). Pets reach the offline cap faster but don't exceed it.
- **`QuestSystem.grantReward`** — coin reward × multiplier (floored).
- Both gate on the coin currency (`"Coins"`), so Gems / other rewards aren't touched.
- **`RaidService` is intentionally excluded** — raid loot is a zero-sum transfer;
  multiplying it would mint currency.
- Lookup is best-effort (`pcall` + NaN guard → `1.0`), so a missing Pet service
  never breaks a grant.

> **Historical note:** Entries below describe older release topology. References
> to direct `Events/*/Action` C2S remotes or multiple automatic `OnAction`
> consumers were superseded by the gateway/enforcement migration above.

### Fixed — high roles can no longer be auto-banned or auto-kicked (escalation banned the owner)
The AntiCheat auto-escalation had no role awareness: dev-tool teleports
hard-flagged the **place creator**, who got temp-banned ("Auto: Teleport x2")
and then kicked at join by the ban gate — locked out of their own game.
- **Escalation exemption** — `escalate()` skips the place creator (sync
  `CreatorId` check, no role-load race) and anyone at/above
  `Config.AntiCheat.BanPolicy.ExemptRole` (default `"admin"` — deliberately
  NOT `"moderator"`, so the lowest staff tier keeps the automated cheating
  deterrent; `false` narrows to creator-only). Exempt detections warn instead
  of kick/ban. Role lookup via new userId-keyed
  `AdminCommands.GetRoleForUserId` / `IsUserIdAtLeast` (in-memory registry
  only; lazy pcall require — BanService still works without AdminCommands,
  falling back to creator-only). Known limit: DataStore-granted roles load
  async at join, so a hard-flag burst in the first seconds can still strike a
  non-Bootstrap admin.
- **Bootstrap kick exemption (historical topology)** — at that point
  `AntiCheat.OnAction` had two enforcing consumers; the default hard-action
  handler in `Gaxia_ServerBootstrap` could kick unconditionally, so the creator
  was still kicked even with the ban exemption. The current architecture has
  only `AntiCheatEnforcement` as the automatic-action owner.
- **Join-gate self-heal** — a stale ban record on the place creator is
  dropped with a warn instead of kicking (creator only: lower staff can be
  legitimately banned, so their records must still enforce).
- **/acban guard hole** — AntiCheatAdmin's `/acban` called `Ban.Ban` directly,
  bypassing the self/creator/rank guard `/ban` has — a delegated admin could
  ban the owner. Now applies the same guard via the new public
  `AdminCommands.ProtectTarget` and REFUSES if the guard is missing
  (fail closed, mixed-version Lib folders).
- **AntiCheatAdmin hardening (same review)** — its private player resolver
  had the audit-outlawed footguns: blank query matched the FIRST player in
  the server (`/acban "" reason` banned someone arbitrary), ambiguity
  resolved by join order, and an earlier-joined prefix match shadowed an
  exact name ("/acban Bob" banned Bobby). Now blank/ambiguous are rejected
  with the reason and exact beats prefix. `/acban` validates `[seconds]`
  (NaN/inf/negative → rejected; NaN expiresAt made a "temp" ban permanent),
  `/acban`+`/acunban` surface the persisted-write WARNING like `/ban`, and
  all rejection paths in the pack (`/ac`, `/flag` usage errors included)
  carry the `(message, failed=true)` contract so they render as rejections.
- Clicking `/unban` in the panel now opens a list of **active bans** —
  `Name (userId) — reason · permanent/Xh left` with a per-row Unban button
  (auto-refreshes after each unban) plus a manual userId fallback box. Backed
  by the new `BanService.ListBans(maxCount?)` (session cache merged with
  DataStore `ListKeysAsync`, expired records filtered, pcall-guarded) and a
  new admin-gated `bans` envelope on `Events/Admin/Action` with cached
  username resolution. Cap via `Config.Admin.BanListLimit` (default 50).

### Fixed — Admin command audit (31 findings, 9 fix batches)
Full report: `docs/superpowers/specs/2026-06-12-admin-command-audit.md`
(multi-agent audit of every built-in command against the service APIs it
calls; 24 findings adversarially verified + 7 critic leads, 0 refuted).

- **Targeting safety** — `findPlayerByPartialName` no longer guesses: a blank
  target used to resolve to the FIRST player in the server (a bare `/kick`
  kicked someone arbitrary), ambiguous prefixes silently picked join order,
  and the DisplayName fallback matched substrings anywhere. Blank/ambiguous
  queries are now rejected with the reason ("Ambiguous target … matches N
  players"); DisplayName matching is prefix-anchored. Same guards in
  `ChatCommandSystem.parsePlayer`.
- **NaN inventory poisoning** — `/give X item nan` wrote NaN into the
  persisted profile inventory (NaN passes one-sided clamps; DataStore then
  rejects every later save of that profile). `ItemService.clampCount` and
  `VaultService.Deposit/Withdraw` now NaN-guard; `/give` validates count as a
  finite positive integer, rejects unknown itemIds when an
  ItemDefinitionService catalog is registered, and reports the DELIVERED
  amount (Give returns the delta) instead of echoing the request.
- **/role moderation guard** — `/role` now runs `protectTarget` like
  `/ban`/`/kick` (a bare "/role me" typo used to silently self-demote with a
  persisted row = permanent lockout for non-creator owners), requires an
  explicit role argument, refuses granting a role at/above the caller's own
  tier (no peer minting), and refuses demotions below a Bootstrap floor
  instead of reporting a change that reverts on next join.
- **Cross-server cache staleness** — `roleByUserId` and the BanService session
  cache are evicted on PlayerRemoving, so demotions/bans/unbans issued on
  another server now apply on rejoin (both were warm-cache-forever; the
  upgrade-only role load made demotions unapplyable). BanService no longer
  negative-caches a GetAsync ERROR as "not banned" for the server lifetime;
  `Ban`/`Unban` warn + return a `persisted` boolean and `/ban`/`/unban`
  append an explicit WARNING when the DataStore write failed. Persisted roles
  also load for players already in-game at module init (catch-up loop).
- **Anti-cheat whitelist sync** — the orchestrator's whitelist/ClearFlags are
  family-aware (entry "HumanoidState" covers "HumanoidState:Climbing" etc. —
  the entry was dead under exact matching); missing "Heuristic" and
  "WorldBounds" (hard severity!) added; "ClientReport" documented as
  deliberately excluded. A bad runtime `/flag` override of
  `Admin.ActionWhitelistSeconds` can no longer error before the handler pcall
  and lock out every admin command incl. the recovery `/flag clear` (tonumber
  coercion + fail-closed Whitelist + pcall'd pre-handler block).
- **/speed, /heal, character resolution** — `Util.Player.GetCharacter`
  honors its documented timeout (was an unbounded `CharacterAdded:Wait()`
  that hung `/speed` and the panel invoke forever on character-less targets);
  `PlayerService.SetWalkSpeed` clamps to `[0, Player.MaxWalkSpeed]` (negative
  WalkSpeed got the target anti-cheat-kicked ~30s later — detector baseline
  floors at 8) and returns the applied value; `/speed` validates input;
  `/heal` errors on no-character/dead targets ("X is dead — use /respawn")
  instead of claiming success.
- **Chat feedback actually delivered** — `ChatCommandSystem.reply` used a
  client-only API from the server (every reply silently dropped, incl.
  "Permission denied." and `/help`); replies now go through a new
  `Events/Chat/SystemMessage` RemoteEvent rendered locally by the new
  `Gaxia.ChatFeedback` client module (TCS system line, legacy SetCore
  fallback). The admin chat bridge forwards Run's real outcome message;
  `Config.Admin.Aliases` now work from chat (each alias registered with
  ChatCommandSystem); ALL TextChannels are hooked (commands in team/whisper
  chat used to leak the raw command line to teammates); `/kick`/`/ban`
  reasons greedy-join the remaining words ("/ban Bob exploiting speed hacks"
  used to persist reason "exploiting").
- **Admin Panel truthfulness + usability** — handlers mark rejections via a
  `fail()` second return, so guard-blocked/not-found commands now toast as
  "Blocked" (red) and show ✗ in the Audit feed instead of green successes;
  the audit broadcast carries the outcome message and renders it; the audit
  buffer fills via an always-on subscription (the tab used to open empty —
  it only buffered while focused); dropdown option menus raise their root
  ZIndex while open (later siblings used to paint over and click-shadow the
  menu — a misclick could fire Run at a default target); trailing blank form
  fields are stripped server-side (bans used to persist with reason "");
  `schema`/`players` envelope endpoints now require moderator+ (any client
  could enumerate the live staff roster with roles).
- **`Config.Admin.Enabled` is wired** — the kill switch existed in Config but
  was never read. `false` now disables registration, `Run`, the Events/Admin
  remote surface, role hooks, and creator auto-grant.

### Added — Phase 27 · Admin UX
- **Admin Panel** (`Gaxia.UI.AdminPanel`) — a role-gated in-game GUI over the
  existing `AdminCommands` registry (no command-surface fork). Three tabs:
  Players (per-target actions filtered to the caller's role), Commands
  (role-filtered list + auto-rendered arg form: `player`→searchable dropdown,
  `number`/`string`→text field), and Audit (live moderator+ feed of the last
  50 command results). Opens via a 🛡 toolbar button (moderator+ only) or the
  F2 hotkey; the client bootstrap pre-warms it so the toolbar + hotkey +
  role-hint subscription wire up at spawn.
- **AdminCommands** server surface — `Events/Admin/Action` RemoteFunction
  (`schema` / `players` / `run` / `role`) + `Events/Admin/Inbound` RemoteEvent
  (audit broadcast to moderator+ only, plus a role hint at join). Server-
  authoritative: every `run` delegates to `AdminCommands.Run`'s existing role
  check; `schema` is role-filtered server-side so a client never learns of
  commands it can't run. The `commands` registry, every `Register` call site,
  `Run`, `GetRole`, and `IsAtLeast` are unchanged.

### Added — Admin moderation guard
- **`/ban` and `/kick` now refuse self / owner / equal-or-higher-rank targets.**
  A single `protectTarget(caller, target)` guard (shared by chat + the Admin
  Panel, since the panel re-enters the same handlers) blocks the classic
  "I banned myself and got locked out" footgun, protects the place creator
  from a delegated admin, and stops a compromised admin from banning peers or
  superiors. The Players-tab Ban/Kick buttons therefore fail safely with a
  clear toast instead of locking you out.
- **`AdminCommands.Run` now returns `(ok, message?)`** — the handler's
  descriptive result string ("Banned X", "You can't target yourself", "You
  don't have permission to run /role", …). The Admin Panel surfaces this in
  its result toast so a guard-blocked action shows the real reason instead of
  a misleading "Done". Existing callers that read only the boolean are
  unaffected (extra return value is ignored).

### Fixed — Plugin double-boot
- **The Companion plugin's bundled bootstraps no longer boot a second framework
  during play test.** The plugin's `Payload` carries the real
  `Gaxia_ServerBootstrap` (Script) and `Gaxia_ClientBootstrap` (LocalScript) so
  the 1-click Installer can clone runnable copies into a place. The plugin
  *entry* is guarded (`if plugin == nil then return`), but those Payload
  bootstraps were not — so when the plugin tree is dev-mounted into the
  DataModel, the Payload's `Gaxia_ServerBootstrap` ran and stood up a SECOND
  AntiCheat + DataManager alongside the place's own (double event handlers,
  concurrent ProfileService loads). Both bootstraps now self-guard on their
  runtime location: the server bootstrap boots only as a **direct child of
  ServerScriptService** (`script.Parent == ServerScriptService` — strict `==`,
  because the Payload copy is a *descendant* of SSS but not a direct child), and
  the client bootstrap boots only when a **descendant of `Players`** (its
  PlayerScripts clone). The place's own bootstraps and the Installer-cloned
  copies are unaffected; the Payload copies stay inert. Verified live: cloning
  the server bootstrap under a Folder-in-ServerScriptService produced no second
  boot, while the real one (direct SSS child) still came up normally.

### Fixed — Admin
- **`/ban` / `/unban`** now delegate to `BanService` (`Gaxia.Ban`) instead of a
  parallel ban store. Previously AdminCommands wrote a raw-string ban record to
  the same DataStore key BanService read as a table, so `Gaxia.Ban.IsBanned`
  returned false for chat-banned players, `Gaxia.Ban.Unban` was a no-op against
  AdminCommands' separate in-memory set, chat bans never fired `OnBan` (Webhook
  "BanReports" missed them), and temp bans were enforced as permanent. One ban
  code path now: `BanService` owns the record shape, session cache, expiresAt-
  aware `IsBanned`, and `OnBan`/`OnUnban` signals. `Gaxia_ServerBootstrap`
  eager-loads `Ban` before `Admin` and `Webhook`.

### Added — Phase 26 · Social
- **Friend** (`Gaxia.Friend`) — game-internal buddies + blocks list persisted
  under `profile.Social`; two-tier online status (same-server free, cross-server
  cached `Player:GetPresenceAsync`); cross-server invite delivery via the new
  `InviteQueue` helper (MemoryStoreSortedMap per kind). Block is bidirectional
  + unilateral (blocked users can't send invites, can't see online status,
  can't be Party/Guild-invited).
- **Guild** (`Gaxia.Guild`) — persistent guilds (per-guild DataStore key
  `guild:<guildId>`) with three roles (Owner / Officer / Member), invite +
  accept + kick + promote + demote + transfer + disband flows, plus a shared
  per-guild vault (own DataStore key `vault:<guildId>`). Every mutation
  serialises across servers through the new `GuildLock` MemoryStore mutex.
  Officer cap configurable (default 5). Webhook auto-reports create/disband/
  transfer to the `"GuildEvents"` channel if configured.
- **Party** invite extensions — `Invite` / `AcceptInvite` / `DeclineInvite`
  / `CancelInvite` / `GetPendingInvites` on the existing PartyService;
  ephemeral RAM-only with TTL from `Config.Social.Party.InviteTTL` (default
  60s).
- **WebhookService** auto-report extended to the new `"GuildEvents"` channel
  for guild create / disband / ownership transfer (no-op if not configured).
- **Config** new top-level `Social = { Friend, Guild, Party }` block; all
  numeric caps overrideable live via `/flag set Social.<…>`.
- **DataManager**: added test-only `_SeedForTest(player, data)` helper for
  MockPlayer-based unit tests; gated so it cannot clobber a real loaded profile.
- **Client UI**: minimal `FriendListPanel`, `GuildPanel`, `InviteToast`
  modules in `Gaxia_Packages/Client/UI/` — open via `:Open()` from a
  LocalScript. Real UX is a starter skeleton; consumers will theme/extend.
- **RemoteFunction surface**: `ReplicatedStorage/Events/Friend/Action`,
  `Events/Guild/Action`, `Events/Party/InviteAction` — single envelope-shaped
  `{type=..., ...}` API per service, server-authoritative validation.

## [1.0.0] — Framework roadmap Phases 17–25 complete

The framework reached feature-complete across all nine roadmap phases. Every
increment below was verified in Studio (server fresh-VM `run_script_in_play_mode`,
client `run_luau`, or Play-mode screenshots) before commit.

### Docs
- **MANUAL.md** — full sweep to match the runtime: documented all 34 previously-missing
  Lib services (Ban, Analytics, Journal, AntiCheatAdmin, Protection, Lifecycle, Vault,
  Shop, Monetization, Trade, Inventory, Loot, ItemDef, Idle, DailyReward, Mail, Raid,
  Party, Event, Visit, Codex, Refine, Placement, Teleport, Cooldown, Interaction,
  Settings, Memory, AI, VFX, SFX, Anim, Motion3D, Ragdoll) as §8.16–§8.49 in the
  existing per-service code-first format. Added a new "Config / EConfig / Flags" sub-
  section at the top of §8 covering the two-layer config (server-private Config defaults
  ← runtime Flags overlay via EConfig.Get/Enabled/Set/Clear), the `/flag` and `/ac`
  admin commands, and the shared `Gaxia.Flags` client read path. TOC regrouped by
  category (Core / Moderation / Economy / Live-ops / Engines / Utility+Juice).

### Added — WebhookService (Discord / outbound webhooks)
- **Webhook** (`Gaxia.Webhook`) — server-side outbound webhook sender. Per-channel
  queue with HTTP 429 retry (honours `Retry-After`), a Discord embed builder
  (`Discord` / `Embed`), raw `Send` / `SendUrl`, and `IsConfigured`. Webhook URLs
  are server-private secrets in `Config.Webhook.Channels` (never replicated, never
  client-callable). Zero-wiring auto-reports for player bans (`Ban.OnBan` /
  `OnUnban`) and AntiCheat hard actions when a channel is configured; the service
  is eager-loaded at boot so those reports wire up automatically. Swappable
  transport (`SetTransport`) for tests. See MANUAL §8.15.

### Added — Phase 22 · UI breadth
- **Theme** — single design-token source (color/font/spacing/radius) + live `SetTheme`/`OnThemeChanged`.
- **Responsive** — viewport-fitted `UIScale`, device class, safe-area insets.
- **Router** — screen stack with unified DisplayOrder (no z-fighting).
- **Localization** — i18n seam: catalogs, `{token}` interpolation, locale fallback.
- **Components** — Button/Toggle/Slider/TextInput/Dropdown/Tabs/Modal + virtualized ScrollList.
- **GamepadNav** — auto `NextSelection*` wiring from on-screen geometry.
- **RebindMenu** — key-capture + action↔key UI over InputManager.
- **Accessibility** — colorblind/high-contrast (reversible) + text-scale + reduced-motion.
- **Toast** — FIFO notification queue (overflow queues, never drops).
- **Haptics** — gamepad rumble + named patterns.

### Added — Phase 23 · Genre engine pack
- **Codex** (collection/dex + sets), **Refine** (atomic craft + timed Begin/Claim),
  **Vault** (capacity storage + GetValue), **Placement** (grid build + overlap +
  rebuild), **Idle** (offline accrual + clamp/cap), **Loot** (weighted + persisted
  pity + drop transparency → Codex), **AI** (PathfindingService mover/roam/follow),
  **Protection** + **Raid** (state machine + atomic loot move).

### Added — Phase 24 · Retention / social / live-ops
- **DailyReward** (streak ladder), **Mail** (persistent inbox + claimable attachments),
  **Trade** (two-party both-confirm **atomic** swap), **Inventory** (unique instances +
  stacks + equip slots), **Event** + **Visit** (live-ops windows + read-only visiting),
  **Teleport** (retry + reserved server), **Memory** (MemoryStore sorted-map + queue +
  fallback), **Party** (grouping + matchmaking).

### Added — Phase 25 · Juice & motion
- **VFX** (pooled effect registry), **SFX** (3D bank + category volume + ducking),
  **Anim** (named clips + priority/blend + markers), **Motion** (UI tween presets +
  sequence + stagger), **Motion3D** (CFrame tween + waypoint path + spin/float),
  **Ragdoll** (Motor6D↔BallSocket toggle).

### Notes
- Phases 17–21 (hardening, foundation, net/state, monetization, anti-cheat durability)
  predate this changelog; see the git history.
- All hardcoded operational values moved to `Gaxia.Config` (server-side config surface).
- Tooling track (Rojo migration, CI, scaffolding CLI, Companion Plugin) is tracked
  separately in `ROADMAP.md` as the MCP/tooling/DX layer.
