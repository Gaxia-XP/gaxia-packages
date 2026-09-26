--!strict
-- ============================================================
-- init (ModuleScript)
-- Location : ServerStorage/Gaxia_Packages_Server
-- Purpose  : Master lazy-loading loader for server-side Gaxia
--            packages. Exposes Lib/ services and AntiCheat/
--            namespace, and re-exports ReplicatedStorage.
--            Gaxia_Packages as .Shared for cross-context access.
-- ============================================================

-- ── Services ─────────────────────────────────────────────────

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

-- ── Type definitions (for IDE auto-complete) ─────────────────
--
-- Same pattern as the shared init: `typeof(require(...))` is type-only,
-- runtime cost is zero, but Studio Script Editor & Luau LSP can now offer
-- full IntelliSense for every server service + AntiCheat detector.
--
-- Consumer usage:
--     local GaxiaServer = require(ServerStorage.Gaxia_Packages_Server)
--     GaxiaServer.Data.Get(player, "Coins")  -- ← autocompletes
--     GaxiaServer.Economy.Add(p, "Coins", 100) -- ← autocompletes
--     GaxiaServer.AntiCheat.Flag(p, "Speed", "soft") -- ← autocompletes
--     GaxiaServer.Shared.Signal.new()        -- ← autocompletes (re-export)

export type GaxiaServerPackage = {
	VERSION : string,
	-- ── Shared re-export (full Gaxia shape) ──
	-- Drill into .init explicitly — Roblox runtime require does NOT auto-
	-- resolve `Folder/init` (that is a Rojo build-time convention only).
	Shared : typeof(require(ReplicatedStorage:WaitForChild("Gaxia_Packages"))),

	-- ── Lib services (accessed via semantic keys) ──
	Data    : typeof(require(script.Lib.DataManager)),
	Player  : typeof(require(script.Lib.PlayerService)),
	Item    : typeof(require(script.Lib.ItemService)),
	Economy : typeof(require(script.Lib.EconomyService)),
	Tool    : typeof(require(script.Lib.ToolService)),
	Zone    : typeof(require(script.Lib.ZoneService)),
	Cooldown : typeof(require(script.Lib.CooldownService)),
	ItemDef  : typeof(require(script.Lib.ItemDefinitionService)),
	Interaction : typeof(require(script.Lib.InteractionService)),
	Settings : typeof(require(script.Lib.SettingsService)),
	Lifecycle : typeof(require(script.Lib.ServiceLifecycle)),
	Monetization : typeof(require(script.Lib.MonetizationService)),
	Shop : typeof(require(script.Lib.ShopService)),
	Analytics : typeof(require(script.Lib.AnalyticsService)),
	Webhook : typeof(require(script.Lib.WebhookService)),
	Journal : typeof(require(script.Lib.AntiCheatJournal)),
	Ban : typeof(require(script.Lib.BanService)),
	AntiCheatAdmin : typeof(require(script.Lib.AntiCheatAdmin)),

	-- ── Phase 23 genre pack ──
	Codex : typeof(require(script.Lib.CodexService)),
	Refine : typeof(require(script.Lib.RefineService)),
	Vault : typeof(require(script.Lib.VaultService)),
	Placement : typeof(require(script.Lib.PlacementService)),
	Idle : typeof(require(script.Lib.IdleService)),
	Loot : typeof(require(script.Lib.LootService)),
	AI : typeof(require(script.Lib.AIService)),
	Protection : typeof(require(script.Lib.ProtectionService)),
	Raid : typeof(require(script.Lib.RaidService)),

	-- ── Phase 24 retention ──
	DailyReward : typeof(require(script.Lib.DailyRewardService)),
	Mail : typeof(require(script.Lib.MailService)),
	Inventory : typeof(require(script.Lib.InventoryService)),
	Event : typeof(require(script.Lib.EventService)),
	Visit : typeof(require(script.Lib.VisitService)),
	Teleport : typeof(require(script.Lib.TeleportService)),
	Memory : typeof(require(script.Lib.MemoryStore)),
	Trade : typeof(require(script.Lib.TradeService)),
	Party : typeof(require(script.Lib.PartyService)),

	-- ── Phase 25 juice ──
	VFX : typeof(require(script.Lib.VFXService)),
	SFX : typeof(require(script.Lib.SFXService)),
	Anim : typeof(require(script.Lib.AnimationService)),
	Motion3D : typeof(require(script.Lib.Motion3DService)),
	Ragdoll : typeof(require(script.Lib.RagdollService)),

	-- ── Phase 26 · Social ──
	Friend       : typeof(require(script.Lib.FriendService)),
	Guild        : typeof(require(script.Lib.GuildService)),
	GuildLock    : typeof(require(script.Lib.GuildLock)),
	InviteQueue  : typeof(require(script.Lib.InviteQueue)),

	-- ── Pet system (stat-boost pets) ──
	Pet : typeof(require(script.Lib.PetService)),

	-- ── Phase 11–14 services ──
	Admin       : typeof(require(script.Lib.AdminCommands)),
	Chat        : typeof(require(script.Lib.ChatCommandSystem)),
	Quest       : typeof(require(script.Lib.QuestSystem)),
	Achievement : typeof(require(script.Lib.AchievementSystem)),
	Level       : typeof(require(script.Lib.LevelSystem)),
	Migration   : typeof(require(script.Lib.DataMigration)),
	Leaderboard : typeof(require(script.Lib.LeaderboardService)),
	Messages    : typeof(require(script.Lib.CrossServerMessaging)),

	-- ── AntiCheat orchestrator (the init ModuleScript, not the folder) ──
	AntiCheat : typeof(require(script.AntiCheat)),

	-- ── Config (server-side single config surface) ──
	Config : typeof(require(script.Config)),
	EConfig : typeof(require(script.Lib.EffectiveConfig)),
}

