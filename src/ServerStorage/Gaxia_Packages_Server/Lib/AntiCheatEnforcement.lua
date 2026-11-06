--!strict
-- ─────────────────────────────────────────────────────────────
-- AntiCheatEnforcement.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AntiCheatEnforcement
-- Purpose : The sole owner of automatic AntiCheat actions. Detector evidence
--           (AntiCheat.OnFlag) and action candidates (AntiCheat.OnAction) are
--           kept apart from Kick/Ban decisions, so untrusted client telemetry
--           can never punish a player by itself and no second consumer can act
--           on its own policy.
--
--           A decision is applied only when ALL of these hold:
--             • AntiCheat is enabled and enforcing (Config.AntiCheat.Enforce /
--               flag "AntiCheat.Enforce") — re-read here, because OnAction is
--               dispatched asynchronously and `/ac off` must cancel a queued one;
--             • the candidate is "hard" and its evidence is trusted
--               ("server", "transport" or "trap");
--             • the player is still in the server, is not escalation-exempt
--               (place creator + roles >= BanPolicy.ExemptRole, BanService),
--               and was not already punished this session;
--             • the same reason did not already act within
--               Config.AntiCheat.Enforcement.ActionCooldownSeconds.
--           Then a strike is added and Config.AntiCheat.BanPolicy picks the
--           action among the enabled Config.AntiCheat.Enforcement.Actions:
--           Kick → TempBan → PermBan. Strikes count per user for the server's
--           lifetime (a rejoin to the same server keeps them); Unban and /acclear
--           reset them (BanService.ResetStrikes). Trap-only evidence has its own
--           counter and can only ever kick: a tripwire is not durable-ban proof.
--
-- Access  : Gaxia.Enforcement  (server)
--   Gaxia.Enforcement.OnDecision:Connect(function(player, reason, kind, source, decision, applied, strikes) end)
--   Gaxia.Enforcement.GetMode()   -- "observe" | "enforce"
--
-- Lifecycle: Start subscribes to AntiCheat.OnAction (when AntiCheat is
--            installed). BanService's Start starts this service, so the policy
--            runs whenever Ban does.
-- ─────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal     = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle  = require(script.Parent.ServiceLifecycle)
local EConfig    = require(script.Parent.EffectiveConfig)
local BanService = require(script.Parent.BanService)
local Config     = require(script.Parent.Parent.Config)
local Types      = require(script.Parent.Parent.Types)

-- The AntiCheat orchestrator is a soft dependency (its package may not be
-- installed): Start subscribes to its OnAction if it is, which never starts it.
type AntiCheatApi = {
	OnAction: Signal.Signal<Player, string, Types.ActionKind, number, Types.EvidenceSource>,
	IsEnabled: () -> boolean,
	IsEnforcing: () -> boolean,
}

-- What a decision did. "observe" = not applied (observe mode, untrusted
-- evidence, not "hard", player gone, or no action enabled for this strike);
-- "deduped" = already punished this session or within the action cooldown.
export type Decision = "observe" | "kick" | "temp_ban" | "perm_ban" | "deduped" | "exempt"

local Enforcement = {}

-- (player, reason, kind, source, decision, applied, strikeCount) for every candidate.
Enforcement.OnDecision = Signal.new() :: Signal.Signal<Player, string, Types.ActionKind, Types.EvidenceSource, Decision, boolean, number>

-- userId → strikes this server. Kept for the server's lifetime (NOT cleared on
-- leave): with the default policy (KickAt 1, TempBanAt 2, PermBanAt 3) a cheater
-- who rejoins the same server after a kick reaches the next rung on the next
-- hard action. Clearing on leave meant kick → rejoin → kick forever. One small
-- number per flagged user, so it stays bounded by the server's lifetime.
local strikes: { [number]: number } = {}
-- userId → trap-only strikes (kick only; freed on leave).
local trapStrikes: { [number]: number } = {}
-- Players already kicked/banned whose disconnect is still pending. Kick is
-- asynchronous, so several hard candidates arriving in the same frame used to
-- add several strikes (KickAt=1 → TempBanAt=2 → PermBanAt=3 inside one frame):
-- three simultaneous flags meant a permanent ban. One punishment per session
-- (cleared on leave, so the next session can be punished again).
local punished: { [number]: boolean } = {}
-- userId → reason → os.clock() of the last decision that passed the gates.
local lastAppliedAt: { [number]: { [string]: number } } = {}

