--!strict
--[[
	Module : PlayerService
	Location: ServerStorage.Gaxia_Packages_Server.Lib.PlayerService
	Purpose : Server-side player lifecycle helpers — joined/left signals,
	          leaderstats CRUD, humanoid property setters, teleport.
]]


-- ── Services ──
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared     = ReplicatedStorage.Gaxia_Packages.Shared
local Signal     = require(Shared.Signal)
local Constants  = require(Shared.Constants)
local PlayerUtil = require(Shared.Util.Player)
local Lifecycle  = require(script.Parent.ServiceLifecycle)
local Config     = require(script.Parent.Parent.Config)
local EConfig    = require(script.Parent.EffectiveConfig)
-- The AntiCheat orchestrator, for the Teleport whitelist only (called at call
-- time). Not a Need: teleporting a player must never start AntiCheat.
local AntiCheat  = require(script.Parent.Parent.AntiCheat)

-- ── Constants ──
local LEADERSTATS_NAME : string = "leaderstats"
-- Set to the value about to be written so AntiCheat's StatGuard sees our own
-- writes as legitimate (it flags any leaderstats change that skips this).
local STAT_EXPECTED_ATTRIBUTE : string = Constants.STAT_EXPECTED_ATTRIBUTE

local function writeStat(stat: Instance, value: any): ()
	if typeof(value) == "number" then
		stat:SetAttribute(STAT_EXPECTED_ATTRIBUTE, value)
	end
	(stat :: any).Value = value
end

-- ── Module ──
local PlayerService = {}

-- ── Signals ──
-- (player) when a player joins (or is already in the game when the service starts),
-- before their character spawns
PlayerService.OnPlayerJoined   = Signal.new() :: Signal.Signal<Player>
-- (player) when a player is leaving the game
PlayerService.OnPlayerLeft     = Signal.new() :: Signal.Signal<Player>
-- (player, character) every time a player's character spawns
PlayerService.OnCharacterAdded = Signal.new() :: Signal.Signal<Player, Model>

-- ── Leaderstats ──

-- Pick the right ValueObject class for the given Lua value.
-- Numbers use IntValue when whole, NumberValue when fractional, etc.
local function classForValue(value: any): string
	local t = typeof(value)
	if t == "number" then
		return (value % 1 == 0) and "IntValue" or "NumberValue"
	elseif t == "string" then
		return "StringValue"
	elseif t == "boolean" then
		return "BoolValue"
	end
	return "StringValue"
end

-- The player's leaderstats Folder, created (and parented) when missing.
local function getOrCreateLeaderstats(player: Player): Instance
	local existing = player:FindFirstChild(LEADERSTATS_NAME)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = LEADERSTATS_NAME
	folder.Parent = player
	return folder
end

-- Create a leaderstats Folder (if missing) and populate with one ValueObject per dict entry.
-- Existing entries are overwritten (Value updated) so this can be called repeatedly.
function PlayerService.SetupLeaderstats(player: Player, dict: { [string]: any }): ()
	local folder = getOrCreateLeaderstats(player)
	for name, value in pairs(dict) do
		local existing = folder:FindFirstChild(name)
		if existing then
			writeStat(existing, value)
		else
			local cls = classForValue(value)
			local v = Instance.new(cls)
			v.Name = name
			;(v :: any).Value = value
			v.Parent = folder
		end
	end
end

function PlayerService.GetLeaderstat(player: Player, name: string): any
	local folder = player:FindFirstChild(LEADERSTATS_NAME)
	if not folder then return nil end
	local stat = folder:FindFirstChild(name)
	return stat and (stat :: any).Value or nil
end

function PlayerService.SetLeaderstat(player: Player, name: string, value: any): ()
	local folder = player:FindFirstChild(LEADERSTATS_NAME)
	if not folder then return end
	local stat = folder:FindFirstChild(name)
	if stat then
		writeStat(stat, value)
	end
end

-- ── Character helpers (proxy to Util.Player) ──

-- Effective max (runtime flag "Player.MaxWalkSpeed" <- Config.Player.MaxWalkSpeed),
-- read at call-time.
local DEFAULT_MAX_WALK_SPEED: number = 500
local function maxWalkSpeed(): number
	local section = Config.Player
	local static: number = if section then section.MaxWalkSpeed or DEFAULT_MAX_WALK_SPEED else DEFAULT_MAX_WALK_SPEED
	return tonumber(EConfig.Get("Player.MaxWalkSpeed", static)) or static
end

-- Returns (applied, actualSpeed). Clamps to [0, Player.MaxWalkSpeed] as
-- defense-in-depth for every caller: a NEGATIVE WalkSpeed still moves the
-- character (in reverse, at |speed|) while SpeedDetector's baseline floors at
-- max(WalkSpeed, 8) — so the player reads as a speeder and gets flagged once
-- any admin whitelist window expires.
function PlayerService.SetWalkSpeed(player: Player, speed: number): (boolean, number?)
	local n = tonumber(speed)
	if n == nil or n ~= n then return false end
	n = math.clamp(n, 0, maxWalkSpeed())
	local hum = PlayerUtil.GetHumanoid(player)
	if not hum then return false end
	hum.WalkSpeed = n
	return true, n
end

function PlayerService.SetJumpPower(player: Player, power: number): ()
	local hum = PlayerUtil.GetHumanoid(player)
	if hum then
		hum.UseJumpPower = true
		hum.JumpPower = power
	end
end

-- Authorised teleport. Whitelists the player against TeleportDetector for a
-- short window so the position-delta sample after this CFrame change does
-- not raise a false-positive flag. 2 seconds comfortably covers one or two
-- sampler ticks (SAMPLER_INTERVAL = 0.5s) plus replication lag. The whitelist
-- call is safe whether or not AntiCheat is running (it never starts it).
function PlayerService.Teleport(player: Player, cframe: CFrame): ()
	local grace = Config.AntiCheat.Teleport.WhitelistGraceSeconds or 2
	AntiCheat.Whitelist(player, "Teleport", EConfig.Get("AntiCheat.Teleport.WhitelistGraceSeconds", grace))
	PlayerUtil.Teleport(player, cframe)
end

-- ── Iteration ──

function PlayerService.ForEach(fn: (player: Player) -> ()): ()
	for _, p in ipairs(Players:GetPlayers()) do
		fn(p)
	end
end

-- ── Lifecycle wiring ──

local function hookCharacter(player: Player, character: Model)
	PlayerService.OnCharacterAdded:Fire(player, character)
end

local function onPlayerAdded(player: Player)
	-- Fire join signal first so listeners can run setup BEFORE character spawns.
	PlayerService.OnPlayerJoined:Fire(player)
	-- If the character already exists (rare race), still fire CharacterAdded once.
	if player.Character then
		task.spawn(hookCharacter, player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		hookCharacter(player, character)
	end)
end

local function onPlayerRemoving(player: Player)
	PlayerService.OnPlayerLeft:Fire(player)
end

Lifecycle.Define(PlayerService, {
	Name = "Player",
	Needs = {},
	Init = function()
		-- Cover current + future players (players may already be in the game when
		-- the service starts).
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(onPlayerAdded, player)
		end
		Players.PlayerAdded:Connect(onPlayerAdded)
		Players.PlayerRemoving:Connect(onPlayerRemoving)
	end,
})

return PlayerService
