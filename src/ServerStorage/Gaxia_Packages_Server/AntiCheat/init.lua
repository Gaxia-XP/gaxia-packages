--!strict
--[[
	Module : AntiCheat
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.init
	Purpose : Anti-cheat orchestrator. Runs a single shared sampler loop that
	          builds a per-player snapshot every Config.AntiCheat.SamplerInterval,
	          then dispatches it to every registered detector. It records bounded
	          evidence from detectors and transports (OnFlag); an action
	          candidate (OnAction) is emitted only after its threshold is
	          reached, and the separate AntiCheatEnforcement service decides
	          whether to kick or ban.

	OnFlag(player, reason, severity, count, source) — every flag.
	OnAction(player, reason, kind, count, source) — kind is "soft", "hard", or
	"observe" (a would-be "hard" action while Config.AntiCheat.Enforce is false;
	see there). Fired only for trusted evidence (source "server", "transport" or
	"trap") once that reason's count AT THAT SEVERITY reaches its threshold
	(SoftFlagThreshold / HardFlagThreshold): a single "hard" flag is not an
	action, and soft flags never add up to a hard action. Client reports,
	client-liveness silence and flags without a known source are journaled
	(OnFlag) but never become a candidate.

	Lifecycle: AutoStart = false. Requiring this module, touching
	GaxiaServer.AntiCheat or calling Flag / Whitelist / OnFlag never starts the
	detectors; only Features (Boot) or Lifecycle.Ensure does. Before it starts,
	every public function only records state (flags, whitelists, detectors).

	Each detector is a child ModuleScript of this module (listed in DETECTORS)
	that returns a Detector:
		{
		  Name    : string,
		  Init    : (orchestrator: DetectorHost) -> ()?   -- optional, called once on start
		  Sample  : (player, snapshot: Snapshot) -> Flag? -- optional, called each tick
		}
	Flag = { reason: string, severity: "soft" | "hard", source: EvidenceSource? }

	A detector must name its source ("server" for evidence the server observed
	itself): a flag without one counts as "unknown" — journaled, never acted on.

	The host a detector's Init receives is the orchestrator's API with its own
	Flag: a flag raised through it is dropped while that detector is disabled
	(SetDetectorEnabled / Config.AntiCheat.<Name>.Enabled), like its Sample is
	skipped. AntiCheat.Flag itself (game code) is never tied to a detector.
]]

-- ── Services ──
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

-- ── Dependencies ──
-- Detectors are NOT required here: they load in Init (see DETECTORS), and they
-- never require this module (they receive it as Init's argument).
local Shared    = ReplicatedStorage.Gaxia_Packages.Shared
local Signal    = require(Shared.Signal)
local Net       = require(Shared.NetService)
local Types     = require(script.Parent.Types)
local Config    = require(script.Parent.Config)
local Lifecycle = require(script.Parent.Lib.ServiceLifecycle)
-- EffectiveConfig resolver (runtime Flag override <- static Config default).
local EConfig   = require(script.Parent.Lib.EffectiveConfig)

-- Player, Admin, Ban, Webhook, Journal and AntiCheatAdmin require this module at
-- load, so its body must never throw: every Config.AntiCheat read falls back to
-- the built-in default when the section is missing.
local AntiCheatConfig = Config.AntiCheat

local SAMPLER_INTERVAL  : number = if AntiCheatConfig then AntiCheatConfig.SamplerInterval or 0.5 else 0.5
local SOFT_THRESHOLD    : number = if AntiCheatConfig then AntiCheatConfig.SoftFlagThreshold or 3 else 3
local HARD_THRESHOLD    : number = if AntiCheatConfig then AntiCheatConfig.HardFlagThreshold or 5 else 5

-- Effective enable state (read LIVE, not frozen at boot — that is the whole point).
local function isAntiCheatEnabled(): boolean
	local static = if AntiCheatConfig then AntiCheatConfig.Enabled ~= false else true
	return EConfig.Enabled("AntiCheat.Enabled", static)
end
-- Static default from Config: a detector's section may carry `Enabled = false`
-- to disable it at boot (Config.AntiCheat.<Name>.Enabled). Absent/true = enabled.
local function detectorStaticDefault(name: string): boolean
	local section = if AntiCheatConfig then (AntiCheatConfig :: { [string]: any })[name] else nil
	return not (typeof(section) == "table" and section.Enabled == false)
end
-- Effective per-detector enable: runtime flag override <- Config static default.
local function isDetectorEnabled(name: string): boolean
	return EConfig.Enabled(`AntiCheat.Detector.{name}.Enabled`, detectorStaticDefault(name))
end
-- Observe mode (Enforce = false): see Config/AntiCheat.lua.
local function isEnforcing(): boolean
	local static = if AntiCheatConfig then AntiCheatConfig.Enforce == true else false
	return EConfig.Enabled("AntiCheat.Enforce", static)
end

-- ── Types ──
-- "soft" | "hard"
export type Severity = Types.Severity
-- "soft" | "hard" | "observe"
export type ActionKind = Types.ActionKind
-- Where a flag's evidence came from. Only "server", "transport" and "trap" can
-- become an action candidate; "client", "client_liveness" and "unknown" are
-- journal-only telemetry.
export type EvidenceSource = Types.EvidenceSource

-- A detector's verdict for one sample, the per-tick snapshot, and what a
-- detector's Init receives. Defined in Types.lua (the detectors cannot require
-- this module: it requires them).
export type Flag = Types.AntiCheatFlag
export type Snapshot = Types.AntiCheatSnapshot
export type DetectorHost = Types.DetectorHost

