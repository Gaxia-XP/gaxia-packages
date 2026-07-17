--!strict
-- ─────────────────────────────────────────────────────────────
-- PlacementService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/PlacementService
-- Purpose : Grid-based building placement for tycoons / base-builders / farms.
--           Server-authoritative: a player gets a plot (grid of cells); objects
--           have footprints; Place() validates in-bounds + no overlap before
--           recording, so clients can't stack or place outside their land.
--           Placements persist under "Placements" and Rebuild() replays them
--           through OnPlace on join — the framework owns the DATA, the game owns
--           spawning the model (connect OnPlace/OnRemove). SnapToGrid/WorldToCell
--           are pure helpers for the client preview.
--
-- Access  : Gaxia.Placement  (server)
--   Gaxia.Placement.AssignPlot(player, { Origin = v3, Cells = Vector2.new(8,8), CellSize = 4 })
--   Gaxia.Placement.DefineObject("House", { Footprint = Vector2.new(2,2) })
--   local id, err = Gaxia.Placement.Place(player, "House", 0, 0)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end

local PLACEMENTS_KEY : string = "Placements"

export type Plot = { Origin: Vector3, Cells: Vector2, CellSize: number }
export type ObjectDef = { Footprint: Vector2 }
export type Placement = { id: string, objectId: string, gx: number, gz: number, rot: number }

local PlacementService = {}

PlacementService.OnPlace = Signal.new()  -- (player, placement)
PlacementService.OnRemove = Signal.new() -- (player, placement)

local plots: { [Player]: Plot } = {}
local objects: { [string]: ObjectDef } = {}

-- ── Pure helpers (no player / data — unit-testable) ──

-- Snap a world position to its grid-cell origin.
function PlacementService.SnapToGrid(worldPos: Vector3, cellSize: number, origin: Vector3?): Vector3
	local o = origin or Vector3.zero
	local gx = math.floor((worldPos.X - o.X) / cellSize)
	local gz = math.floor((worldPos.Z - o.Z) / cellSize)
	return Vector3.new(o.X + gx * cellSize, worldPos.Y, o.Z + gz * cellSize)
end

-- World position → integer cell coords.
function PlacementService.WorldToCell(plot: Plot, worldPos: Vector3): (number, number)
	return math.floor((worldPos.X - plot.Origin.X) / plot.CellSize),
		math.floor((worldPos.Z - plot.Origin.Z) / plot.CellSize)
end

-- Cell coords → world position at the CENTRE of the footprint.
function PlacementService.CellToWorld(plot: Plot, gx: number, gz: number, footprint: Vector2?): Vector3
	local f = footprint or Vector2.new(1, 1)
	return Vector3.new(
		plot.Origin.X + (gx + f.X / 2) * plot.CellSize,
		plot.Origin.Y,
		plot.Origin.Z + (gz + f.Y / 2) * plot.CellSize
	)
end

-- Footprint accounting for 90°/270° rotation (width/depth swap).
local function effectiveFootprint(objectId: string, rot: number): (number, number)
	local def = objects[objectId]
	local f = def and def.Footprint or Vector2.new(1, 1)
	if rot == 90 or rot == 270 then
		return f.Y, f.X
	end
	return f.X, f.Y
end

local function inBounds(plot: Plot, gx: number, gz: number, fw: number, fd: number): boolean
	return gx >= 0 and gz >= 0 and gx + fw <= plot.Cells.X and gz + fd <= plot.Cells.Y
end

local function footprintCells(gx: number, gz: number, fw: number, fd: number): { string }
	local cells: { string } = {}
	for x = gx, gx + fw - 1 do
		for z = gz, gz + fd - 1 do
			table.insert(cells, `{x},{z}`)
		end
	end
	return cells
end

-- ── Registration ──

function PlacementService.AssignPlot(player: Player, plot: Plot): ()
	plots[player] = plot
end

function PlacementService.GetPlot(player: Player): Plot?
	return plots[player]
end

function PlacementService.DefineObject(objectId: string, def: ObjectDef): ()
	objects[objectId] = def
end

-- ── Persistence ──

local function loadPlacements(player: Player): { [string]: any }
	local p = server().Data.Get(player, PLACEMENTS_KEY)
	return (typeof(p) == "table") and p or {}
end

local function savePlacements(player: Player, p: { [string]: any }): ()
	server().Data.Set(player, PLACEMENTS_KEY, p)
end

local function occupancyOf(placements: { [string]: any }): { [string]: boolean }
	local occ: { [string]: boolean } = {}
	for id, pl in pairs(placements) do
		if id ~= "__seq" and typeof(pl) == "table" then
			local fw, fd = effectiveFootprint(pl.objectId, pl.rot or 0)
			for _, cell in ipairs(footprintCells(pl.gx, pl.gz, fw, fd)) do
				occ[cell] = true
			end
		end
	end
	return occ
end

-- ── Public placement API ──

function PlacementService.CanPlace(player: Player, objectId: string, gx: number, gz: number, rot: number?): (boolean, string)
	local plot = plots[player]
	if not plot then
		return false, "no plot assigned"
	end
	local r = rot or 0
	local fw, fd = effectiveFootprint(objectId, r)
	if not inBounds(plot, gx, gz, fw, fd) then
		return false, "out of bounds"
	end
	local occ = occupancyOf(loadPlacements(player))
	for _, cell in ipairs(footprintCells(gx, gz, fw, fd)) do
		if occ[cell] then
			return false, "overlap"
		end
	end
	return true, "ok"
end

function PlacementService.Place(player: Player, objectId: string, gx: number, gz: number, rot: number?): (string?, string?)
	local ok, err = PlacementService.CanPlace(player, objectId, gx, gz, rot)
	if not ok then
		return nil, err
	end
	local placements = loadPlacements(player)
	local seq = (tonumber(placements.__seq) or 0) + 1
	placements.__seq = seq
	local id = `p_{seq}`
	local placement: Placement = { id = id, objectId = objectId, gx = gx, gz = gz, rot = rot or 0 }
	placements[id] = { objectId = objectId, gx = gx, gz = gz, rot = rot or 0 }
	savePlacements(player, placements)
	PlacementService.OnPlace:Fire(player, placement)
	return id, nil
end

function PlacementService.Remove(player: Player, placementId: string): boolean
	local placements = loadPlacements(player)
	local pl = placements[placementId]
	if typeof(pl) ~= "table" then
		return false
	end
	placements[placementId] = nil
	savePlacements(player, placements)
	PlacementService.OnRemove:Fire(player, {
		id = placementId, objectId = pl.objectId, gx = pl.gx, gz = pl.gz, rot = pl.rot or 0,
	})
	return true
end

function PlacementService.GetPlacements(player: Player): { Placement }
	local out: { Placement } = {}
	for id, pl in pairs(loadPlacements(player)) do
		if id ~= "__seq" and typeof(pl) == "table" then
			table.insert(out, { id = id, objectId = pl.objectId, gx = pl.gx, gz = pl.gz, rot = pl.rot or 0 })
		end
	end
	return out
end

-- Replay every saved placement through OnPlace (call on join after data loads;
-- the same OnPlace handler that spawns live placements rebuilds the base).
function PlacementService.Rebuild(player: Player): number
	local list = PlacementService.GetPlacements(player)
	for _, placement in ipairs(list) do
		PlacementService.OnPlace:Fire(player, placement)
	end
	return #list
end

Players.PlayerRemoving:Connect(function(player: Player)
	plots[player] = nil
end)

return PlacementService
