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
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

local GaxiaServer: any = nil
local function getData(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer.Data
end

local PROTECT_KEY : string = "ProtectedUntil"

local ProtectionService = {}

ProtectionService.OnProtected = Signal.new() -- (player, untilTimestamp, duration)
ProtectionService.OnExpired = Signal.new()   -- (player)  (fired lazily on a checked read)

local function readUntil(player: Player): number
	local Data = getData()
	if not Data then
		return 0
	end
	local v = Data.Get(player, PROTECT_KEY)
	return (typeof(v) == "number") and v or 0
end

-- ── Public API ──

function ProtectionService.Grant(player: Player, duration: number): number
	local untilTs = os.time() + math.max(0, math.floor(duration))
	local Data = getData()
	if Data then
		Data.Set(player, PROTECT_KEY, untilTs)
	end
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
	local Data = getData()
	if Data then
		Data.Set(player, PROTECT_KEY, 0)
	end
	if was then
		ProtectionService.OnExpired:Fire(player)
	end
end

return ProtectionService
