--!strict
-- ============================================================
-- init (ModuleScript)
-- Location : ReplicatedStorage/Gaxia_Packages
-- Purpose  : Master lazy-loading loader for the Gaxia_Packages
--            framework. Exposes Shared namespaces on all contexts
--            and Client namespaces only on the client. Provides
--            Tween shortcut, Logger singleton, and Constants
--            direct-require helpers. Auto-tags every descendant
--            with the "Gaxia_Packages" CollectionService tag.
-- ============================================================

-- ── Services ─────────────────────────────────────────────────

local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

-- ── Type definitions (for IDE auto-complete) ─────────────────
--
-- `typeof(require(...))` is type-only: Studio's Luau analyser follows the
-- path at type-check time but does NOT execute the require at runtime.
-- That means: lazy loading still works (modules load on first __index hit),
-- but the editor sees every top-level field and its methods, so consumers
-- get IntelliSense without paying a startup cost.
--
-- Consumer usage (no extra setup needed):
--     local Gaxia = require(ReplicatedStorage.Gaxia_Packages)
--     Gaxia.Signal.new()                  -- ← autocompletes
--     Gaxia.Util.String.FormatNumber(...) -- ← autocompletes
--     Gaxia.UI.NotificationService.Notify(...) -- ← autocompletes (client)
--
-- NOTE: UI / Input / Camera / Sound / Effects / AntiCheat are CLIENT-ONLY.
-- They appear in the type for editor convenience but are nil on the server.
-- Server consumers should require `Gaxia_Packages_Server` instead.

export type GaxiaPackage = {
	VERSION : string,
	-- ── Shared (always available) ──
	Signal    : typeof(require(script.Shared.Signal)),
	Maid      : typeof(require(script.Shared.Maid)),
	Janitor   : typeof(require(script.Shared.Janitor)),
	Trove     : typeof(require(script.Shared.Trove)),
	Promise   : typeof(require(script.Shared.Promise)),
	TweenUtil : typeof(require(script.Shared.TweenUtil)),
	Raycaster : typeof(require(script.Shared.Raycaster)),
	Spring    : typeof(require(script.Shared.Spring)),
	Logger    : typeof(require(script.Shared.Logger)),
	Symbol    : typeof(require(script.Shared.Symbol)),
	Constants : typeof(require(script.Shared.Constants)),
	Net       : typeof(require(script.Shared.NetService)),       -- alias key (maps to NetService)
	State     : typeof(require(script.Shared.ReplicatedState)),  -- alias key (maps to ReplicatedState)
	Perf      : typeof(require(script.Shared.PerformanceMonitor)),
	TestRunner : typeof(require(script.Shared.TestRunner)),
	MockPlayer : typeof(require(script.Shared.MockPlayer)),
	Bench      : typeof(require(script.Shared.PerformanceBenchmark)),
	Random     : typeof(require(script.Shared.Random)),
	Pool       : typeof(require(script.Shared.Pool)),
	Scheduler  : typeof(require(script.Shared.Scheduler)),
	Guard      : typeof(require(script.Shared.Guard)),
	Serializer : typeof(require(script.Shared.Serializer)),
	Component  : typeof(require(script.Shared.Component)),
	Command    : typeof(require(script.Shared.Command)),
	Flags      : typeof(require(script.Shared.Flags)),
	Theme      : typeof(require(script.Shared.Theme)),
	Localization : typeof(require(script.Shared.Localization)),
	GuiCodec   : typeof(require(script.Shared.GuiCodec)),

	-- ── Shared/Util ──
	Util : {
		Table    : typeof(require(script.Shared.Util.Table)),
		String   : typeof(require(script.Shared.Util.String)),
		Math     : typeof(require(script.Shared.Util.Math)),
		Instance : typeof(require(script.Shared.Util.Instance)),
		Player   : typeof(require(script.Shared.Util.Player)),
		Debug    : typeof(require(script.Shared.Util.Debug)),
	},

	-- ── Client UI (client-only — nil on server) ──
	UI : {
		UIController        : typeof(require(script.Client.UI.UIController)),
		NotificationService : typeof(require(script.Client.UI.NotificationService)),
		HealthBarController : typeof(require(script.Client.UI.HealthBarController)),
		MenuController      : typeof(require(script.Client.UI.MenuController)),
		InventoryController : typeof(require(script.Client.UI.InventoryController)),
		HUDController       : typeof(require(script.Client.UI.HUDController)),
		LoadingScreenController : typeof(require(script.Client.UI.LoadingScreenController)),
		StateBinding : typeof(require(script.Client.UI.StateBinding)),
		Responsive : typeof(require(script.Client.UI.Responsive)),
		Router : typeof(require(script.Client.UI.Router)),
		Components : typeof(require(script.Client.UI.Components)),
		GamepadNav : typeof(require(script.Client.UI.GamepadNav)),
		RebindMenu : typeof(require(script.Client.UI.RebindMenu)),
		Accessibility : typeof(require(script.Client.UI.Accessibility)),
		Toast : typeof(require(script.Client.UI.Toast)),
		Haptics : typeof(require(script.Client.UI.Haptics)),
		Motion : typeof(require(script.Client.UI.Motion)),
		AdminPanel : typeof(require(script.Client.UI.AdminPanel)),
	},

	-- ── Client modules accessed via short keys (CLIENT_KEY_MAP) ──
	Input   : typeof(require(script.Client.InputManager)),
	Camera  : typeof(require(script.Client.CameraController)),
	Sound   : typeof(require(script.Client.SoundController)),
	Effects : typeof(require(script.Client.EffectsController)),
	AntiCheat : typeof(require(script.Client.ClientAntiCheat)),
	ChatFeedback : typeof(require(script.Client.ChatFeedback)),
	DebugConsole : typeof(require(script.Client.DebugConsole)),
	Dialog   : typeof(require(script.Client.DialogSystem)),
	Tooltip  : typeof(require(script.Client.TooltipSystem)),
	Cutscene : typeof(require(script.Client.CutsceneSystem)),

	-- ── Convenience helpers ──
	Tween : (instance: Instance, info: TweenInfo, props: { [string]: any }) -> Tween,
}

