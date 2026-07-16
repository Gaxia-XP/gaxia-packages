--!strict
-- ──────────────────────────────────────────────────────────────────
--  CutsceneSystem.lua
--  Location: ReplicatedStorage/Gaxia_Packages/Client/CutsceneSystem
--  Purpose:  Sequenced cutscenes — camera tweens, dialog, fades,
--            subtitles, custom actions, waits. Promise-based.
-- ──────────────────────────────────────────────────────────────────

export type CutsceneStep =
	  { type: "camera", cframe: CFrame, duration: number, easing: Enum.EasingStyle? }
	| { type: "dialog", dialog: any }
	| { type: "wait", duration: number }
	| { type: "fade", to: number, duration: number }
	| { type: "action", fn: () -> () }
	| { type: "subtitle", text: string, duration: number }

export type CutsceneSystem = {
	Play: (steps: { CutsceneStep }) -> any,
	Stop: () -> (),
	IsPlaying: () -> boolean,
}

local RunService = game:GetService("RunService")
if not RunService:IsClient() then return ({} :: any) :: CutsceneSystem end

local CollectionService = game:GetService("CollectionService")

-- ── Services ──
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")

local LocalPlayer : Player = Players.LocalPlayer
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Promise = SharedPkg.Promise
local Maid    = SharedPkg.Maid

-- ── Constants ──
local UI_ROOT_NAME : string = "Gaxia_UI"
local OVERLAY_FOLDER_NAME : string = "Overlays"
local DEFAULT_EASING : Enum.EasingStyle = Enum.EasingStyle.Sine

-- ── State ──
local Module = {}

local _isPlaying : boolean = false
local _cancelFlag : { cancelled: boolean } = { cancelled = false }
local _activeMaid : any = nil
local _fadeFrame : Frame? = nil

-- ── Lazy DialogSystem reference ──
local _dialog : any = nil
local function getDialog(): any
	if _dialog then return _dialog end
	local mod = script.Parent and script.Parent:FindFirstChild("DialogSystem")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod)
		if ok then
			_dialog = m
		end
	end
	return _dialog
end

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
local function ensureFade(maid: any): Frame
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
	maid:GiveTask(frame)
	return frame
end

-- ── Step runners ──

local function runCamera(step: any, cancelFlag: { cancelled: boolean }): ()
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

local function runWait(step: any, cancelFlag: { cancelled: boolean }): ()
	local elapsed = 0
	while elapsed < step.duration do
		if cancelFlag.cancelled then return end
		local dt = task.wait()
		elapsed += dt
	end
end

local function runFade(step: any, cancelFlag: { cancelled: boolean }, maid: any): ()
	local frame = ensureFade(maid)
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

local function runSubtitle(step: any, cancelFlag: { cancelled: boolean }, maid: any): ()
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

	maid:GiveTask(label)

	local elapsed = 0
	while elapsed < step.duration do
		if cancelFlag.cancelled then break end
		local dt = task.wait()
		elapsed += dt
	end
	label:Destroy()
end

local function runDialog(step: any, cancelFlag: { cancelled: boolean }): ()
	local ds = getDialog()
	if not ds then
		warn("[CutsceneSystem] DialogSystem not found — skipping dialog step")
		return
	end
	local p = ds.Show(step.dialog)
	-- WHY: poll for completion while respecting cancel
	local done = false
	p:andThen(function() done = true end, function() done = true end)
	while not done do
		if cancelFlag.cancelled then
			if p.cancel then p:cancel() end
			if ds.Close then ds.Close() end
			return
		end
		task.wait()
	end
end

local function runAction(step: any, cancelFlag: { cancelled: boolean }): ()
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
	if _activeMaid then
		_activeMaid:Destroy()
		_activeMaid = nil
	end
	_isPlaying = false
end

function Module.Play(steps: { CutsceneStep }): any
	return Promise.new(function(resolve: (val: any) -> (), reject: (err: any) -> (), onCancel: (fn: () -> ()) -> ())
		if _isPlaying then
			reject("cutscene already playing")
			return
		end

		_isPlaying = true
		local cancelFlag = { cancelled = false }
		_cancelFlag = cancelFlag

		local maid = Maid.new()
		_activeMaid = maid

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

		maid:GiveTask(restore)

		onCancel(function()
			cancelFlag.cancelled = true
			if _activeMaid == maid then
				_activeMaid = nil
				_isPlaying = false
			end
			maid:Destroy()
		end)

		task.spawn(function()
			for _, step in ipairs(steps) do
				if cancelFlag.cancelled then break end
				local t = (step :: any).type
				if t == "camera" then
					runCamera(step, cancelFlag)
				elseif t == "wait" then
					runWait(step, cancelFlag)
				elseif t == "fade" then
					runFade(step, cancelFlag, maid)
				elseif t == "subtitle" then
					runSubtitle(step, cancelFlag, maid)
				elseif t == "dialog" then
					runDialog(step, cancelFlag)
				elseif t == "action" then
					runAction(step, cancelFlag)
				else
					warn(`[CutsceneSystem] unknown step type: {tostring(t)}`)
				end
			end

			local wasCancelled = cancelFlag.cancelled
			if _activeMaid == maid then
				_activeMaid = nil
				_isPlaying = false
			end
			maid:Destroy()

			if wasCancelled then
				reject("cancelled")
			else
				resolve(true)
			end
		end)
	end)
end

return Module :: CutsceneSystem
