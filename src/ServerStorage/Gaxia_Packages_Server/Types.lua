--!strict
-- ─────────────────────────────────────────────────────────────
-- Types.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Types
-- Purpose : Type-only definitions shared across the server package (no runtime
--           state). Anything two modules must agree on lives here: the service
--           names Features accepts, and the signatures of the hooks that break
--           dependency cycles (a higher-level module installs them in its Init).
--
-- Usage   : local Types = require(script.Parent.Parent.Types)   -- from Lib/ or Config/
--           local features: Types.Features = { Services = { "Data", "Economy" } }
-- ─────────────────────────────────────────────────────────────

-- Every service that registers with ServiceLifecycle (Lifecycle.Define). These are
-- the names Config/Features accepts; they match the GaxiaServer.<Name> loader keys.
export type ServiceName =
	"Data" | "Player" | "Item" | "Economy" | "Tool" | "Zone" | "Cooldown" | "ItemDef"
	| "Interaction" | "Settings" | "Monetization" | "Shop" | "Analytics" | "Webhook"
	| "Journal" | "Ban" | "AntiCheatAdmin" | "Codex" | "Refine" | "Vault" | "Placement"
	| "Idle" | "Loot" | "AI" | "Protection" | "Raid" | "DailyReward" | "Mail" | "Inventory"
	| "Event" | "Visit" | "Teleport" | "Memory" | "Trade" | "Party" | "VFX" | "SFX" | "Anim"
	| "Motion3D" | "Ragdoll" | "Admin" | "Chat" | "Quest" | "Achievement" | "Level"
	| "Migration" | "Leaderboard" | "Messages" | "Friend" | "Guild" | "GuildLock"
	| "InviteQueue" | "Pet" | "AntiCheat"

-- Every GaxiaServer.<Key> the loader resolves: services plus framework utilities.
export type ModuleKey = ServiceName | "Lifecycle" | "EConfig"

-- Config/Features (framework default) and the optional game-owned
-- ServerStorage.GaxiaFeatures override. Services = started at boot, in this order
-- (plus whatever they Need). A service not listed still starts the first time game
-- code touches GaxiaServer.<Name> or calls one of its functions.
export type Features = {
	Services: { ServiceName },
}
export type FeaturesOverride = {
	Services: { ServiceName }?,
}

-- AntiCheat
export type Severity = "soft" | "hard"
-- "observe" = would have been "hard" while Config.AntiCheat.Enforce is false.
export type ActionKind = "soft" | "hard" | "observe"

-- The AntiCheat detector contract. They live here because a detector cannot
-- require the orchestrator (the orchestrator requires the detectors);
-- AntiCheat/init.lua re-exports them as AntiCheat.Flag / Snapshot / DetectorHost.
--
-- A detector's verdict for one sample. Detectors pass their
-- Config.AntiCheat.<Name>.Severity through, so any string is accepted.
export type AntiCheatFlag = {
	reason: string,
	severity: Severity | string,
}

-- Built once per player per sampler tick and shared by every detector's Sample.
export type AntiCheatSnapshot = {
	clock: number,
	character: Model?,
	hrp: BasePart?,
	humanoid: Humanoid?,
	position: Vector3?,
	velocity: Vector3?,
	state: Enum.HumanoidStateType?,
	walkSpeed: number?,
}

-- What a detector's Init receives: the orchestrator (only these members are part
-- of the contract).
export type DetectorHost = {
	Flag: (player: Player, reason: string, severity: (Severity | string)?) -> (),
	IsEnforcing: () -> boolean,
	IsDetectorEnabled: (name: string) -> boolean,
}

-- Cycle-breaking hooks (installed by the higher-level module's Init):
-- NetService → AntiCheat: NetService reports rate-limit / validation violations.
export type ViolationHandler = (player: Player, reason: string, severity: Severity) -> ()
-- BanService → AdminCommands: is this userId at or above `role`? (escalation exemption)
export type UserRoleResolver = (userId: number, role: string) -> boolean
-- ChatCommandSystem → AdminCommands: is this player at or above `role`? (command gating)
export type PlayerRoleResolver = (player: Player, role: string) -> boolean

return {}
