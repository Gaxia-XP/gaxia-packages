--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   Templates
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/Templates
-- Purpose:  Code-first builders for all 10 Gaxia_UI templates.
--           Replaces the legacy `StarterGui/Gaxia_UI/Templates.rbxm`
--           binary so every template lives in version-controllable
--           Luau source — no binary blob, diffable, refactorable.
--
-- Usage:
--   local Templates = require(.../Templates)
--   local btn = Templates.ButtonTemplate(parentInstance)
--   -- or via UIController:
--   local btn = UIController.CloneTemplate("ButtonTemplate", parent)
--
-- Every builder:
--   • Constructs the Instance tree with Instance.new
--   • Sets only non-default properties (matches the original .rbxm)
--   • Returns the root GuiObject (caller can mutate / re-parent further)
--   • Visible defaults to false (caller flips it on after staging) —
--     this preserves the original .rbxm template behavior.
-- ─────────────────────────────────────────────────────────────

-- ── Shared fonts ──
-- Keeping these as locals (not Constants) so type inference picks them up
-- as `Font` and editor auto-complete works inside builders.
local FONT_BOLD: Font = Font.new(
	"rbxasset://fonts/families/GothamSSm.json",
	Enum.FontWeight.Bold,
	Enum.FontStyle.Normal
)
local FONT_REGULAR: Font = Font.new(
	"rbxasset://fonts/families/GothamSSm.json",
	Enum.FontWeight.Regular,
	Enum.FontStyle.Normal
)

-- ── Color palette ──
-- Names mirror the original .rbxm template palette so future tweaks are
-- consistent — adjust one constant and every template that uses it updates.
local C = {
	-- Surfaces (darkest → lightest)
	BG_DEEP       = Color3.fromRGB(15, 17, 22),
	BG_PANEL      = Color3.fromRGB(25, 28, 35),
	BG_PANEL_ALT  = Color3.fromRGB(28, 30, 35),
	BG_CARD       = Color3.fromRGB(30, 33, 40),
	BG_CARD_ALT   = Color3.fromRGB(35, 38, 45),
	BG_RAISED     = Color3.fromRGB(40, 44, 52),
	BG_TITLEBAR   = Color3.fromRGB(20, 22, 28),
	BG_HEALTH_BG  = Color3.fromRGB(20, 20, 20),
	-- Strokes / dividers
	STROKE_LIGHT  = Color3.fromRGB(60, 65, 75),
	STROKE_MED    = Color3.fromRGB(65, 70, 80),
	STROKE_STRONG = Color3.fromRGB(70, 75, 85),
	-- Action colors
	ACCENT_BLUE   = Color3.fromRGB(45, 125, 245),
	ACCENT_STROKE = Color3.fromRGB(30, 90, 180),
	ACCEPT_GREEN  = Color3.fromRGB(80, 180, 100),
	HEALTH_GREEN  = Color3.fromRGB(80, 220, 100),
	DANGER_RED    = Color3.fromRGB(220, 70, 70),
	GOLD          = Color3.fromRGB(255, 220, 100),
	-- Text
	TEXT_PRIMARY  = Color3.fromRGB(255, 255, 255),
	TEXT_MUTED    = Color3.fromRGB(200, 200, 200),
	TEXT_FAINT    = Color3.fromRGB(180, 180, 180),
}

-- ── Builder helpers ──
-- WHY a make() helper: every Instance creation is class + property table +
-- optional children. Without this the file balloons to ~600 lines of
-- repetitive `local x = Instance.new(); x.Foo = ... ; x.Parent = ...`.
-- With it, each template reads like a declarative tree.
type Children = { Instance }

local function make(className: string, props: { [string]: any }, children: Children?): Instance
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		(inst :: any)[key] = value
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	return inst
end

