--!strict
-- ============================================================
-- init (ModuleScript)
-- Location : ServerStorage/Gaxia_Packages_Server
-- Purpose  : Server entry point. Loads services lazily by key
--            (GaxiaServer.Economy → Lib/EconomyService) and starts them through
--            ServiceLifecycle: the services listed in Config/Features (or the
--            game-owned ServerStorage.GaxiaFeatures) start at Boot; any other
--            service starts the first time it is touched. Re-exports
--            ReplicatedStorage.Gaxia_Packages as .Shared.
--
--            Boot runs once, on whichever comes first: the bootstrap Script
--            calling GaxiaServer.Boot(), or any game code touching a service key.
--            ReplicatedStorage.Events (+ Events/Net) exist as soon as this module
--            is required, so game Scripts never depend on Script run order.
-- ============================================================

-- ── Services ─────────────────────────────────────────────────

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local ServerStorage     = game:GetService("ServerStorage")

local Types = require(script.Types)

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

	-- ── Boot / status ──
	-- Start the Features services (idempotent; also runs on first service access).
	Boot : () -> (),
	-- True once the service has started (a listed Features service after Boot, or
	-- any service after first use). Never loads anything.
	IsEnabled : (name: Types.ServiceName | string) -> boolean,
}

-- ── Guards ───────────────────────────────────────────────────

if RunService:IsClient() then
	error("[Gaxia_Packages_Server] Cannot require server package from the client.")
end

-- Edit mode (plugins, command bar): expose the package but never boot services or
-- create instances in the place.
local IS_RUNNING : boolean = RunService:IsRunning()

-- ── Constants ────────────────────────────────────────────────

local TAG_NAME : string = "Gaxia_Packages"
-- Attribute on ReplicatedStorage.Gaxia_Packages listing started services (comma
-- separated) so the client bootstrap only pre-warms modules whose server side runs.
local FEATURES_ATTRIBUTE : string = "GaxiaServerFeatures"

-- Maps short server-side keys to their full ModuleScript names under Lib/
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

-- Keys resolved from the package root instead of Lib/.
local ROOT_KEY_MAP : { [string]: string } = {
	AntiCheat = "AntiCheat",
}

-- Framework utilities: loader keys, but not services (never listed as started).
local UTILITY_KEYS : { [string]: boolean } = {
	Lifecycle = true,
	EConfig   = true,
}

-- ── Internal State ───────────────────────────────────────────

local moduleCache : { [string]: any } = {}
local failedKeys  : { [string]: boolean } = {}
local bootStarted = false

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
	-- FindFirstChild, never WaitForChild: this runs inside the __index metamethod,
	-- where Luau forbids yielding. Package children exist once the loader returns.
	local child : Instance? = folder:FindFirstChild(name)
	if child == nil or not child:IsA("ModuleScript") then
		return nil
	end
	return child :: ModuleScript
end

-- ── Auto-tagger ──────────────────────────────────────────────

local function autoTagDescendants(): ()
	-- Under Rojo this `init` IS the Gaxia_Packages_Server ModuleScript and the
	-- package's modules are its descendants. (It used to tag script.Parent, which is
	-- the whole ServerStorage — every game asset got the tag.) Tag the package + all
	-- its descendants so consumers can query "everything that belongs to
	-- Gaxia_Packages_Server" via CollectionService.
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

-- ── Module Assembly ──────────────────────────────────────────

