--!strict
-- ─────────────────────────────────────────────────────────────
-- Panel.lua
-- Location: plugin/src/Panel
-- Purpose : Self-contained dock-widget UI for the Gaxia Companion.
--           Instance.new only (no Gaxia.UI dependency — Gaxia may
--           not be installed in the open place yet). Exposes a
--           `create(parent, callbacks)` factory that returns a
--           handle with `:setStatus(text, level)`.
--
-- Layout   : a fixed tab bar (Convert / Build / Install) + a fixed
--            status line bracket a flexible content area. Only one
--            page is visible at a time and its code box grows
--            (UIFlexItem) to fill leftover space, so the widget is
--            usable at ANY size — no need to enlarge it to reach a
--            feature that would otherwise sit below the fold.
-- ─────────────────────────────────────────────────────────────

local Panel = {}

local PADDING = 8
local TAB_H = 28
local STATUS_H = 16
local GAP = 6

local COLORS = {
	bg     = Color3.fromRGB(30, 30, 32),
	panel  = Color3.fromRGB(48, 48, 52),
	editor = Color3.fromRGB(24, 24, 26),
	text   = Color3.fromRGB(220, 220, 220),
	muted  = Color3.fromRGB(140, 140, 140),
	accent = Color3.fromRGB(70, 130, 200),
	ok     = Color3.fromRGB(95, 180, 110),
	err    = Color3.fromRGB(220, 100, 100),
}

-- Non-UI instance classes the user can choose to skip during conversion (UI is
-- always kept). Order here = display order in the Settings tab.
local SKIP_CLASSES = {
	{ class = "Folder", label = "Skip Folders" },
	{ class = "LocalScript", label = "Skip LocalScripts" },
	{ class = "ModuleScript", label = "Skip ModuleScripts" },
	{ class = "Script", label = "Skip Scripts" },
}

local function corner(inst: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function newButton(text: string, parent: Instance, order: number): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 28)
	b.BackgroundColor3 = COLORS.accent
	b.TextColor3 = COLORS.text
	b.Text = text
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 14
	b.AutoButtonColor = true
	b.LayoutOrder = order
	b.Parent = parent
	corner(b, 4)
	return b
end

-- Wrapping, auto-growing hint label so long copy stays readable in a narrow
-- widget instead of clipping.
local function newHint(text: string, parent: Instance, order: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, 14)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.BackgroundTransparency = 1
	l.TextColor3 = COLORS.muted
	l.Text = text
	l.Font = Enum.Font.Gotham
	l.TextSize = 12
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.LayoutOrder = order
	l.Parent = parent
	return l
end

-- Scrollable code box: a ScrollingFrame holding a TextBox that auto-grows to fit
-- its content. The frame clips the box's natural overflow (a TextBox does NOT clip
-- by itself — long content draws OUTSIDE its bounds and overlaps neighbours). A
-- UIFlexItem(Fill) makes the box grow to occupy leftover vertical space in its page.
local function newCodeBox(parent: Instance, order: number, placeholder: string): (ScrollingFrame, TextBox)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, 0, 0, 60) -- base height; UIFlexItem grows it to fill
	scroll.BackgroundColor3 = COLORS.editor
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = COLORS.muted
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.XY
	scroll.ScrollingDirection = Enum.ScrollingDirection.XY
	scroll.ClipsDescendants = true
	scroll.LayoutOrder = order
	scroll.Parent = parent
	corner(scroll, 4)

	local flex = Instance.new("UIFlexItem")
	flex.FlexMode = Enum.UIFlexMode.Fill
	flex.Parent = scroll

	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, 0, 0, 0)
	box.AutomaticSize = Enum.AutomaticSize.XY
	box.MultiLine = true
	box.ClearTextOnFocus = false
	box.TextEditable = true
	box.TextWrapped = false
	box.BackgroundTransparency = 1
	box.TextColor3 = COLORS.text
	box.Font = Enum.Font.Code
	box.TextSize = 12
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.PlaceholderText = placeholder
	box.Text = ""
	box.Parent = scroll
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, 4); p.PaddingBottom = UDim.new(0, 4)
	p.PaddingLeft = UDim.new(0, 6); p.PaddingRight = UDim.new(0, 6)
	p.Parent = box

	return scroll, box