-- Convenience helpers — declared as returning Instance (not the narrow class)
-- so Luau type-narrows the Children array correctly: { corner(...), stroke(...) }
-- needs to be `{Instance}` not `{UICorner | UIStroke}` (Luau locks element type
-- to the first element otherwise → false positives at every mixed list).
local function corner(radius: number): Instance
	return make("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color: Color3, thickness: number): Instance
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
end

local function paddingAll(px: number): Instance
	local u = UDim.new(0, px)
	return make("UIPadding", { PaddingTop = u, PaddingBottom = u, PaddingLeft = u, PaddingRight = u })
end

local function paddingX(px: number): Instance
	local u = UDim.new(0, px)
	return make("UIPadding", {
		PaddingTop = UDim.new(0, 0), PaddingBottom = UDim.new(0, 0),
		PaddingLeft = u, PaddingRight = u,
	})
end

-- ── Module ──
local Templates = {}

-- Every builder accepts an optional `parent` so callers can chain. Parenting
-- happens AFTER the tree is fully built (Roblox's set-parent-last pattern
-- avoids redundant property replication during construction).
local function finalize(inst: Instance, parent: Instance?): Instance
	if parent ~= nil then inst.Parent = parent end
	return inst
end

-- ── 1. ButtonTemplate (TextButton) ──
function Templates.ButtonTemplate(parent: Instance?): TextButton
	local btn = make("TextButton", {
		Name = "ButtonTemplate",
		Size = UDim2.fromOffset(200, 50),
		BackgroundColor3 = C.ACCENT_BLUE,
		BorderSizePixel = 0,
		Visible = false,
		AutoButtonColor = false,
		Text = "Button",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextScaled = true,
		TextWrapped = true,
	}, {
		corner(8),
		stroke(C.ACCENT_STROKE, 2),
		paddingX(12),
	}) :: TextButton
	return finalize(btn, parent) :: TextButton
end

-- ── 2. FrameTemplate (Frame) ──
function Templates.FrameTemplate(parent: Instance?): Frame
	local frame = make("Frame", {
		Name = "FrameTemplate",
		Size = UDim2.fromOffset(400, 300),
		BackgroundColor3 = C.BG_CARD_ALT,
		BorderSizePixel = 0,
		Visible = false,
	}, {
		corner(12),
		stroke(C.STROKE_LIGHT, 1),
		paddingAll(12),
	}) :: Frame
	return finalize(frame, parent) :: Frame
end

-- ── 3. HealthBarTemplate (Frame) ──
function Templates.HealthBarTemplate(parent: Instance?): Frame
	local fill = make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.HEALTH_GREEN,
		BorderSizePixel = 0,
	}, { corner(4) }) :: Frame
	local label = make("TextLabel", {
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "100/100",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextScaled = true,
		TextWrapped = true,
		ZIndex = 2,
	}) :: TextLabel
	local bar = make("Frame", {
		Name = "HealthBarTemplate",
		Size = UDim2.fromOffset(200, 24),
		BackgroundColor3 = C.BG_HEALTH_BG,
		BorderSizePixel = 0,
		Visible = false,
	}, { corner(4), fill, label }) :: Frame
	return finalize(bar, parent) :: Frame
end

-- ── 4. NotificationTemplate (Frame) ──
function Templates.NotificationTemplate(parent: Instance?): Frame
	local icon = make("ImageLabel", {
		Name = "Icon",
		Position = UDim2.new(0, 12, 0.5, -24),
		Size = UDim2.fromOffset(48, 48),
		BackgroundColor3 = C.BG_RAISED,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Image = "",
	}) :: ImageLabel
	local title = make("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(72, 10),
		Size = UDim2.new(1, -80, 0, 24),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Title",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
	}) :: TextLabel
	local message = make("TextLabel", {
		Name = "Message",
		Position = UDim2.fromOffset(72, 36),
		Size = UDim2.new(1, -80, 0, 36),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Message",
		TextColor3 = C.TEXT_MUTED,
		FontFace = FONT_REGULAR,
		TextSize = 13,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}) :: TextLabel
	local notif = make("Frame", {
		Name = "NotificationTemplate",
		Size = UDim2.fromOffset(320, 80),
		BackgroundColor3 = C.BG_RAISED,
		BorderSizePixel = 0,
		Visible = false,
	}, {
		corner(10),
		stroke(C.STROKE_STRONG, 1),
		icon, title, message,
	}) :: Frame
	return finalize(notif, parent) :: Frame
end