-- What a detector's Init actually receives: the orchestrator's public API, with a
-- Flag that is ignored while that detector is disabled. The built-in detectors
-- only rely on the DetectorHost subset (Flag, IsEnforcing, IsDetectorEnabled); a
-- game detector may use the rest.
export type Host = {
	Flag: (player: Player, reason: string, severity: (Types.Severity | string)?, source: Types.EvidenceSource?) -> (),
	IsEnforcing: () -> boolean,
	IsDetectorEnabled: (name: string) -> boolean,
	IsEnabled: () -> boolean,
	Whitelist: (player: Player, reason: string, duration: number?) -> (),
	GetFlagCount: (player: Player, reason: string) -> number,
	ClearFlags: (player: Player, reason: string?) -> (),
	GetDetector: (name: string) -> any?,
	GetDetectorNames: () -> { string },
	OnFlag: Signal.Signal<Player, string, Types.Severity | string, number, Types.EvidenceSource>,
	OnAction: Signal.Signal<Player, string, Types.ActionKind, number, Types.EvidenceSource>,
}

export type Detector = {
	Name: string,
	Init: ((orchestrator: Host) -> ())?,
	Sample: ((player: Player, snapshot: Snapshot) -> Flag?)?,
}

-- ── Built-in detectors ──
-- Required when AntiCheat initialises (never at load), in this order — the order
-- script:GetChildren() registered them in (module names A → Z). A built-in
-- detector module must be added here; a game's own detector module (any other
-- ModuleScript child of AntiCheat) is discovered by loadDetectors after these. Load's result is only typed { Name: string }: Luau
-- rejects a module that leaves out an optional Detector field (Init or Sample).
type DetectorModule = { Module: string, Load: () -> { Name: string } }
local DETECTORS: { DetectorModule } = {
	{ Module = "AnimationGuard",          Load = function() return require(script.AnimationGuard) end },
	{ Module = "BackpackGuard",           Load = function() return require(script.BackpackGuard) end },
	{ Module = "CombatGuard",             Load = function() return require(script.CombatGuard) end },
	{ Module = "ExploitSignatureScanner", Load = function() return require(script.ExploitSignatureScanner) end },
	{ Module = "FlyDetector",             Load = function() return require(script.FlyDetector) end },
	{ Module = "HeartbeatGuard",          Load = function() return require(script.HeartbeatGuard) end },
	{ Module = "HeuristicDetector",       Load = function() return require(script.HeuristicDetector) end },
	{ Module = "HumanoidStateGuard",      Load = function() return require(script.HumanoidStateGuard) end },
	{ Module = "NoClipDetector",          Load = function() return require(script.NoClipDetector) end },
	{ Module = "RemoteRateLimiter",       Load = function() return require(script.RemoteRateLimiter) end },
	{ Module = "RemoteTrap",              Load = function() return require(script.RemoteTrap) end },
	{ Module = "SpeedDetector",           Load = function() return require(script.SpeedDetector) end },
	{ Module = "StatGuard",               Load = function() return require(script.StatGuard) end },
	{ Module = "TeleportDetector",        Load = function() return require(script.TeleportDetector) end },
	{ Module = "ToolDuplicationGuard",    Load = function() return require(script.ToolDuplicationGuard) end },
	{ Module = "WorldBoundsDetector",     Load = function() return require(script.WorldBoundsDetector) end },
}

