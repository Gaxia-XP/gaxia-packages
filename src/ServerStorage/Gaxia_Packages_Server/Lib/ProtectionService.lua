--!strict
-- ─────────────────────────────────────────────────────────────
-- ProtectionService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/ProtectionService
-- Purpose : Time-boxed immunity / shields — the "you can't be raided right now"
--           primitive. Granted after being raided (revenge grace), on a newbie
--           shield, or from a purchased shield item. The protectedUntil stamp is
--           an os.time() value in the profile, so it survives rejoins and is
--           checked the same online or offline. RaidService consults this before
--           allowing a hit; games can also gate any PvP action on it.
--
-- Access  : Gaxia.Protection  (server)
--   Gaxia.Protection.Grant(player, 600)        -- 10-minute shield
--   if Gaxia.Protection.IsProtected(target) then return "shielded" end
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared      = ReplicatedStorage.Gaxia_Packages.Shared
local Signal      = require(Shared.Signal)
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local DataManager = require(script.Parent.DataManager)

local PROTECT_KEY : string = "ProtectedUntil"

local ProtectionService = {}

-- (player, untilTimestamp, duration) after Grant
ProtectionService.OnProtected = Signal.new() :: Signal.Signal<Player, number, number>
-- (player) when Clear removes a shield that was still active (not on natural expiry)
ProtectionService.OnExpired = Signal.new() :: Signal.Signal<Player>

-- 0 when the profile is not loaded (or Data is not running).
local function readUntil(player: Player): number
	local v = DataManager.Get(player, PROTECT_KEY)
	return (typeof(v) == "number") and v or 0
end

-- ── Public API ──

function ProtectionService.Grant(player: Player, duration: number): number
	local untilTs = os.time() + math.max(0, math.floor(duration))
	-- Not persisted (Set returns false) while the profile is not loaded; the shield
	-- stamp is still returned and announced, as before.
	DataManager.Set(player, PROTECT_KEY, untilTs)
	ProtectionService.OnProtected:Fire(player, untilTs, duration)
	return untilTs
end

function ProtectionService.IsProtected(player: Player): boolean
	return os.time() < readUntil(player)
end

function ProtectionService.GetRemaining(player: Player): number
	return math.max(0, readUntil(player) - os.time())
end

function ProtectionService.Clear(player: Player): ()
	local was = ProtectionService.IsProtected(player)
	DataManager.Set(player, PROTECT_KEY, 0)
	if was then
		ProtectionService.OnExpired:Fire(player)
	end
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(ProtectionService, {
	Name = "Protection",
	Needs = {},
})

return ProtectionService