-- ── Constants ────────────────────────────────────────────────

local TAG_NAME      : string  = "Gaxia_Packages"
local IS_CLIENT     : boolean = RunService:IsClient()
local CONTEXT_LABEL : string  = if IS_CLIENT then "client" else "server"

-- Maps short client-side keys to their full ModuleScript names
local CLIENT_KEY_MAP : { [string]: string } = {
	Input        = "InputManager",
	Camera       = "CameraController",
	Sound        = "SoundController",
	Effects      = "EffectsController",
	AntiCheat    = "ClientAntiCheat",
	ChatFeedback = "ChatFeedback",
	DebugConsole = "DebugConsole",
	Dialog       = "DialogSystem",
	Tooltip      = "TooltipSystem",
	Cutscene     = "CutsceneSystem",
}

-- Maps short shared-side keys to their full ModuleScript names. Lets callers
-- write `Gaxia.Net.Fire(...)` instead of `Gaxia.NetService.Fire(...)`.
local SHARED_KEY_MAP : { [string]: string } = {
	Net        = "NetService",
	State      = "ReplicatedState",
	Perf       = "PerformanceMonitor",
	Bench      = "PerformanceBenchmark",
	TestRunner = "TestRunner",
	MockPlayer = "MockPlayer",
}

-- ── Internal Cache ───────────────────────────────────────────

local moduleCache : { [string]: any } = {}

-- ── Private Helpers ──────────────────────────────────────────

-- Safely require a ModuleScript; warns on failure and returns nil
local function safeRequire(mod: ModuleScript, label: string): any?
	local ok, result = pcall(require, mod)
	if not ok then
		warn(`[Gaxia_Packages] Failed to require '{label}': {tostring(result)}`)
		return nil
	end
	return result
end

-- Resolve a child ModuleScript from a folder without yielding. We must use
-- FindFirstChild here (NOT WaitForChild) because this helper is invoked from
-- inside __index metamethods — Luau forbids yielding across metamethod / C
-- call boundaries ("attempt to yield across metamethod/C-call boundary").
--
-- By the time any consumer triggers __index, this script has already finished
-- its synchronous body which WaitForChild's both Shared and Client folders,
-- so their flat children are guaranteed present on the client too.
local function resolveChild(folder: Instance, name: string): ModuleScript?
	local child: Instance? = folder:FindFirstChild(name)
	if child == nil or not child:IsA("ModuleScript") then
		return nil
	end
	return child :: ModuleScript
end

-- ── Auto-tagger ──────────────────────────────────────────────

local function autoTagDescendants(): ()
	-- script.Parent is the Gaxia_Packages Folder; script is the `init` ModuleScript
	-- (sibling). Tag the folder + all package descendants so consumers can query
	-- "everything that belongs to Gaxia_Packages" via CollectionService.
	local packageRoot = script.Parent :: Instance
	if not CollectionService:HasTag(packageRoot, TAG_NAME) then
		CollectionService:AddTag(packageRoot, TAG_NAME)
	end
	for _, d in ipairs(packageRoot:GetDescendants()) do
		if not CollectionService:HasTag(d, TAG_NAME) then
			CollectionService:AddTag(d, TAG_NAME)
		end
	end
end

-- ── Logger Fallback ──────────────────────────────────────────

