--!strict
-- ─────────────────────────────────────────────────────────────
-- RagdollService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/RagdollService
-- Purpose : Toggle a character into a physics ragdoll and back — combat knock-
--           down, raid defeat, obby falls. Enable() swaps every Motor6D for a
--           BallSocketConstraint (built from the joint's own C0/C1 attachments)
--           and platform-stands the Humanoid so the limbs go limp; Disable()
--           rebuilds the rig and stands it back up. WatchState observes Humanoid
--           state transitions WITHOUT driving them (a detector, not a controller)
--           so games can react to FallingDown/Dead and decide to ragdoll.
--
-- Access  : Gaxia.Ragdoll  (server)
--   Gaxia.Ragdoll.Enable(character) ; task.wait(2) ; Gaxia.Ragdoll.Disable(character)
--   Gaxia.Ragdoll.AutoRagdollOnDeath(character)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

local RAGDOLL_FLAG : string = "__GaxiaRagdolled"
local PART_FLAG : string = "__GaxiaRagdollPart"

local RagdollService = {}

RagdollService.OnRagdoll = Signal.new() -- (character)
RagdollService.OnRecover = Signal.new() -- (character)

local function getHumanoid(character: Instance): Humanoid?
	return character:FindFirstChildOfClass("Humanoid")
end

-- ── Enable ──

function RagdollService.Enable(character: Instance): boolean
	if character:GetAttribute(RAGDOLL_FLAG) then
		return false
	end
	local hum = getHumanoid(character)
	if not hum then
		return false
	end

	for _, motor in ipairs(character:GetDescendants()) do
		if motor:IsA("Motor6D") and motor.Part0 and motor.Part1 then
			local a0 = Instance.new("Attachment")
			a0.CFrame = motor.C0
			a0:SetAttribute(PART_FLAG, true)
			a0.Parent = motor.Part0

			local a1 = Instance.new("Attachment")
			a1.CFrame = motor.C1
			a1:SetAttribute(PART_FLAG, true)
			a1.Parent = motor.Part1

			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket:SetAttribute(PART_FLAG, true)
			socket.Parent = motor.Part0

			motor.Enabled = false
		end
	end

	hum.PlatformStand = true
	hum.AutoRotate = false
	pcall(function()
		hum:ChangeState(Enum.HumanoidStateType.Physics)
	end)

	character:SetAttribute(RAGDOLL_FLAG, true)
	RagdollService.OnRagdoll:Fire(character)
	return true
end

-- ── Disable / Recover ──

function RagdollService.Disable(character: Instance): boolean
	if not character:GetAttribute(RAGDOLL_FLAG) then
		return false
	end
	for _, d in ipairs(character:GetDescendants()) do
		if d:GetAttribute(PART_FLAG) then
			d:Destroy()
		end
	end
	for _, motor in ipairs(character:GetDescendants()) do
		if motor:IsA("Motor6D") then
			motor.Enabled = true
		end
	end
	local hum = getHumanoid(character)
	if hum then
		hum.PlatformStand = false
		hum.AutoRotate = true
		pcall(function()
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
	character:SetAttribute(RAGDOLL_FLAG, false)
	RagdollService.OnRecover:Fire(character)
	return true
end

function RagdollService.IsRagdolled(character: Instance): boolean
	return character:GetAttribute(RAGDOLL_FLAG) == true
end

function RagdollService.Toggle(character: Instance): ()
	if RagdollService.IsRagdolled(character) then
		RagdollService.Disable(character)
	else
		RagdollService.Enable(character)
	end
end

-- ── State watch (detector only — never drives the Humanoid) ──

function RagdollService.WatchState(humanoid: Humanoid, fn: (old: Enum.HumanoidStateType, new: Enum.HumanoidStateType) -> ()): RBXScriptConnection
	return humanoid.StateChanged:Connect(fn)
end

-- Convenience: ragdoll on death (still detector-driven — Died fires, we react).
function RagdollService.AutoRagdollOnDeath(character: Instance): RBXScriptConnection?
	local hum = getHumanoid(character)
	if not hum then
		return nil
	end
	return hum.Died:Connect(function()
		RagdollService.Enable(character)
	end)
end

return RagdollService