-- ── Guards ───────────────────────────────────────────────────

if RunService:IsClient() then
	error("[Gaxia_Packages_Server] Cannot require server package from the client.")
end

-- ── Constants ────────────────────────────────────────────────

local TAG_NAME : string = "Gaxia_Packages"

-- Maps short server-side keys to their full ModuleScript names
local LIB_KEY_MAP : { [string]: string } = {
	Data        = "DataManager",
	Player      = "PlayerService",
	Item        = "ItemService",
	Economy     = "EconomyService",
	Tool        = "ToolService",
	Zone        = "ZoneService",
	Cooldown    = "CooldownService",
	ItemDef     = "ItemDefinitionService",
	Interaction = "InteractionService",
	Settings    = "SettingsService",
	Lifecycle   = "ServiceLifecycle",
	Monetization = "MonetizationService",
	Shop        = "ShopService",
	Analytics   = "AnalyticsService",
	Webhook     = "WebhookService",
	Journal     = "AntiCheatJournal",
	Ban         = "BanService",
	AntiCheatAdmin = "AntiCheatAdmin",
	Codex       = "CodexService",
	Refine      = "RefineService",
	Vault       = "VaultService",
	Placement   = "PlacementService",
	Idle        = "IdleService",
	Loot        = "LootService",
	AI          = "AIService",
	Protection  = "ProtectionService",
	Raid        = "RaidService",
	DailyReward = "DailyRewardService",
	Mail        = "MailService",
	Inventory   = "InventoryService",
	Event       = "EventService",
	Visit       = "VisitService",
	Teleport    = "TeleportService",
	Memory      = "MemoryStore",
	Trade       = "TradeService",
	Party       = "PartyService",
	VFX         = "VFXService",
	SFX         = "SFXService",
	Anim        = "AnimationService",
	Motion3D    = "Motion3DService",
	Ragdoll     = "RagdollService",
	EConfig     = "EffectiveConfig",
	Admin       = "AdminCommands",
	Chat        = "ChatCommandSystem",
	Quest       = "QuestSystem",
	Achievement = "AchievementSystem",
	Level       = "LevelSystem",
	Migration   = "DataMigration",
	Leaderboard = "LeaderboardService",
	Messages    = "CrossServerMessaging",
	Friend      = "FriendService",
	Guild       = "GuildService",
	GuildLock   = "GuildLock",
	InviteQueue = "InviteQueue",
	Pet         = "PetService",
}

-- ── Internal Cache ───────────────────────────────────────────

local moduleCache : { [string]: any } = {}

-- ── Private Helpers ──────────────────────────────────────────

local function safeRequire(mod: ModuleScript, label: string): any?
	local ok, result = pcall(require, mod)
	if not ok then
		warn(`[Gaxia_Packages_Server] Failed to require '{label}': {tostring(result)}`)
		return nil
	end
	return result
end

local function resolveChild(folder: Instance, name: string): ModuleScript?
	-- WaitForChild fallback removed: this helper is reachable from __index
	-- metamethods, and Luau forbids yielding across metamethod / C-call
	-- boundaries ("attempt to yield across metamethod/C-call boundary").
	-- Lib children are already present by the time the loader returns.
	local child : Instance? = folder:FindFirstChild(name)
	if child == nil or not child:IsA("ModuleScript") then
		return nil
	end
	return child :: ModuleScript
end

-- ── Auto-tagger ──────────────────────────────────────────────

local function autoTagDescendants(): ()
	-- Under Rojo this `init` IS the Gaxia_Packages_Server ModuleScript and the package's
	-- modules are its descendants. (It used to tag script.Parent, which is the
	-- whole ServerStorage — every game asset got the tag.) Tag the
	-- package + all its descendants so consumers can query "everything that
	-- belongs to Gaxia_Packages_Server" via CollectionService.
	local packageRoot = script :: Instance
	if not CollectionService:HasTag(packageRoot, TAG_NAME) then
		CollectionService:AddTag(packageRoot, TAG_NAME)
	end
	for _, d in ipairs(packageRoot:GetDescendants()) do
		if not CollectionService:HasTag(d, TAG_NAME) then
			CollectionService:AddTag(d, TAG_NAME)
		end
	end
end