-- ── Config (read live: runtime flags override the static defaults) ──

local AntiCheatConfig = Config.AntiCheat

local function isEnforcingConfig(): boolean
	local static = if AntiCheatConfig then AntiCheatConfig.Enforce == true else false
	return EConfig.Enabled("AntiCheat.Enforce", static)
end

local function actionEnabled(name: "Kick" | "TempBan" | "PermBan"): boolean
	local section = if AntiCheatConfig then AntiCheatConfig.Enforcement else nil
	local static = if section then section.Actions[name] == true else (name == "Kick")
	return EConfig.Enabled(`AntiCheat.Enforcement.Actions.{name}`, static)
end

local function actionCooldownSeconds(): number
	local section = if AntiCheatConfig then AntiCheatConfig.Enforcement else nil
	local static = if section then section.ActionCooldownSeconds else 60
	local value = tonumber(EConfig.Get("AntiCheat.Enforcement.ActionCooldownSeconds", static))
	if value == nil or value ~= value or value < 0 then
		return 60
	end
	return value
end

-- ── Helpers ──

local KNOWN_SOURCES: { [string]: boolean } = {
	server = true, transport = true, trap = true, client = true, client_liveness = true,
}
local function normalizeSource(source: any): Types.EvidenceSource
	if typeof(source) == "string" and KNOWN_SOURCES[source] then
		return source :: Types.EvidenceSource
	end
	return "unknown"
end

local function isEnforceableSource(source: Types.EvidenceSource): boolean
	return source == "server" or source == "transport" or source == "trap"
end

-- Re-read the switches at the decision boundary (OnAction is asynchronous). A
-- broken probe fails closed: observe rather than act.
local function isAntiCheatEnforcing(antiCheat: AntiCheatApi): boolean
	local okEnabled, enabled = pcall(antiCheat.IsEnabled)
	if not okEnabled or enabled ~= true then
		return false
	end
	local okEnforcing, enforcing = pcall(antiCheat.IsEnforcing)
	return okEnforcing and enforcing == true
end

local function isCurrentPlayer(player: Player): boolean
	return player.Parent == Players and Players:GetPlayerByUserId(player.UserId) == player
end

local function emit(player: Player, reason: string, kind: Types.ActionKind, source: Types.EvidenceSource, decision: Decision, applied: boolean, strikeCount: number): ()
	Enforcement.OnDecision:Fire(player, reason, kind, source, decision, applied, strikeCount)
end

local function kick(player: Player, reason: string): boolean
	if player.Parent == nil then
		return false
	end
	punished[player.UserId] = true
	player:Kick(`[AntiCheat] {reason}`)
	return true
end

