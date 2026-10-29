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
-- Layout   : a fixed tab bar (Convert / Build / Install / Settings) + a fixed
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

local function escapeRich(text: string): string
	return (string.gsub(text, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
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

-- What the Install tab's package picker needs from the plugin entry.
export type PackageInfo = {
	Name: string,
	Category: string,
	Description: string,
	Boot: boolean?,
}
export type PickerSource = {
	packages: { PackageInfo },
	presets: { [string]: { string } },
	initial: { string },
	-- Every package the pick installs (the pick + what it Requires).
	resolve: (picked: { string }) -> { string },
}

export type Callbacks = {
	onSelectionToScript: () -> (),
	onInsertModule:      () -> (),
	onScriptToInstance:  () -> (),
	onUseSelectedModule: () -> (),
	onInstall:           (picked: { string }?) -> (),
	-- The package picker's data, or nil + why (no Payload / no catalogue).
	getPickerSource:     () -> (PickerSource?, string?),
	onPickChanged:       (picked: { string }) -> (),
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

	-- ── Install page ── (presets on top; package list fills the middle; Install below)
	local installPage = newPage(content)
	newHint("Pick the packages this game uses. What they need is added automatically; nothing else is installed.", installPage, 1)
	local presetBar = Instance.new("Frame")
	presetBar.Size = UDim2.new(1, 0, 0, 24)
	presetBar.BackgroundTransparency = 1
	presetBar.LayoutOrder = 2
	presetBar.Parent = installPage
	local presetLayout = Instance.new("UIListLayout")
	presetLayout.FillDirection = Enum.FillDirection.Horizontal
	presetLayout.Padding = UDim.new(0, 4)
	presetLayout.SortOrder = Enum.SortOrder.LayoutOrder
	presetLayout.Parent = presetBar

	local list = Instance.new("ScrollingFrame")
	list.Size = UDim2.new(1, 0, 0, 60) -- base height; UIFlexItem grows it to fill
	list.BackgroundColor3 = COLORS.editor
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.ScrollBarImageColor3 = COLORS.muted
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.LayoutOrder = 3
	list.Parent = installPage
	corner(list, 4)
	local listFlex = Instance.new("UIFlexItem")
	listFlex.FlexMode = Enum.UIFlexMode.Fill
	listFlex.Parent = list
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 2)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list
	local listPad = Instance.new("UIPadding")
	listPad.PaddingTop = UDim.new(0, 4); listPad.PaddingBottom = UDim.new(0, 4)
	listPad.PaddingLeft = UDim.new(0, 6); listPad.PaddingRight = UDim.new(0, 10)
	listPad.Parent = list

	local pickSummary = newHint("", installPage, 4)
	local btnInstall = newButton("Install / Update Gaxia in this place", installPage, 5)

	-- Picker state: built the first time the Install tab opens.
	local picked: { [string]: boolean } = {}
	local pickerSource: PickerSource? = nil
	local rows: { [string]: { button: TextButton, info: PackageInfo } } = {}

	local function pickedList(): { string }
		local out: { string } = {}
		if pickerSource then
			for _, info in ipairs(pickerSource.packages) do
				if picked[info.Name] then
					table.insert(out, info.Name)
				end
			end
		end
		return out
	end

	local function renderPicker()
		local source = pickerSource
		if source == nil then return end
		local current = pickedList()
		local installedSet: { [string]: boolean } = {}
		for _, name in ipairs(source.resolve(current)) do
			installedSet[name] = true
		end
		local deps = 0
		for name, row in pairs(rows) do
			local mark
			if picked[name] then
				mark = "[x]"
				row.button.TextColor3 = COLORS.text
			elseif installedSet[name] then
				mark = "[+]"
				deps += 1
				row.button.TextColor3 = COLORS.muted
			else
				mark = "[  ]"
				row.button.TextColor3 = COLORS.muted
			end
			local boot = if row.info.Boot then "  · starts at boot" else ""
			row.button.Text = `{mark}  <b>{name}</b>{boot}\n      {escapeRich(row.info.Description)}`
		end
		pickSummary.Text = `{#current} picked · {deps} added because a picked package needs them ([+]) · Core is always installed`
	end

	local function setPick(names: { string })
		table.clear(picked)
		for _, name in ipairs(names) do
			if rows[name] then
				picked[name] = true
			end
		end
		renderPicker()
		if cb.onPickChanged then cb.onPickChanged(pickedList()) end
	end

	local function addPresetButton(label: string, order: number, names: () -> { string })
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, 0, 1, 0)
		b.BackgroundColor3 = COLORS.panel
		b.TextColor3 = COLORS.text
		b.Text = label
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 12
		b.LayoutOrder = order
		b.Parent = presetBar
		corner(b, 4)
		local flex = Instance.new("UIFlexItem")
		flex.FlexMode = Enum.UIFlexMode.Fill
		flex.Parent = b
		b.Activated:Connect(function() setPick(names()) end)
	end

	local function buildPicker(): boolean
		if pickerSource then return true end
		if not cb.getPickerSource then return false end
		local source, why = cb.getPickerSource()
		if source == nil then
			pickSummary.Text = "Package picker unavailable: " .. tostring(why)
			return false
		end
		pickerSource = source
		local order = 0
		local category = ""
		for _, info in ipairs(source.packages) do
			if info.Category ~= category then
				category = info.Category
				order += 1
				local header = Instance.new("TextLabel")
				header.Size = UDim2.new(1, 0, 0, 20)
				header.BackgroundTransparency = 1
				header.TextColor3 = COLORS.accent
				header.Font = Enum.Font.GothamMedium
				header.TextSize = 13
				header.TextXAlignment = Enum.TextXAlignment.Left
				header.Text = category
				header.LayoutOrder = order
				header.Parent = list
			end
			order += 1
			local b = Instance.new("TextButton")
			b.Size = UDim2.new(1, 0, 0, 0)
			b.AutomaticSize = Enum.AutomaticSize.Y
			b.BackgroundColor3 = COLORS.panel
			b.BackgroundTransparency = 0.4
			b.Font = Enum.Font.Gotham
			b.TextSize = 12
			b.RichText = true
			b.TextWrapped = true
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.AutoButtonColor = true
			b.LayoutOrder = order
			b.Parent = list
			corner(b, 3)
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0, 3); pad.PaddingBottom = UDim.new(0, 3)
			pad.PaddingLeft = UDim.new(0, 6)
			pad.Parent = b
			rows[info.Name] = { button = b, info = info }
			local name = info.Name
			b.Activated:Connect(function()
				if picked[name] then
					picked[name] = nil
				else
					picked[name] = true
				end
				renderPicker()
				if cb.onPickChanged then cb.onPickChanged(pickedList()) end
			end)
		end
		local presetOrder = 0
		for presetName, names in pairs(source.presets) do
			presetOrder += 1
			addPresetButton(presetName, presetOrder, function() return names end)
		end
		addPresetButton("All", 100, function()
			local all: { string } = {}
			for _, info in ipairs(source.packages) do
				table.insert(all, info.Name)
			end
			return all
		end)
		addPresetButton("None", 101, function() return {} end)
		setPick(source.initial)
		return true
	end

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
	tabInstall.Activated:Connect(function()
		selectTab("Install")
		buildPicker()
	end)
	tabSettings.Activated:Connect(function() selectTab("Settings") end)
	selectTab("Convert")

	-- ── Wire callbacks ──
	-- Closures deref cb.onX at click time, not connect time, so the caller can
	-- assign cb.onX AFTER Panel.create() returns.
	btnSelToScript.Activated:Connect(function() if cb.onSelectionToScript then cb.onSelectionToScript() end end)
	btnInsertModule.Activated:Connect(function() if cb.onInsertModule then cb.onInsertModule() end end)
	btnUseSelected.Activated:Connect(function() if cb.onUseSelectedModule then cb.onUseSelectedModule() end end)
	btnRun.Activated:Connect(function() if cb.onScriptToInstance then cb.onScriptToInstance() end end)
	btnInstall.Activated:Connect(function()
		if cb.onInstall then
			-- No catalogue (older bundle): install everything, as before.
			cb.onInstall(if buildPicker() then pickedList() else nil)
		end
	end)

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
