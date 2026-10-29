# Sword combat and enemy NPCs

> Every player gets a Sword. Green Zombies chase the nearest player and hit them. A Zombie dies after 3 sword hits, pays 10 Coins to its killer and comes back 5 seconds later.

**Use this when** the user asks for: "combat", "a sword", "a melee weapon", "hit enemies", "enemy NPC", "mobs", "zombies that chase the player", "NPC that attacks", "kill enemies for coins", "enemy respawn" (ไทย: "ระบบต่อสู้", "ดาบ", "อาวุธ", "ฟันศัตรู", "มอนสเตอร์", "มอน", "ซอมบี้ไล่ผู้เล่น", "NPC โจมตี", "ฆ่ามอนได้เงิน", "มอนเกิดใหม่").
**Packages:** `Economy` (it also installs `Data`), `Tool` and `Cooldown`. Also pick `AntiCheat`: it is optional, but this playbook is written so the AntiCheat does not flag legit hits. The scripts stop with a clear message if a needed package is missing.
**You will create:** the Scripts `ServerScriptService/CombatSword` and `ServerScriptService/EnemyNPCs`, and a LocalScript `StarterPlayer/StarterPlayerScripts/SwordInput`.

How it works (the scripts make their own Sword and Zombies, so they work in an empty Baseplate):

- **The server decides every hit.** The client only says "I swung". The server checks that the player is alive, holds the real Sword and is not swinging too fast. Then it finds the closest Zombie within 8 studs and takes 20 health.
- Each Zombie has its own `Trove`. Its body, its `Died` connection and its brain loop go into it. When the Zombie dies, `trove:Destroy()` removes all of them at once.
- An enemy hit on a player first calls `GaxiaServer.AntiCheat.Combat.RegisterDamage`. Without it, the AntiCheat treats every health drop as a cheat (reason `Combat`).

## Step 1 — Give the Sword and check every swing on the server

Create a **Script** in **ServerScriptService** named **CombatSword**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/CombatSword
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

for _, package in { "Tool", "Cooldown" } do
	assert(GaxiaServer.IsInstalled(package), `CombatSword needs the {package} package: install it (playbooks/start/01-install-packages.md)`)
end
local Net = Gaxia.Net
local Trove = Gaxia.Trove
local Tool = GaxiaServer.Tool
local Cooldown = GaxiaServer.Cooldown

local SWORD_DAMAGE = 20 -- damage per hit. The server decides it, never the client.
local SWING_COOLDOWN = 0.5 -- seconds between two swings of one player
local HIT_RANGE = 8 -- studs from the player's body to the enemy's body

-- Gives the player a Sword in the Backpack. Tool.Create makes a Tool the AntiCheat accepts.
local function giveSword(player: Player)
	task.wait() -- let Roblox finish the new Backpack
	local backpack = player:WaitForChild("Backpack", 5)
	local character = player.Character
	if backpack == nil or backpack:FindFirstChild("Sword") or (character and character:FindFirstChild("Sword")) then
		return
	end
	local sword = Tool.Create("Sword", { CanBeDropped = false })
	local handle = Instance.new("Part")
	handle.Name = "Handle" -- the part the player holds
	handle.Size = Vector3.new(0.4, 4, 0.4)
	handle.Color = Color3.fromRGB(200, 200, 210)
	handle.CanCollide = false
	handle.Parent = sword
	sword.Parent = backpack
	print(`[CombatSword] gave a Sword to {player.Name}`)
end

-- The closest living enemy within HIT_RANGE of `position`, or nil.
local function findClosestEnemy(position: Vector3): (Model?, Humanoid?)
	local bestEnemy: Model?, bestHumanoid: Humanoid? = nil, nil
	local bestDistance = HIT_RANGE
	for _, enemy in CollectionService:GetTagged("Enemy") do
		local humanoid = enemy:FindFirstChildOfClass("Humanoid")
		local root = enemy:FindFirstChild("HumanoidRootPart")
		if enemy:IsA("Model") and humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			local distance = (root.Position - position).Magnitude
			if distance <= bestDistance then
				bestEnemy, bestHumanoid, bestDistance = enemy, humanoid, distance
			end
		end
	end
	return bestEnemy, bestHumanoid
end

