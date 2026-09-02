--!strict
--[[
	Module : ZoneService
	Location: ServerStorage.Gaxia_Packages_Server.Lib.ZoneService
	Purpose : Preserve Gaxia's zone API while delegating spatial detection to
	          the open-source ZonePlus package.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedRoot = ReplicatedStorage:WaitForChild("Gaxia_Packages")
local SharedPkg = require(SharedRoot) :: any
local ZonePlus = require(SharedRoot:WaitForChild("Packages"):WaitForChild("ZonePlus")) :: any
local Signal = SharedPkg.Signal
local Janitor = SharedPkg.Janitor

export type Zone = {
	Name: string,
	Region: BasePart,
	OnEntered: any,
	OnLeft: any,
	IsInside: (self: Zone, player: Player) -> boolean,
	GetPlayers: (self: Zone) -> { Player },
	Destroy: (self: Zone) -> (),
}

local ZoneService = {}
local zonesByName: { [string]: Zone } = {}

local Zone = {}
Zone.__index = Zone

local function newZone(name: string, region: BasePart): Zone
	local zonePlus = ZonePlus.new(region)
	local self = setmetatable({
		Name = name,
		Region = region,
		OnEntered = Signal.new(),
		OnLeft = Signal.new(),
		_inside = {} :: { [Player]: boolean },
		_janitor = Janitor.new(),
		_zonePlus = zonePlus,
	}, Zone)

	local s = self :: any
	s._janitor:Add(zonePlus.playerEntered:Connect(function(player: Player)
		if not s._inside[player] then
			s._inside[player] = true
			s.OnEntered:Fire(player)
		end
	end))
	s._janitor:Add(zonePlus.playerExited:Connect(function(player: Player)
		if s._inside[player] then
			s._inside[player] = nil
			s.OnLeft:Fire(player)
		end
	end))
	s._janitor:Add(Players.PlayerRemoving:Connect(function(player: Player)
		if s._inside[player] then
			s._inside[player] = nil
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
	if not s._zonePlus then
		return
	end
	s._janitor:Cleanup()
	s._zonePlus:destroy()
	s._zonePlus = nil
	s.Region = nil
	s.OnEntered:DisconnectAll()
	s.OnLeft:DisconnectAll()
	table.clear(s._inside)
	if zonesByName[s.Name] == self then
		zonesByName[s.Name] = nil
	end
end

function ZoneService.Create(name: string, region: BasePart): Zone
	assert(typeof(name) == "string" and #name > 0, "name must be non-empty string")
	assert(typeof(region) == "Instance" and region:IsA("BasePart"), "region must be a BasePart")
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
	local zone = zonesByName[name]
	if zone then
		zone:Destroy()
	end
end

return ZoneService