local function buildGaxiaServer(): { [string]: any }
	local packageRoot : ModuleScript = script :: ModuleScript
	local libFolder   : Folder = packageRoot:WaitForChild("Lib") :: Folder

	autoTagDescendants()

	-- Re-export ReplicatedStorage.Gaxia_Packages as .Shared. It is the Gaxia_Packages
	-- ModuleScript itself (Rojo init.lua), with Shared/ and Client/ as its children.
	local sharedRoot : Instance? = ReplicatedStorage:WaitForChild("Gaxia_Packages", 10)
	local sharedPackage : { [string]: any } = {}
	if sharedRoot and sharedRoot:IsA("ModuleScript") then
		local loaded = safeRequire(sharedRoot, "Gaxia_Packages")
		if loaded then
			sharedPackage = loaded
		end
	else
		warn("[Gaxia_Packages_Server] Could not find the ReplicatedStorage.Gaxia_Packages ModuleScript")
	end

	-- Config (server-side single config surface). Pure-table body → no yield.
	local configModule: any = {}
	local configInst = packageRoot:FindFirstChild("Config")
	if configInst and configInst:IsA("ModuleScript") then
		local loaded = safeRequire(configInst, "Config")
		if loaded then
			configModule = loaded
		end
	end

	-- Lifecycle is pure (no side effects); needed by Boot and the __index path.
	local lifecycleMod = resolveChild(libFolder, "ServiceLifecycle")
	local Lifecycle : any = if lifecycleMod then safeRequire(lifecycleMod, "Lifecycle") else nil

	-- NetService's server body creates ReplicatedStorage.Events and Events/Net. Do it
	-- now, while the loader is being required, so game Scripts that index
	-- ReplicatedStorage.Events right after requiring the loader work whatever order
	-- Roblox runs Scripts in (the AntiCheat orchestrator used to do this implicitly).
	if IS_RUNNING then
		local _net = sharedPackage.Net
	end

	local GaxiaServer : { [string]: any } = {
		Shared = sharedPackage,
		Config = configModule,
	}

	-- Resolve a key to its module WITHOUT starting it. Caches successes and failures.
	local function loadKey(key: string): any?
		local cached = moduleCache[key]
		if cached ~= nil then
			return cached
		end
		if failedKeys[key] then
			return nil
		end
		local mod: ModuleScript? = nil
		local rootName = ROOT_KEY_MAP[key]
		if rootName then
			mod = resolveChild(packageRoot, rootName)
		else
			local libName = LIB_KEY_MAP[key]
			mod = resolveChild(libFolder, libName or key)
		end
		if mod == nil then
			return nil
		end
		local result = safeRequire(mod, key)
		if result == nil then
			failedKeys[key] = true
			return nil
		end
		moduleCache[key] = result
		return result
	end

	-- A service counts as started when it has no lifecycle spec (legacy module: its
	-- body did the setup when it was loaded) or its spec reached "initialized".
	local function isStarted(key: string): boolean
		local mod = moduleCache[key]
		if mod == nil then
			return false
		end
		if Lifecycle == nil then
			return true
		end
		local state = Lifecycle.GetState(mod)
		return state == nil or state == "initialized"
	end

	local function publishFeatures(): ()
		if not IS_RUNNING or sharedRoot == nil then
			return
		end
		local names: { string } = {}
		for key in pairs(moduleCache) do
			if (LIB_KEY_MAP[key] or ROOT_KEY_MAP[key]) and not UTILITY_KEYS[key] and isStarted(key) then
				table.insert(names, key)
			end
		end
		table.sort(names)
		sharedRoot:SetAttribute(FEATURES_ATTRIBUTE, table.concat(names, ","))
	end

	local function readFeatures(): { string }
		local services: { string } = {}
		local defaults = configModule.Features
		if type(defaults) == "table" and type(defaults.Services) == "table" then
			services = defaults.Services
		end
		-- Game-owned override survives Companion reinstalls (outside this package).
		local overrideInst = ServerStorage:FindFirstChild("GaxiaFeatures")
		if overrideInst and overrideInst:IsA("ModuleScript") then
			local override = safeRequire(overrideInst, "ServerStorage.GaxiaFeatures")
			if type(override) == "table" and type(override.Services) == "table" then
				services = override.Services
			elseif override ~= nil then
				warn("[Gaxia_Packages_Server] ServerStorage.GaxiaFeatures must return { Services = { ... } } — ignored")
			end
		end
		return services
	end

	function GaxiaServer.Boot(): ()
		if bootStarted or not IS_RUNNING then
			return
		end
		bootStarted = true
		local modules: { any } = {}
		for _, name in ipairs(readFeatures()) do
			if LIB_KEY_MAP[name] == nil and ROOT_KEY_MAP[name] == nil then
				warn(`[Gaxia_Packages_Server] Features: unknown service "{name}" — ignored`)
				continue
			end
			-- A module whose body errors is warned and skipped; Boot carries on.
			local mod = loadKey(name)
			if mod ~= nil then
				table.insert(modules, mod)
			end
		end
		if Lifecycle then
			Lifecycle.Boot(modules)
			Lifecycle.OnAnyInitialized(function()
				publishFeatures()
			end)
		end
		publishFeatures()
		-- Role-gated behaviour depends on AdminCommands installing its resolvers.
		for _, dependent in ipairs({ "Chat", "Ban" }) do
			if isStarted(dependent) and not isStarted("Admin") then
				warn(`[Gaxia_Packages_Server] {dependent} is running without Admin: role checks fall back to defaults (role-gated chat commands are denied; only the place creator is exempt from auto-bans)`)
			end
		end
	end

	function GaxiaServer.IsEnabled(name: string): boolean
		return isStarted(name)
	end

	-- ── Root __index: lazy load + start on first access ──────
	setmetatable(GaxiaServer, {
		__index = function(t: { [string]: any }, key: string): any?
			if not bootStarted and IS_RUNNING and (LIB_KEY_MAP[key] or ROOT_KEY_MAP[key]) then
				-- First service access boots the framework, so game code never sees a
				-- half-started framework whatever order Roblox runs Scripts in.
				GaxiaServer.Boot()
			end
			local result = loadKey(key)
			if result == nil then
				return nil
			end
			if Lifecycle and IS_RUNNING then
				Lifecycle.EnsureAuto(result)
				if Lifecycle.GetState(result) == "failed" then
					if not failedKeys[key] then
						failedKeys[key] = true
						warn(`[Gaxia_Packages_Server] '{key}' failed to start — returning nil`)
					end
					moduleCache[key] = nil
					return nil
				end
				publishFeatures()
			end
			rawset(t, key, result)
			return result
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
