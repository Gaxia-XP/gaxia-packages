--!strict
--[[
	Player.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/Util/Player
	Purpose: Character/humanoid/HRP access plus lifecycle event helpers.
	         All getters can yield up to `timeout` seconds; check for nil.
--]]

local Players = game:GetService("Players")

local PlayerUtil = {}

-- ── Constants ──
local DEFAULT_TIMEOUT: number = 5

-- ── Getters ──

-- Returns the player's Character, waiting up to `timeout` seconds.
-- Nil result means "character did not spawn in time" — never error.
function PlayerUtil.GetCharacter(player: Player, timeout: number?): Model?
	if player.Character then
		return player.Character
	end
	-- Bounded poll, NOT CharacterAdded:Wait(): the Wait is unbounded (it only
	-- ever returns once a character spawns), which contradicted this module's
	-- timeout contract — callers hung forever on character-less targets
	-- (CharacterAutoLoads off, pre-spawn) and leaked the thread when the player
	-- left before spawning.
	local deadline: number = os.clock() + (timeout or DEFAULT_TIMEOUT)
	while os.clock() < deadline do
		if player.Character then
			return player.Character
		end
		if player.Parent == nil then
			-- Player left; no character is ever coming.
			return nil
		end
		task.wait(0.05)
	end
	return player.Character
end

-- Returns the Humanoid inside the player's character, or nil on timeout.
function PlayerUtil.GetHumanoid(player: Player, timeout: number?): Humanoid?
	local char: Model? = PlayerUtil.GetCharacter(player, timeout)
	if not char then return nil end
	-- WaitForChild is bounded by `timeout` to avoid infinite yield.
	local humanoid: Instance? = char:WaitForChild("Humanoid", timeout or DEFAULT_TIMEOUT)
	return humanoid :: Humanoid?
end

-- Returns HumanoidRootPart, or nil on timeout.
function PlayerUtil.GetHRP(player: Player, timeout: number?): BasePart?
	local char: Model? = PlayerUtil.GetCharacter(player, timeout)
	if not char then return nil end
	local hrp: Instance? = char:WaitForChild("HumanoidRootPart", timeout or DEFAULT_TIMEOUT)
	return hrp :: BasePart?
end

-- ── State ──

-- True if the player has a character with a living Humanoid.
function PlayerUtil.IsAlive(player: Player): boolean
	local char: Model? = player.Character
	if not char then return false end
	local humanoid: Humanoid? = char:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	return humanoid.Health > 0
end

-- Teleports the player by setting HRP.CFrame. No-op if HRP is unavailable.
function PlayerUtil.Teleport(player: Player, cframe: CFrame): ()
	local hrp: BasePart? = PlayerUtil.GetHRP(player)
	if not hrp then return end
	hrp.CFrame = cframe
end

-- ── Lifecycle ──

-- Calls `fn(character)` for the current character (if any) AND every future
-- CharacterAdded. Returns the underlying RBXScriptConnection — caller is
-- responsible for :Disconnect()ing on cleanup.
function PlayerUtil.OnCharacterAdded(player: Player, fn: (Model) -> ()): RBXScriptConnection
	if player.Character then
		-- Fire async so the caller's connection isn't held by a long handler.
		task.spawn(fn, player.Character)
	end
	return player.CharacterAdded:Connect(fn)
end

-- Iterates all currently-connected players.
function PlayerUtil.ForEachPlayer(fn: (Player) -> ()): ()
	for _, player in ipairs(Players:GetPlayers()) do
		fn(player)
	end
end

-- Calls `fn(player)` for every current player AND every future PlayerAdded.
-- Mirrors OnCharacterAdded — caller manages the returned connection.
function PlayerUtil.OnPlayerAdded(fn: (Player) -> ()): RBXScriptConnection
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(fn, player)
	end
	return Players.PlayerAdded:Connect(fn)
end

return PlayerUtil
