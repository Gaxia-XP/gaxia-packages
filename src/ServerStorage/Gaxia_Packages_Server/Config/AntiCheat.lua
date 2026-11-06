--!strict
-- Config/AntiCheat.lua — Anti-cheat orchestrator + detector tunables
--
-- Severity drives the orchestrator's threshold ladder, counted per reason and
-- per severity from TRUSTED evidence only (source "server" / "transport" / "trap"):
--   "soft" → soft counter → OnAction "soft" at SoftFlagThreshold
--   "hard" → hard counter → OnAction "hard" (or "observe") at HardFlagThreshold
-- Client reports and client-liveness evidence are journaled, never counted.
-- An OnAction candidate is not a punishment: AntiCheatEnforcement (Lib) alone
-- decides whether a "hard" candidate kicks or bans (Enforcement + BanPolicy).
--
-- Per-detector Enabled: runtime override via flag "AntiCheat.Detector.<Name>.Enabled"
-- Master switch:        runtime override via flag "AntiCheat.Enabled"
-- Enforcement:          runtime override via flag "AntiCheat.Enforce"
-- Enforcement actions:  runtime overrides via flags "AntiCheat.Enforcement.Actions.<Kick|TempBan|PermBan>"
--                       and "AntiCheat.Enforcement.ActionCooldownSeconds"

local Types = require(script.Parent.Parent.Types)

-- "soft" | "hard"
export type Severity = Types.Severity

-- Every detector section: Enabled = false turns the detector off at boot.
export type DetectorConfig = {
	Enabled: boolean?,
	Severity: Severity,
	[string]: any,
}

export type AntiCheatConfig = {
	Enabled: boolean,
	Enforce: boolean,
	SamplerInterval: number,
	SoftFlagThreshold: number,
	HardFlagThreshold: number,

	Speed: { ToleranceMultiplier: number, FreefallMultiplier: number?, Enabled: boolean?, Severity: Severity },
	Fly: { VelocityThreshold: number, Enabled: boolean?, Severity: Severity },
	NoClip: { RaycastInterval: number, Enabled: boolean?, Severity: Severity },
	Teleport: { MaxDelta: number, WhitelistGraceSeconds: number, Enabled: boolean?, Severity: Severity },
	RemoteRate: { Enabled: boolean?, Severity: Severity },
	-- Optional: RemoteTrap (honeypot / wrong-direction remotes) always flags "hard".
	RemoteTrap: { Enabled: boolean? }?,
	Stat: { Enabled: boolean?, Severity: Severity },
	ToolDupe: { Enabled: boolean?, Severity: Severity },
	Animation: { Enabled: boolean?, Severity: Severity },
	Combat: { Enabled: boolean?, Severity: Severity },
	Backpack: { Enabled: boolean?, Severity: Severity },
	Heartbeat: { TimeoutSeconds: number, JoinGraceSeconds: number, Enabled: boolean?, Severity: Severity },
	-- Optional sections: their detectors fall back to built-in defaults without them.
	HumanoidState: { Enabled: boolean?, Severity: Severity }?,
	WorldBounds: { MinY: number, MaxXZ: number, Enabled: boolean?, Severity: Severity }?,
	Heuristic: {
		WindowSize: number,
		NearLimitFactor: number,
		MaxVariance: number,
		MinSpeed: number,
		Enabled: boolean?,
		Severity: Severity,
	}?,

	FlagDecay: { Interval: number, Amount: number }?,

	-- What AntiCheatEnforcement may do with a "hard" candidate once Enforce is true.
	-- A disabled action falls through to the next lower enabled one (PermBan →
	-- TempBan → Kick); with none enabled the decision is only journaled.
	Enforcement: {
		-- One automatic action per player per reason within this window.
		ActionCooldownSeconds: number,
		Actions: { Kick: boolean, TempBan: boolean, PermBan: boolean },
	},

	-- ExemptRole = false turns the role exemption off (only the place creator is exempt).
	BanPolicy: {
		KickAt: number,
		TempBanAt: number,
		PermBanAt: number,
		TempBanSeconds: number,
		ExemptRole: string | false,
	},
}

local AntiCheat: AntiCheatConfig = {
	Enabled           = true,
	-- OBSERVE MODE while false: detectors run and flags are recorded (OnFlag, the
	-- Journal, warnings), but a would-be HARD action is published as
	-- OnAction(player, reason, "observe") instead of "hard" — nobody is kicked or
	-- banned (AntiCheatEnforcement only acts on "hard") and BackpackGuard does not
	-- destroy tools. Client / client-liveness evidence is never enforceable,
	-- whatever this says. The detectors did not load at
	-- all between 2026-07-17 and this fix, so play-test with a NON-creator account
	-- (the creator is always exempt) and check the "would take hard action" warnings
	-- before setting this to true.
	Enforce           = false,
	SamplerInterval   = 0.5,
	SoftFlagThreshold = 3,
	HardFlagThreshold = 5,

	Speed         = { ToleranceMultiplier = 1.5,                                   Severity = "soft" },
	Fly           = { VelocityThreshold   = 30,                                    Severity = "soft" },
	NoClip        = { RaycastInterval     = 1,                                     Severity = "soft" },
	Teleport      = { MaxDelta            = 50, WhitelistGraceSeconds = 2,         Severity = "hard" },
	RemoteRate    = {                                                               Severity = "soft" },
	Stat          = {                                                               Severity = "hard" },
	ToolDupe      = {                                                               Severity = "hard" },
	Animation     = {                                                               Severity = "soft" },
	Combat        = {                                                               Severity = "hard" },
	Backpack      = {                                                               Severity = "hard" },
	-- OFF: this game has custom (non-Truss) climbing; Enabled=false disables it entirely
	HumanoidState = { Enabled            = false,                                  Severity = "soft" },
	Heartbeat     = { TimeoutSeconds     = 15,   JoinGraceSeconds = 30,            Severity = "soft" },
	WorldBounds   = { MinY               = -500, MaxXZ = 10000,                    Severity = "hard" },

	-- Flag-count decay: prevents long legit sessions from slowly accumulating flags
	FlagDecay = { Interval = 60, Amount = 1 },

	-- Kick only by default: automatic temp/perm bans are opt-in (a ban outlives the
	-- server, so a false positive costs far more than a kick).
	Enforcement = {
		ActionCooldownSeconds = 60,
		Actions = { Kick = true, TempBan = false, PermBan = false },
	},

	-- Strike ladder AntiCheatEnforcement applies to repeat HARD actions (strikes
	-- per user for the server's lifetime; RemoteTrap evidence only ever kicks).
	-- ExemptRole and above (+ place creator always) skip auto-kick/auto-ban.
	BanPolicy = { KickAt = 1, TempBanAt = 2, PermBanAt = 3, TempBanSeconds = 3600, ExemptRole = "admin" },

	-- Sustained high mean speed + low variance = held near-constant speed (tuned speedhack)
	Heuristic = { WindowSize = 20, NearLimitFactor = 1.3, MaxVariance = 6, MinSpeed = 8, Severity = "soft" },
}

return AntiCheat
