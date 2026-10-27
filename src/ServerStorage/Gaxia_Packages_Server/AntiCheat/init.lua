--!strict
--[[
	Module : AntiCheat
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.init
	Purpose : Anti-cheat orchestrator. Runs a single shared sampler loop that
	          builds a per-player snapshot every Constants.SAMPLER_INTERVAL,
	          then dispatches it to every registered detector. Detectors that
	          records bounded evidence from detectors and transports. An action
	          candidate is emitted only after its threshold is reached; the
	          separate AntiCheatEnforcement service decides whether to act.

	Each detector is a sibling ModuleScript that returns:
		{
		  Name    : string,
		  Init    : (orchestrator) -> ()?            -- optional, called once on boot
		  Sample  : (player, snapshot) -> Flag?      -- optional, called each tick
		}
	Flag = { reason: string, severity: "soft" | "hard", source?: EvidenceSource }
]]

-- ── Services ──
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Shared ──
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

-- ── Server config ──
-- WHY FindFirstChild (never WaitForChild): the orchestrator + its detectors are
-- required THROUGH the server loader's no-yield __index metamethod; WaitForChild
-- yields → "attempt to yield across metamethod/C-call boundary". Config sits at
-- the package ROOT (sibling of the AntiCheat folder), so script.Parent.Parent is
-- Gaxia_Packages_Server. Its body is a pure table (no yields), so require is safe.
local Config = require(script.Parent:FindFirstChild("Config") :: ModuleScript) :: any
local AntiCheatConfig = Config.AntiCheat

-- EffectiveConfig resolver (runtime Flag override <- static Config default). Same
-- no-yield require pattern as Config: FindFirstChild (Lib is present at boot), and
-- EffectiveConfig's body does not yield (Flags state is resolved lazily at use).
local EConfig = require(
	(script.Parent:FindFirstChild("Lib") :: Instance):FindFirstChild(
			"EffectiveConfig"
		) :: ModuleScript
) :: any

local SAMPLER_INTERVAL: number = (AntiCheatConfig.SamplerInterval :: any) or 0.5
local SOFT_THRESHOLD: number = (AntiCheatConfig.SoftFlagThreshold :: any) or 3
local HARD_THRESHOLD: number = (AntiCheatConfig.HardFlagThreshold :: any) or 5

-- Effective enable state (read LIVE, not frozen at boot — that is the whole point).
local function isAntiCheatEnabled(): boolean
	return EConfig.Enabled("AntiCheat.Enabled", AntiCheatConfig.Enabled ~= false)
end
-- Static default from Config: a detector's section may carry `Enabled = false`
-- to disable it at boot (Config.AntiCheat.<Name>.Enabled). Absent/true = enabled.
local function detectorStaticDefault(name: string): boolean
	local section = (AntiCheatConfig :: any)[name]
	return not (typeof(section) == "table" and section.Enabled == false)
end
-- Effective per-detector enable: runtime flag override <- Config static default.
local function isDetectorEnabled(name: string): boolean
	return EConfig.Enabled(`AntiCheat.Detector.{name}.Enabled`, detectorStaticDefault(name))
end

-- ── Types ──
export type EvidenceSource = "server" | "transport" | "trap" | "client" | "client_liveness" | "unknown"

export type Flag = {
	reason: string,
	severity: string, -- "soft" | "hard"
	source: EvidenceSource?,
}

export type Detector = {
	Name: string,
	Init: ((orchestrator: any) -> ())?,
	Sample: ((player: Player, snapshot: any) -> Flag?)?,
}

-- ── Module ──
local AntiCheat = {}

-- (player, reason, severity, count, source) — fires every flag; consumers may dedupe.
AntiCheat.OnFlag = Signal.new()
-- (player, reason, kind, count, source) — fires when an enforcement threshold
-- is reached. This is a candidate, not proof that a player was punished.
AntiCheat.OnAction = Signal.new()

