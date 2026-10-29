--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   UIController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/UIController
-- Purpose:  Central UI manager. Builds templates via the code-first
--           Templates module (no .rbxm binary), and owns PlayerGui.Gaxia_UI:
--           the one place that creates it (with its HUD and Overlays folders)
--           on demand, so no game or module has to make it first.
-- ─────────────────────────────────────────────────────────────

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UIController = {}
-- The module's own type (every function below), so the server stub and the
-- client module share one type and `Gaxia.UI.UIController.<method>` autocompletes.
export type UIController = typeof(UIController)

-- Client-only module. The server gets an EMPTY table (calls error there); only
-- its type is the client module's.
if not RunService:IsClient() then
	return ({} :: any) :: typeof(UIController)
end

-- ── Constants ──
local SCREEN_WAIT_TIMEOUT: number = 5
local ACTIVE_SCREEN_NAME: string = "Gaxia_UI"
local HUD_NAME: string = "HUD"
local OVERLAYS_NAME: string = "Overlays"

-- ── Cached references ──
local StarterGui = game:GetService("StarterGui")
local LocalPlayer: Player = Players.LocalPlayer
local PlayerGui: PlayerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

-- ── Templates (code-first, replaces legacy StarterGui Templates.rbxm) ──
-- Sibling require (typed): keeps the dependency local and avoids the master
-- loader's lazy proxy round-trip.
local Templates = require(script.Parent.Templates)

-- Names CloneTemplate knows (re-exported from Templates for callers).
export type TemplateName = Templates.TemplateName

-- The one PlayerGui.Gaxia_UI this module made or found (re-checked on each call:
-- a game may destroy it, or a ResetOnSpawn copy from StarterGui may replace it).
local cachedRoot: ScreenGui? = nil
-- A stand-in Gaxia_UI made while the game's StarterGui.Gaxia_UI had not been
-- copied into PlayerGui yet (no character). Replaced by that copy when it comes.
local standIn: ScreenGui? = nil
local standInConn: RBXScriptConnection? = nil

-- Finds `name` under `root`, or creates an empty Folder with that name.
local function ensureFolder(root: ScreenGui, name: string): Instance
	local existing = root:FindFirstChild(name)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = root
	return folder
end

-- Moves everything Gaxia drew into the stand-in over to the game's own
-- Gaxia_UI (the StarterGui copy that just arrived), then removes the stand-in,
-- so PlayerGui never keeps two Gaxia_UI.
local function adoptStarterCopy(copy: ScreenGui): ()
	local temp = standIn
	if not temp or copy == temp then
		return
	end
	standIn = nil
	if standInConn then
		standInConn:Disconnect()
		standInConn = nil
	end
	for _, child in ipairs(temp:GetChildren()) do
		local target: Instance? = copy:FindFirstChild(child.Name)
		local isRootFolder: boolean = child.ClassName == "Folder" and (child.Name == HUD_NAME or child.Name == OVERLAYS_NAME)
		if isRootFolder and target then
			-- The game's folder (and whatever its designer put in it) wins: move our content in.
			for _, item in ipairs(child:GetChildren()) do
				item.Parent = target
			end
		else
			child.Parent = copy
		end
	end
	temp:Destroy()
	cachedRoot = copy
	ensureFolder(copy, HUD_NAME)
	ensureFolder(copy, OVERLAYS_NAME)
end

