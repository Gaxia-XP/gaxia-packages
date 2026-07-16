--!strict
-- ─────────────────────────────────────────────────────────────
-- Reflection.lua
-- Location: plugin/src/Reflection
-- Purpose : Curated property knowledge for GUI classes. Provides
--           non-default property diff + attribute capture so the
--           Serializer only emits what an author actually changed.
--
-- Why curated: Roblox exposes no runtime "list all settable properties"
-- API for instances. We hand-list the props that matter for UI work
-- (covers the common case) and fall back to the GuiObject base for
-- unrecognised classes — partial output, not a crash.
-- ─────────────────────────────────────────────────────────────

local Reflection = {}

export type PropEntry = { name: string, value: any }

-- ── Property catalog ────────────────────────────────────────
-- Per-class list of property names to consider. We manually compose
-- GuiObject base into each concrete class — explicit beats clever for
-- a curated list.

local GUI_OBJECT_BASE: { string } = {
	"Name", "Size", "Position", "AnchorPoint", "Rotation",
	"BackgroundColor3", "BackgroundTransparency", "BorderSizePixel",
	"BorderColor3", "BorderMode",
	"Visible", "ZIndex", "LayoutOrder", "ClipsDescendants",
	"Active", "AutomaticSize", "SizeConstraint",
}

local TEXT_PROPS: { string } = {
	"Text", "TextColor3", "TextSize", "FontFace",
	"TextXAlignment", "TextYAlignment",
	"TextWrapped", "TextScaled", "TextTruncate", "RichText",
	"TextTransparency", "TextStrokeColor3", "TextStrokeTransparency",
	"LineHeight",
}

local BUTTON_PROPS: { string } = { "AutoButtonColor", "Modal", "Selected", "Style" }

local IMAGE_PROPS: { string } = {
	"Image", "ImageColor3", "ImageTransparency", "ImageRectOffset", "ImageRectSize",
	"ScaleType", "SliceCenter", "SliceScale", "TileSize", "ResampleMode",
}

local SCROLL_PROPS: { string } = {
	"CanvasSize", "CanvasPosition", "AutomaticCanvasSize", "ScrollBarThickness",
	"ScrollingDirection", "ScrollBarImageColor3", "ScrollBarImageTransparency",
	"ElasticBehavior", "VerticalScrollBarInset", "HorizontalScrollBarInset",
	"VerticalScrollBarPosition",
}

local function concat(...: { string }): { string }
	local out: { string } = {}
	for _, list in ipairs({...}) do
		for _, name in ipairs(list) do
			table.insert(out, name)
		end
	end
	return out
end

local CATALOG: { [string]: { string } } = {
	-- Folder: not a GuiObject, but devs routinely use Folders to GROUP UI
	-- (ScreenGui > Folder "Buttons" > TextButtons). Listing it here makes the
	-- Serializer treat it as a known container — it is emitted (Name only) AND
	-- recursed into, instead of being skipped with its whole subtree lost.
	Folder             = { "Name" },
	Frame              = GUI_OBJECT_BASE,
	ScrollingFrame     = concat(GUI_OBJECT_BASE, SCROLL_PROPS),
	TextLabel          = concat(GUI_OBJECT_BASE, TEXT_PROPS),
	TextButton         = concat(GUI_OBJECT_BASE, TEXT_PROPS, BUTTON_PROPS),
	TextBox            = concat(GUI_OBJECT_BASE, TEXT_PROPS, {
		"ClearTextOnFocus", "MultiLine", "PlaceholderColor3", "PlaceholderText",
		"ShowNativeInput", "TextEditable",
	}),
	ImageLabel         = concat(GUI_OBJECT_BASE, IMAGE_PROPS),
	ImageButton        = concat(GUI_OBJECT_BASE, IMAGE_PROPS, BUTTON_PROPS),
	ViewportFrame      = concat(GUI_OBJECT_BASE, {
		"Ambient", "LightColor", "LightDirection", "CurrentCamera",
		"ImageColor3", "ImageTransparency",
	}),
	VideoFrame         = concat(GUI_OBJECT_BASE, { "Video", "Playing", "Looped", "Volume", "TimePosition" }),
	CanvasGroup        = concat(GUI_OBJECT_BASE, { "GroupColor3", "GroupTransparency" }),
	ScreenGui          = { "Name", "ResetOnSpawn", "IgnoreGuiInset", "Enabled", "DisplayOrder", "ZIndexBehavior" },
	-- UI* helper instances (no GuiObject inheritance — flat, small lists)
	UICorner           = { "Name", "CornerRadius" },
	UIPadding          = { "Name", "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" },
	UIListLayout       = { "Name", "FillDirection", "HorizontalAlignment", "VerticalAlignment",
		"Padding", "SortOrder", "Wraps" },
	UIGridLayout       = { "Name", "CellSize", "CellPadding", "FillDirection", "FillDirectionMaxCells",
		"HorizontalAlignment", "VerticalAlignment", "SortOrder", "StartCorner" },
	UIStroke           = { "Name", "Color", "Thickness", "Transparency", "ApplyStrokeMode", "LineJoinMode" },
	UIGradient         = { "Name", "Color", "Transparency", "Offset", "Rotation", "Enabled" },
	UIAspectRatioConstraint = { "Name", "AspectRatio", "AspectType", "DominantAxis" },
	UISizeConstraint   = { "Name", "MinSize", "MaxSize" },
	UITextSizeConstraint = { "Name", "MinTextSize", "MaxTextSize" },
}

-- ── Default cache: one fresh Instance.new(class) per class. ─
local defaultCache: { [string]: Instance } = {}
local function getDefault(class: string): Instance?
	local cached = defaultCache[class]
	if cached then return cached end
	local ok, inst = pcall(Instance.new, class)
	if not ok then return nil end
	defaultCache[class] = inst
	return inst
end

-- Plain `==` covers every Roblox value type we list in the catalog
-- (Color3/UDim2/Vector2/EnumItem/etc. all implement value-equality).
local function valEq(a: any, b: any): boolean
	return a == b
end

-- ── Public API ─────────────────────────────────────────────

function Reflection.isKnown(class: string): boolean
	return CATALOG[class] ~= nil
end

-- Return the property list this class will be diffed against (falls back to
-- GuiObject base on unknown class — partial coverage, not a crash).
function Reflection.propsFor(class: string): { string }
	return CATALOG[class] or GUI_OBJECT_BASE
end

-- Read all currently-set attributes as a sorted list (deterministic emit order).
function Reflection.attributes(inst: Instance): { PropEntry }
	local out: { PropEntry } = {}
	for name, value in pairs(inst:GetAttributes()) do
		table.insert(out, { name = name, value = value })
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- Return only the properties of `inst` whose values differ from a fresh
-- Instance.new(inst.ClassName). Skips `Name` if it equals the class name
-- (the default "Frame"/"TextLabel"/... name).
function Reflection.diff(inst: Instance): { PropEntry }
	local class = inst.ClassName
	local default = getDefault(class)
	local props = Reflection.propsFor(class)
	local out: { PropEntry } = {}

	for _, name in ipairs(props) do
		local ok, gotVal = pcall(function() return (inst :: any)[name] end)
		if not ok then continue end
		local defVal: any = nil
		if default then
			local okD, dv = pcall(function() return (default :: any)[name] end)
			if okD then defVal = dv end
		end
		if name == "Name" and gotVal == class then continue end
		if not valEq(gotVal, defVal) then
			table.insert(out, { name = name, value = gotVal })
		end
	end
	return out
end

return Reflection