-- ── Internal state ──
local detectors: { Detector } = {}
-- WHY also keep a name → detector map: lets callers access detector-specific
-- helper APIs (CombatGuard.RegisterDamage, AnimationGuard.Allow, StatGuard.Expect,
-- ...) through the orchestrator without each consumer having to `require` the
-- detector module directly. Exposed via AntiCheat.GetDetector(name) and via the
-- orchestrator's __index metamethod (e.g. `AntiCheat.Combat.RegisterDamage(...)`).
local detectorsByName: { [string]: any } = {}
local flagCounts: { [number]: { [string]: number } } = {} -- userId → reason → count
-- Candidate counts deliberately exclude client/client-liveness telemetry. A
-- spoofed client report for a reason must never move trusted evidence closer to
-- an automatic-action threshold.
local candidateCounts: { [number]: { [string]: { [string]: number } } } = {}
local whitelists: { [number]: { [string]: number } } = {} -- userId → reason → expiresAtClock
local samplerRunning = false

-- ── Helpers ──

-- Returns true if (player, reason) is currently whitelisted (expiry not yet
-- reached). Family-aware: detectors emit namespaced reasons ("HumanoidState:Climbing",
-- "Heuristic:SustainedSpeed"), so a whitelist entry on the family prefix
-- ("HumanoidState") covers every ":kind" variant. Never the reverse — an entry
-- on "HumanoidState:Climbing" does not cover "HumanoidState:Swimming".
local function isWhitelisted(player: Player, reason: string): boolean
	local entry = whitelists[player.UserId]
	if not entry then
		return false
	end
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
local function buildSnapshot(player: Player): { [string]: any }
	local character = player.Character
	local hrp = character and (character :: any):FindFirstChild("HumanoidRootPart")
	local humanoid = character and (character :: any):FindFirstChildOfClass("Humanoid")
	return {
		clock = os.clock(),
		character = character,
		hrp = hrp,
		humanoid = humanoid,
		position = hrp and hrp.Position or nil,
		velocity = hrp and hrp.AssemblyLinearVelocity or nil,
		state = humanoid and humanoid:GetState() or nil,
		walkSpeed = humanoid and humanoid.WalkSpeed or nil,
	}
end

-- Record a flag and emit signals when thresholds cross.
local function normalizeSource(source: any): EvidenceSource
	if source == "server" then
		return "server"
	end
	if source == "client" then
		return "client"
	end
	if source == "client_liveness" then
		return "client_liveness"
	end
	if source == "transport" then
		return "transport"
	end
	if source == "trap" then
		return "trap"
	end
	-- Public Flag callers must opt in to a trusted source. Missing or misspelled
	-- provenance is still journaled, but fails closed for automatic action.
	return "unknown"
end

local function recordFlag(player: Player, reason: string, severity: string, source: EvidenceSource?)
	-- Master kill-switch: when AntiCheat is disabled (live), drop EVERY flag —
	-- sampler-driven and external AntiCheat.Flag() alike. Detectors keep sampling
	-- so they stay warm and re-enabling is seamless.
	if not isAntiCheatEnabled() then
		return
	end
	if isWhitelisted(player, reason) then
		return
	end
	local uid = player.UserId
	flagCounts[uid] = flagCounts[uid] or {}
	flagCounts[uid][reason] = (flagCounts[uid][reason] or 0) + 1
	local count = flagCounts[uid][reason]
	local evidenceSource = normalizeSource(source)
	AntiCheat.OnFlag:Fire(player, reason, severity, count, evidenceSource)

	-- Client-controlled telemetry is useful for an operator's journal but can
	-- never become an automatic action candidate. A compromised client may
	-- fabricate, suppress, or replay it at will.
	if
		evidenceSource ~= "server"
		and evidenceSource ~= "transport"
		and evidenceSource ~= "trap"
	then
		return
	end

	local normalizedSeverity = if severity == "hard" then "hard" else "soft"
	candidateCounts[uid] = candidateCounts[uid] or {}
	candidateCounts[uid][reason] = candidateCounts[uid][reason] or {}
	local bySeverity = candidateCounts[uid][reason]
	bySeverity[normalizedSeverity] = (bySeverity[normalizedSeverity] or 0) + 1
	local candidateCount = bySeverity[normalizedSeverity]
	local threshold = if normalizedSeverity == "hard" then HARD_THRESHOLD else SOFT_THRESHOLD
	if candidateCount >= threshold then
		AntiCheat.OnAction:Fire(player, reason, severity, candidateCount, evidenceSource)
	end