local function onAction(antiCheat: AntiCheatApi, player: Player, reason: string, kind: Types.ActionKind, source: Types.EvidenceSource?): ()
	local evidenceSource: Types.EvidenceSource = normalizeSource(source)
	local uid = player.UserId

	if kind ~= "hard" or not isEnforceableSource(evidenceSource) or not isAntiCheatEnforcing(antiCheat) then
		emit(player, reason, kind, evidenceSource, "observe", false, strikes[uid] or 0)
		return
	end
	-- The player can leave between the flag and this decision: never strike or
	-- ban an obsolete Player instance.
	if not isCurrentPlayer(player) then
		emit(player, reason, kind, evidenceSource, "observe", false, strikes[uid] or 0)
		return
	end
	if BanService.IsEscalationExempt(uid) then
		warn(`[AntiCheatEnforcement] escalation exempt for {player.Name} ({uid}) — would have acted on: {reason}`)
		emit(player, reason, kind, evidenceSource, "exempt", false, strikes[uid] or 0)
		return
	end
	if punished[uid] then
		emit(player, reason, kind, evidenceSource, "deduped", false, strikes[uid] or 0)
		return
	end

	local now = os.clock()
	local perReason = lastAppliedAt[uid]
	if not perReason then
		perReason = {}
		lastAppliedAt[uid] = perReason
	end
	local last = perReason[reason]
	if last and now - last < actionCooldownSeconds() then
		emit(player, reason, kind, evidenceSource, "deduped", false, strikes[uid] or 0)
		return
	end
	perReason[reason] = now

	local policy = AntiCheatConfig.BanPolicy
	local kickAt    : number = policy.KickAt or 1
	local tempBanAt : number = policy.TempBanAt or 2
	local permBanAt : number = policy.PermBanAt or 3
	local tempSecs  : number = policy.TempBanSeconds or 3600

	-- A trap is a useful high-signal tripwire, but not durable-ban proof: its own
	-- counter, outside the server/transport ladder, and it can only ever kick.
	if evidenceSource == "trap" then
		local n = (trapStrikes[uid] or 0) + 1
		trapStrikes[uid] = n
		if n >= kickAt and actionEnabled("Kick") and kick(player, reason) then
			emit(player, reason, kind, evidenceSource, "kick", true, n)
		else
			emit(player, reason, kind, evidenceSource, "observe", false, n)
		end
		return
	end

	local n = (strikes[uid] or 0) + 1
	strikes[uid] = n
	if n >= permBanAt and actionEnabled("PermBan") then
		punished[uid] = true
		BanService.Ban(uid, `Auto: {reason} x{n}`)
		emit(player, reason, kind, evidenceSource, "perm_ban", true, n)
	elseif n >= tempBanAt and actionEnabled("TempBan") then
		punished[uid] = true
		BanService.Ban(uid, `Auto: {reason} x{n}`, tempSecs)
		emit(player, reason, kind, evidenceSource, "temp_ban", true, n)
	elseif n >= kickAt and actionEnabled("Kick") and kick(player, reason) then
		emit(player, reason, kind, evidenceSource, "kick", true, n)
	else
		emit(player, reason, kind, evidenceSource, "observe", false, n)
	end
end

-- ── Public API ──

-- "enforce" while Config.AntiCheat.Enforce (flag "AntiCheat.Enforce") is on,
-- else "observe". The same switch the orchestrator reads.
function Enforcement.GetMode(): "observe" | "enforce"
	return if isEnforcingConfig() then "enforce" else "observe"
end

-- Runtime switch (a Gaxia.Flags override of "AntiCheat.Enforce"; AntiCheat
-- .ClearOverrides reverts it to the Config default).
function Enforcement.SetMode(mode: "observe" | "enforce"): ()
	assert(mode == "observe" or mode == "enforce", "mode must be observe or enforce")
	EConfig.Set("AntiCheat.Enforce", mode == "enforce")
end

-- This server's strike count for a user (server/transport evidence).
function Enforcement.GetStrikes(userId: number): number
	return strikes[userId] or 0
end

-- Forget a user's strikes in this server (the next hard action starts again at
-- KickAt). BanService.ResetStrikes (Unban, /acclear) calls this.
function Enforcement.ResetStrikes(userId: number): ()
	strikes[userId] = nil
	trapStrikes[userId] = nil
end

local function onPlayerRemoving(player: Player): ()
	-- strikes[uid] is kept on purpose (see strikes above).
	local uid = player.UserId
	punished[uid] = nil
	trapStrikes[uid] = nil
	lastAppliedAt[uid] = nil
end

Lifecycle.Define(Enforcement, {
	Name = "Enforcement",
	Needs = { BanService },
	Init = function()
		Players.PlayerRemoving:Connect(onPlayerRemoving)
	end,
	Start = function()
		local AntiCheat: AntiCheatApi? = Lifecycle.Find("AntiCheat")
		if AntiCheat == nil then
			return
		end
		local antiCheat: AntiCheatApi = AntiCheat
		antiCheat.OnAction:Connect(function(player: Player, reason: string, kind: Types.ActionKind, _count: number, source: Types.EvidenceSource)
			onAction(antiCheat, player, reason, kind, source)
		end)
	end,
})

return Enforcement