-- The built-in detectors' helper APIs by detector Name, as the __index installed
-- in Init resolves them (GaxiaServer.AntiCheat.Combat.RegisterDamage(victim, 25)).
-- nil until AntiCheat has started, or when that detector's module failed to load.
export type DetectorAccess = {
	Animation: typeof(require(script.AnimationGuard))?,
	Backpack: typeof(require(script.BackpackGuard))?,
	Combat: typeof(require(script.CombatGuard))?,
	ExploitSig: typeof(require(script.ExploitSignatureScanner))?,
	Fly: typeof(require(script.FlyDetector))?,
	Heartbeat: typeof(require(script.HeartbeatGuard))?,
	Heuristic: typeof(require(script.HeuristicDetector))?,
	HumanoidState: typeof(require(script.HumanoidStateGuard))?,
	NoClip: typeof(require(script.NoClipDetector))?,
	RemoteRate: typeof(require(script.RemoteRateLimiter))?,
	RemoteTrap: typeof(require(script.RemoteTrap))?,
	Speed: typeof(require(script.SpeedDetector))?,
	Stat: typeof(require(script.StatGuard))?,
	Teleport: typeof(require(script.TeleportDetector))?,
	ToolDupe: typeof(require(script.ToolDuplicationGuard))?,
	WorldBounds: typeof(require(script.WorldBoundsDetector))?,
}

-- ── Module ──
local AntiCheat = {}

-- (player, reason, severity, count, source) — fires every flag; consumers may dedupe.
AntiCheat.OnFlag = Signal.new() :: Signal.Signal<Player, string, Types.Severity | string, number, Types.EvidenceSource>
-- (player, reason, kind, count, source) — fires when trusted evidence reaches a
-- threshold; kind "observe" = a would-be "hard" action while
-- Config.AntiCheat.Enforce is false. A candidate, not proof that anyone was
-- punished: AntiCheatEnforcement decides that.
AntiCheat.OnAction = Signal.new() :: Signal.Signal<Player, string, Types.ActionKind, number, Types.EvidenceSource>

-- ── Internal state ──
local detectors: { Detector } = {}
-- WHY also keep a name → detector map: lets callers access detector-specific
-- helper APIs (CombatGuard.RegisterDamage, AnimationGuard.Allow, StatGuard.Expect,
-- ...) through the orchestrator without each consumer having to `require` the
-- detector module directly. Exposed via AntiCheat.GetDetector(name) and via the
-- orchestrator's __index metamethod (e.g. `AntiCheat.Combat.RegisterDamage(...)`).
local detectorsByName: { [string]: Detector } = {}
local flagCounts: { [number]: { [string]: number } } = {} -- userId → reason → count
-- userId → reason → severity → count of TRUSTED evidence only. Client and
-- client-liveness telemetry never moves a player closer to an action threshold:
-- a spoofed client report must not count toward an automatic action.
local candidateCounts: { [number]: { [string]: { [string]: number } } } = {}
-- "uid:reason" → true once the observe-mode warning was printed (cleared on leave).
local observeWarned : { [string]: boolean } = {}
local whitelists: { [number]: { [string]: number } } = {} -- userId → reason → expiresAtClock
local samplerRunning = false
-- Set by Init. Until then RegisterDetector only records a detector; its Init
-- runs when AntiCheat starts.
local initialized = false
-- Players.PlayerRemoving cleanup. Connected by Init, or by the first Flag /
-- Whitelist call when AntiCheat was never started (not listed in Features), so
-- per-player state is always freed on leave.
local cleanupConnection: RBXScriptConnection? = nil

-- ── Player cleanup ──