end

-- ── Public API ──

-- External entry-point detectors and gameplay code can record evidence.
-- `source` must be an explicit trusted source (`server`, `transport`, or
-- `trap`) to contribute to an automatic-action candidate. Client, liveness,
-- omitted, and unknown sources are journal-only telemetry.
function AntiCheat.Flag(player: Player, reason: string, severity: string?, source: EvidenceSource?)
	recordFlag(player, reason, severity or "soft", source)
end

-- ── Runtime enable/disable (live, no redeploy — flips a Gaxia.Flags override) ──

function AntiCheat.IsEnabled(): boolean
	return isAntiCheatEnabled()
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
-- Also clears enforcement overrides so `/ac reset` truly reverts to observe
-- defaults instead of re-enabling the master with a stale punish mode.
function AntiCheat.ClearOverrides(): ()
	EConfig.Clear("AntiCheat.Enabled")
	for _, d in ipairs(detectors) do
		EConfig.Clear(`AntiCheat.Detector.{d.Name}.Enabled`)
	end
	EConfig.Clear("AntiCheat.Enforcement.Mode")
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
			warn(
				`[AntiCheat] Whitelist({player.Name}, {reason}): non-numeric duration {tostring(
					duration
				)} — ignored`
			)
			return
		end
		d = n
	end
	whitelists[player.UserId] = whitelists[player.UserId] or {}
	whitelists[player.UserId][reason] = os.clock() + d
end

function AntiCheat.GetFlagCount(player: Player, reason: string): number
	local entry = flagCounts[player.UserId]
	return entry and entry[reason] or 0
end

function AntiCheat.ClearFlags(player: Player, reason: string?)
	local function clearReason(entry: { [string]: number }?, target: string): ()
		if not entry then
			return
		end
		entry[target] = nil
		-- Family clear, mirroring isWhitelisted: clearing "HumanoidState" also
		-- wipes pending "HumanoidState:Climbing" etc.
		local prefix = target .. ":"
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
	local function clearCandidateReason(
		entry: { [string]: { [string]: number } }?,
		target: string
	): ()
		if not entry then
			return
		end
		entry[target] = nil
		local prefix = target .. ":"
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

	if reason then
		clearReason(flagCounts[player.UserId], reason)
		clearCandidateReason(candidateCounts[player.UserId], reason)
	else
		flagCounts[player.UserId] = nil
		candidateCounts[player.UserId] = nil
	end
end

-- Used by detector loaders; orchestrator's __index gives them access.
function AntiCheat.RegisterDetector(detector: Detector)
	-- Reject duplicate registrations so loaders are idempotent.
	for _, d in ipairs(detectors) do
		if d.Name == detector.Name then
			return
		end
	end
	table.insert(detectors, detector)
	-- WHY also store by name SYNCHRONOUSLY (before detector.Init runs async):
	-- Init may call back into the orchestrator's accessor APIs (e.g. another
	-- detector's Init asking for `AntiCheat.Stat.Expect`) — the map must already
	-- be populated by then.
	detectorsByName[detector.Name] = detector
	if detector.Init then
		-- task.spawn so a broken Init in one detector doesn't take down loading.
		task.spawn(function()
			local ok, err = pcall(detector.Init, AntiCheat)
			if not ok then
				warn(`[AntiCheat] {detector.Name}.Init failed: {tostring(err)}`)
			end
		end)
	end
end

-- Look up a registered detector by its `.Name` (e.g. "Combat", "Animation",
-- "Stat", "Speed"). Returns nil if no detector with that name has registered
-- yet — typically because the detector module errored at require time. Prefer
-- the metatable shorthand `AntiCheat.Combat.RegisterDamage(...)` over calling
-- this directly; the helper exists so callers can defensively check existence
-- (`if AntiCheat.GetDetector("Combat") then ... end`).
function AntiCheat.GetDetector(name: string): any?
	return detectorsByName[name]
end

-- ── Loader: auto-require child ModuleScripts ──