-- ── 5. MenuTemplate (Frame) ──
function Templates.MenuTemplate(parent: Instance?): Frame
	local title = make("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(1, -60, 1, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Menu",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
	}) :: TextLabel
	local closeBtn = make("TextButton", {
		Name = "CloseButton",
		Position = UDim2.new(1, -40, 0.5, -16),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = C.DANGER_RED,
		BorderSizePixel = 0,
		Text = "×",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextScaled = true,
		TextWrapped = true,
	}, { corner(6) }) :: TextButton
	local titleBar = make("Frame", {
		Name = "TitleBar",
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundColor3 = C.BG_TITLEBAR,
		BorderSizePixel = 0,
	}, { corner(14), title, closeBtn }) :: Frame
	local content = make("ScrollingFrame", {
		Name = "Content",
		Position = UDim2.fromOffset(12, 56),
		Size = UDim2.new(1, -24, 1, -68),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollingDirection = Enum.ScrollingDirection.XY,
		ClipsDescendants = true,
	}) :: ScrollingFrame
	local menu = make("Frame", {
		Name = "MenuTemplate",
		Size = UDim2.fromOffset(600, 450),
		BackgroundColor3 = C.BG_PANEL_ALT,
		BorderSizePixel = 0,
		Visible = false,
	}, {
		corner(14),
		stroke(C.STROKE_MED, 2),
		titleBar, content,
	}) :: Frame
	return finalize(menu, parent) :: Frame
end

-- ── 6. InventoryTemplate (Frame) ──
function Templates.InventoryTemplate(parent: Instance?): Frame
	local grid = make("ScrollingFrame", {
		Name = "Grid",
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 1, -20),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollingDirection = Enum.ScrollingDirection.XY,
		ClipsDescendants = true,
	}, {
		make("UIGridLayout", {
			CellPadding = UDim2.fromOffset(6, 6),
			CellSize = UDim2.fromOffset(70, 70),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Top,
			StartCorner = Enum.StartCorner.TopLeft,
		}),
	}) :: ScrollingFrame
	local inv = make("Frame", {
		Name = "InventoryTemplate",
		Size = UDim2.fromOffset(500, 400),
		BackgroundColor3 = C.BG_CARD,
		BorderSizePixel = 0,
		Visible = false,
	}, {
		corner(12),
		stroke(C.STROKE_LIGHT, 1),
		grid,
	}) :: Frame
	return finalize(inv, parent) :: Frame
end

-- ── 7. DialogTemplate (Frame) ──
function Templates.DialogTemplate(parent: Instance?): Frame
	local portrait = make("ImageLabel", {
		Name = "Portrait",
		Position = UDim2.new(0, 16, 0.5, -65),
		Size = UDim2.fromOffset(130, 130),
		BackgroundColor3 = C.BG_RAISED,
		BorderSizePixel = 0,
		Image = "",
	}, { corner(8) }) :: ImageLabel
	local name = make("TextLabel", {
		Name = "Name",
		Position = UDim2.fromOffset(160, 14),
		Size = UDim2.new(1, -180, 0, 28),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Name",
		TextColor3 = C.GOLD,
		FontFace = FONT_BOLD,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
	}) :: TextLabel
	local message = make("TextLabel", {
		Name = "Message",
		Position = UDim2.fromOffset(160, 46),
		Size = UDim2.new(1, -180, 1, -70),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Dialog message text goes here",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_REGULAR,
		TextSize = 15,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}) :: TextLabel
	local continueBtn = make("TextButton", {
		Name = "ContinueButton",
		Position = UDim2.new(1, -130, 1, -42),
		Size = UDim2.fromOffset(110, 30),
		BackgroundColor3 = C.ACCENT_BLUE,
		BorderSizePixel = 0,
		Text = "Continue",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextSize = 14,
	}, { corner(6) }) :: TextButton
	local dialog = make("Frame", {
		Name = "DialogTemplate",
		Size = UDim2.fromOffset(700, 180),
		BackgroundColor3 = C.BG_PANEL,
		BorderSizePixel = 0,
		Visible = false,
	}, {
		corner(12),
		stroke(C.STROKE_LIGHT, 1),
		portrait, name, message, continueBtn,
	}) :: Frame
	return finalize(dialog, parent) :: Frame
end

