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
local ServerStorage     = game:GetService("ServerStorage")

-- ── Shared ──
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal    = SharedPkg.Signal
local Util      = SharedPkg.Util

-- ── Lazy server (Config + EConfig) — resolved at CALL-TIME, never module load ──
local _server: any = nil
local function server(): any
	if not _server then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		_server = require(serverInit :: any)
	end
	return _server
end

-- ── Constants ──
local LEADERSTATS_NAME : string = "leaderstats"
-- Set to the value about to be written so AntiCheat's StatGuard sees our own
-- writes as legitimate (it flags any leaderstats change that skips this).
local STAT_EXPECTED_ATTRIBUTE : string = SharedPkg.Constants.STAT_EXPECTED_ATTRIBUTE

local function writeStat(stat: Instance, value: any): ()
	if typeof(value) == "number" then
		stat:SetAttribute(STAT_EXPECTED_ATTRIBUTE, value)
	end
	(stat :: any).Value = value
end

-- ── Module ──
local PlayerService = {}

-- ── Signals ──
PlayerService.OnPlayerJoined   = Signal.new()
PlayerService.OnPlayerLeft     = Signal.new()
PlayerService.OnCharacterAdded = Signal.new()

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

-- Create a leaderstats Folder (if missing) and populate with one ValueObject per dict entry.
-- Existing entries are overwritten (Value updated) so this can be called repeatedly.
function PlayerService.SetupLeaderstats(player: Player, dict: { [string]: any }): ()
	local folder = player:FindFirstChild(LEADERSTATS_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = LEADERSTATS_NAME
		folder.Parent = player
	end
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

-- Effective max (Config default <- runtime override), read at call-time.
local DEFAULT_MAX_WALK_SPEED: number = 500
local function maxWalkSpeed(): number
	local s = server()
	return tonumber(s.EConfig.Get(
		"Player.MaxWalkSpeed",
		(s.Config.Player or {}).MaxWalkSpeed or DEFAULT_MAX_WALK_SPEED
	)) or DEFAULT_MAX_WALK_SPEED
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
	local hum = Util.Player.GetHumanoid(player)
	if not hum then return false end
	hum.WalkSpeed = n
	return true, n
end

function PlayerService.SetJumpPower(player: Player, power: number): ()
	local hum = Util.Player.GetHumanoid(player)
	if hum then
		hum.UseJumpPower = true
		hum.JumpPower = power
	end
end

-- Cached lazy reference to the AntiCheat orchestrator. We resolve by direct
-- path (NOT via GaxiaServer) so that requiring this module from inside
-- GaxiaServer's __index doesn't form a recursion cycle.
local _antiCheatRef: any = nil
local function getAntiCheat(): any
	if _antiCheatRef ~= nil then return _antiCheatRef end
	local serverPkg = script.Parent.Parent  -- Lib → Gaxia_Packages_Server
	local acFolder = serverPkg:FindFirstChild("AntiCheat")
	local acInit = acFolder and acFolder
	if acInit and acInit:IsA("ModuleScript") then
		local ok, mod = pcall(require, acInit)
		if ok then _antiCheatRef = mod end
	end
	return _antiCheatRef
end

-- Authorised teleport. Whitelists the player against TeleportDetector for a
-- short window so the position-delta sample after this CFrame change does
-- not raise a false-positive flag. 2 seconds comfortably covers one or two
-- sampler ticks (SAMPLER_INTERVAL = 0.5s) plus replication lag.
function PlayerService.Teleport(player: Player, cframe: CFrame): ()
	local ac = getAntiCheat()
	if ac then
		local s = server()
		local grace = ((s.Config.AntiCheat or {}).Teleport or {}).WhitelistGraceSeconds or 2
		ac.Whitelist(player, "Teleport", s.EConfig.Get("AntiCheat.Teleport.WhitelistGraceSeconds", grace))
	end
	Util.Player.Teleport(player, cframe)
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

-- Cover current + future players to avoid race between module load and join.
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

return PlayerService
