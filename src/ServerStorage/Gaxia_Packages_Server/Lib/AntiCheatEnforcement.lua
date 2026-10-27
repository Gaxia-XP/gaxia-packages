--!strict
--[[
	Module : AntiCheatEnforcement
	Location: ServerStorage.Gaxia_Packages_Server.Lib.AntiCheatEnforcement
	Purpose : The sole owner of automatic AntiCheat actions. Detector evidence
	          and AntiCheat.OnAction candidates are deliberately separate from
	          Kick/Ban decisions so untrusted client telemetry cannot punish a
	          player by itself.

	Bootstrap must call Start(AntiCheat, Ban) once after both services load.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any
local EConfig = require(script.Parent:FindFirstChild("EffectiveConfig") :: ModuleScript) :: any

-- Signal payloads cross module boundaries as dynamic values, so normalize the
-- source at runtime instead of claiming the incoming signal is already a union.
type EvidenceSource = string
type Action = "observe" | "kick" | "temp_ban" | "perm_ban" | "deduped" | "exempt"

type BanAdapter = {
	IsEscalationExempt: (userId: number) -> boolean,
	Ban: (userId: number, reason: string, durationSec: number?) -> boolean,
}

local Enforcement = {}

-- (player, reason, kind, source, action, applied, strikeCount)
Enforcement.OnDecision = Signal.new()

local bound = false
local strikes: { [number]: number } = {}
local trapStrikes: { [number]: number } = {}
local lastAppliedAt: { [number]: { [string]: number } } = {}

local function enforcementConfig(): { [string]: any }
	local config = ((Config.AntiCheat or {}).Enforcement or {}) :: any
	return config
end

local function mode(): string
	local value = EConfig.Get("AntiCheat.Enforcement.Mode", enforcementConfig().Mode or "observe")
	return if value == "enforce" then "enforce" else "observe"
end

local function actionEnabled(name: string): boolean
	local actions = enforcementConfig().Actions or {}
	return EConfig.Enabled(`AntiCheat.Enforcement.Actions.{name}`, actions[name] == true)
end

local function actionCooldownSeconds(): number
	local value = tonumber(
		EConfig.Get(
			"AntiCheat.Enforcement.ActionCooldownSeconds",
			enforcementConfig().ActionCooldownSeconds or 60
		)
	)
	if value == nil or value ~= value or value < 0 then
		return 60
	end
	return value
end

local function isEnforceableSource(source: any): boolean
	return source == "server" or source == "transport" or source == "trap"
end

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
	return "unknown"
end

local function isAntiCheatEnabled(antiCheat: any): boolean
	-- OnAction handlers run asynchronously. Re-read the master switch at the
	-- decision boundary so `/ac off` also cancels a candidate already queued by
	-- Signal before it can kick or ban anyone. A broken/missing probe fails
	-- closed: observe rather than act.
	if not antiCheat or typeof(antiCheat.IsEnabled) ~= "function" then
		return false
	end
	local ok, enabled = pcall(antiCheat.IsEnabled)
	return ok and enabled == true
end

local function isCurrentPlayer(player: Player): boolean
	return player.Parent == Players and Players:GetPlayerByUserId(player.UserId) == player
end

local function emitDecision(
	player: Player,
	reason: string,
	kind: string,
	source: EvidenceSource,
	action: Action,
	applied: boolean,
	strikeCount: number
): ()
	Enforcement.OnDecision:Fire(player, reason, kind, source, action, applied, strikeCount)
end

local function onAction(
	antiCheat: any,
	ban: BanAdapter,
	player: Player,
	reason: string,
	kind: string,
	_count: number?,
	source: EvidenceSource?
): ()
	local evidenceSource = normalizeSource(source)
	if not isAntiCheatEnabled(antiCheat) then
		emitDecision(player, reason, kind, evidenceSource, "observe", false, 0)
		return
	end
	if kind ~= "hard" or not isEnforceableSource(evidenceSource) then
		emitDecision(player, reason, kind, evidenceSource, "observe", false, 0)
		return
	end

	if mode() ~= "enforce" then
		emitDecision(player, reason, kind, evidenceSource, "observe", false, 0)
		return
	end

	-- OnAction is dispatched asynchronously. A player can leave between the
	-- flag and this decision, so do not create a strike or durable ban for an
	-- obsolete Player instance.
	if not isCurrentPlayer(player) then
		emitDecision(player, reason, kind, evidenceSource, "observe", false, 0)
		return
	end

	if ban.IsEscalationExempt(player.UserId) then
		warn(
			`[AntiCheatEnforcement] exempt {player.Name} ({player.UserId}) — would act on {reason}`
		)
		emitDecision(player, reason, kind, evidenceSource, "exempt", false, 0)
		return
	end

	local now = os.clock()
	local existingPerReason = lastAppliedAt[player.UserId]
	if
		existingPerReason
		and existingPerReason[reason]
		and now - existingPerReason[reason] < actionCooldownSeconds()
	then
		emitDecision(
			player,
			reason,
			kind,
			evidenceSource,
			"deduped",
			false,
			strikes[player.UserId] or 0
		)
		return
	end

	local perReason: { [string]: number }
	if existingPerReason then
		perReason = existingPerReason
	else
		perReason = {}
	end
	lastAppliedAt[player.UserId] = perReason
	perReason[reason] = now
	-- Recheck at the actual action boundary as role/leave events can occur
	-- between the asynchronous candidate and this policy evaluation.
	if not isCurrentPlayer(player) then
		emitDecision(player, reason, kind, evidenceSource, "observe", false, 0)
		return
	end

	-- A trap is a useful high-signal tripwire, but it is not durable-ban proof.
	-- Keep its decision count out of the server/transport escalation ladder so
	-- trap-only activity can never cause a temp or permanent ban.
	if evidenceSource == "trap" then
		trapStrikes[player.UserId] = (trapStrikes[player.UserId] or 0) + 1
		local trapStrikeCount = trapStrikes[player.UserId]
		local policy = ((Config.AntiCheat or {}).BanPolicy or {}) :: any
		local kickAt = tonumber(policy.KickAt) or 1
		if trapStrikeCount >= kickAt and actionEnabled("Kick") and player.Parent then
			player:Kick(`[AntiCheat] {reason}`)
			emitDecision(player, reason, kind, evidenceSource, "kick", true, trapStrikeCount)
		else
			emitDecision(player, reason, kind, evidenceSource, "observe", false, trapStrikeCount)
		end
		return
	end

	strikes[player.UserId] = (strikes[player.UserId] or 0) + 1
	local strikeCount = strikes[player.UserId]

	local policy = ((Config.AntiCheat or {}).BanPolicy or {}) :: any
	local kickAt = tonumber(policy.KickAt) or 1
	local tempBanAt = tonumber(policy.TempBanAt) or math.huge
	local permBanAt = tonumber(policy.PermBanAt) or math.huge
	local tempBanSeconds = tonumber(policy.TempBanSeconds) or 3600

	if strikeCount >= permBanAt and actionEnabled("PermBan") then
		ban.Ban(player.UserId, `Auto: {reason} x{strikeCount}`)
		emitDecision(player, reason, kind, evidenceSource, "perm_ban", true, strikeCount)
	elseif strikeCount >= tempBanAt and actionEnabled("TempBan") then
		ban.Ban(player.UserId, `Auto: {reason} x{strikeCount}`, tempBanSeconds)
		emitDecision(player, reason, kind, evidenceSource, "temp_ban", true, strikeCount)
	elseif strikeCount >= kickAt and actionEnabled("Kick") then
		if player.Parent then
			player:Kick(`[AntiCheat] {reason}`)
			emitDecision(player, reason, kind, evidenceSource, "kick", true, strikeCount)
		else
			emitDecision(player, reason, kind, evidenceSource, "observe", false, strikeCount)
		end
	else
		emitDecision(player, reason, kind, evidenceSource, "observe", false, strikeCount)
	end
end

function Enforcement.GetMode(): string
	return mode()
end

function Enforcement.SetMode(nextMode: string): ()
	assert(nextMode == "observe" or nextMode == "enforce", "mode must be observe or enforce")
	EConfig.Set("AntiCheat.Enforcement.Mode", nextMode)
end

function Enforcement.Start(antiCheat: any, ban: BanAdapter): ()
	if bound then
		return
	end
	assert(
		antiCheat and antiCheat.OnAction and antiCheat.IsEnabled,
		"AntiCheatEnforcement.Start requires AntiCheat.OnAction and AntiCheat.IsEnabled"
	)
	assert(
		ban and ban.IsEscalationExempt and ban.Ban,
		"AntiCheatEnforcement.Start requires BanService"
	)
	bound = true

	antiCheat.OnAction:Connect(
		function(
			player: Player,
			reason: string,
			kind: string,
			count: number?,
			source: EvidenceSource?
		)
			onAction(antiCheat, ban, player, reason, kind, count, source)
		end
	)

	Players.PlayerRemoving:Connect(function(player)
		strikes[player.UserId] = nil
		trapStrikes[player.UserId] = nil
		lastAppliedAt[player.UserId] = nil
	end)
end

return Enforcement
