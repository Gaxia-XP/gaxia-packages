--!strict
-- ────────────────────────────────────────────────────────
-- Module:   LoadingScreenController
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/LoadingScreenController
-- Purpose:  Drive the (otherwise unreachable) LoadingScreenTemplate. Owns a
--           full-screen ScreenGui in PlayerGui, tweens the ProgressBar.Fill
--           width on SetProgress(0..1), updates the Status label on
--           SetStatus(text). Show()/Hide() build, reuse, and reveal the
--           overlay above all gameplay UI.
--
-- Usage (client):
--   local Gaxia = require(ReplicatedStorage.Gaxia_Packages)
--   Gaxia.UI.LoadingScreenController.Show()
--   Gaxia.UI.LoadingScreenController.SetStatus("Loading world…")
--   Gaxia.UI.LoadingScreenController.SetProgress(0.5)
--   Gaxia.UI.LoadingScreenController.Hide()
-- ────────────────────────────────────────────────────────

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LoadingScreenController = {}
-- The module's own type (every function below), so the server stub and the client
-- module share one type and Gaxia.UI.LoadingScreenController.Show autocompletes.
export type LoadingScreenController = typeof(LoadingScreenController)

-- Client-only module; return a no-op stub on the server so server require() is safe.
if not RunService:IsClient() then
	return ({
		Show = function() end,
		Hide = function() end,
		SetProgress = function(_: number) end,
		SetStatus = function(_: string) end,
	} :: any) :: typeof(LoadingScreenController)
end

local UIController = require(script.Parent.UIController)

-- ── Constants ──
local PROGRESS_TWEEN_TIME : number = 0.2    -- bar fill, snappier than the fade
local FADE_TIME           : number = 0.3    -- Hide() fade-out duration
local TEMPLATE_NAME       : UIController.TemplateName = "LoadingScreenTemplate"
local SCREEN_NAME         : string = "Gaxia_LoadingScreen"
local DISPLAY_ORDER       : number = 10000  -- above all gameplay HUD/Overlays

-- ── Cached references ──
local LocalPlayer : Player    = Players.LocalPlayer
local PlayerGui   : PlayerGui = LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

-- ── State ──
-- One overlay is built lazily on first Show() and reused (kept hidden, not
-- destroyed) so subsequent Show() calls are instant.
local screenGui   : ScreenGui? = nil
local rootFrame   : Frame?     = nil
local fillFrame   : Frame?     = nil
local statusLabel : TextLabel? = nil
local progressTween : Tween? = nil
local fadeTween     : Tween? = nil

-- ── Internal: build (or reuse) the overlay ──
local function ensureBuilt(): boolean
	if screenGui and screenGui.Parent and rootFrame and rootFrame.Parent then
		return true
	end

	-- A dedicated full-screen ScreenGui (NOT the shared Gaxia_UI): the template is
	-- UDim2.fromScale(1,1) and must cover the whole viewport above every layer.
	local gui = Instance.new("ScreenGui")
	gui.Name = SCREEN_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false  -- revealed in Show()
	gui.Parent = PlayerGui

	-- Build from the single-source-of-truth template (CloneTemplate parents into gui).
	local frame = UIController.CloneTemplate(TEMPLATE_NAME, gui)
	if not frame or not frame:IsA("Frame") then
		warn("[LoadingScreenController] failed to clone LoadingScreenTemplate")
		gui:Destroy()
		return false
	end

	-- Resolve named children defensively so a future template tweak can't hard-crash.
	local resolvedFill: Frame? = nil
	local resolvedStatus: TextLabel? = nil
	pcall(function()
		local progressBar = frame:FindFirstChild("ProgressBar")
		if progressBar then
			local fill = progressBar:FindFirstChild("Fill")
			if fill and fill:IsA("Frame") then
				resolvedFill = fill
			end
		end
		local status = frame:FindFirstChild("Status")
		if status and status:IsA("TextLabel") then
			resolvedStatus = status
		end
	end)

	screenGui = gui
	rootFrame = frame
	fillFrame = resolvedFill
	statusLabel = resolvedStatus
	return true
end

-- ── Show ──
-- Build/reuse the overlay, reset it to a clean opaque 0% state, reveal it.
function LoadingScreenController.Show(): ()
	if not ensureBuilt() then
		return
	end
	local gui = screenGui
	local frame = rootFrame
	if not gui or not frame then
		return
	end

	-- Cancel any in-flight Hide() fade so a Hide()->Show() during the 0.3s fade
	-- does not keep tweening the just-shown overlay back to transparent.
	if fadeTween then
		fadeTween:Cancel()
		fadeTween = nil
	end

	frame.BackgroundTransparency = 0
	frame.Visible = true
	if fillFrame then
		fillFrame.Size = UDim2.new(0, 0, 1, 0)
	end
	gui.Enabled = true
end

-- ── Hide ──
-- Fade the root frame out, then disable the ScreenGui. The overlay is kept
-- (not Destroyed) so a later Show() reuses it instantly.
function LoadingScreenController.Hide(): ()
	local gui = screenGui
	local frame = rootFrame
	if not gui or not frame or not frame.Parent then
		return
	end

	if fadeTween then
		fadeTween:Cancel()
	end
	local tween = TweenService:Create(
		frame,
		TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	fadeTween = tween
	tween.Completed:Connect(function()
		-- Only disable if no newer Show() re-revealed it mid-fade.
		if frame.BackgroundTransparency >= 1 and screenGui == gui then
			gui.Enabled = false
		end
	end)
	tween:Play()
end

-- ── SetProgress ──
-- alpha clamped to 0..1; drives ProgressBar.Fill X-scale via a short tween
-- (mirrors HealthBarController). No-op if the overlay/Fill is absent.
function LoadingScreenController.SetProgress(alpha: number): ()
	if not fillFrame then
		return
	end
	local fill = fillFrame
	if not fill.Parent then
		return
	end
	local ratio = math.clamp(alpha, 0, 1)

	if progressTween then
		progressTween:Cancel()
		progressTween = nil
	end
	local tween = TweenService:Create(
		fill,
		TweenInfo.new(PROGRESS_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.new(ratio, 0, 1, 0) }
	)
	progressTween = tween
	tween:Play()
end

-- ── SetStatus ──
-- Update the Status TextLabel. No-op if the overlay/label is absent.
function LoadingScreenController.SetStatus(text: string): ()
	if statusLabel and statusLabel.Parent then
		statusLabel.Text = text
	end
end

return LoadingScreenController
