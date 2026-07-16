--!strict
-- ─────────────────────────────────────────────────────────────
-- Router.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/Router
-- Purpose : Screen-stack navigator + unified z-ordering. Register named screens
--           (a builder that returns the content GuiObject), then Push/Pop/
--           Replace them. Each screen lives in its own ScreenGui with an
--           ascending DisplayOrder, so the stack order IS the visual order —
--           fixing the ad-hoc DisplayOrder z-fighting (Tooltip=1000, Cutscene
--           =500, Dialog unset). The top of the stack is always on top.
--
-- Access  : Gaxia.UI.Router  (client)
--   Gaxia.UI.Router.Register("Shop", function() return buildShopFrame() end)
--   Gaxia.UI.Router.Push("Shop")   ;   Gaxia.UI.Router.Pop()
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local BASE_DISPLAY_ORDER : number = 100

export type Router = {
	Register: (name: string, builder: (props: any) -> Instance) -> (),
	Push: (name: string, props: any?) -> Instance?,
	Pop: () -> (),
	Replace: (name: string, props: any?) -> Instance?,
	Clear: () -> (),
	Current: () -> string?,
	IsOpen: (name: string) -> boolean,
	Depth: () -> number,
}

if not RunService:IsClient() then
	return ({
		Register = function() end,
		Push = function() return nil end,
		Pop = function() end,
		Replace = function() return nil end,
		Clear = function() end,
		Current = function() return nil end,
		IsOpen = function() return false end,
		Depth = function() return 0 end,
	} :: any) :: Router
end

local Router = {}

local builders: { [string]: (props: any) -> Instance } = {}
type Entry = { name: string, gui: ScreenGui }
local stack: { Entry } = {}

local function playerGui(): Instance
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- ── Public API ──

function Router.Register(name: string, builder: (props: any) -> Instance): ()
	builders[name] = builder
end

function Router.Push(name: string, props: any?): Instance?
	local builder = builders[name]
	if not builder then
		warn(`[Router] no screen registered as '{name}'`)
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = `Gaxia_Route_{name}`
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = BASE_DISPLAY_ORDER + #stack
	gui.Parent = playerGui()

	local content = builder(props)
	if content then
		content.Parent = gui
	end
	table.insert(stack, { name = name, gui = gui })
	return content
end

function Router.Pop(): ()
	local top = table.remove(stack)
	if top then
		top.gui:Destroy()
	end
end

function Router.Replace(name: string, props: any?): Instance?
	Router.Pop()
	return Router.Push(name, props)
end

function Router.Clear(): ()
	while #stack > 0 do
		Router.Pop()
	end
end

function Router.Current(): string?
	local top = stack[#stack]
	return top and top.name
end

function Router.IsOpen(name: string): boolean
	for _, e in ipairs(stack) do
		if e.name == name then
			return true
		end
	end
	return false
end

function Router.Depth(): number
	return #stack
end

return Router