-- ── 8. TooltipTemplate (Frame) ──
function Templates.TooltipTemplate(parent: Instance?): Frame
	local label = make("TextLabel", {
		Name = "Label",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Tooltip text",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_REGULAR,
		TextSize = 13,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}) :: TextLabel
	local tooltip = make("Frame", {
		Name = "TooltipTemplate",
		Size = UDim2.fromOffset(220, 60),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.BG_DEEP,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Visible = false,
	}, {
		corner(6),
		stroke(C.STROKE_STRONG, 1),
		paddingAll(8),
		label,
	}) :: Frame
	return finalize(tooltip, parent) :: Frame
end

-- ── 9. LoadingScreenTemplate (Frame) ──
function Templates.LoadingScreenTemplate(parent: Instance?): Frame
	local logo = make("TextLabel", {
		Name = "Logo",
		Position = UDim2.new(0.5, -200, 0.5, -80),
		Size = UDim2.fromOffset(400, 80),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Gaxia",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextScaled = true,
		TextWrapped = true,
	}) :: TextLabel
	local fill = make("Frame", {
		Name = "Fill",
		Size = UDim2.new(0, 0, 1, 0),  -- caller scales X for progress
		BackgroundColor3 = C.HEALTH_GREEN,
		BorderSizePixel = 0,
	}, { corner(6) }) :: Frame
	local progressBar = make("Frame", {
		Name = "ProgressBar",
		Position = UDim2.new(0.5, -200, 0.5, 40),
		Size = UDim2.fromOffset(400, 12),
		BackgroundColor3 = C.BG_RAISED,
		BorderSizePixel = 0,
	}, { corner(6), fill }) :: Frame
	local status = make("TextLabel", {
		Name = "Status",
		Position = UDim2.new(0.5, -200, 0.5, 64),
		Size = UDim2.fromOffset(400, 24),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Loading…",
		TextColor3 = C.TEXT_FAINT,
		FontFace = FONT_REGULAR,
		TextSize = 14,
	}) :: TextLabel
	local screen = make("Frame", {
		Name = "LoadingScreenTemplate",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.BG_DEEP,
		BorderSizePixel = 0,
		Visible = false,
		-- WHY explicit `:: { Instance }`: this list mixes TextLabel + Frame, and
		-- without the cast Luau locks the array element type to whichever class
		-- comes first (TextLabel here) and then rejects the Frame entry.
	}, { logo, progressBar, status } :: { Instance }) :: Frame
	return finalize(screen, parent) :: Frame
end

-- ── 10. ConfirmDialogTemplate (Frame) ──
function Templates.ConfirmDialogTemplate(parent: Instance?): Frame
	local title = make("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(16, 16),
		Size = UDim2.new(1, -32, 0, 28),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Confirm",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
	}) :: TextLabel
	local message = make("TextLabel", {
		Name = "Message",
		Position = UDim2.fromOffset(16, 48),
		Size = UDim2.new(1, -32, 0, 60),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "Are you sure?",
		TextColor3 = C.TEXT_MUTED,
		FontFace = FONT_REGULAR,
		TextSize = 14,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}) :: TextLabel
	local yesBtn = make("TextButton", {
		Name = "YesButton",
		Position = UDim2.new(1, -260, 1, -52),
		Size = UDim2.fromOffset(120, 36),
		BackgroundColor3 = C.ACCEPT_GREEN,
		BorderSizePixel = 0,
		Text = "Yes",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextSize = 15,
	}, { corner(8) }) :: TextButton
	local noBtn = make("TextButton", {
		Name = "NoButton",
		Position = UDim2.new(1, -130, 1, -52),
		Size = UDim2.fromOffset(120, 36),
		BackgroundColor3 = C.DANGER_RED,
		BorderSizePixel = 0,
		Text = "No",
		TextColor3 = C.TEXT_PRIMARY,
		FontFace = FONT_BOLD,
		TextSize = 15,
	}, { corner(8) }) :: TextButton
	local dialog = make("Frame", {
		Name = "ConfirmDialogTemplate",
		Size = UDim2.fromOffset(380, 180),
		BackgroundColor3 = C.BG_PANEL_ALT,
		BorderSizePixel = 0,
		Visible = false,
	}, {
		corner(12),
		stroke(C.STROKE_MED, 2),
		title, message, yesBtn, noBtn,
	}) :: Frame
	return finalize(dialog, parent) :: Frame
end

return Templates
