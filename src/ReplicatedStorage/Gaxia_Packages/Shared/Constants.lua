--!strict
-- ============================================================
-- Constants (ModuleScript)
-- Location : ReplicatedStorage/Gaxia_Packages/Shared/Constants
-- Purpose  : Single source of truth for all framework-wide
--            numeric and string constants. Frozen at load time
--            so values cannot be mutated at runtime.
-- ============================================================

-- ── Module ───────────────────────────────────────────────────

-- Typed as {[string]: any} to allow heterogeneous values without weakening
-- consumers — readers still get autocomplete on individual keys.
local Constants : { [string]: any } = table.freeze({

	-- ── Network ──────────────────────────────────────────────
	-- NOTE: still read by NetService (Shared) + RemoteRateLimiter (server).
	-- Migrate to Config.Network in Increment C (17.5), then delete this block.
	REMOTE_RATE_LIMIT_DEFAULT = 10,   -- max remote calls per second per player
	REMOTE_RATE_BURST         = 20,   -- burst allowance before throttling

	-- ── Anti-cheat thresholds ────────────────────────────────
	-- MOVED to ServerStorage/Gaxia_Packages_Server/Config.AntiCheat — kept
	-- server-private (NOT replicated) so cheat clients cannot read tolerances
	-- to tune around them. Detectors + orchestrator require() that Config now.
	-- (ZoneService still reads SAMPLER_INTERVAL via a graceful `or 0.5` fallback;
	--  repoint it at Config.AntiCheat.SamplerInterval in a follow-up.)

	-- ── UI ───────────────────────────────────────────────────
	NOTIFICATION_DEFAULT_DURATION = 3,    -- seconds a notification stays visible
	NOTIFICATION_MAX_STACK        = 5,    -- max simultaneous notification panels
	UI_ANIMATION_TIME             = 0.25, -- default tween duration for UI transitions

	-- ── Player ───────────────────────────────────────────────
	CHARACTER_LOAD_TIMEOUT = 10, -- seconds to wait before timing out character load
	-- Attribute a server writer sets on a leaderstats ValueObject to the value it is
	-- about to write, so AntiCheat's StatGuard treats the change as legitimate
	-- (PlayerService.SetupLeaderstats/SetLeaderstat do this; so does Stat.Expect).
	STAT_EXPECTED_ATTRIBUTE = "__GaxiaExpected",

	-- ── General ──────────────────────────────────────────────
	MAX_PLAYERS = 50, -- hard cap enforced server-side
})

return Constants
