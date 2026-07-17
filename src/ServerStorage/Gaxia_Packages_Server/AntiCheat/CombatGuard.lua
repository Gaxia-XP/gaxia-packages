--!strict
--[[
	Module : CombatGuard
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.CombatGuard
	Purpose : Watches Humanoid.HealthChanged on every player. A health DROP
	          without a recent `RegisterDamage` call means the change did not
	          go through the game's authorised combat pathway — likely an
	          exploit writing directly to Humanoid.Health, an unsanctioned
	          remote handler, or a hostile mutation.

	Game-code integration:
		local CombatGuard = require(... .AntiCheat.CombatGuard)
		-- Just before applying damage:
		CombatGuard.RegisterDamage(victim, 25)
		victim.Humanoid:TakeDamage(25)

	No call to RegisterDamage → next HP drop on that humanoid raises a flag
	on the player itself ("StatTamper" style — the only certainty is that an
	unauthorised mutation happened on their character).
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Maid      = SharedPkg.Maid

-- ── Config (server-side, see ServerStorage/Gaxia_Packages_Server/Config) ──
-- FindFirstChild (not WaitForChild): detectors are required THROUGH the server
-- loader's no-yield __index metamethod; WaitForChild would yield across that
-- boundary. Config's body is a pure table (no yields), so require is safe.
local Config = require(script.Parent.Parent:FindFirstChild("Config") :: ModuleScript) :: any

-- ── Tunables ──
-- AUTH_WINDOW must exceed network round-trip + any TakeDamage queuing slop.
-- Pre-registered damage older than this is considered "leaked", not authorised.
local AUTH_WINDOW : number = 1.0
-- Tolerance for floating-point HP comparisons + minor passive regen ticks
-- from Roblox's built-in health regen (1% per second by default).
local NOISE_FLOOR : number = 0.5

local CombatGuard = {}
CombatGuard.Name = "Combat"

local orchestratorRef : any = nil

-- (humanoid) → { amount, expiresAtClock }
type Auth = { amount: number, expiresAtClock: number }
local pending : { [Humanoid]: Auth } = setmetatable({}, { __mode = "k" }) :: any
local playerMaids : { [Player]: any } = {}

-- Public: declare an authorised incoming damage tick. The next health drop on
-- `victim` within AUTH_WINDOW will be considered legitimate up to `amount`.
function CombatGuard.RegisterDamage(victim: Player | Humanoid, amount: number): ()
	local humanoid : Humanoid?
	if typeof(victim) == "Instance" and (victim :: any):IsA("Humanoid") then
		humanoid = victim :: Humanoid
	elseif typeof(victim) == "Instance" and (victim :: any):IsA("Player") then
		local char = (victim :: Player).Character
		humanoid = char and char:FindFirstChildOfClass("Humanoid")
	end
	if not humanoid then return end
	pending[humanoid] = { amount = amount, expiresAtClock = os.clock() + AUTH_WINDOW }
end

local function attachHumanoid(player: Player, humanoid: Humanoid)
	local maid = playerMaids[player]
	if not maid then return end

	local lastHealth = humanoid.Health
	maid:GiveTask(humanoid.HealthChanged:Connect(function(newHealth: number)
		local drop = lastHealth - newHealth
		lastHealth = newHealth
		if drop <= NOISE_FLOOR then return end -- ignore regen / no-op writes

		local auth = pending[humanoid]
		if auth and os.clock() < auth.expiresAtClock and drop <= auth.amount + NOISE_FLOOR then
			pending[humanoid] = nil
			return
		end
		-- Unauthorised drop — flag the player as a hard violation. Roblox
		-- health changes on a player's humanoid must always be server-authored
		-- through the official pathway.
		if orchestratorRef then
			orchestratorRef.Flag(player, "Combat", Config.AntiCheat.Combat.Severity)
		end
	end))
end

local function attachPlayer(player: Player)
	if playerMaids[player] then return end
	local maid = Maid.new()
	playerMaids[player] = maid

	local function hookCharacter(character: Model)
		local hum = character:WaitForChild("Humanoid", 5) :: Humanoid?
		if hum then attachHumanoid(player, hum) end
	end

	if player.Character then hookCharacter(player.Character) end
	maid:GiveTask(player.CharacterAdded:Connect(hookCharacter))
end

local function detachPlayer(player: Player)
	local maid = playerMaids[player]
	if maid then
		maid:DoCleaning()
		playerMaids[player] = nil
	end
end

function CombatGuard.Init(orchestrator: any): ()
	orchestratorRef = orchestrator
	for _, p in ipairs(Players:GetPlayers()) do attachPlayer(p) end
	Players.PlayerAdded:Connect(attachPlayer)
	Players.PlayerRemoving:Connect(detachPlayer)
end

return CombatGuard
