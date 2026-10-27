--!strict
-- Config/AntiCheat.lua — Anti-cheat orchestrator + detector tunables
--
-- Severity drives the orchestrator's threshold ladder. It creates an action
-- candidate only after its matching threshold; AntiCheatEnforcement separately
-- decides whether that candidate can apply a Kick/Ban.
--
-- Per-detector Enabled: runtime override via flag "AntiCheat.Detector.<Name>.Enabled"
-- Master switch:        runtime override via flag "AntiCheat.Enabled"

export type DetectorConfig = {
	Severity: string,
	[string]: any,
}

return {
	Enabled = true,
	SamplerInterval = 0.5,
	SoftFlagThreshold = 3,
	HardFlagThreshold = 5,

	-- Observe first: detectors and transport rejects are journaled, but no player
	-- is automatically punished until an operator explicitly switches to enforce.
	-- Client/client-liveness evidence is never enforceable regardless of this mode.
	Enforcement = {
		Mode = "observe",
		ActionCooldownSeconds = 60,
		Actions = {
			Kick = true,
			TempBan = false,
			PermBan = false,
		},
	},

	Speed = { ToleranceMultiplier = 1.5, Severity = "soft" } :: DetectorConfig,
	Fly = { VelocityThreshold = 30, Severity = "soft" } :: DetectorConfig,
	NoClip = { RaycastInterval = 1, Severity = "soft" } :: DetectorConfig,
	Teleport = { MaxDelta = 50, WhitelistGraceSeconds = 2, Severity = "hard" } :: DetectorConfig,
	Stat = { Severity = "hard" } :: DetectorConfig,
	ToolDupe = { Severity = "hard" } :: DetectorConfig,
	Animation = { Severity = "soft" } :: DetectorConfig,
	Combat = { Severity = "hard" } :: DetectorConfig,
	Backpack = { Severity = "hard" } :: DetectorConfig,
	-- OFF: this game has custom (non-Truss) climbing; Enabled=false disables it entirely
	HumanoidState = {
		Enabled = false,
		Severity = "soft",
	} :: DetectorConfig,
	Heartbeat = { TimeoutSeconds = 15, JoinGraceSeconds = 30, Severity = "soft" } :: DetectorConfig,
	WorldBounds = { MinY = -500, MaxXZ = 10000, Severity = "hard" } :: DetectorConfig,

	-- Flag-count decay: prevents long legit sessions from slowly accumulating flags
	FlagDecay = { Interval = 60, Amount = 1 },

	-- Thresholds consumed by AntiCheatEnforcement when Mode = "enforce".
	-- ExemptRole and above (+ place creator always) skip automatic action.
	BanPolicy = {
		KickAt = 1,
		TempBanAt = 2,
		PermBanAt = 3,
		TempBanSeconds = 3600,
		ExemptRole = "admin",
	},

	-- Sustained high mean speed + low variance = held near-constant speed (tuned speedhack)
	Heuristic = {
		WindowSize = 20,
		NearLimitFactor = 1.3,
		MaxVariance = 6,
		MinSpeed = 8,
		Severity = "soft",
	},
}
