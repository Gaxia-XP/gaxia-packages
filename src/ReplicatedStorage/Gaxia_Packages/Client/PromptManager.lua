--!strict
--[[
	PromptManager.lua
	Location: ReplicatedStorage/Gaxia_Packages/Client/PromptManager
	Purpose: Tracks the active ProximityPrompt, exposes manual hold controls,
	         and highlights the prompt's nearest renderable ancestor.
--]]

export type PromptManager = {
	SetCurrentPrompt: (self: PromptManager, prompt: ProximityPrompt?) -> (),
	GetCurrentPrompt: (self: PromptManager) -> ProximityPrompt?,
	ManualHoldCurrent: (self: PromptManager) -> (),
	ManualStopHoldCurrent: (self: PromptManager) -> (),
	Clear: (self: PromptManager) -> (),
	Destroy: (self: PromptManager) -> (),
}

local RunService = game:GetService("RunService")

-- Client-only guard. Returning a typed shell keeps cross-context type requires safe.
if not RunService:IsClient() then
	return ({} :: any) :: PromptManager
end

local Logger = (require(script.Parent.Parent.Shared.Logger) :: any):Scope("PromptManager")

type InternalPromptManager = PromptManager & {
	_prompt: ProximityPrompt?,
	_promptAncestryConnection: RBXScriptConnection?,
	_highlight: Highlight?,
	_destroyed: boolean,
}

local PromptManager = (
	{
		_prompt = nil,
		_promptAncestryConnection = nil,
		_highlight = nil,
		_destroyed = false,
	} :: any
) :: InternalPromptManager

local function disconnectPromptConnection(self: InternalPromptManager): ()
	local connection = self._promptAncestryConnection
	if connection then
		connection:Disconnect()
		self._promptAncestryConnection = nil
	end
end

local function getHighlightAdornee(prompt: ProximityPrompt): Instance?
	local candidate = prompt.Parent
	while candidate do
		if candidate:IsA("BasePart") or candidate:IsA("Model") then
			return candidate
		end
		candidate = candidate.Parent
	end
	return nil
end

local function ensureHighlight(self: InternalPromptManager): Highlight
	local highlight = self._highlight
	if highlight then
		return highlight
	end

	local newHighlight = Instance.new("Highlight")
	newHighlight.Name = "GaxiaPromptHighlight"
	newHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
	newHighlight.FillColor = Color3.new(1, 1, 1)
	newHighlight.OutlineColor = Color3.new(1, 1, 1)
	newHighlight.FillTransparency = 0.5
	newHighlight.OutlineTransparency = 0.2
	newHighlight.Enabled = false
	newHighlight.Parent = workspace
	self._highlight = newHighlight
	return newHighlight
end

local function updateHighlight(self: InternalPromptManager): ()
	local prompt = self._prompt
	if not prompt then
		local existing = self._highlight
		if existing then
			existing.Adornee = nil
			existing.Enabled = false
		end
		return
	end

	local highlight = ensureHighlight(self)
	local adornee = getHighlightAdornee(prompt)
	highlight.Adornee = adornee
	highlight.Enabled = adornee ~= nil
end

local function stopHold(prompt: ProximityPrompt): ()
	local ok, reason = pcall(function()
		prompt:InputHoldEnd()
	end)
	if not ok then
		Logger:Warn("Could not end hold for prompt '{}': {}", prompt.Name, reason)
	end
end

local function clearCurrent(self: InternalPromptManager): ()
	local previous = self._prompt
	disconnectPromptConnection(self)
	self._prompt = nil
	updateHighlight(self)

	if previous then
		stopHold(previous)
	end
end

function PromptManager.SetCurrentPrompt(self: PromptManager, prompt: ProximityPrompt?): ()
	local internal = (self :: any) :: InternalPromptManager
	if internal._destroyed then
		Logger:Warn("SetCurrentPrompt ignored after PromptManager was destroyed")
		return
	end

	local candidate = prompt :: any
	if
		candidate ~= nil
		and (typeof(candidate) ~= "Instance" or not candidate:IsA("ProximityPrompt"))
	then
		Logger:Warn("SetCurrentPrompt expected a ProximityPrompt or nil, got {}", typeof(candidate))
		return
	end

	local nextPrompt = candidate :: ProximityPrompt?
	if nextPrompt == internal._prompt then
		updateHighlight(internal)
		return
	end

	clearCurrent(internal)
	if not nextPrompt then
		return
	end

	internal._prompt = nextPrompt
	updateHighlight(internal)
	internal._promptAncestryConnection = nextPrompt.AncestryChanged:Connect(function()
		if internal._prompt ~= nextPrompt then
			return
		end

		if nextPrompt.Parent == nil then
			clearCurrent(internal)
		else
			updateHighlight(internal)
		end
	end)
end

function PromptManager.GetCurrentPrompt(self: PromptManager): ProximityPrompt?
	return ((self :: any) :: InternalPromptManager)._prompt
end

function PromptManager.ManualHoldCurrent(self: PromptManager): ()
	local internal = (self :: any) :: InternalPromptManager
	local prompt = internal._prompt
	if not prompt then
		return
	end

	if prompt.Parent == nil then
		clearCurrent(internal)
		return
	end

	local ok, reason = pcall(function()
		prompt:InputHoldBegin()
	end)
	if not ok then
		Logger:Warn("Could not begin hold for prompt '{}': {}", prompt.Name, reason)
	end
end

function PromptManager.ManualStopHoldCurrent(self: PromptManager): ()
	local prompt = ((self :: any) :: InternalPromptManager)._prompt
	if prompt then
		stopHold(prompt)
	end
end

function PromptManager.Clear(self: PromptManager): ()
	local internal = (self :: any) :: InternalPromptManager
	if not internal._destroyed then
		clearCurrent(internal)
	end
end

function PromptManager.Destroy(self: PromptManager): ()
	local internal = (self :: any) :: InternalPromptManager
	if internal._destroyed then
		return
	end

	clearCurrent(internal)
	local highlight = internal._highlight
	if highlight then
		highlight:Destroy()
		internal._highlight = nil
	end
	internal._destroyed = true
end

return PromptManager :: PromptManager
