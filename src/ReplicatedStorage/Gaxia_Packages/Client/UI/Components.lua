--!strict
-- ─────────────────────────────────────────────────────────────
-- Components.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/Components
-- Purpose : Themed UI widget kit. Every game re-hand-rolled Buttons / toggles /
--           sliders / dropdowns / text fields / tabs / modals / scroll lists
--           with literal colors and copy-pasted drag math. These factories
--           return real Instances styled from Gaxia.Theme tokens (so a reskin
--           is one SetTheme call) with the fiddly behaviour (knob drag, hover
--           feedback, list virtualization) written once and verified.
--
-- Access  : Gaxia.UI.Components  (client)
--   local btn = Gaxia.UI.Components.Button({ Text = "Play", OnClick = start })
--   local t   = Gaxia.UI.Components.Toggle({ Value = true, OnChanged = print })
--   local s   = Gaxia.UI.Components.Slider({ Min = 0, Max = 100, Value = 30 })
--   local list= Gaxia.UI.Components.ScrollList({ Items = data, ItemHeight = 40,
--                 Render = function(item, i, frame) ... end })   -- virtualized
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")

-- ── Handle types (controllers returned by stateful widgets) ──
export type Toggle = { Instance: GuiObject, Get: () -> boolean, Set: (v: boolean) -> () }
export type Slider = { Instance: GuiObject, Get: () -> number, Set: (v: number) -> () }
export type Dropdown = { Instance: GuiObject, Get: () -> string, Set: (v: string) -> () }
export type Tabs = { Instance: GuiObject, GetActive: () -> number, Select: (i: number) -> () }
export type ScrollList = { Instance: ScrollingFrame, SetItems: (items: { any }) -> (), Refresh: () -> () }
export type Modal = { Instance: GuiObject, Close: () -> () }

-- ── Server stub (UI is meaningless off the client) ──
if not RunService:IsClient() then
	local nilGui = function(): any return nil end
	return ({
		Button = nilGui, Toggle = nilGui, Slider = nilGui, TextInput = nilGui,
		Dropdown = nilGui, Tabs = nilGui, ScrollList = nilGui, Modal = nilGui,
	} :: any)
end

-- ── Client implementation ──
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Theme = require(script.Parent.Parent.Parent.Shared.Theme)

local Components = {}

local QUICK = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ── Internal helpers ──
local function corner(inst: Instance, radius: number): ()
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function pad(inst: Instance, amount: number): ()
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, amount)
	p.PaddingBottom = UDim.new(0, amount)
	p.PaddingLeft = UDim.new(0, amount)
	p.PaddingRight = UDim.new(0, amount)
	p.Parent = inst
end

local function lighten(c: Color3, amt: number): Color3
	return Color3.new(
		math.clamp(c.R + amt, 0, 1),
		math.clamp(c.G + amt, 0, 1),
		math.clamp(c.B + amt, 0, 1)
	)
end

-- ── Button ──
export type ButtonProps = {
	Text: string?, Size: UDim2?, Position: UDim2?, Parent: Instance?,
	OnClick: (() -> ())?, Variant: string?,
}
function Components.Button(props: ButtonProps): TextButton
	local variant = props.Variant or "primary"
	local base = if variant == "danger" then Theme.Color("Danger")
		elseif variant == "surface" then Theme.Color("Surface")
		else Theme.Color("Primary")

	local btn = Instance.new("TextButton")
	btn.Name = "GaxButton"
	btn.Size = props.Size or UDim2.fromOffset(160, 44)
	btn.Position = props.Position or UDim2.new()
	btn.BackgroundColor3 = base
	btn.AutoButtonColor = false
	btn.Text = props.Text or "Button"
	btn.Font = Theme.Get().Font.Bold
	btn.TextSize = 18
	btn.TextColor3 = Theme.Color("Text")
	corner(btn, Theme.Radius("M"))

	btn.MouseEnter:Connect(function()
		TweenService:Create(btn, QUICK, { BackgroundColor3 = lighten(base, 0.08) }):Play()
	end)
	btn.MouseLeave:Connect(function()
		TweenService:Create(btn, QUICK, { BackgroundColor3 = base }):Play()
	end)
	if props.OnClick then
		btn.Activated:Connect(props.OnClick)
	end
	btn.Parent = props.Parent
	return btn
