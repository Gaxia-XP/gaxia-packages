--!strict
--[[
	Module : ZoneService
	Location: ServerStorage.Gaxia_Packages_Server.Lib.ZoneService
	Purpose : Trigger zones. Wraps a BasePart region with Enter/Left signals
	          via OBB containment sampled at Constants.SAMPLER_INTERVAL (0.5s).
]]


-- ── Services ──
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

-- ── Shared ──
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal    = SharedPkg.Signal
local Trove     = SharedPkg.Trove

-- Constants is a frozen table; fall back to defaults if missing.
local Constants = SharedPkg.Constants or {}
local SAMPLER_INTERVAL : number = (Constants.SAMPLER_INTERVAL :: any) or 0.5

-- ── Types ──
export type Zone = {
	Name: string,
	Region: BasePart,
	OnEntered: any,
	OnLeft: any,
	IsInside: (self: Zone, player: Player) -> boolean,
	GetPlayers: (self: Zone) -> { Player },
	Destroy: (self: Zone) -> (),
}

-- ── Module ──
local ZoneService = {}

local zonesByName: { [string]: Zone } = {}

-- ── OBB containment helper ──
-- Returns true if world-space `pos` is inside the BasePart's local box.
-- Uses :PointToObjectSpace to handle rotated parts without manual matrix math.
local function pointInRegion(region: BasePart, pos: Vector3): boolean
	local local_ = region.CFrame:PointToObjectSpace(pos)
	local hx = region.Size.X * 0.5
	local hy = region.Size.Y * 0.5
	local hz = region.Size.Z * 0.5
	return math.abs(local_.X) <= hx
		and math.abs(local_.Y) <= hy
		and math.abs(local_.Z) <= hz
end

-- ── Zone factory ──

local Zone = {}
Zone.__index = Zone

local function newZone(name: string, region: BasePart): Zone
	local self = setmetatable({
		Name      = name,
		Region    = region,
		OnEntered = Signal.new(),
		OnLeft    = Signal.new(),
		_inside   = {} :: { [Player]: boolean },
		_trove    = Trove.new(),
	}, Zone)

	-- Heartbeat-style polling. Sampling instead of Touched events because
	-- Touched fires *many* times per frame and is unreliable for players
	-- standing still on a thin trigger.
	local s = self :: any
	task.spawn(function()
		while s.Region and s.Region.Parent do
			for _, player in ipairs(Players:GetPlayers()) do
				local char = player.Character
				local hrp = char and (char :: any):FindFirstChild("HumanoidRootPart")
				if hrp then
					local nowInside = pointInRegion(s.Region, hrp.Position)
					local wasInside = s._inside[player] == true
					if nowInside and not wasInside then
						s._inside[player] = true
						s.OnEntered:Fire(player)
					elseif (not nowInside) and wasInside then
						s._inside[player] = nil
						s.OnLeft:Fire(player)
					end
				elseif s._inside[player] then
					-- Character lost (death / leave) — emit Left so listener cleans up.
					s._inside[player] = nil
					s.OnLeft:Fire(player)
				end
			end
			task.wait(SAMPLER_INTERVAL)
		end
	end)

	-- Fire OnLeft when a tracked player leaves the game so external state stays consistent.
	s._trove:Add(Players.PlayerRemoving:Connect(function(player)
		if s._inside[player] then
			s._inside[player] = nil
			-- Emit Left when a tracked player disconnects so listeners
			-- (e.g. cleanup of per-player zone state) get a final signal.
			s.OnLeft:Fire(player)
		end
	end))

	return self :: any
end

function Zone:IsInside(player: Player): boolean
	local s = self :: any
	return s._inside[player] == true
end

function Zone:GetPlayers(): { Player }
	local s = self :: any
	local out: { Player } = {}
	for player in pairs(s._inside) do
		table.insert(out, player)
	end
	return out
end

function Zone:Destroy(): ()
	local s = self :: any
	s._trove:Clean()
	-- Drop the BasePart reference so the sampler loop exits naturally.
	s.Region = nil
	s.OnEntered:DisconnectAll()
	s.OnLeft:DisconnectAll()
	table.clear(s._inside)
	if zonesByName[s.Name] == self then
		zonesByName[s.Name] = nil
	end
end

-- ── Public API ──

function ZoneService.Create(name: string, region: BasePart): Zone
	assert(typeof(name) == "string" and #name > 0, "name must be non-empty string")
	assert(typeof(region) == "Instance" and region:IsA("BasePart"), "region must be a BasePart")
	-- Replace an existing zone of the same name to avoid two samplers racing.
	if zonesByName[name] then
		zonesByName[name]:Destroy()
	end
	local zone = newZone(name, region)
	zonesByName[name] = zone
	return zone
end

function ZoneService.Get(name: string): Zone?
	return zonesByName[name]
end

function ZoneService.Destroy(name: string): ()
	local z = zonesByName[name]
	if z then z:Destroy() end
end

return ZoneService