local function onPlayerRemoving(player: Player)
	-- Drop per-player state so leavers don't linger in memory.
	flagCounts[player.UserId] = nil
	candidateCounts[player.UserId] = nil
	whitelists[player.UserId] = nil
	local prefix = `{player.UserId}:`
	for key in pairs(observeWarned) do
		if key:sub(1, #prefix) == prefix then
			observeWarned[key] = nil
		end
	end
end

local function ensureCleanup(): ()
	if cleanupConnection == nil then
		cleanupConnection = Players.PlayerRemoving:Connect(onPlayerRemoving)
	end
end

-- ── Helpers ──

-- Returns true if (player, reason) is currently whitelisted (expiry not yet
-- reached). Family-aware: detectors emit namespaced reasons ("HumanoidState:Climbing",
-- "Heuristic:SustainedSpeed"), so a whitelist entry on the family prefix
-- ("HumanoidState") covers every ":kind" variant. Never the reverse — an entry
-- on "HumanoidState:Climbing" does not cover "HumanoidState:Swimming".
local function isWhitelisted(player: Player, reason: string): boolean
	local entry = whitelists[player.UserId]
	if not entry then return false end
	local colon = reason:find(":", 1, true)
	local family = if colon then reason:sub(1, colon - 1) else nil
	for _, key in ipairs(if family then { reason, family } else { reason }) do
		local expires = entry[key]
		if expires then
			if os.clock() < expires then
				return true
			end
			-- Clean up stale entry so the dict doesn't grow unbounded.
			entry[key] = nil
		end
	end
	return false
end

-- Build a single snapshot per tick to feed every detector. We keep it small
-- (current critical state) so detectors stay O(1) per player per tick.
local function buildSnapshot(player: Player): Snapshot
	local character = player.Character
	local hrp = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	return {
		clock     = os.clock(),
		character = character,
		hrp       = hrp,
		humanoid  = humanoid,
		position  = hrp and hrp.Position or nil,
		velocity  = hrp and hrp.AssemblyLinearVelocity or nil,
		state     = humanoid and humanoid:GetState() or nil,
		walkSpeed = humanoid and humanoid.WalkSpeed or nil,
	}
end

-- Missing or misspelled provenance is still journaled, but fails closed for
-- automatic action ("unknown").
local KNOWN_SOURCES: { [string]: boolean } = {
	server = true, transport = true, trap = true, client = true, client_liveness = true,
}
local function normalizeSource(source: any): Types.EvidenceSource
	if typeof(source) == "string" and KNOWN_SOURCES[source] then
		return source :: Types.EvidenceSource
	end
	return "unknown"
end

-- Record a flag and emit signals when thresholds cross.
local function recordFlag(player: Player, reason: string, severity: Types.Severity | string, source: Types.EvidenceSource?)
	-- Master kill-switch: when AntiCheat is disabled (live), drop EVERY flag —
	-- sampler-driven and external AntiCheat.Flag() alike. Detectors keep sampling
	-- so they stay warm and re-enabling is seamless.
	if not isAntiCheatEnabled() then return end
	if isWhitelisted(player, reason) then return end
	local uid = player.UserId
	ensureCleanup()
	flagCounts[uid] = flagCounts[uid] or {}
	flagCounts[uid][reason] = (flagCounts[uid][reason] or 0) + 1
	local count = flagCounts[uid][reason]
	local evidenceSource: Types.EvidenceSource = normalizeSource(source)
	AntiCheat.OnFlag:Fire(player, reason, severity, count, evidenceSource)

	-- Client-controlled telemetry is useful for an operator's journal but can
	-- never become an action candidate: a compromised client may fabricate,
	-- suppress or replay it at will.
	if
		evidenceSource ~= "server"
		and evidenceSource ~= "transport"
		and evidenceSource ~= "trap"
	then
		return
	end

	-- Trusted evidence counts per severity: "hard" needs HARD_THRESHOLD hard flags
	-- (one hard flag is not an action) and soft flags never add up to "hard".
	local normalizedSeverity = if severity == "hard" then "hard" else "soft"
	local byReason = candidateCounts[uid]
	if not byReason then
		byReason = {}
		candidateCounts[uid] = byReason
	end
	local bySeverity = byReason[reason]
	if not bySeverity then
		bySeverity = {}
		byReason[reason] = bySeverity
	end
	local candidateCount = (bySeverity[normalizedSeverity] or 0) + 1
	bySeverity[normalizedSeverity] = candidateCount

	if normalizedSeverity == "hard" then
		if candidateCount < HARD_THRESHOLD then return end
		if isEnforcing() then
			AntiCheat.OnAction:Fire(player, reason, "hard", candidateCount, evidenceSource)
		else
			-- Observe mode: publish what WOULD have been a hard action. The one
			-- enforcing consumer (AntiCheatEnforcement) only acts on "hard".
			local key = `{uid}:{reason}`
			if not observeWarned[key] then
				observeWarned[key] = true
				warn(`[AntiCheat] observe mode — would take HARD action against {player.Name} ({uid}): {reason}. Not enforced (Config.AntiCheat.Enforce = false).`)
			end
			AntiCheat.OnAction:Fire(player, reason, "observe", candidateCount, evidenceSource)
		end
	elseif candidateCount >= SOFT_THRESHOLD then
		AntiCheat.OnAction:Fire(player, reason, "soft", candidateCount, evidenceSource)
	end
end

-- The host a detector's Init receives: the orchestrator's API (through __index),
-- except Flag, which drops the flag while that detector is disabled — the same
-- switch that skips its Sample. Event-driven detectors (Combat, Backpack, Stat,
-- ...) only flag through this, so without it /ac off <Detector> and
-- Config.AntiCheat.<Name>.Enabled = false did not silence them.
local function hostFor(detector: Detector): Host
	local name = detector.Name
	local host = setmetatable({
		Flag = function(player: Player, reason: string, severity: (Types.Severity | string)?, source: Types.EvidenceSource?)
			if not isDetectorEnabled(name) then
				return
			end
			recordFlag(player, reason, severity or "soft", source)
		end,
	}, { __index = AntiCheat })
	return host :: any
end

-- Run a registered detector's Init on its own thread (it may yield, e.g.
-- WaitForChild on a character) so a broken or slow Init never blocks the others.
local function initDetector(detector: Detector): ()
	local init = detector.Init
	if init then
		local host = hostFor(detector)
		task.spawn(function()
			local ok, err = pcall(function(): ...any
				return init(host)
			end)
			if not ok then
				warn(`[AntiCheat] {detector.Name}.Init failed: {tostring(err)}`)
			end
		end)
	end
