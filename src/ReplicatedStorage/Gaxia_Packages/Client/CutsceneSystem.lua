--!strict
-- ──────────────────────────────────────────────────────────────────
--  CutsceneSystem.lua
--  Location: ReplicatedStorage/Gaxia_Packages/Client/CutsceneSystem
--  Purpose:  Sequenced cutscenes — camera tweens, dialog, fades,
--            subtitles, custom actions, waits. Promise-based.
-- ──────────────────────────────────────────────────────────────────

-- ── Dependencies ──
local Promise      = require(script.Parent.Parent.Shared.Promise)
local PromiseTypes = require(script.Parent.Parent.Shared.PromiseTypes)
local Trove        = require(script.Parent.Parent.Shared.Trove)
local DialogSystem = require(script.Parent.DialogSystem)

-- The value Trove.new() returns. (Annotating with the exported Trove.Trove is
-- rejected by the type checker: its generic methods do not unify with the
-- instantiated result of Trove.new().)
type TroveObject = typeof(Trove.new())

-- ── Promise types ──
-- Shared/Promise (vendored evaera Promise) exports no types; Shared/PromiseTypes
-- describes it, so callers get :andThen / :await / :expect completion.
type Promise<T...> = PromiseTypes.Promise<T...>

export type CameraStep = { type: "camera", cframe: CFrame, duration: number, easing: Enum.EasingStyle? }
export type DialogStep = { type: "dialog", dialog: DialogSystem.DialogConfig }
export type WaitStep = { type: "wait", duration: number }
-- `to` is the black overlay's opacity (0 = clear, 1 = black).
export type FadeStep = { type: "fade", to: number, duration: number }
export type ActionStep = { type: "action", fn: () -> ...any }
export type SubtitleStep = { type: "subtitle", text: string, duration: number }

export type CutsceneStep = CameraStep | DialogStep | WaitStep | FadeStep | ActionStep | SubtitleStep

export type CutsceneSystem = {
	-- Resolves with true when every step ran; rejects with "cancelled" (Stop /
	-- promise:cancel()) or "cutscene already playing".
	Play: (steps: { CutsceneStep }) -> Promise<boolean>,
	Stop: () -> (),
	IsPlaying: () -> boolean,
}

local RunService = game:GetService("RunService")
if not RunService:IsClient() then return ({} :: any) :: CutsceneSystem end

local CollectionService = game:GetService("CollectionService")

-- ── Services ──
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")

local LocalPlayer : Player = Players.LocalPlayer

-- ── Constants ──
local UI_ROOT_NAME : string = "Gaxia_UI"
local OVERLAY_FOLDER_NAME : string = "Overlays"
local DEFAULT_EASING : Enum.EasingStyle = Enum.EasingStyle.Sine

-- ── State ──
local Module = {}

local _isPlaying : boolean = false
local _cancelFlag : { cancelled: boolean } = { cancelled = false }
local _activeTrove : TroveObject? = nil
local _fadeFrame : Frame? = nil

-- ── Helpers ──

local function getOverlays(): Instance
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local uiRoot = pg:FindFirstChild(UI_ROOT_NAME)
	if not uiRoot then
		local sg = Instance.new("ScreenGui")
		sg.Name = UI_ROOT_NAME
		sg.ResetOnSpawn = false
		sg.IgnoreGuiInset = true
		sg.DisplayOrder = 500
		sg.Parent = pg
		uiRoot = sg
	end
	local overlays = uiRoot:FindFirstChild(OVERLAY_FOLDER_NAME)
	if not overlays then
		local f = Instance.new("Folder")
		f.Name = OVERLAY_FOLDER_NAME
		f.Parent = uiRoot
		overlays = f
	end
	return overlays :: Instance
end

-- WHY: build/return the persistent fade overlay
local function ensureFade(trove: TroveObject): Frame
	if _fadeFrame and _fadeFrame.Parent then return _fadeFrame end
	local frame = Instance.new("Frame")
	frame.Name = "CutsceneFade"
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = 200
	frame.Parent = getOverlays()
	_fadeFrame = frame
	trove:Add(frame)
	return frame
end

-- ── Step runners ──

local function runCamera(step: CameraStep, cancelFlag: { cancelled: boolean }): ()
	local cam = workspace.CurrentCamera
	if not cam then return end
	cam.CameraType = Enum.CameraType.Scriptable
	local easing : Enum.EasingStyle = step.easing or DEFAULT_EASING
	local ti = TweenInfo.new(step.duration, easing, Enum.EasingDirection.InOut)
	local tween = TweenService:Create(cam, ti, { CFrame = step.cframe })
	tween:Play()
	local elapsed = 0
	while elapsed < step.duration do
		if cancelFlag.cancelled then
			tween:Cancel()
			return
		end
		local dt = task.wait()
		elapsed += dt
	end
end

