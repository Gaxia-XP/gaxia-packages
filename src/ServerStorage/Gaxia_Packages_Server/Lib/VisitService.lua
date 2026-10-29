--!strict
-- ─────────────────────────────────────────────────────────────
-- VisitService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/VisitService
-- Purpose : Read-only base/island visiting. Tracks who is currently viewing
--           whose base and, crucially, exposes CanModify() — the one guard
--           every build/economy action checks so a visitor can never edit the
--           host's (or even their own, while away) base. Visit state is session-
--           only (in-memory); the host's base DATA load is the game's job (its
--           own profile if online, or the 24.7 global-store layer if offline).
--
-- Access  : Gaxia.Visit  (server)
--   Gaxia.Visit.Start(visitor, hostUserId)
--   if not Gaxia.Visit.CanModify(player, baseOwnerUserId) then return end
-- ─────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal    = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)

local VisitService = {}

-- (visitor, hostUserId)
VisitService.OnVisitStart = Signal.new() :: Signal.Signal<Player, number>
-- (visitor, hostUserId)
VisitService.OnVisitEnd = Signal.new() :: Signal.Signal<Player, number>

-- visitorUserId → hostUserId (session-only)
local visits: { [number]: number } = {}

-- ── Public API ──

function VisitService.Start(visitor: Player, hostUserId: number): boolean
	if visitor.UserId == hostUserId then
		return false -- "visiting" your own base is just being home
	end
	visits[visitor.UserId] = hostUserId
	VisitService.OnVisitStart:Fire(visitor, hostUserId)
	return true
end

function VisitService.End(visitor: Player): ()
	local host = visits[visitor.UserId]
	if host == nil then
		return
	end
	visits[visitor.UserId] = nil
	VisitService.OnVisitEnd:Fire(visitor, host)
end

function VisitService.IsVisiting(visitor: Player): boolean
	return visits[visitor.UserId] ~= nil
end

function VisitService.GetHost(visitor: Player): number?
	return visits[visitor.UserId]
end

function VisitService.GetVisitorsOf(hostUserId: number): { number }
	local out: { number } = {}
	for visitorId, h in pairs(visits) do
		if h == hostUserId then
			table.insert(out, visitorId)
		end
	end
	return out
end

-- The universal write-guard: you may only modify your own base, and only while
-- at home (not currently visiting someone else).
function VisitService.CanModify(player: Player, baseOwnerUserId: number): boolean
	if VisitService.IsVisiting(player) then
		return false
	end
	return baseOwnerUserId == player.UserId
end

Lifecycle.Define(VisitService, {
	Name = "Visit",
	Needs = {},
	Init = function()
		-- Forget a leaving player's visit (session-only state).
		Players.PlayerRemoving:Connect(function(player: Player)
			visits[player.UserId] = nil
		end)
	end,
})

return VisitService