end

-- One tab button in the top tab bar. Equal width via UIFlexItem(Fill).
local function newTab(text: string, parent: Instance): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 0, 1, 0)
	b.BackgroundColor3 = COLORS.panel
	b.TextColor3 = COLORS.text
	b.Text = text
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 13
	b.AutoButtonColor = false
	b.Parent = parent
	corner(b, 4)
	local flex = Instance.new("UIFlexItem")
	flex.FlexMode = Enum.UIFlexMode.Fill
	flex.Parent = b
	return b
end

-- A page (one tab's content): transparent frame filling the content area, with a
-- vertical list layout. Hidden by default; the tab switcher toggles Visible.
local function newPage(parent: Instance): Frame
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, 0, 1, 0)
	f.BackgroundTransparency = 1
	f.Visible = false
	f.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = f
	return f
end

-- A skip-toggle row: a full-width button whose label is prefixed with a check-box
-- glyph. Returns the button plus get/set for its boolean state.
local function newToggle(parent: Instance, order: number, labelText: string): (TextButton, () -> boolean, (boolean) -> ())
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 26)
	b.BackgroundColor3 = COLORS.panel
	b.TextColor3 = COLORS.text
	b.Font = Enum.Font.Gotham
	b.TextSize = 13
	b.TextXAlignment = Enum.TextXAlignment.Left
	b.AutoButtonColor = true
	b.LayoutOrder = order
	b.Parent = parent
	corner(b, 4)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.Parent = b
	local state = false
	local function render()
		b.Text = (state and "[x]   " or "[  ]   ") .. labelText
	end
	render()
	return b, function(): boolean return state end, function(v: boolean) state = v; render() end
end

export type Callbacks = {
	onSelectionToScript: () -> (),
	onInsertModule:      () -> (),
	onScriptToInstance:  () -> (),
	onUseSelectedModule: () -> (),
	onInstall:           () -> (),
	onSkipToggle:        (class: string, skip: boolean) -> (),
	getOutputText:   () -> string,
	setOutputText:   (text: string) -> (),
	getInputText:    () -> string,
	setInputText:    (text: string) -> (),
}

export type Handle = {
	setStatus: (text: string, level: string?) -> (),
	setSkip: (class: string, skip: boolean) -> (),
	gui: Frame,
}

