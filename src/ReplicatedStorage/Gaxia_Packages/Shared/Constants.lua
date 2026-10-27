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
local Constants: { [string]: any } = table.freeze({

	-- ── Network ──────────────────────────────────────────────
	-- NetService owns Events.Net and enforces both a per-RPC bucket and a
	-- broader per-player bucket before it decodes a request. These values are
	-- tuning defaults, not secrets or a replacement for server validation.
	REMOTE_RATE_LIMIT_DEFAULT = 10, -- max calls/sec for one logical RPC
	REMOTE_RATE_BURST = 20, -- per-RPC burst allowance
	REMOTE_GLOBAL_RATE_LIMIT_DEFAULT = 60, -- max combined calls/sec per player
	REMOTE_GLOBAL_RATE_BURST = 100, -- combined burst allowance
	REMOTE_CONCURRENCY_DEFAULT = 4, -- in-flight handlers/player/RPC

	-- ── Anti-cheat thresholds ────────────────────────────────
	-- MOVED to ServerStorage/Gaxia_Packages_Server/Config.AntiCheat — kept
	-- server-private (NOT replicated) so cheat clients cannot read tolerances
	-- to tune around them. Detectors + orchestrator require() that Config now.

	-- ── UI ───────────────────────────────────────────────────
	NOTIFICATION_DEFAULT_DURATION = 3, -- seconds a notification stays visible
	NOTIFICATION_MAX_STACK = 5, -- max simultaneous notification panels
	UI_ANIMATION_TIME = 0.25, -- default tween duration for UI transitions

	-- ── Player ───────────────────────────────────────────────
	CHARACTER_LOAD_TIMEOUT = 10, -- seconds to wait before timing out character load

	-- ── General ──────────────────────────────────────────────
	MAX_PLAYERS = 50, -- hard cap enforced server-side
})

return Constants