local function runWait(step: WaitStep, cancelFlag: { cancelled: boolean }): ()
	local elapsed = 0
	while elapsed < step.duration do
		if cancelFlag.cancelled then return end
		local dt = task.wait()
		elapsed += dt
	end
end

local function runFade(step: FadeStep, cancelFlag: { cancelled: boolean }, trove: TroveObject): ()
	local frame = ensureFade(trove)
	local target = math.clamp(step.to, 0, 1)
	-- BackgroundTransparency: 0 = fully visible (black), 1 = invisible
	-- step.to is opacity (0..1), so transparency = 1 - to
	local ti = TweenInfo.new(step.duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut)
	local tween = TweenService:Create(frame, ti, { BackgroundTransparency = 1 - target })
	tween:Play()
	local elapsed = 0
	while elapsed < step.duration do
		if cancelFlag.cancelled then
			tween:Cancel()
			return
		end
		local dt = task.wait()
		elapsed += dt
	end
end

local function runSubtitle(step: SubtitleStep, cancelFlag: { cancelled: boolean }, trove: TroveObject): ()
	local label = Instance.new("TextLabel")
	label.Name = "Subtitle"
	label.Size = UDim2.new(0.8, 0, 0, 60)
	label.Position = UDim2.new(0.1, 0, 0.85, 0)
	label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	label.BackgroundTransparency = 0.4
	label.BorderSizePixel = 0
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.Gotham
	label.TextSize = 20
	label.TextWrapped = true
	label.Text = step.text
	label.ZIndex = 210
	label.Parent = getOverlays()

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = label

	trove:Add(label)

	local elapsed = 0
	while elapsed < step.duration do
		if cancelFlag.cancelled then break end
		local dt = task.wait()
		elapsed += dt
	end
	label:Destroy()
end

local function runDialog(step: DialogStep, cancelFlag: { cancelled: boolean }): ()
	local p = DialogSystem.Show(step.dialog)
	-- WHY: poll for completion while respecting cancel
	local done = false
	p:andThen(function() done = true end, function() done = true end)
	while not done do
		if cancelFlag.cancelled then
			p:cancel()
			DialogSystem.Close()
			return
		end
		task.wait()
	end
end

local function runAction(step: ActionStep, cancelFlag: { cancelled: boolean }): ()
	if cancelFlag.cancelled then return end
	local ok, err = pcall(step.fn)
	if not ok then
		warn(`[CutsceneSystem] action step error: {err}`)
	end
end

-- ── Public API ──

function Module.IsPlaying(): boolean
	return _isPlaying
end

function Module.Stop(): ()
	_cancelFlag.cancelled = true
	if _activeTrove then
		_activeTrove:Destroy()
		_activeTrove = nil
	end
	_isPlaying = false
end

function Module.Play(steps: { CutsceneStep }): Promise<boolean>
	return (Promise.new(function(resolve: (val: any) -> (), reject: (err: any) -> (), onCancel: (fn: () -> ()) -> ())
		if _isPlaying then
			reject("cutscene already playing")
			return
		end

		_isPlaying = true
		local cancelFlag = { cancelled = false }
		_cancelFlag = cancelFlag

		local trove = Trove.new()
		_activeTrove = trove

		-- Snapshot camera
		local cam = workspace.CurrentCamera
		local savedType : Enum.CameraType? = nil
		local savedCFrame : CFrame? = nil
		if cam then
			savedType = cam.CameraType
			savedCFrame = cam.CFrame
		end

		local function restore(): ()
			if cam and savedType and savedCFrame then
				cam.CameraType = savedType
				cam.CFrame = savedCFrame
			end
		end

		trove:Add(restore)

		onCancel(function()
			cancelFlag.cancelled = true
			if _activeTrove == trove then
				_activeTrove = nil
				_isPlaying = false
			end
			trove:Destroy()
		end)

		task.spawn(function()
			for _, step in ipairs(steps) do
				if cancelFlag.cancelled then break end
				local t = step.type
				if t == "camera" then
					runCamera(step :: CameraStep, cancelFlag)
				elseif t == "wait" then
					runWait(step :: WaitStep, cancelFlag)
				elseif t == "fade" then
					runFade(step :: FadeStep, cancelFlag, trove)
				elseif t == "subtitle" then
					runSubtitle(step :: SubtitleStep, cancelFlag, trove)
				elseif t == "dialog" then
					runDialog(step :: DialogStep, cancelFlag)
				elseif t == "action" then
					runAction(step :: ActionStep, cancelFlag)
				else
					warn(`[CutsceneSystem] unknown step type: {tostring(t)}`)
				end
			end

			local wasCancelled = cancelFlag.cancelled
			if _activeTrove == trove then
				_activeTrove = nil
				_isPlaying = false
			end
			trove:Destroy()

			if wasCancelled then
				reject("cancelled")
			else
				resolve(true)
			end
		end)
	end) :: any) :: Promise<boolean>
end

return Module :: CutsceneSystem
