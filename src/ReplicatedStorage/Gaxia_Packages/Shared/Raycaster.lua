--!strict
--[[
	Raycaster.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/Raycaster
	Purpose: Builder-style wrapper around RaycastParams + workspace:Raycast.
	         Lets us chain configuration, then cast from arbitrary origins,
	         the camera, or the local player's mouse.
--]]

-- ── Services ──
local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")
local Workspace  = game:GetService("Workspace")

-- ── Types ──
export type Raycaster = {
	_params: RaycastParams,
	Filter: (self: Raycaster, instances: { Instance }) -> Raycaster,
	FilterType: (self: Raycaster, kind: Enum.RaycastFilterType) -> Raycaster,
	IgnoreWater: (self: Raycaster, value: boolean) -> Raycaster,
	CollisionGroup: (self: Raycaster, name: string) -> Raycaster,
	Cast: (self: Raycaster, origin: Vector3, direction: Vector3) -> RaycastResult?,
	CastFromCamera: (self: Raycaster, distance: number) -> RaycastResult?,
	CastFromMouse: (self: Raycaster, distance: number) -> RaycastResult?,
}

local Raycaster = {}
Raycaster.__index = Raycaster

-- ── Construction ──

function Raycaster.new(): Raycaster
	-- Default to Exclude (the most common case) so users can immediately :Filter().
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = false
	local self = setmetatable({ _params = params }, Raycaster)
	return (self :: any) :: Raycaster
end

-- ── Builder methods (return self for chaining) ──

function Raycaster:Filter(instances: { Instance }): Raycaster
	-- Replace, not append — matches RaycastParams semantics.
	self._params.FilterDescendantsInstances = instances
	return self
end

function Raycaster:FilterType(kind: Enum.RaycastFilterType): Raycaster
	self._params.FilterType = kind
	return self
end

function Raycaster:IgnoreWater(value: boolean): Raycaster
	self._params.IgnoreWater = value
	return self
end

function Raycaster:CollisionGroup(name: string): Raycaster
	self._params.CollisionGroup = name
	return self
end

-- ── Cast methods ──

function Raycaster:Cast(origin: Vector3, direction: Vector3): RaycastResult?
	return Workspace:Raycast(origin, direction, self._params)
end

function Raycaster:CastFromCamera(distance: number): RaycastResult?
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local cf = cam.CFrame
	return Workspace:Raycast(cf.Position, cf.LookVector * distance, self._params)
end

function Raycaster:CastFromMouse(distance: number): RaycastResult?
	-- WHY: server has no mouse — refuse loudly so callers don't silently get nil.
	if RunService:IsServer() then
		warn("Raycaster:CastFromMouse called on server — returning nil")
		return nil
	end
	local lp = Players.LocalPlayer
	if not lp then return nil end
	local mouse = lp:GetMouse()
	local unitRay = mouse.UnitRay
	return Workspace:Raycast(unitRay.Origin, unitRay.Direction * distance, self._params)
end

-- ── Static convenience ──

-- Quick one-off cast with optional Exclude list. Avoids new() boilerplate.
function Raycaster.Quick(origin: Vector3, direction: Vector3, ignoreList: { Instance }?): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	if ignoreList then
		params.FilterDescendantsInstances = ignoreList
	end
	return Workspace:Raycast(origin, direction, params)
end

return Raycaster
