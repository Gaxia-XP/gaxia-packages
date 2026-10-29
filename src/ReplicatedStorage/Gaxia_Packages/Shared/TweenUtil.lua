--!strict
--[[
	TweenUtil.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/TweenUtil
	Purpose: Convenience layer over TweenService — presets, table-to-TweenInfo,
	         play-and-forget, promise-based completion, and sequential chains.
--]]

-- ── Services ──
local TweenService = game:GetService("TweenService")

-- ── Dependencies ──
-- Sibling Shared modules, static paths (no WaitForChild: TweenUtil can be first
-- required inside the Gaxia loader's __index, where yielding is not allowed).
local Promise      = require(script.Parent.Promise)
local PromiseTypes = require(script.Parent.PromiseTypes) -- types only

-- ── Types ──
export type TweenInfoLike = TweenInfo | {
	Time: number?,
	EasingStyle: Enum.EasingStyle?,
	EasingDirection: Enum.EasingDirection?,
	RepeatCount: number?,
	Reverses: boolean?,
	DelayTime: number?,
}

export type ChainStep = {
	instance: Instance,
	info: TweenInfoLike,
	props: { [string]: any },
}

local TweenUtil = {}

-- ── Presets ──
-- Common-case TweenInfos so callers don't reinvent timing constants per file.
TweenUtil.Presets = {
	Linear = TweenInfo.new(0.25, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
	Quick  = TweenInfo.new(0.15, Enum.EasingStyle.Quad,   Enum.EasingDirection.Out),
	Smooth = TweenInfo.new(0.35, Enum.EasingStyle.Quad,   Enum.EasingDirection.InOut),
	Bounce = TweenInfo.new(0.50, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out),
}

-- ── Internal helpers ──

-- Convert a table-form spec into a real TweenInfo. Pass-through if already one.
local function toTweenInfo(infoOrTable: TweenInfoLike): TweenInfo
	if typeof(infoOrTable) == "TweenInfo" then
		return infoOrTable
	end
	local t = infoOrTable :: any
	return TweenInfo.new(
		t.Time or 0.25,
		t.EasingStyle or Enum.EasingStyle.Quad,
		t.EasingDirection or Enum.EasingDirection.Out,
		t.RepeatCount or 0,
		t.Reverses == true,
		t.DelayTime or 0
	)
end

-- ── Public API ──

function TweenUtil.Create(instance: Instance, infoOrTable: TweenInfoLike, props: { [string]: any }): Tween
	return TweenService:Create(instance, toTweenInfo(infoOrTable), props)
end

function TweenUtil.Play(instance: Instance, infoOrTable: TweenInfoLike, props: { [string]: any }): Tween
	local tw = TweenUtil.Create(instance, infoOrTable, props)
	tw:Play()
	return tw
end

-- Returns a Promise that resolves with the tween's final PlaybackState
-- (Completed, or Cancelled if the tween was cancelled) when it ends.
function TweenUtil.PlayAsync(
	instance: Instance,
	infoOrTable: TweenInfoLike,
	props: { [string]: any }
): PromiseTypes.Promise<Enum.PlaybackState>
	local tw = TweenUtil.Create(instance, infoOrTable, props)
	return (Promise.new(function(resolve, _reject, onCancel)
		local conn: RBXScriptConnection? = nil
		-- WHY: support cancellation so callers can stop a chain mid-flight.
		if onCancel then
			onCancel(function()
				if conn then conn:Disconnect() end
				tw:Cancel()
			end)
		end
		conn = tw.Completed:Connect(function(status: Enum.PlaybackState)
			if conn then conn:Disconnect() end
			resolve(status)
		end)
		tw:Play()
	end) :: any) :: PromiseTypes.Promise<Enum.PlaybackState>
end

-- Sequentially play a list of tween steps. Returns a Promise resolving (true)
-- when the last step ends.
function TweenUtil.Chain(steps: { ChainStep }): PromiseTypes.Promise<boolean>
	return (Promise.new(function(resolve, reject)
		task.spawn(function()
			for i, step in ipairs(steps) do
				local ok, err = pcall(function()
					-- await each step before moving to the next
					TweenUtil.PlayAsync(step.instance, step.info, step.props):await()
				end)
				if not ok then
					reject(`TweenUtil.Chain step {i} failed: {tostring(err)}`)
					return
				end
			end
			resolve(true)
		end)
	end) :: any) :: PromiseTypes.Promise<boolean>
end

return TweenUtil