end

-- ── Toggle (sliding switch) ──
export type ToggleProps = {
	Value: boolean?, Size: UDim2?, Position: UDim2?, Parent: Instance?, OnChanged: ((v: boolean) -> ())?,
}
function Components.Toggle(props: ToggleProps): Toggle
	local state = props.Value == true

	local track = Instance.new("TextButton")
	track.Name = "GaxToggle"
	track.Size = props.Size or UDim2.fromOffset(56, 28)
	track.Position = props.Position or UDim2.new()
	track.AutoButtonColor = false
	track.Text = ""
	track.BackgroundColor3 = if state then Theme.Color("Success") else Theme.Color("Surface")
	corner(track, 999)

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.Size = UDim2.fromOffset(22, 22)
	knob.Position = if state then UDim2.new(1, -25, 0.5, -11) else UDim2.new(0, 3, 0.5, -11)
	knob.BackgroundColor3 = Theme.Color("Text")
	corner(knob, 999)
	knob.Parent = track

	local handle = {} :: Toggle
	handle.Instance = track
	handle.Get = function(): boolean
		return state
	end
	handle.Set = function(v: boolean): ()
		state = v
		TweenService:Create(track, QUICK, {
			BackgroundColor3 = if v then Theme.Color("Success") else Theme.Color("Surface"),
		}):Play()
		TweenService:Create(knob, QUICK, {
			Position = if v then UDim2.new(1, -25, 0.5, -11) else UDim2.new(0, 3, 0.5, -11),
		}):Play()
		if props.OnChanged then
			props.OnChanged(v)
		end
	end
	track.Activated:Connect(function()
		handle.Set(not state)
	end)
	track.Parent = props.Parent
	return handle
end

-- ── Slider ──
export type SliderProps = {
	Min: number, Max: number, Value: number?, Step: number?,
	Size: UDim2?, Position: UDim2?, Parent: Instance?, OnChanged: ((v: number) -> ())?,
}
function Components.Slider(props: SliderProps): Slider
	local min, max = props.Min, props.Max
	local step = props.Step
	local value = math.clamp(props.Value or min, min, max)

	local root = Instance.new("Frame")
	root.Name = "GaxSlider"
	root.Size = props.Size or UDim2.fromOffset(200, 24)
	root.Position = props.Position or UDim2.new()
	root.BackgroundTransparency = 1

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, 0, 0, 6)
	track.Position = UDim2.new(0, 0, 0.5, -3)
	track.BackgroundColor3 = Theme.Color("Surface")
	corner(track, 999)
	track.Parent = root

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Theme.Color("Primary")
	corner(fill, 999)
	fill.Parent = track

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.Size = UDim2.fromOffset(18, 18)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.BackgroundColor3 = Theme.Color("Text")
	corner(knob, 999)
	knob.Parent = root

	local function alpha(): number
		return if max > min then (value - min) / (max - min) else 0
	end
	local function redraw(): ()
		local a = alpha()
		fill.Size = UDim2.new(a, 0, 1, 0)
		knob.Position = UDim2.new(a, 0, 0.5, 0)
	end

	local handle = {} :: Slider
	handle.Instance = root
	handle.Get = function(): number
		return value
	end
	handle.Set = function(v: number): ()
		v = math.clamp(v, min, max)
		if step and step > 0 then
			v = min + math.floor((v - min) / step + 0.5) * step
			v = math.clamp(v, min, max)
		end
		value = v
		redraw()
		if props.OnChanged then
			props.OnChanged(v)
		end
	end
	redraw()

	-- Drag: clicking/dragging anywhere on the track sets the value from mouse X.
	local dragging = false
	local function setFromX(px: number): ()
		local rel = (px - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1)
		handle.Set(min + math.clamp(rel, 0, 1) * (max - min))
	end
	track.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	root.Parent = props.Parent
	return handle
