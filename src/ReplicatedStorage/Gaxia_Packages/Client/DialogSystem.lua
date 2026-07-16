--!strict
-- ──────────────────────────────────────────────────────────────────
--  DialogSystem.lua
--  Location: ReplicatedStorage/Gaxia_Packages/Client/DialogSystem
--  Purpose:  Branching NPC dialog UI with typewriter effect + choices.
--            Promise-based API — resolves to chosen index (1-based).
-- ──────────────────────────────────────────────────────────────────

export type DialogLine = { speaker: string?, text: string, portrait: string? }
export type DialogChoice = { text: string, value: any? }
export type DialogConfig = {
	lines : { DialogLine },
	choices : { DialogChoice }?,
	speed : number?,
}

export type DialogSystem = {
	Show: (config: DialogConfig) -> any,
	Close: () -> (),
	IsOpen: () -> boolean,
}

local RunService = game:GetService("RunService")
if not RunService:IsClient() then return ({} :: any) :: DialogSystem end

local CollectionService = game:GetService("CollectionService")

-- ── Services ──
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local StarterGui        = game:GetService("StarterGui")

local LocalPlayer : Player = Players.LocalPlayer
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Promise = SharedPkg.Promise
local Maid    = SharedPkg.Maid

-- ── Constants ──
local DEFAULT_SPEED : number = 30
local OVERLAY_FOLDER_NAME : string = "Overlays"
local UI_ROOT_NAME : string = "Gaxia_UI"

-- ── State ──
local Module = {}

local _activeMaid : any = nil
local _activeReject : ((err: any) -> ())? = nil
local _isOpen : boolean = false

-- ── Helpers ──

-- WHY: ensure a PlayerGui Overlays folder exists for transient UI
local function getOverlays(): Instance
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local uiRoot = pg:FindFirstChild(UI_ROOT_NAME)
	if not uiRoot then
		local sg = Instance.new("ScreenGui")
		sg.Name = UI_ROOT_NAME
		sg.ResetOnSpawn = false
		sg.IgnoreGuiInset = true
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

-- WHY: try to locate the designer-built DialogTemplate; fall back to programmatic
local function findTemplate(): GuiObject?
	local sg = StarterGui:FindFirstChild(UI_ROOT_NAME)
	if not sg then return nil end
	local templates = sg:FindFirstChild("Templates")
	if not templates then return nil end
	local tmpl = templates:FindFirstChild("DialogTemplate")
	if tmpl and tmpl:IsA("GuiObject") then
		return tmpl
	end
	return nil
end

-- WHY: programmatic fallback if no template available in StarterGui
local function buildFallback(): Frame
	local frame = Instance.new("Frame")
	frame.Name = "DialogTemplate"
	frame.Size = UDim2.new(0.6, 0, 0, 180)
	frame.Position = UDim2.new(0.2, 0, 0.7, 0)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	frame.BackgroundTransparency = 0.1
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 140, 200)
	stroke.Thickness = 2
	stroke.Parent = frame

	local portrait = Instance.new("ImageLabel")
	portrait.Name = "Portrait"
	portrait.Size = UDim2.new(0, 80, 0, 80)
	portrait.Position = UDim2.new(0, 12, 0, 12)
	portrait.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
	portrait.BorderSizePixel = 0
	portrait.Parent = frame

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Name = "Name"
	nameLbl.Size = UDim2.new(1, -110, 0, 28)
	nameLbl.Position = UDim2.new(0, 100, 0, 10)
	nameLbl.BackgroundTransparency = 1
	nameLbl.TextColor3 = Color3.fromRGB(255, 220, 120)
	nameLbl.TextScaled = true
	nameLbl.Font = Enum.Font.GothamBold
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left
	nameLbl.Text = ""
	nameLbl.Parent = frame

	local msg = Instance.new("TextLabel")
	msg.Name = "Message"
	msg.Size = UDim2.new(1, -110, 1, -90)
	msg.Position = UDim2.new(0, 100, 0, 42)
	msg.BackgroundTransparency = 1
	msg.TextColor3 = Color3.fromRGB(240, 240, 240)
	msg.TextWrapped = true
	msg.TextSize = 18
	msg.Font = Enum.Font.Gotham
	msg.TextXAlignment = Enum.TextXAlignment.Left
	msg.TextYAlignment = Enum.TextYAlignment.Top
	msg.RichText = false
	msg.Text = ""
	msg.Parent = frame

	local continueBtn = Instance.new("TextButton")
	continueBtn.Name = "ContinueButton"
	continueBtn.Size = UDim2.new(0, 120, 0, 32)
	continueBtn.Position = UDim2.new(1, -132, 1, -40)
	continueBtn.BackgroundColor3 = Color3.fromRGB(60, 100, 180)
	continueBtn.BorderSizePixel = 0
	continueBtn.Text = "Continue"
	continueBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	continueBtn.Font = Enum.Font.GothamBold
	continueBtn.TextSize = 16
	continueBtn.Parent = frame

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 6)
	btnCorner.Parent = continueBtn

	return frame
