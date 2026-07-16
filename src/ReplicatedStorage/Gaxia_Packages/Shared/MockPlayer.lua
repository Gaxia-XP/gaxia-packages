--!strict
-- ─────────────────────────────────────────────────────────────
-- MockPlayer.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/MockPlayer.lua
-- Purpose:  Fake Player-like object for unit tests so server-side
--           code that takes a Player can be exercised without a
--           real client session.
-- ─────────────────────────────────────────────────────────────


-- WHY: depend on sibling Signal for event semantics matching Roblox events.
local Signal = require(script.Parent:WaitForChild("Signal"))

-- ── Types ──
export type MockPlayerObj = {
	Name           : string,
	UserId         : number,
	DisplayName    : string,
	Character      : Model?,
	IsA            : (self: MockPlayerObj, className: string) -> boolean,
	GetMouse       : (self: MockPlayerObj) -> any,
	Kick           : (self: MockPlayerObj, reason: string?) -> (),
	CharacterAdded : any,
	Chatted        : any,
	SpawnCharacter : (self: MockPlayerObj) -> Model,
}

-- ── Constants ──
local DEFAULT_NAME: string = "MockPlayer"
local DEFAULT_USER_ID: number = -1

local MockPlayer = {}

-- ── Constructor ──
function MockPlayer.new(opts: { name: string?, userId: number?, displayName: string? }?): MockPlayerObj
	local o = opts or {}
	local name: string = o.name or DEFAULT_NAME
	local userId: number = o.userId or DEFAULT_USER_ID
	local displayName: string = o.displayName or name

	local self = {} :: any
	self.Name = name
	self.UserId = userId
	self.DisplayName = displayName
	self.Character = nil :: Model?
	self.CharacterAdded = Signal.new()
	self.Chatted = Signal.new()
	-- WHY: tests assert on _kicked instead of actually killing anything.
	self._kicked = nil :: string?

	function self:IsA(className: string): boolean
		return className == "Player"
	end

	function self:GetMouse(): any
		-- Return a minimal stub; tests that care will replace.
		return {
			Hit    = CFrame.new(),
			Target = nil :: Instance?,
			X      = 0,
			Y      = 0,
		}
	end

	function self:Kick(reason: string?): ()
		local s = self :: any
		s._kicked = reason or ""
	end

	function self:SpawnCharacter(): Model
		local character: Model = Instance.new("Model")
		character.Name = self.Name

		local humanoid: Humanoid = Instance.new("Humanoid")
		humanoid.Parent = character

		local hrp: Part = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Size = Vector3.new(2, 2, 1)
		hrp.Anchored = true
		hrp.Parent = character

		character.PrimaryPart = hrp

		local s = self :: any
		s.Character = character
		s.CharacterAdded:Fire(character)
		return character
	end

	return self :: MockPlayerObj
end

return MockPlayer