-- The single place that finds or creates PlayerGui.Gaxia_UI (with HUD and
-- Overlays). Every Gaxia UI module reaches the root through the getters below.
local function ensureRoot(): ScreenGui?
	local root = cachedRoot
	if root and root.Parent == PlayerGui then
		return root
	end

	local found = PlayerGui:FindFirstChild(ACTIVE_SCREEN_NAME)
	local fromStarter = StarterGui:FindFirstChild(ACTIVE_SCREEN_NAME) ~= nil
	if not found and fromStarter then
		-- WHY: the game made Gaxia_UI in Studio. Roblox copies it into PlayerGui
		-- when the character spawns: wait for that copy instead of making a
		-- second one.
		found = PlayerGui:WaitForChild(ACTIVE_SCREEN_NAME, SCREEN_WAIT_TIMEOUT)
		if not found then
			-- The copy may be on its way (another thread waited) — or never comes
			-- (no character yet). Fall through and create one so callers never
			-- get nil.
			found = PlayerGui:FindFirstChild(ACTIVE_SCREEN_NAME)
		end
	end

	if found then
		if not found:IsA("ScreenGui") then
			-- WHY: nil-safe — something else holds the name; do not guess.
			warn(`[UIController] PlayerGui.{ACTIVE_SCREEN_NAME} is a {found.ClassName}, not a ScreenGui`)
			return nil
		end
		root = found
	else
		local screen = Instance.new("ScreenGui")
		screen.Name = ACTIVE_SCREEN_NAME
		screen.ResetOnSpawn = false -- keep the UI after the character respawns
		screen.IgnoreGuiInset = true
		screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		screen.DisplayOrder = 1000
		screen.Parent = PlayerGui
		root = screen
		if fromStarter then
			-- WHY: no character yet (CharacterAutoLoads off, slow spawn). Draw into
			-- this stand-in now; when Roblox copies the game's Gaxia_UI in, move
			-- our content there and drop the stand-in (see adoptStarterCopy).
			standIn = screen
			standInConn = PlayerGui.ChildAdded:Connect(function(child: Instance)
				if child ~= screen and child.Name == ACTIVE_SCREEN_NAME and child:IsA("ScreenGui") then
					adoptStarterCopy(child)
				end
			end)
		end
	end

	local screen = root :: ScreenGui
	ensureFolder(screen, HUD_NAME)
	ensureFolder(screen, OVERLAYS_NAME)
	cachedRoot = screen
	return screen
end

-- ── GetActiveScreen ──
-- Returns PlayerGui.Gaxia_UI, creating it (ResetOnSpawn off, with the HUD and Overlays folders) the first time any Gaxia UI module asks. A Gaxia_UI made in StarterGui is reused: it waits up to 5 s for Roblox to copy it into PlayerGui; with no copy yet (no character) it returns a stand-in whose content moves into the copy when it arrives, so call this again rather than keeping the result. Nil only when something that is not a ScreenGui is named Gaxia_UI.
function UIController.GetActiveScreen(): ScreenGui?
	return ensureRoot()
end

-- Finds a direct Folder child of the root (made by ensureRoot when missing).
local function rootFolder(name: string): Folder?
	local screen = ensureRoot()
	if not screen then
		return nil
	end
	local child = screen:FindFirstChild(name)
	if child and child:IsA("Folder") then
		return child
	end
	return nil
end

-- ── HUD ──
-- Container for persistent on-screen elements (health bars, text labels): the Folder PlayerGui.Gaxia_UI.HUD, created on demand. Nil only when a non-Folder named HUD is already in Gaxia_UI.
function UIController.HUD(): Folder?
	return rootFolder(HUD_NAME)
end

-- ── Overlays ──
-- Container for modal / temporary UI (menus, dialogs, inventory): the Folder PlayerGui.Gaxia_UI.Overlays, created on demand. Nil only when a non-Folder named Overlays is already in Gaxia_UI.
function UIController.Overlays(): Folder?
	return rootFolder(OVERLAYS_NAME)
end

-- ── CloneTemplate ──
-- Builds a fresh instance of the named template via the code-first
-- Templates module, parents it (default = active ScreenGui), and flips
-- Visible=true so callers can stage further without an extra step.
-- The legacy name "CloneTemplate" is preserved so existing call sites
-- (NotificationService / HealthBarController / MenuController /
-- InventoryController) keep working — semantics are identical from
-- their perspective.
function UIController.CloneTemplate(templateName: TemplateName | string, parent: Instance?): GuiObject?
	-- Looked up by runtime name (unknown names warn below), hence the `any` index.
	local builder = (Templates :: any)[templateName]
	if typeof(builder) ~= "function" then
		warn(`[UIController] Template '{templateName}' not registered in Templates module`)
		return nil
	end

	local ok, result = pcall(builder, nil)  -- build unparented first
	if not ok then
		warn(`[UIController] Build failed for '{templateName}': {tostring(result)}`)
		return nil
	end
	if not result or not (result :: any):IsA("GuiObject") then
		warn(`[UIController] Template '{templateName}' did not return a GuiObject`)
		return nil
	end

	local inst = result :: GuiObject
	inst.Visible = true
	inst.Parent = parent or UIController.GetActiveScreen()
	return inst
end

return UIController
