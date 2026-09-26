--!strict
--[[
	Module : ToolService
	Location: ServerStorage.Gaxia_Packages_Server.Lib.ToolService
	Purpose : Tool lifecycle helpers with anti-duplication via a UID attribute.
	          Each new tool gets a unique GUID; if another tool with the same
	          UID ever appears, it is destroyed and OnDuplicate fires.
]]


-- ── Services ──
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")

-- ── Dependencies ──
-- Keep this list free of AntiCheat (and of anything that requires it): the
-- AntiCheat detectors BackpackGuard and ToolDuplicationGuard require ToolService.
local Signal    = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle = require(script.Parent.ServiceLifecycle)

-- ── Constants ──
local UID_ATTR     : string = "UID"
local ITEM_ID_ATTR : string = "ItemId"

-- ── Module ──
local ToolService = {}

-- (tool) when a duplicate UID is detected — fired just before the duplicate is destroyed
ToolService.OnDuplicate = Signal.new() :: Signal.Signal<Tool>

-- UID → Tool registry. WeakValues so destroyed tools self-evict.
local trackedTools: { [string]: Tool } = setmetatable({}, { __mode = "v" }) :: any

-- ── Helpers ──

-- Generate a unique identifier. GenerateGUID returns 32-hex w/o braces (38 chars w/ braces).
local function newUID(): string
	return HttpService:GenerateGUID(false)
end

-- Apply user-supplied props to the tool. Wrap in pcall so a bad property name
-- (e.g. removed in a future Roblox release) does not poison the constructor.
local function applyProps(tool: Tool, props: { [string]: any })
	for key, value in pairs(props) do
		pcall(function() (tool :: any)[key] = value end)
	end
end

-- ── Public API ──

-- Create a fresh Tool with a unique UID + ItemId. Returns the Tool unparented.
function ToolService.Create(itemId: string, props: { [string]: any }?): Tool
	assert(typeof(itemId) == "string" and #itemId > 0, "itemId must be non-empty string")
	local tool = Instance.new("Tool")
	tool.Name = itemId
	tool:SetAttribute(ITEM_ID_ATTR, itemId)
	tool:SetAttribute(UID_ATTR, newUID())
	if props then applyProps(tool, props) end
	ToolService.Track(tool)
	return tool
end

-- Create + parent to player.Backpack so it appears in their hotbar immediately.
function ToolService.Give(player: Player, itemId: string, props: { [string]: any }?): Tool?
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then return nil end
	local tool = ToolService.Create(itemId, props)
	tool.Parent = backpack
	return tool
end

-- Register a tool in the anti-dupe registry. If its UID already exists,
-- this is the duplicate — destroy it instead of the original.
function ToolService.Track(tool: Tool): ()
	local uid = tool:GetAttribute(UID_ATTR) :: any
	if typeof(uid) ~= "string" or uid == "" then
		-- No UID yet — assign one so subsequent dupe checks have an anchor.
		uid = newUID()
		tool:SetAttribute(UID_ATTR, uid)
	end

	local existing = trackedTools[uid]
	if existing and existing ~= tool and existing.Parent ~= nil then
		-- Existing tool with same UID is alive → this one is a clone.
		ToolService.OnDuplicate:Fire(tool)
		tool:Destroy()
		return
	end

	trackedTools[uid] = tool
	-- Auto-evict when tool leaves the data model so dupes after a real loss
	-- are not flagged as duplicates of a ghost entry.
	tool.AncestryChanged:Connect(function(_, parent)
		if parent == nil and trackedTools[uid] == tool then
			trackedTools[uid] = nil
		end
	end)
end

function ToolService.IsTracked(tool: Tool): boolean
	local uid = tool:GetAttribute(UID_ATTR) :: any
	if typeof(uid) ~= "string" then return false end
	return trackedTools[uid] == tool
end

-- Pure API: nothing to set up (the registry and OnDuplicate exist as soon as the
-- module is required — AntiCheat's ToolDuplicationGuard connects to it then).
Lifecycle.Define(ToolService, {
	Name = "Tool",
	Needs = {},
})

return ToolService