-- Detectors are children of this ModuleScript (AntiCheat/init.lua) under Rojo.
local function loadDetectors()
	for _, child in ipairs(script:GetChildren()) do
		if child:IsA("ModuleScript") and child ~= script then
			local ok, result = pcall(require, child)
			if not ok then
				warn(`[AntiCheat] Failed to require detector '{child.Name}': {tostring(result)}`)
			elseif typeof(result) == "table" and result.Name then
				AntiCheat.RegisterDetector(result)
			end
		end
	end
end

-- ── Sampler loop ──

local function startSampler()
	if samplerRunning then
		return
	end
	samplerRunning = true
	task.spawn(function()
		while samplerRunning do
			local snapshot
			for _, player in ipairs(Players:GetPlayers()) do
				-- One snapshot per player per tick — shared across all detectors.
				snapshot = buildSnapshot(player)
				for _, detector in ipairs(detectors) do
					if detector.Sample and isDetectorEnabled(detector.Name) then
						local ok, flag = pcall(detector.Sample, player, snapshot)
						if not ok then
							warn(`[AntiCheat] {detector.Name}.Sample errored: {tostring(flag)}`)
						elseif flag then
							-- Every source must be explicit, including sampled detectors.
							-- A custom detector which omits provenance is journal-only rather
							-- than silently gaining escalation authority.
							recordFlag(
								player,
								flag.reason,
								flag.severity or "soft",
								flag.source
							)
						end
					end
				end
			end
			task.wait(SAMPLER_INTERVAL)
		end
	end)
end

-- ── Lifecycle wiring ──

Players.PlayerRemoving:Connect(function(player)
	-- Drop per-player state so leavers don't linger in memory.
	flagCounts[player.UserId] = nil
	candidateCounts[player.UserId] = nil
	whitelists[player.UserId] = nil
end)

-- ── Detector access via metatable ──
-- After loadDetectors() runs, every detector is in detectorsByName. We attach
-- a __index that resolves any unknown key (i.e. not OnFlag/OnAction/Flag/
-- Whitelist/etc.) to a registered detector with that exact `.Name`. This is
-- what makes the API ergonomic:
--     GaxiaServer.AntiCheat.Combat.RegisterDamage(victim, 25)
--     GaxiaServer.AntiCheat.Animation.Allow("rbxassetid://...")
--     GaxiaServer.AntiCheat.Stat.Expect(player, "Coins", newValue)
-- Direct AntiCheat members (`AntiCheat.OnFlag`, `AntiCheat.Flag`, ...) still
-- win because raw lookups skip __index entirely.
loadDetectors()
setmetatable(AntiCheat, {
	__index = function(_, key: string): any?
		return detectorsByName[key]
	end,
})
startSampler()

-- ── Flag-count time-decay (Phase 21.6) ──
-- Old flags age out so a long, legitimate session doesn't slowly accumulate
-- enough soft flags to cross a threshold. Exposed as _decayFlags for testing.
function AntiCheat._decayFlags(amount: number): ()
	local function decay(counts: { [number]: { [string]: number } }): ()
		for _, reasons in pairs(counts) do
			for reason, count in pairs(reasons) do
				local n = count - amount
				if n <= 0 then
					reasons[reason] = nil
				else
					reasons[reason] = n
				end
			end
		end
	end
	local function decayCandidates(counts: { [number]: { [string]: { [string]: number } } }): ()
		for _, reasons in pairs(counts) do
			for reason, bySeverity in pairs(reasons) do
				for severity, count in pairs(bySeverity) do
					local n = count - amount
					if n <= 0 then
						bySeverity[severity] = nil
					else
						bySeverity[severity] = n
					end
				end
				if next(bySeverity) == nil then
					reasons[reason] = nil
				end
			end
		end
	end
	decay(flagCounts)
	decayCandidates(candidateCounts)
end

do
	local decayCfg = AntiCheatConfig.FlagDecay or {}
	local interval: number = (decayCfg.Interval :: any) or 60
	local amount: number = (decayCfg.Amount :: any) or 1
	task.spawn(function()
		while true do
			task.wait(interval)
			AntiCheat._decayFlags(amount)
		end
	end)
end

return AntiCheat