-- Inline logger used until Shared/Logger is available
local function buildLogger(sharedFolder: Instance): { [string]: any }
	local loggerMod = resolveChild(sharedFolder, "Logger")
	if loggerMod then
		local loaded = safeRequire(loggerMod, "Logger")
		if loaded then
			return loaded
		end
	end

	local fallback = {}
	function fallback:Info(msg: string)  print(`[Gaxia][INFO]  {tostring(msg)}`) end
	function fallback:Warn(msg: string)  warn(`[Gaxia][WARN]  {tostring(msg)}`)  end
	function fallback:Error(msg: string) warn(`[Gaxia][ERROR] {tostring(msg)}`)  end
	function fallback:Debug(msg: string) print(`[Gaxia][DEBUG] {tostring(msg)}`) end
	return fallback
end

-- ── Tween Shortcut ───────────────────────────────────────────

local function tweenShortcut(
	instance : Instance,
	info     : TweenInfo,
	props    : { [string]: any }
): Tween
	local t = TweenService:Create(instance, info, props)
	t:Play()
	return t
end

-- ── Nested Namespace Proxy ───────────────────────────────────

-- Builds a lazy-load table for a sub-folder (Util/, UI/, etc.)
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
				warn(`[Gaxia_Packages] '{prefix}.{key}' not found in {folder:GetFullName()}`)
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

local function buildGaxia(): { [string]: any }
	-- Shared/ and Client/ are *siblings* of this `init` ModuleScript under the
	-- Gaxia_Packages folder, not children of `init`. Resolve via script.Parent.
	local packageRoot  : ModuleScript  = script :: ModuleScript
	local sharedFolder : Folder  = packageRoot:WaitForChild("Shared") :: Folder
	local clientFolder : Folder? = if IS_CLIENT
		then (packageRoot:WaitForChild("Client") :: Folder)
		else nil

	autoTagDescendants()

	-- Util namespace: lazy proxy over Shared/Util/
	local utilFolder : Instance? = sharedFolder:FindFirstChild("Util")
	local utilProxy = if utilFolder
		then makeNamespaceProxy(utilFolder, "Util")
		else {}

	-- Client-only nested namespaces
	local clientProxies : { [string]: { [string]: any } } = {}
	if IS_CLIENT and clientFolder then
		local uiFolder : Instance? = clientFolder:FindFirstChild("UI")
		if uiFolder then
			clientProxies["UI"] = makeNamespaceProxy(uiFolder, "UI")
		end
	end

	-- Constants: require directly; empty table fallback
	local constantsMod = resolveChild(sharedFolder, "Constants")
	local constants : { [string]: any } = if constantsMod
		then (safeRequire(constantsMod, "Constants") or {})
		else {}

	-- Logger singleton
	local logger = buildLogger(sharedFolder)

	-- ── Root Table ───────────────────────────────────────────

	local Gaxia : { [string]: any } = {
		Util      = utilProxy,
		Constants = constants,
		Logger    = logger,
		Tween     = tweenShortcut,
	}

	-- Merge client namespace proxies into root
	if IS_CLIENT then
		for k, v in clientProxies do
			Gaxia[k] = v
		end
	end

	-- ── Root __index for flat Shared/ + Client/ modules ──────
	setmetatable(Gaxia, {
		__index = function(t: { [string]: any }, key: string): any?
			if moduleCache[key] ~= nil then
				return moduleCache[key]
			end

			-- 1. Try Shared/ — direct file name first, then via SHARED_KEY_MAP alias.
			local sharedName = SHARED_KEY_MAP[key] or key
			local sharedMod = resolveChild(sharedFolder, sharedName)
			if sharedMod then
				local result = safeRequire(sharedMod, key)
				moduleCache[key] = result
				rawset(t, key, result)
				return result
			end

			-- 2. Try Client/ flat modules via key map
			if IS_CLIENT and clientFolder then
				local modName = CLIENT_KEY_MAP[key]
				if modName then
					local clientMod = resolveChild(clientFolder, modName)
					if clientMod then
						local result = safeRequire(clientMod, key)
						moduleCache[key] = result
						rawset(t, key, result)
						return result
					end
				end
			end

			return nil
		end,
	})

	-- Runtime version stamp (direct field — bypasses the lazy __index proxy).
	Gaxia.VERSION = "1.0.0"

	print(`[Gaxia_Packages] loaded ({CONTEXT_LABEL}) v{Gaxia.VERSION}`)
	return Gaxia
end

-- ── Module Return ────────────────────────────────────────────

-- The cast attaches our exported `GaxiaPackage` shape so IDE auto-complete
-- (Studio Script Editor, Luau LSP) can resolve every namespace and method.
-- Runtime semantics are unchanged: the metatable __index still lazy-loads
-- each module on first access.
return buildGaxia() :: GaxiaPackage