end

-- ── Public API ──

-- Flag a player from game code (or a detector that kept the module instead of its
-- host). Never tied to a detector's enabled switch: the master switch, the
-- whitelists and the thresholds apply as for every flag. `source` must name a
-- trusted source ("server" for something the server observed itself,
-- "transport", "trap") for the flag to count toward an action; "client",
-- "client_liveness" and an omitted or unknown source are journal-only:
--     AntiCheat.Flag(player, "Speed", "soft", "server")
function AntiCheat.Flag(player: Player, reason: string, severity: (Types.Severity | string)?, source: Types.EvidenceSource?)
	recordFlag(player, reason, severity or "soft", source)
end

-- ── Runtime enable/disable (live, no redeploy — flips a Gaxia.Flags override) ──

function AntiCheat.IsEnabled(): boolean
	return isAntiCheatEnabled()
end

-- False in observe mode (Config.AntiCheat.Enforce / flag "AntiCheat.Enforce"):
-- hard actions are published as "observe" and detectors must not change game
-- state (e.g. BackpackGuard keeps the tool).
function AntiCheat.IsEnforcing(): boolean
	return isEnforcing()
end

-- Master kill-switch. SetEnabled(false) stops all flagging instantly; restart (or
-- ClearOverride) reverts to the Config default.
function AntiCheat.SetEnabled(on: boolean): ()
	EConfig.Set("AntiCheat.Enabled", on == true)
end

function AntiCheat.IsDetectorEnabled(name: string): boolean
	return isDetectorEnabled(name)
end

function AntiCheat.SetDetectorEnabled(name: string, on: boolean): ()
	EConfig.Set(`AntiCheat.Detector.{name}.Enabled`, on == true)
end