end

-- ── TextInput ──
export type TextInputProps = {
	Placeholder: string?, Text: string?, Size: UDim2?, Position: UDim2?, Parent: Instance?,
	OnChanged: ((text: string) -> ())?, OnSubmit: ((text: string, enter: boolean) -> ())?, ClearTextOnFocus: boolean?,
}
function Components.TextInput(props: TextInputProps): TextBox
	local box = Instance.new("TextBox")
	box.Name = "GaxTextInput"
	box.Size = props.Size or UDim2.fromOffset(220, 40)
	box.Position = props.Position or UDim2.new()
	box.BackgroundColor3 = Theme.Color("Surface")
	box.Text = props.Text or ""
	box.PlaceholderText = props.Placeholder or ""
	box.PlaceholderColor3 = Theme.Color("TextMuted")
	box.TextColor3 = Theme.Color("Text")
	box.Font = Theme.Get().Font.Regular
	box.TextSize = 16
	box.ClearTextOnFocus = props.ClearTextOnFocus == true
	box.TextXAlignment = Enum.TextXAlignment.Left
	corner(box, Theme.Radius("M"))
	pad(box, Theme.Spacing("M"))

	if props.OnChanged then
		box:GetPropertyChangedSignal("Text"):Connect(function()
			props.OnChanged(box.Text)
		end)
	end
	if props.OnSubmit then
		box.FocusLost:Connect(function(enter: boolean)
			props.OnSubmit(box.Text, enter)
		end)
	end
	box.Parent = props.Parent
	return box
end