-- The client only says "I swung". The server checks everything and picks the enemy.
Net.OnServer("SwordSwing", function(player: Player)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if character == nil or humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return -- no living character
	end
	local sword = character:FindFirstChild("Sword")
	if sword == nil or not sword:IsA("Tool") or not Tool.IsTracked(sword) then
		return -- not holding the real Sword (it must be equipped, and made by Tool.Create)
	end
	if not Cooldown.ConsumePlayer(player, "SwordSwing", SWING_COOLDOWN) then
		return -- swinging too fast
	end
	local enemy, enemyHumanoid = findClosestEnemy(root.Position)
	if enemy == nil or enemyHumanoid == nil then
		print(`[CombatSword] {player.Name} swung and missed`)
		return
	end
	enemy:SetAttribute("LastHitUserId", player.UserId) -- EnemyNPCs reads it to pay the killer
	enemyHumanoid:TakeDamage(SWORD_DAMAGE)
	print(`[CombatSword] {player.Name} hit {enemy.Name}: {enemyHumanoid.Health} HP left`)
end, { rate = 4, burst = 4 })

local function onPlayerAdded(player: Player)
	local trove = Trove.new()
	trove:AttachToInstance(player) -- disconnects when the player leaves
	trove:Connect(player.CharacterAdded, function()
		giveSword(player)
	end)
	if player.Character then
		task.spawn(giveSword, player)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[CombatSword] ready")
```

What it does: on every spawn the player gets a Sword made by `Tool.Create` (the AntiCheat `Backpack` detector accepts it). Each `SwordSwing` is checked on the server. A hit writes the player's `UserId` on the Zombie, so Step 2 knows who killed it.

## Step 2 — Spawn Zombies that chase, attack, die and come back

Create a **Script** in **ServerScriptService** named **EnemyNPCs**:

```lua
-- Script: ServerScriptService/EnemyNPCs
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Economy"), "EnemyNPCs needs the Economy package: install it (playbooks/start/01-install-packages.md)")
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local Trove = Gaxia.Trove
-- Optional: tells the AntiCheat that enemy hits are allowed. nil when AntiCheat is not installed.
local Combat = if GaxiaServer.IsInstalled("AntiCheat") then GaxiaServer.AntiCheat.Combat else nil

local ENEMY_HEALTH = 60
local ENEMY_SPEED = 10 -- players walk at 16, so they can run away
local CHASE_RANGE = 60 -- studs: enemies chase players closer than this
local ATTACK_RANGE = 5 -- studs: enemies hit players closer than this
local ATTACK_DAMAGE = 10
local ATTACK_COOLDOWN = 1 -- seconds between two hits of one enemy
local HURT_GAP = 0.5 -- seconds: a player takes at most one enemy hit in this time
local KILL_REWARD = 10 -- Coins for the player who killed the enemy
local RESPAWN_SECONDS = 5
local THINK_EVERY = 0.2 -- seconds between two "where is the nearest player?" checks
local SPAWN_POINTS = { Vector3.new(-20, 4, -40), Vector3.new(0, 4, -40), Vector3.new(20, 4, -40) }

local lastHurt: { [Player]: number } = {} -- when each player last took an enemy hit

-- Builds one enemy: a body part, a head and a Humanoid. No model from the Toolbox needed.
local function buildEnemy(position: Vector3): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	model.Name = "Zombie"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart" -- the Humanoid moves this part
	root.Size = Vector3.new(2, 2, 1)
	root.Color = Color3.fromRGB(90, 160, 90)
	root.Position = position
	root.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head" -- the name and health bar show above it
	head.Size = Vector3.new(1.5, 1.5, 1.5)
	head.Color = Color3.fromRGB(120, 200, 120)
	head.Position = position + Vector3.new(0, 1.75, 0)
	head.Parent = model
	local weld = Instance.new("WeldConstraint") -- keeps the head on the body
	weld.Part0 = root
	weld.Part1 = head
	weld.Parent = root
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15 -- R15 + HipHeight: the body floats 2 studs up, no legs needed
	humanoid.HipHeight = 2
	humanoid.RequiresNeck = false -- no neck joint: do not die from it
	humanoid.MaxHealth = ENEMY_HEALTH
	humanoid.Health = ENEMY_HEALTH
	humanoid.WalkSpeed = ENEMY_SPEED
	humanoid.Parent = model
	model.PrimaryPart = root
	CollectionService:AddTag(model, "Enemy") -- CombatSword finds enemies by this tag
	model.Parent = Workspace
	root:SetNetworkOwner(nil) -- the server moves enemies, not a nearby player's computer
	return model, humanoid, root
end

-- The nearest living player within CHASE_RANGE, with their Humanoid, body part and distance.
local function findNearestPlayer(position: Vector3): (Player?, Humanoid?, BasePart?, number)
	local bestPlayer: Player?, bestHumanoid: Humanoid?, bestRoot: BasePart? = nil, nil, nil
	local bestDistance = CHASE_RANGE
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			local distance = (root.Position - position).Magnitude
			if distance < bestDistance then
				bestPlayer, bestHumanoid, bestRoot, bestDistance = player, humanoid, root, distance
			end
		end
	end
	return bestPlayer, bestHumanoid, bestRoot, bestDistance
end