-- Drop runtime overrides so enable-state falls back to the Config defaults.
-- Also clears the enforcement overrides, so `/ac reset` truly reverts to the
-- Config defaults (observe mode) instead of re-enabling the master switch with a
-- stale enforce / punish setting.
function AntiCheat.ClearOverrides(): ()
	EConfig.Clear("AntiCheat.Enabled")
	for _, d in ipairs(detectors) do
		EConfig.Clear(`AntiCheat.Detector.{d.Name}.Enabled`)
	end
	EConfig.Clear("AntiCheat.Enforce")
	EConfig.Clear("AntiCheat.Enforcement.ActionCooldownSeconds")
	EConfig.Clear("AntiCheat.Enforcement.Actions.Kick")
	EConfig.Clear("AntiCheat.Enforcement.Actions.TempBan")
	EConfig.Clear("AntiCheat.Enforcement.Actions.PermBan")
end

-- Names of every registered detector (for /ac list + admin tooling).
function AntiCheat.GetDetectorNames(): { string }
	local names: { string } = {}
	for _, d in ipairs(detectors) do
		table.insert(names, d.Name)
	end
	table.sort(names)
	return names
end

-- Forgive a specific reason (or reason family, see isWhitelisted) for a player
-- for `duration` seconds (or forever when nil).
function AntiCheat.Whitelist(player: Player, reason: string, duration: number?)
	-- Coerce defensively: runtime-flag-fed callers can hand us a boolean or
	-- string (EConfig stores /flag overrides unvalidated). `nil` keeps meaning
	-- forever; a non-coercible non-nil value fails CLOSED (no whitelist) rather
	-- than erroring mid-dispatch or silently whitelisting forever.
	local d: number
	if duration == nil then
		d = math.huge
	else
		local n = tonumber(duration)
		if n == nil or n ~= n then
			warn(`[AntiCheat] Whitelist({player.Name}, {reason}): non-numeric duration {tostring(duration)} — ignored`)
			return
		end
		d = n
	end
	ensureCleanup()
	whitelists[player.UserId] = whitelists[player.UserId] or {}
	whitelists[player.UserId][reason] = os.clock() + d
end

function AntiCheat.GetFlagCount(player: Player, reason: string): number
	local entry = flagCounts[player.UserId]
	return entry and entry[reason] or 0
end

