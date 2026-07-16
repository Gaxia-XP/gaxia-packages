--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   HealthBarController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/HealthBarController
-- Purpose:  Attach a tweened health bar to any Humanoid.
--           Color shifts green/yellow/red by % health.
-- ─────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- WHY this explicit type:
-- The early-return guard below needs to match the module's real return shape
-- so Luau collapses the (server-return | client-return) union into a single
-- typed value. Without this, `Gaxia.UI.HealthBarController.Attach` does not
-- autocomplete because the union resolves to `any`.
export type HealthBarHandle = {
	Update: (current: number, max: number) -> (),
	Destroy: () -> (),
}
export type HealthBarController = {
	Attach: (humanoid: Humanoid, parent: GuiBase2d?) -> HealthBarHandle,
}

-- Client-only module.
if not RunService:IsClient() then
	return ({} :: any) :: HealthBarController
end

local UIController = require(script.Parent:WaitForChild("UIController"))

-- ── Constants ──
local function getConstants(): { [string]: any }
	local pkg = ReplicatedStorage:FindFirstChild("Gaxia_Packages")
	if not pkg then return {} end
	local shared = pkg:FindFirstChild("Shared")
	if not shared then return {} end
	local constMod = shared:FindFirstChild("Constants")
	if not constMod or not constMod:IsA("ModuleScript") then return {} end
	local ok, data = pcall(require, constMod)
	if ok and typeof(data) == "table" then
		return data
	end
	return {}
end

local CONST = getConstants()
local _ANIM_TIME: number = (CONST.UI_ANIMATION_TIME :: number?) or 0.25
local FILL_TWEEN_TIME: number = 0.15  -- snappier than generic UI tweens
local TEMPLATE_NAME: string = "HealthBarTemplate"

local COLOR_GREEN: Color3 = Color3.fromRGB(80, 200, 120)
local COLOR_YELLOW: Color3 = Color3.fromRGB(240, 200, 70)
local COLOR_RED: Color3 = Color3.fromRGB(230, 80, 80)

-- ── Types ──
-- Legacy alias retained for any external code referencing this name.
-- Structurally identical to HealthBarHandle (exported above).
export type HealthBarControl = HealthBarHandle

-- ── Internal: pick color by ratio ──
local function colorFor(ratio: number): Color3
	if ratio > 0.6 then
		return COLOR_GREEN
	elseif ratio > 0.3 then
		return COLOR_YELLOW
	else
		return COLOR_RED
	end
end

local HealthBarController = {}

-- ── Attach ──
function HealthBarController.Attach(
	humanoid: Humanoid,
	parent: GuiBase2d?
): HealthBarHandle
	local fallbackControl: HealthBarHandle = {
		Update = function(_: number, _: number) end,
		Destroy = function() end,
	}

	local hudParent: Instance? = parent
	if not hudParent then
		hudParent = UIController.HUD() or UIController.GetActiveScreen()
	end

	local frame = UIController.CloneTemplate(TEMPLATE_NAME, hudParent)
	if not frame or not frame:IsA("Frame") then
		warn("[HealthBarController] failed to clone HealthBarTemplate")
		return fallbackControl
	end

	-- Resolve named children defensively.
	local fill = frame:FindFirstChild("Fill")
	local label = frame:FindFirstChild("Label")
	local fillFrame: Frame? = (fill and fill:IsA("Frame")) and fill or nil
	local labelText: TextLabel? = (label and label:IsA("TextLabel")) and label or nil

	local connection: RBXScriptConnection? = nil
	local destroyed = false

	-- ── Internal: apply update with tween ──
	local function apply(current: number, max: number): ()
		if destroyed or not frame.Parent then
			return
		end
		local safeMax = math.max(max, 1)
		local ratio = math.clamp(current / safeMax, 0, 1)

		if fillFrame then
			pcall(function()
				local tween = TweenService:Create(
					fillFrame,
					TweenInfo.new(FILL_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{
						Size = UDim2.new(ratio, 0, 1, 0),
						BackgroundColor3 = colorFor(ratio),
					}
				)
				tween:Play()
			end)
		end

		if labelText then
			labelText.Text = `{math.floor(current)} / {math.floor(safeMax)}`
		end
	end

	local control: HealthBarHandle = {
		Update = function(current: number, max: number)
			apply(current, max)
		end,
		Destroy = function()
			destroyed = true
			if connection then
				connection:Disconnect()
				connection = nil
			end
			if frame and frame.Parent then
				frame:Destroy()
			end
		end,
	}

	-- Live-wire to humanoid health changes.
	apply(humanoid.Health, humanoid.MaxHealth)
	connection = humanoid:GetPropertyChangedSignal("Health"):Connect(function()
		apply(humanoid.Health, humanoid.MaxHealth)
	end)

	-- Clean up if humanoid dies/leaves.
	humanoid.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then
			control.Destroy()
		end
	end)

	return control
end

return HealthBarController :: HealthBarController