-- ── Nested Namespace Proxy ───────────────────────────────────

local function makeNamespaceProxy(folder: Instance, prefix: string): { [string]: any }
	local proxy = {}
	local cache : { [string]: any } = {}

	setmetatable(proxy, {
		__index = function(_, key: string): any?
			if cache[key] ~= nil then
				return cache[key]
			end
			local mod = resolveChild(folder, key)
			if mod == nil then
				warn(`[Gaxia_Packages_Server] '{prefix}.{key}' not found in {folder:GetFullName()}`)
				return nil
			end
			local result = safeRequire(mod, `{prefix}.{key}`)
			cache[key] = result
			return result
		end,
	})

	return proxy
end

-- ── Module Assembly ──────────────────────────────────────────

local function buildGaxiaServer(): { [string]: any }
	-- Lib/ and AntiCheat/ are siblings of this `init` ModuleScript under the
	-- Gaxia_Packages_Server folder, not children of `init`.
	local packageRoot     : ModuleScript = script :: ModuleScript
	local libFolder       : Folder = packageRoot:WaitForChild("Lib")       :: Folder
	local antiCheatFolder : Folder = packageRoot:WaitForChild("AntiCheat") :: Folder

	autoTagDescendants()

	-- Re-export ReplicatedStorage.Gaxia_Packages as .Shared
	-- The Gaxia_Packages instance is a Folder, not a ModuleScript — its child
	-- `init` is the actual loader (Rojo's "init.lua" convention is build-time
	-- only, so at runtime we must drill in manually).
	local sharedFolder : Instance? = ReplicatedStorage:WaitForChild("Gaxia_Packages", 10)
	local sharedInitMod : Instance? = if sharedFolder then sharedFolder else nil
	local sharedPackage : { [string]: any } = {}
	if sharedInitMod and sharedInitMod:IsA("ModuleScript") then
		local loaded = safeRequire(sharedInitMod :: ModuleScript, "Gaxia_Packages.init")
		if loaded then
			sharedPackage = loaded
		end
	else
		warn("[Gaxia_Packages_Server] Could not find ReplicatedStorage.Gaxia_Packages.init ModuleScript")
	end

	-- WHY AntiCheat is the orchestrator directly (not a namespace proxy):
	-- Consumers want `GaxiaServer.AntiCheat.Flag(...)` and `.OnFlag` — these
	-- are members of the AntiCheat orchestrator (the `init` ModuleScript inside
	-- the AntiCheat folder), NOT sibling detector modules. Returning the
	-- orchestrator here makes the API match user expectations *and* matches
	-- the type definition `typeof(require(script.Parent.AntiCheat))`.
	-- The orchestrator itself auto-loads every sibling detector at boot.
	local antiCheatInitMod = antiCheatFolder
	local antiCheatModule : any = {}
	if antiCheatInitMod and antiCheatInitMod:IsA("ModuleScript") then
		local loaded = safeRequire(antiCheatInitMod :: ModuleScript, "AntiCheat")
		if loaded then
			antiCheatModule = loaded
		end
	else
		warn("[Gaxia_Packages_Server] AntiCheat not found — AntiCheat namespace will be empty")
	end

	-- ── Root Table ───────────────────────────────────────────

	-- Config (server-side single config surface). Pure-table body → no yield, safe here.
	local configModule: any = {}
	local configInst = packageRoot:FindFirstChild("Config")
	if configInst and configInst:IsA("ModuleScript") then
		local loaded = safeRequire(configInst, "Config")
		if loaded then
			configModule = loaded
		end
	end

	local GaxiaServer : { [string]: any } = {
		Shared    = sharedPackage,
		AntiCheat = antiCheatModule,
		Config    = configModule,
	}

	-- ── Root __index for flat Lib/ services ──────────────────
	setmetatable(GaxiaServer, {
		__index = function(t: { [string]: any }, key: string): any?
			if moduleCache[key] ~= nil then
				return moduleCache[key]
			end

			-- 1. Try semantic key map (Data → DataManager, etc.)
			local modName = LIB_KEY_MAP[key]
			if modName then
				local mod = resolveChild(libFolder, modName)
				if mod then
					local result = safeRequire(mod, key)
					moduleCache[key] = result
					rawset(t, key, result)
					return result
				end
			end

			-- 2. Try Lib/ by exact key name (fallback)
			local directMod = resolveChild(libFolder, key)
			if directMod then
				local result = safeRequire(directMod, key)
				moduleCache[key] = result
				rawset(t, key, result)
				return result
			end

			return nil
		end,
	})

	-- Runtime version stamp (direct field — bypasses the lazy __index proxy).
	GaxiaServer.VERSION = "1.0.0"

	print(`[Gaxia_Packages_Server] loaded v{GaxiaServer.VERSION}`)
	return GaxiaServer
end

-- ── Module Return ────────────────────────────────────────────

-- Cast to the exported shape so IDE auto-complete works. Runtime behaviour
-- (lazy proxy lookup, Shared re-export) is unchanged.
return buildGaxiaServer() :: GaxiaServerPackage