-- Every enemy hit on a player goes through here.
local function hurtPlayer(player: Player, humanoid: Humanoid)
	local now = os.clock()
	if now - (lastHurt[player] or 0) < HURT_GAP then
		return -- hit a moment ago by another enemy
	end
	lastHurt[player] = now
	if Combat then
		Combat.RegisterDamage(humanoid, ATTACK_DAMAGE) -- right before TakeDamage, or AntiCheat flags "Combat"
	end
	humanoid:TakeDamage(ATTACK_DAMAGE)
	print(`[EnemyNPCs] a Zombie hit {player.Name}: {humanoid.Health} HP left`)
end

-- The enemy's brain: walk to the nearest player and hit them when close. Stops when the enemy dies.
local function runBrain(humanoid: Humanoid, root: BasePart)
	local lastAttack = 0
	while humanoid.Health > 0 and root.Parent ~= nil do
		local player, playerHumanoid, playerRoot, distance = findNearestPlayer(root.Position)
		if player and playerHumanoid and playerRoot then
			humanoid:MoveTo(playerRoot.Position)
			if distance <= ATTACK_RANGE and os.clock() - lastAttack >= ATTACK_COOLDOWN then
				lastAttack = os.clock()
				hurtPlayer(player, playerHumanoid)
			end
		else
			humanoid:MoveTo(root.Position) -- nobody near: stand still
		end
		task.wait(THINK_EVERY)
	end
end

-- Pays the player who hit the enemy last (CombatSword wrote their UserId on it).
local function rewardKiller(model: Model)
	local userId = model:GetAttribute("LastHitUserId")
	local killer = if typeof(userId) == "number" then Players:GetPlayerByUserId(userId) else nil
	if killer == nil or not Data.IsLoaded(killer) then
		return -- nobody hit it, the killer left, or their data is still loading
	end
	if Economy.Add(killer, "Coins", KILL_REWARD) then
		print(`[EnemyNPCs] {killer.Name} killed a Zombie: +{KILL_REWARD} Coins, now {Economy.Get(killer, "Coins")}`)
	end
end

local function spawnEnemy(spawnPoint: Vector3)
	local trove = Trove.new() -- everything this enemy owns: its model, connections and brain
	local model, humanoid, root = buildEnemy(spawnPoint)
	trove:Add(model)
	local dead = false
	local function onDied()
		if dead then
			return -- already handled
		end
		dead = true
		rewardKiller(model)
		task.delay(1, function()
			trove:Destroy() -- removes the body, stops the brain, disconnects
		end)
		task.delay(RESPAWN_SECONDS, spawnEnemy, spawnPoint)
	end
	trove:Connect(humanoid.Died, onDied)
	trove:Add(task.spawn(function()
		runBrain(humanoid, root)
		onDied() -- the brain also stops when the body is gone (fell off the map)
	end))
	print(`[EnemyNPCs] spawned a Zombie at {spawnPoint}`)
end

Players.PlayerRemoving:Connect(function(player: Player)
	lastHurt[player] = nil
end)

for _, spawnPoint in SPAWN_POINTS do
	spawnEnemy(spawnPoint)
end

print("[EnemyNPCs] ready")
```

What it does: 3 Zombies stand 40 studs from the middle of the Baseplate, toward -Z. Every 0.2 seconds each one walks to the nearest player within 60 studs and hits them when closer than 5 studs. On death the killer gets 10 Coins, the body goes away after 1 second, and a new Zombie spawns 5 seconds later at the same place.

## Step 3 — Send a swing when the player clicks

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **SwordInput**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/SwordInput
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

local Net = Gaxia.Net
local player = Players.LocalPlayer

local function onSwordActivated()
	-- Send only "I swung". No target, no damage: the server decides both.
	Net.FireServer("SwordSwing")
	print("[SwordInput] swing")
end

-- An equipped Tool moves into the character. Connect each Sword once.
local function onChildAdded(child: Instance)
	if child:IsA("Tool") and child.Name == "Sword" and not child:GetAttribute("SwordInputHooked") then
		child:SetAttribute("SwordInputHooked", true)
		child.Activated:Connect(onSwordActivated)
	end
end

local function onCharacterAdded(character: Model)
	character.ChildAdded:Connect(onChildAdded) -- goes away with the character
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded(player.Character)
end

print("[SwordInput] ready")
```

What it does: `Activated` fires when the player clicks while holding the Sword. The script only tells the server; the server does the rest.

## Check that it works