-- Remove `reason` and its family from a reason-keyed map. Family clear, mirroring
-- isWhitelisted: clearing "HumanoidState" also wipes pending
-- "HumanoidState:Climbing" etc.
local function clearReasonFamily(entry: { [string]: any }?, reason: string): ()
	if not entry then
		return
	end
	entry[reason] = nil
	local prefix = reason .. ":"
	local familyKeys: { string } = {}
	for key in pairs(entry) do
		if key:sub(1, #prefix) == prefix then
			table.insert(familyKeys, key)
		end
	end
	for _, key in ipairs(familyKeys) do
		entry[key] = nil
	end
end

function AntiCheat.ClearFlags(player: Player, reason: string?)
	if reason then
		clearReasonFamily(flagCounts[player.UserId], reason)
		clearReasonFamily(candidateCounts[player.UserId], reason)
	else
		flagCounts[player.UserId] = nil
		candidateCounts[player.UserId] = nil
	end
end

-- Add a detector (the built-in ones register when AntiCheat starts). Before
-- AntiCheat has started this only records it; its Init runs on start.
function AntiCheat.RegisterDetector(detector: Detector)
	-- Reject duplicate registrations so loaders are idempotent.
	for _, d in ipairs(detectors) do
		if d.Name == detector.Name then
			if d ~= detector then
				warn(`[AntiCheat] RegisterDetector: a detector named '{detector.Name}' is already registered — ignored`)
			end
			return
		end
	end
	table.insert(detectors, detector)
	-- WHY also store by name SYNCHRONOUSLY (before detector.Init runs async):
	-- Init may call back into the orchestrator's accessor APIs (e.g. another
	-- detector's Init asking for `AntiCheat.Stat.Expect`) — the map must already
	-- be populated by then.
	detectorsByName[detector.Name] = detector
	if initialized then
		initDetector(detector)
	end
end

-- Look up a registered detector by its `.Name` (e.g. "Combat", "Animation",
-- "Stat", "Speed"). Returns nil if no detector with that name has registered
-- yet — AntiCheat has not started, or the detector module errored when it was
-- required. Prefer the metatable shorthand `AntiCheat.Combat.RegisterDamage(...)`
-- over calling this directly; the helper exists so callers can defensively check
-- existence (`if AntiCheat.GetDetector("Combat") then ... end`).
function AntiCheat.GetDetector(name: string): any?
	return detectorsByName[name]
end

-- ── Flag-count time-decay (Phase 21.6) ──
-- Old flags age out so a long, legitimate session doesn't slowly accumulate
-- enough soft flags to cross a threshold. Exposed as _decayFlags for testing.
local function decayCounts(counts: { [string]: number }, amount: number): ()
	for key, count in pairs(counts) do
		local n = count - amount
		if n <= 0 then
			counts[key] = nil
		else
			counts[key] = n
		end
	end
end

function AntiCheat._decayFlags(amount: number): ()
	for _, reasons in pairs(flagCounts) do
		decayCounts(reasons, amount)
	end
	for _, reasons in pairs(candidateCounts) do
		for reason, bySeverity in pairs(reasons) do
			decayCounts(bySeverity, amount)
			if next(bySeverity) == nil then
				reasons[reason] = nil
			end
		end
	end
end

-- ── Detector loading ──

local function registerModuleResult(moduleName: string, ok: boolean, result: any): ()
	if not ok then
		-- pcall(entry.Load) re-raises require's error from inside the closure, which
		-- prefixes this script's "<path>:<line>: "; strip it so the text is require's.
		local message = string.gsub(tostring(result), "^[%w_%.]+:%d+: ", "", 1)
		warn(`[AntiCheat] Failed to require detector '{moduleName}': {message}`)
	elseif typeof(result) == "table" and result.Name then
		AntiCheat.RegisterDetector(result :: any)
	end
end

-- Require + register every built-in detector, in DETECTORS order, then every other
-- ModuleScript child (a game's own detector, MANUAL §9). A built-in module deleted
-- in Studio is skipped silently; a detector whose module errors is warned and skipped.
local function loadDetectors()
	local builtIn: { [string]: boolean } = {}
	for _, entry in ipairs(DETECTORS) do
		builtIn[entry.Module] = true
		if script:FindFirstChild(entry.Module) ~= nil then
			local ok, result = pcall(entry.Load)
			registerModuleResult(entry.Module, ok, result)
		end
	end
	for _, child in ipairs(script:GetChildren()) do
		if child:IsA("ModuleScript") and not builtIn[child.Name] then
			local ok, result = pcall(require, child)
			registerModuleResult(child.Name, ok, result)
		end
	end
end

-- ── Sampler loop ──

-- MicroProfiler labels (debug.profilebegin): "AntiCheat.Sampler" around each frame's
-- batch of players, and "AntiCheat.<Name>" around each detector's Sample inside it.
local SAMPLER_PROFILE_LABEL : string = "AntiCheat.Sampler"
local detectorProfileLabels: { [string]: string } = {}
local function detectorProfileLabel(name: string): string
	local label = detectorProfileLabels[name]
	if label == nil then
		label = "AntiCheat." .. name
		detectorProfileLabels[name] = label
	end
	return label
end

-- A pass spreads its players over this share of SAMPLER_INTERVAL (the rest is
-- slack for slow frames), so no single frame samples every player.
local SAMPLER_SPREAD : number = 0.8

-- One snapshot per player per pass, shared across all detectors.
local function samplePlayer(player: Player): ()
	local snapshot = buildSnapshot(player)
	for _, detector in ipairs(detectors) do
		local sample = detector.Sample
		if sample and isDetectorEnabled(detector.Name) then
			debug.profilebegin(detectorProfileLabel(detector.Name))
			local ok, flag = pcall(sample, player, snapshot)
			debug.profileend()
			if not ok then
				warn(`[AntiCheat] {detector.Name}.Sample errored: {tostring(flag)}`)
			elseif flag then
				-- Every source must be explicit, sampled detectors included: a
				-- custom detector that omits it is journal-only rather than
				-- silently gaining escalation authority.
				recordFlag(player, flag.reason, flag.severity or "soft", flag.source)
			end
		end
	end
end

-- Every player is sampled once per SAMPLER_INTERVAL, as before, but a pass is spread
-- over frames: after the first player, players are taken in proportion to the time
-- elapsed since the pass began, finishing within SAMPLER_SPREAD of the interval. A
-- player keeps the same slot in each pass, so the time between two of their samples
-- stays about SAMPLER_INTERVAL (it only shortens when players ahead of them leave).
-- With one player the whole pass runs in one frame, as before.
local function startSampler()
	if samplerRunning then return end
	samplerRunning = true
	task.spawn(function()
		while samplerRunning do
			local passStart = os.clock()
			local players = Players:GetPlayers()
			local total = #players
			local window = SAMPLER_INTERVAL * SAMPLER_SPREAD
			local done = 0
			while done < total do
				local elapsed = os.clock() - passStart
				local due = if window > 0 then math.ceil(total * elapsed / window) else total
				due = math.clamp(due, done + 1, total)
				debug.profilebegin(SAMPLER_PROFILE_LABEL)
				while done < due do
					done += 1
					local player = players[done]
					-- Skip a player who left since the pass started: sampling them now
					-- would recreate the per-player state their PlayerRemoving freed.
					if player.Parent == Players then
						samplePlayer(player)
					end
				end
				debug.profileend()
				if done < total then
					RunService.Heartbeat:Wait()
				end
			end
			task.wait(math.max(SAMPLER_INTERVAL - (os.clock() - passStart), 0))
		end
	end)
end

-- ── Flag-count decay loop ──

local function startFlagDecay()
	local decayCfg = if AntiCheatConfig then AntiCheatConfig.FlagDecay else nil
	local interval : number = if decayCfg then decayCfg.Interval or 60 else 60
	local amount   : number = if decayCfg then decayCfg.Amount or 1 else 1
	task.spawn(function()
		while true do
			task.wait(interval)
			AntiCheat._decayFlags(amount)
		end
	end)
end

-- ── Detector access via metatable ──
-- Installed in Init, after loadDetectors(): a __index that resolves any unknown
-- key (i.e. not OnFlag/OnAction/Flag/Whitelist/etc.) to a registered detector
-- with that exact `.Name`. This is what makes the API ergonomic:
--     GaxiaServer.AntiCheat.Combat.RegisterDamage(victim, 25)
--     GaxiaServer.AntiCheat.Animation.Allow("rbxassetid://...")
--     GaxiaServer.AntiCheat.Stat.Expect(player, "Coins", newValue)
-- Direct AntiCheat members (`AntiCheat.OnFlag`, `AntiCheat.Flag`, ...) still
-- win because raw lookups skip __index entirely.
local function installDetectorAccess(): ()
	setmetatable(AntiCheat, {
		__index = function(_, key: string): any?
			return detectorsByName[key]
		end,
	})
end

-- ── Lifecycle ──

Lifecycle.Define(AntiCheat, {
	Name = "AntiCheat",
	-- Only Features (Boot) or Lifecycle.Ensure start the detectors.
	AutoStart = false,
	Needs = {},
	Init = function()
		ensureCleanup()
		-- The client channels (AntiCheat.Report, AntiCheat.Heartbeat) are Net RPCs
		-- the detectors register in their Init; no raw Events remotes are created.
		-- NetService reports rate-limit / argument-validation violations through this
		-- hook (it does not require this module from the shared side). A rejected
		-- request is client-controlled input, so NetService names it "client":
		-- journaled, never an action candidate.
		Net.SetViolationHandler(function(player: Player, reason: string, severity: Types.Severity, source: Types.EvidenceSource?)
			recordFlag(player, reason, severity, source or "client")
		end)
		-- Detectors game code registered before AntiCheat started are registered
		-- again after the built-in ones, as when the built-ins always loaded first:
		-- a built-in keeps its name, and they sample and Init after the built-ins.
		local registeredEarly = table.clone(detectors)
		table.clear(detectors)
		table.clear(detectorsByName)
		initialized = true
		loadDetectors()
		installDetectorAccess()
		for _, detector in ipairs(registeredEarly) do
			AntiCheat.RegisterDetector(detector)
		end
	end,
	Start = function()
		startSampler()
		startFlagDecay()
	end,
})

-- Typed with the detector accessors so `AntiCheat.Stat.Expect(...)` autocompletes.
return AntiCheat :: typeof(AntiCheat) & DetectorAccess