function Panel.create(parent: Instance, cb: Callbacks): Handle
	local root = Instance.new("Frame")
	root.Size = UDim2.new(1, 0, 1, 0)
	root.BackgroundColor3 = COLORS.bg
	root.BorderSizePixel = 0
	root.Parent = parent

	local rootPad = Instance.new("UIPadding")
	rootPad.PaddingTop = UDim.new(0, PADDING); rootPad.PaddingBottom = UDim.new(0, PADDING)
	rootPad.PaddingLeft = UDim.new(0, PADDING); rootPad.PaddingRight = UDim.new(0, PADDING)
	rootPad.Parent = root

	-- ── Tab bar (top, fixed height) ──
	local tabBar = Instance.new("Frame")
	tabBar.Size = UDim2.new(1, 0, 0, TAB_H)
	tabBar.Position = UDim2.new(0, 0, 0, 0)
	tabBar.BackgroundTransparency = 1
	tabBar.Parent = root
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 4)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabBar
	local tabConvert = newTab("Convert", tabBar)
	local tabBuild = newTab("Build", tabBar)
	local tabInstall = newTab("Install", tabBar)
	local tabSettings = newTab("Settings", tabBar)

	-- ── Content area (fills the middle between tab bar and status line) ──
	local content = Instance.new("Frame")
	content.Position = UDim2.new(0, 0, 0, TAB_H + GAP)
	content.Size = UDim2.new(1, 0, 1, -(TAB_H + GAP + STATUS_H + GAP))
	content.BackgroundTransparency = 1
	content.Parent = root

	-- ── Convert page ── (actions stacked on top; code box fills the rest below)
	local convertPage = newPage(content)
	newHint("Select GUI in Explorer, then:", convertPage, 1)
	local btnSelToScript = newButton("Selection → Script", convertPage, 2)
	local btnInsertModule = newButton("Insert as ModuleScript", convertPage, 3)
	local _, outputBox = newCodeBox(convertPage, 4, "Converted Luau appears here. Ctrl+A, Ctrl+C to copy.")

	-- ── Build page ── (actions stacked on top; code box fills the rest below)
	local buildPage = newPage(content)
	newHint("Paste a Luau UI Script, or load a selected ModuleScript:", buildPage, 1)
	local btnUseSelected = newButton("Use selected ModuleScript", buildPage, 2)
	local btnRun = newButton("Script → Instance", buildPage, 3)
	local _, inputBox = newCodeBox(buildPage, 4, "return function(parent) ... end")

	-- ── Install page ──
	local installPage = newPage(content)
	newHint("Clone the Gaxia framework into this place's services:", installPage, 1)
	local btnInstall = newButton("Install / Update Gaxia in this place", installPage, 2)

	-- ── Settings page ── (skip toggles; UI classes are always kept)
	local settingsPage = newPage(content)
	newHint("Skip these instance classes when converting:", settingsPage, 0)
	local skipSetters: { [string]: (boolean) -> () } = {}
	for i, item in ipairs(SKIP_CLASSES) do
		local btn, getState, setState = newToggle(settingsPage, i, item.label)
		btn.Activated:Connect(function()
			setState(not getState())
			if cb.onSkipToggle then cb.onSkipToggle(item.class, getState()) end
		end)
		skipSetters[item.class] = setState
	end

	-- ── Status line (bottom, fixed height, anchored) ──
	local status = Instance.new("TextLabel")
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, 0, 1, 0)
	status.Size = UDim2.new(1, 0, 0, STATUS_H)
	status.BackgroundTransparency = 1
	status.TextColor3 = COLORS.muted
	status.Font = Enum.Font.Gotham
	status.TextSize = 11
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextTruncate = Enum.TextTruncate.AtEnd
	status.Text = "Ready"
	status.Parent = root

	-- ── Tab switching ──
	local pages = { Convert = convertPage, Build = buildPage, Install = installPage, Settings = settingsPage }
	local tabs = { Convert = tabConvert, Build = tabBuild, Install = tabInstall, Settings = tabSettings }
	local function selectTab(name: string)
		for n, page in pairs(pages) do
			page.Visible = (n == name)
		end
		for n, tab in pairs(tabs) do
			tab.BackgroundColor3 = (n == name) and COLORS.accent or COLORS.panel
		end
	end
	tabConvert.Activated:Connect(function() selectTab("Convert") end)
	tabBuild.Activated:Connect(function() selectTab("Build") end)
	tabInstall.Activated:Connect(function() selectTab("Install") end)
	tabSettings.Activated:Connect(function() selectTab("Settings") end)
	selectTab("Convert")

	-- ── Wire callbacks ──
	-- Closures deref cb.onX at click time, not connect time, so the caller can
	-- assign cb.onX AFTER Panel.create() returns.
	btnSelToScript.Activated:Connect(function() if cb.onSelectionToScript then cb.onSelectionToScript() end end)
	btnInsertModule.Activated:Connect(function() if cb.onInsertModule then cb.onInsertModule() end end)
	btnUseSelected.Activated:Connect(function() if cb.onUseSelectedModule then cb.onUseSelectedModule() end end)
	btnRun.Activated:Connect(function() if cb.onScriptToInstance then cb.onScriptToInstance() end end)
	btnInstall.Activated:Connect(function() if cb.onInstall then cb.onInstall() end end)

	-- ── Output/input getters/setters (back-channels) ──
	function cb.getOutputText() return outputBox.Text end
	function cb.setOutputText(text: string) outputBox.Text = text end
	function cb.getInputText() return inputBox.Text end
	function cb.setInputText(text: string) inputBox.Text = text end

	return {
		gui = root,
		setStatus = function(text: string, level: string?)
			status.Text = text
			status.TextColor3 = (level == "err" and COLORS.err)
				or (level == "ok" and COLORS.ok)
				or COLORS.muted
		end,
		setSkip = function(class: string, skip: boolean)
			local setState = skipSetters[class]
			if setState then setState(skip) end
		end,
	}
end

return Panel