1. Press **Play** in Studio. Output shows `[CombatSword] ready`, `[EnemyNPCs] ready` and `[SwordInput] ready`, and no red errors.
2. Output shows `[EnemyNPCs] spawned a Zombie at ...` three times, then `[CombatSword] gave a Sword to <YourName>`.
3. Three green Zombies walk toward you. Press **1** to hold the Sword.
4. Stand next to a Zombie and click. Output shows `[SwordInput] swing` and `[CombatSword] <YourName> hit Zombie: 40 HP left`. Click far from every Zombie: `[CombatSword] <YourName> swung and missed`.
5. Hit the same Zombie 3 times. Output shows `[EnemyNPCs] <YourName> killed a Zombie: +10 Coins, now 10` (more if you already had Coins). About 5 seconds later: `[EnemyNPCs] spawned a Zombie at ...`.
6. Let a Zombie touch you. Output shows `[EnemyNPCs] a Zombie hit <YourName>: 90 HP left`. For the first 10 seconds after you spawn, the Baseplate's spawn shield (a ForceField) blocks the damage: the number stays at `100`.
7. If AntiCheat is installed: Output has **no** yellow line `[AntiCheat] observe mode — would take HARD action against <YourName> (...): Combat`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| The client sends `"SwordSwing", zombie, 20` (a target or damage) | The client sends only `"SwordSwing"` | A cheater can send any target and any damage. The server finds the target and knows the damage. |
| `sword.Handle.Touched` deals the damage | The distance check in `SwordSwing` | Touched misses fast swings and can be faked. The server checks the real distance. |
| `humanoid:TakeDamage(10)` on a player alone | `Combat.RegisterDamage(humanoid, 10)` right before it | AntiCheat flags every health drop it was not told about (reason `Combat`). With `AntiCheat.Enforce` on it kicks the player. |
| Two hits on one player in the same moment | One hit at most every `HURT_GAP` seconds (`hurtPlayer`) | `RegisterDamage` remembers only the last amount. A second drop in the same moment is flagged `Combat`. |
| `Instance.new("Tool")` or a Tool from the Toolbox put in the Backpack | `Tool.Create("Sword", ...)` | Untracked Tools are flagged `Backpack` (and destroyed once enforcing is on). |
| Enemy parts with `Anchored = true` | Leave them unanchored (the default for `Instance.new("Part")`) | An anchored body never moves: `MoveTo` does nothing. |
| `while true do` per enemy with no exit | `while humanoid.Health > 0 and root.Parent ~= nil do`, and the brain thread in the Trove | A loop that never ends keeps running (and hitting) after the enemy is gone. |
| Paying Coins in CombatSword when health reaches 0 | Pay once in `onDied` (the `dead` flag) | Two fast hits can both see 0 health and pay twice. |

## Change it

- More Zombies, or other places: add or change the `Vector3` values in `SPAWN_POINTS` (`y = 4` stands on the Baseplate).
- Harder or easier: change `ENEMY_HEALTH`, `ENEMY_SPEED`, `ATTACK_DAMAGE`, `ATTACK_COOLDOWN` (EnemyNPCs) or `SWORD_DAMAGE`, `HIT_RANGE`, `SWING_COOLDOWN` (CombatSword). Bigger reward: `KILL_REWARD`.
- Your own enemy model: put a Model named `Zombie` in **ServerStorage** with an unanchored part named `HumanoidRootPart` and a `Humanoid`. In `buildEnemy`, replace the lines from `local model = Instance.new("Model")` to `humanoid.HipHeight = 2` with:
  ```lua
  -- fragment
  local model = (game:GetService("ServerStorage"):WaitForChild("Zombie") :: Model):Clone()
  local root = model:WaitForChild("HumanoidRootPart") :: BasePart
  local humanoid = model:WaitForChild("Humanoid") :: Humanoid
  model:PivotTo(CFrame.new(position))
  ```
- Players can hit players (PvP): in `findClosestEnemy`, also check other players' characters, and call `Combat.RegisterDamage(victimHumanoid, SWORD_DAMAGE)` right before `TakeDamage` (the same way as `hurtPlayer`).
- Enemies that walk around walls: the optional `AI` package follows a target with pathfinding (`GaxiaServer.AI.Follow`, see [API: AI](../api/AI.md)).
- Only owners get the Sword: give it from saved items instead ([items-and-inventory](items-and-inventory.md), Step 3).
- Show Coins on the leaderboard: [currency-and-leaderstats](currency-and-leaderstats.md). Swing sounds and hit effects: [effects-and-feel](effects-and-feel.md).

## See also

- [API: AntiCheat](../api/AntiCheat.md) · [API: Tool](../api/Tool.md) · [API: Cooldown](../api/Cooldown.md) · [API: Economy](../api/Economy.md) · [API: Trove](../api/Core.Trove.md) · [API: Net](../api/Core.NetService.md)
- [Items and inventory](items-and-inventory.md) · [Anti-cheat and bans](anticheat-and-bans.md) · [Signals, cleanup and timing](signals-cleanup-and-timing.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Troubleshooting](../troubleshooting.md)