end

-- WHY: spawn typewriter coroutine that reveals one grapheme at a time
local function runTypewriter(label: TextLabel, fullText: string, speed: number, skipFlag: { skip: boolean }): ()
	label.Text = fullText
	label.MaxVisibleGraphemes = 0
	local graphemes = utf8.len(fullText) or #fullText
	local perChar = 1 / math.max(speed, 1)
	local i = 0
	while i < graphemes do
		if skipFlag.skip then
			label.MaxVisibleGraphemes = graphemes
			break
		end
		i += 1
		label.MaxVisibleGraphemes = i
		task.wait(perChar)
	end
	label.MaxVisibleGraphemes = -1
end

-- ── Public API ──

function Module.IsOpen(): boolean
	return _isOpen
end

function Module.Close(): ()
	if _activeMaid then
		_activeMaid:Destroy()
		_activeMaid = nil
	end
	_activeReject = nil
	_isOpen = false
end

function Module.Show(config: DialogConfig): any
	return Promise.new(function(resolve: (val: any) -> (), reject: (err: any) -> (), onCancel: (fn: () -> ()) -> ())
		-- WHY: only one dialog at a time; reject previous
		if _isOpen and _activeReject then
			local prev = _activeReject
			_activeReject = nil
			prev("superseded")
			if _activeMaid then
				_activeMaid:Destroy()
				_activeMaid = nil
			end
		end

		_isOpen = true
		_activeReject = reject

		local maid = Maid.new()
		_activeMaid = maid

		onCancel(function()
			if _activeMaid == maid then
				_activeMaid = nil
				_activeReject = nil
				_isOpen = false
			end
			maid:Destroy()
		end)

		-- Build UI
		local tmpl = findTemplate()
		local frame : GuiObject
		if tmpl then
			frame = tmpl:Clone()
		else
			frame = buildFallback()
		end
		frame.Visible = true

		local overlays = getOverlays()
		frame.Parent = overlays
		maid:GiveTask(frame)

		local msgLabel = frame:FindFirstChild("Message")
		local nameLabel = frame:FindFirstChild("Name")
		local portrait = frame:FindFirstChild("Portrait")
		local continueBtn = frame:FindFirstChild("ContinueButton")

		if not (msgLabel and msgLabel:IsA("TextLabel")) then
			reject("DialogTemplate missing Message TextLabel")
			return
		end
		if not (continueBtn and continueBtn:IsA("TextButton")) then
			reject("DialogTemplate missing ContinueButton")
			return
		end

		local speed : number = config.speed or DEFAULT_SPEED
		local lines = config.lines
		local choices = config.choices

		local skipFlag = { skip = false }
		local lineIdx = 0
		local advancing = false
		local typing = false

		local clickArea = Instance.new("TextButton")
		clickArea.Name = "ClickArea"
		clickArea.Size = UDim2.new(1, 0, 1, 0)
		clickArea.BackgroundTransparency = 1
		clickArea.Text = ""
		clickArea.ZIndex = 0
		clickArea.AutoButtonColor = false
		clickArea.Parent = frame
		maid:GiveTask(clickArea)

		local choiceContainer : Frame? = nil

		local advanceLine : () -> ()
		local showChoices : () -> ()

		showChoices = function()
			if not choices or #choices == 0 then return end
			local cont = Instance.new("Frame")
			cont.Name = "Choices"
			cont.Size = UDim2.new(1, -20, 0, #choices * 36 + (#choices - 1) * 4)
			cont.Position = UDim2.new(0, 10, 1, 8)
			cont.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
			cont.BackgroundTransparency = 0.1
			cont.BorderSizePixel = 0
			cont.Parent = frame

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 6)
			corner.Parent = cont

			local list = Instance.new("UIListLayout")
			list.Padding = UDim.new(0, 4)
			list.SortOrder = Enum.SortOrder.LayoutOrder
			list.Parent = cont

			local padding = Instance.new("UIPadding")
			padding.PaddingTop = UDim.new(0, 4)
			padding.PaddingBottom = UDim.new(0, 4)
			padding.PaddingLeft = UDim.new(0, 6)
			padding.PaddingRight = UDim.new(0, 6)
			padding.Parent = cont

			for i, c in ipairs(choices) do
				local btn = Instance.new("TextButton")
				btn.Name = `Choice_{i}`
				btn.Size = UDim2.new(1, 0, 0, 32)
				btn.BackgroundColor3 = Color3.fromRGB(60, 80, 140)
				btn.BorderSizePixel = 0
				btn.Text = c.text
				btn.TextColor3 = Color3.fromRGB(255, 255, 255)
				btn.Font = Enum.Font.Gotham
				btn.TextSize = 16
				btn.LayoutOrder = i
				btn.Parent = cont

				local bc = Instance.new("UICorner")
				bc.CornerRadius = UDim.new(0, 4)
				bc.Parent = btn

				local conn = btn.MouseButton1Click:Connect(function()
					if _activeMaid == maid then
						_activeMaid = nil
						_activeReject = nil
						_isOpen = false
					end
					maid:Destroy()
					resolve(i)
				end)
				maid:GiveTask(conn)
			end

			choiceContainer = cont
			maid:GiveTask(cont)
			continueBtn.Visible = false
		end

		advanceLine = function()
			if advancing then return end
			advancing = true

			if typing then
				-- WHY: skip typewriter to end of current line on click
				skipFlag.skip = true
				advancing = false
				return
			end

			lineIdx += 1
			if lineIdx > #lines then
				-- end of lines
				if choices and #choices > 0 then
					showChoices()
					advancing = false
				else
					if _activeMaid == maid then
						_activeMaid = nil
						_activeReject = nil
						_isOpen = false
					end
					maid:Destroy()
					resolve(1)
				end
				return
			end

			local line = lines[lineIdx]
			if nameLabel and nameLabel:IsA("TextLabel") then
				nameLabel.Text = line.speaker or ""
			end
			if portrait and portrait:IsA("ImageLabel") then
				portrait.Image = line.portrait or ""
			end

			skipFlag = { skip = false }
			typing = true
			task.spawn(function()
				runTypewriter(msgLabel :: TextLabel, line.text, speed, skipFlag)
				typing = false
				advancing = false
			end)
			advancing = false
		end

		local connContinue = continueBtn.MouseButton1Click:Connect(advanceLine)
		maid:GiveTask(connContinue)

		local connClick = clickArea.MouseButton1Click:Connect(function()
			if typing then
				skipFlag.skip = true
			else
				advanceLine()
			end
		end)
		maid:GiveTask(connClick)

		-- kick off first line
		advanceLine()
	end)
end

return Module :: DialogSystem