-- ── Dropdown ──
export type DropdownProps = {
	Options: { string }, Value: string?, Size: UDim2?, Position: UDim2?, Parent: Instance?,
	OnChanged: ((v: string) -> ())?,
}
function Components.Dropdown(props: DropdownProps): Dropdown
	local options = props.Options
	local value = props.Value or options[1] or ""

	local root = Instance.new("Frame")
	root.Name = "GaxDropdown"
	root.Size = props.Size or UDim2.fromOffset(200, 40)
	root.Position = props.Position or UDim2.new()
	root.BackgroundTransparency = 1

	local header = Instance.new("TextButton")
	header.Size = UDim2.new(1, 0, 1, 0)
	header.BackgroundColor3 = Theme.Color("Surface")
	header.AutoButtonColor = false
	header.Text = value
	header.Font = Theme.Get().Font.Medium
	header.TextSize = 16
	header.TextColor3 = Theme.Color("Text")
	corner(header, Theme.Radius("M"))
	pad(header, Theme.Spacing("M"))
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Parent = root

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Position = UDim2.new(0, 0, 1, 4)
	list.Size = UDim2.new(1, 0, 0, #options * 34)
	list.BackgroundColor3 = Theme.Color("BackgroundDeep")
	list.Visible = false
	list.ZIndex = 5
	corner(list, Theme.Radius("M"))
	list.Parent = root
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	-- Open/close also raises/restores the ROOT's ZIndex. Under the default
	-- ZIndexBehavior=Sibling, the root competes with its siblings (the form's
	-- other rows and the Run/Back buttons): with equal ZIndex, later-created
	-- siblings paint over AND click-shadow the open list — clicking an option
	-- toggled the next dropdown or fired the Run button instead.
	local baseZIndex = root.ZIndex
	local function setOpen(open: boolean): ()
		list.Visible = open
		root.ZIndex = if open then baseZIndex + 100 else baseZIndex
	end

	local handle = {} :: Dropdown
	handle.Instance = root
	handle.Get = function(): string
		return value
	end
	handle.Set = function(v: string): ()
		value = v
		header.Text = v
		if props.OnChanged then
			props.OnChanged(v)
		end
	end

	for i, opt in ipairs(options) do
		local item = Instance.new("TextButton")
		item.Size = UDim2.new(1, 0, 0, 34)
		item.LayoutOrder = i
		item.BackgroundColor3 = Theme.Color("BackgroundDeep")
		item.AutoButtonColor = true
		item.Text = opt
		item.Font = Theme.Get().Font.Regular
		item.TextSize = 15
		item.TextColor3 = Theme.Color("Text")
		item.ZIndex = 6
		item.Parent = list
		item.Activated:Connect(function()
			setOpen(false)
			handle.Set(opt)
		end)
	end

	header.Activated:Connect(function()
		setOpen(not list.Visible)
	end)
	root.Parent = props.Parent
	return handle
end

-- ── Tabs ──
export type TabsProps = {
	Tabs: { string }, Active: number?, Size: UDim2?, Position: UDim2?, Parent: Instance?,
	OnChanged: ((index: number, name: string) -> ())?,
}
function Components.Tabs(props: TabsProps): Tabs
	local names = props.Tabs
	local active = props.Active or 1

	local root = Instance.new("Frame")
	root.Name = "GaxTabs"
	root.Size = props.Size or UDim2.fromOffset(#names * 110, 38)
	root.Position = props.Position or UDim2.new()
	root.BackgroundTransparency = 1
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, Theme.Spacing("XS"))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = root

	local buttons: { TextButton } = {}
	local handle = {} :: Tabs
	handle.Instance = root
	handle.GetActive = function(): number
		return active
	end
	local function restyle(): ()
		for i, b in ipairs(buttons) do
			local on = i == active
			TweenService:Create(b, QUICK, {
				BackgroundColor3 = if on then Theme.Color("Primary") else Theme.Color("Surface"),
			}):Play()
			b.TextColor3 = if on then Theme.Color("Text") else Theme.Color("TextMuted")
		end
	end
	handle.Select = function(i: number): ()
		if i < 1 or i > #names or i == active then
			return
		end
		active = i
		restyle()
		if props.OnChanged then
			props.OnChanged(i, names[i])
		end
	end

	for i, name in ipairs(names) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(106, 38)
		b.LayoutOrder = i
		b.AutoButtonColor = false
		b.Text = name
		b.Font = Theme.Get().Font.Medium
		b.TextSize = 16
		b.BackgroundColor3 = Theme.Color("Surface")
		b.TextColor3 = Theme.Color("TextMuted")
		corner(b, Theme.Radius("M"))
		b.Activated:Connect(function()
			handle.Select(i)
		end)
		b.Parent = root
		buttons[i] = b
	end
	restyle()
	root.Parent = props.Parent
	return handle
end

-- ── ScrollList (virtualized — pool size is bound by the viewport, not #items) ──
export type ScrollListProps = {
	Items: { any }, ItemHeight: number, Render: (item: any, index: number, frame: Frame) -> (),
	Size: UDim2?, Position: UDim2?, Parent: Instance?,
}
function Components.ScrollList(props: ScrollListProps): ScrollList
	local itemHeight = props.ItemHeight
	local items = props.Items

	local sf = Instance.new("ScrollingFrame")
	sf.Name = "GaxScrollList"
	sf.Size = props.Size or UDim2.fromOffset(280, 320)
	sf.Position = props.Position or UDim2.new()
	sf.BackgroundColor3 = Theme.Color("BackgroundDeep")
	sf.BorderSizePixel = 0
	sf.ScrollBarThickness = 6
	sf.CanvasSize = UDim2.fromOffset(0, #items * itemHeight)
	corner(sf, Theme.Radius("M"))

	local pool: { Frame } = {}
	local function poolSize(): number
		return math.ceil(sf.AbsoluteSize.Y / itemHeight) + 2
	end

	local function ensurePool(): ()
		local want = poolSize()
		while #pool < want do
			local f = Instance.new("Frame")
			f.Size = UDim2.new(1, 0, 0, itemHeight)
			f.BackgroundTransparency = 1
			f.Visible = false
			f.Parent = sf
			table.insert(pool, f)
		end
	end

	local function reflow(): ()
		ensurePool()
		local first = math.max(0, math.floor(sf.CanvasPosition.Y / itemHeight))
		for i, f in ipairs(pool) do
			local dataIndex = first + i -- 1-based data index
			if dataIndex <= #items then
				f.Position = UDim2.fromOffset(0, (dataIndex - 1) * itemHeight)
				f.Visible = true
				props.Render(items[dataIndex], dataIndex, f)
			else
				f.Visible = false
			end
		end
	end

	local handle = {} :: ScrollList
	handle.Instance = sf
	handle.Refresh = reflow
	handle.SetItems = function(newItems: { any }): ()
		items = newItems
		sf.CanvasSize = UDim2.fromOffset(0, #items * itemHeight)
		reflow()
	end

	sf:GetPropertyChangedSignal("CanvasPosition"):Connect(reflow)
	sf:GetPropertyChangedSignal("AbsoluteSize"):Connect(reflow)
	sf.Parent = props.Parent
	task.defer(reflow) -- AbsoluteSize is 0 until laid out one frame
	return handle
end

-- ── Modal (scrim + centered card + button row) ──
export type ModalButton = { Text: string, OnClick: (() -> ())?, Variant: string? }
export type ModalProps = {
	Title: string?, Body: string?, Buttons: { ModalButton }?, Parent: Instance?, OnClose: (() -> ())?,
}
function Components.Modal(props: ModalProps): Modal
	local scrim = Instance.new("TextButton")
	scrim.Name = "GaxModalScrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 0.45
	scrim.AutoButtonColor = false
	scrim.Text = ""
	scrim.ZIndex = 50

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(360, 220)
	card.BackgroundColor3 = Theme.Color("Background")
	card.ZIndex = 51
	corner(card, Theme.Radius("L"))
	pad(card, Theme.Spacing("L"))
	card.Parent = scrim

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, Theme.Spacing("M"))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = card

	local title = Instance.new("TextLabel")
	title.LayoutOrder = 1
	title.Size = UDim2.new(1, 0, 0, 32)
	title.BackgroundTransparency = 1
	title.Text = props.Title or ""
	title.Font = Theme.Get().Font.Bold
	title.TextSize = 22
	title.TextColor3 = Theme.Color("Text")
	title.ZIndex = 52
	title.Parent = card

	local body = Instance.new("TextLabel")
	body.LayoutOrder = 2
	body.Size = UDim2.new(1, 0, 1, -84)
	body.BackgroundTransparency = 1
	body.Text = props.Body or ""
	body.Font = Theme.Get().Font.Regular
	body.TextSize = 16
	body.TextWrapped = true
	body.TextColor3 = Theme.Color("TextMuted")
	body.ZIndex = 52
	body.Parent = card

	local handle = {} :: Modal
	handle.Instance = scrim
	handle.Close = function(): ()
		scrim:Destroy()
		if props.OnClose then
			props.OnClose()
		end
	end

	local row = Instance.new("Frame")
	row.LayoutOrder = 3
	row.Size = UDim2.new(1, 0, 0, 44)
	row.BackgroundTransparency = 1
	row.ZIndex = 52
	row.Parent = card
	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	rowLayout.Padding = UDim.new(0, Theme.Spacing("S"))
	rowLayout.Parent = row

	for i, def in ipairs(props.Buttons or { { Text = "OK" } }) do
		local b = Components.Button({
			Text = def.Text,
			Size = UDim2.fromOffset(120, 40),
			Variant = def.Variant,
			Parent = row,
		})
		b.LayoutOrder = i
		b.ZIndex = 53
		b.Activated:Connect(function()
			if def.OnClick then
				def.OnClick()
			end
			handle.Close()
		end)
	end

	scrim.Parent = props.Parent
	return handle
end

return Components
