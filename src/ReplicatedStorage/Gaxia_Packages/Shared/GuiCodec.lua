--!strict
-- ─────────────────────────────────────────────────────────────
-- GuiCodec.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/GuiCodec
-- Purpose : Two-way GUI ⇄ code converter so a UI can be designed visually in
--           Studio (Instances) AND version-controlled as text. ToCode() walks a
--           GuiObject subtree and emits Luau that rebuilds it via make(className,
--           props, children) — only properties that differ from the class default
--           are written, so output stays readable. Make() is that runtime builder
--           (the code→Instance direction), so a tree round-trips: design it,
--           ToCode it into a Templates file, and Make rebuilds it identically.
--
-- Access  : Gaxia.GuiCodec  (shared)
--   local src = Gaxia.GuiCodec.ToCode(myFrame)        -- Instance -> Luau string
--   local gui = Gaxia.GuiCodec.Make("Frame", { Size = UDim2.fromScale(1,1) }, { child })
-- ─────────────────────────────────────────────────────────────
local GuiCodec = {}

-- Properties considered for emission, by relevance. Reads are pcall-guarded, so
-- listing a prop that doesn't exist on a given class is harmless.
local PROP_NAMES: { string } = {
	"Name", "Size", "Position", "AnchorPoint", "Rotation", "Visible", "ZIndex",
	"LayoutOrder", "ClipsDescendants", "BackgroundColor3", "BackgroundTransparency",
	"BorderSizePixel", "BorderColor3",
	-- text
	"Text", "TextColor3", "TextTransparency", "TextSize", "Font", "TextScaled",
	"TextWrapped", "TextXAlignment", "TextYAlignment", "PlaceholderText", "RichText",
	-- image
	"Image", "ImageColor3", "ImageTransparency", "ScaleType",
	-- buttons
	"AutoButtonColor",
	-- UI* objects
	"CornerRadius", "Padding", "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight",
	"FillDirection", "HorizontalAlignment", "VerticalAlignment", "SortOrder", "Scale",
	"Color", "Thickness", "Transparency",
}

-- ── Value → Luau literal ──

local function quote(s: string): string
	return string.format("%q", s)
end

local function lit(v: any): string?
	local t = typeof(v)
	if t == "string" then
		return quote(v)
	elseif t == "number" then
		return tostring(v)
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "EnumItem" then
		return tostring(v) -- "Enum.Font.Gotham"
	elseif t == "UDim" then
		return string.format("UDim.new(%g, %g)", v.Scale, v.Offset)
	elseif t == "UDim2" then
		return string.format("UDim2.new(%g, %g, %g, %g)", v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset)
	elseif t == "Vector2" then
		return string.format("Vector2.new(%g, %g)", v.X, v.Y)
	elseif t == "Color3" then
		return string.format("Color3.fromRGB(%d, %d, %d)",
			math.round(v.R * 255), math.round(v.G * 255), math.round(v.B * 255))
	end
	return nil -- unsupported type → skip
end

-- ── Make (code → Instance) ──

function GuiCodec.Make(className: string, props: { [string]: any }?, children: { Instance }?): Instance
	local inst = Instance.new(className)
	if props then
		for k, v in pairs(props) do
			pcall(function()
				(inst :: any)[k] = v
			end)
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	return inst
end

-- ── ToCode (Instance → Luau) ──

-- One unparented default Instance per class (nil = class could not be created;
-- not cached, so it is retried next time).
local defaults: { [string]: Instance? } = {}
local function defaultFor(className: string): Instance?
	if defaults[className] == nil then
		local ok, inst = pcall(Instance.new, className)
		defaults[className] = if ok then inst else nil
	end
	return defaults[className]
end

local function changedProps(inst: Instance): { { name: string, value: string } }
	local out: { { name: string, value: string } } = {}
	local def = defaultFor(inst.ClassName)
	for _, name in ipairs(PROP_NAMES) do
		local ok, value = pcall(function()
			return (inst :: any)[name]
		end)
		if ok and value ~= nil then
			local isDefault = false
			if def then
				local dok, dval = pcall(function()
					return (def :: any)[name]
				end)
				if dok and dval == value then
					isDefault = true
				end
			end
			if not isDefault then
				local serialized = lit(value)
				if serialized then
					table.insert(out, { name = name, value = serialized })
				end
			end
		end
	end
	return out
end

local function emit(inst: Instance, indent: number, lines: { string }): ()
	-- Built with plain concatenation, not backtick interpolation: Luau interp
	-- strings treat `{`/`}` as expression delimiters, so emitting literal Luau
	-- table braces must avoid them.
	local pad = string.rep("\t", indent)
	local props = changedProps(inst)

	local guiChildren: { Instance } = {}
	for _, c in ipairs(inst:GetChildren()) do
		if c:IsA("GuiObject") or c:IsA("UIComponent") or c:IsA("UIBase") then
			table.insert(guiChildren, c)
		end
	end

	local propParts: { string } = {}
	for _, p in ipairs(props) do
		table.insert(propParts, p.name .. " = " .. p.value)
	end
	local propStr = "{ " .. table.concat(propParts, ", ") .. " }"
	local head = pad .. 'make("' .. inst.ClassName .. '", ' .. propStr

	if #guiChildren == 0 then
		table.insert(lines, head .. ")")
		return
	end

	table.insert(lines, head .. ", {")
	for i, child in ipairs(guiChildren) do
		emit(child, indent + 1, lines)
		if i < #guiChildren then
			lines[#lines] = lines[#lines] .. ","
		end
	end
	table.insert(lines, pad .. "})")
end

-- Emit Luau source that rebuilds `root` via a `make(className, props, children)`
-- helper. `opts.varName` names the returned local (default "root").
function GuiCodec.ToCode(root: Instance, opts: { varName: string? }?): string
	local lines: { string } = {}
	emit(root, 0, lines)
	local body = table.concat(lines, "\n")
	local var = (opts and opts.varName) or "root"
	return `local {var} = {body}\nreturn {var}`
end

return GuiCodec
