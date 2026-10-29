# Areas that react when players enter, and "press E" prompts

> A green area heals players who stand in it. A chest gives 50 Coins when a player holds **E**, once every 30 seconds. A door opens with **E** for 3 seconds.

**Use this when** the user asks for: "a zone", "an area that does something when you walk in", "a healing area", "a safe zone", "press E to open", "a prompt", "ProximityPrompt", "a chest that gives coins", "a door that opens" (ไทย: "โซน", "เดินเข้าพื้นที่แล้วให้ทำอะไร", "โซนฮีล", "เซฟโซน", "กด E", "ปุ่มกด E เปิด", "หีบสมบัติให้เงิน", "ประตูเปิดได้").
**Packages:** `Zone`, `Interaction`, `Cooldown`, `Economy` (it also installs `Data`) on the server, and `UI.Toast` on the client. Optional, only for *Change it*: `AntiCheat` (damage zone), `Motion3D` (sliding door). The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/HealZone`, `ServerScriptService/CoinChest`, `ServerScriptService/OpenDoor` and a LocalScript `StarterPlayer/StarterPlayerScripts/WorldMessages`.

How it works (all three packages are **server only**; the server sends messages to the client in Step 4; the scripts create their own parts, so they work in an empty Baseplate):

- `GaxiaServer.Zone.Create(name, part)` checks every 0.5 seconds whether each player's **HumanoidRootPart** (the middle of the body) is inside the part. It fires `OnEntered(player)` and `OnLeft(player)`. Leaving the game, or losing the character (respawn after death), also fires `OnLeft`. A dead player stays "inside" until they respawn: check `humanoid.Health > 0` (as HealZone does).
- `GaxiaServer.Interaction.Register(part, config)` puts a "press E" prompt (a ProximityPrompt) on a part. `OnTrigger(player)` runs on the server when a player uses it.
- `GaxiaServer.Cooldown.ConsumePlayer(player, action, seconds)` returns `true` and starts the cooldown, or `false` while it is still running.

## Step 1 — Create a healing zone

Create a **Script** in **ServerScriptService** named **HealZone**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/HealZone
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Zone"), "HealZone needs the Zone package: install it (playbooks/start/01-install-packages.md)")
local Zone = GaxiaServer.Zone
local HEAL_PER_SECOND = 10

-- The area. It must be tall enough to contain the player's body (8 studs), not a flat floor tile.
local zonePart = Instance.new("Part")
zonePart.Name = "HealZone"
zonePart.Size = Vector3.new(12, 8, 12)
zonePart.Position = Vector3.new(0, 4, -24) -- 24 studs from the middle of the Baseplate
zonePart.Anchored = true
zonePart.CanCollide = false -- players walk through it
zonePart.Transparency = 0.7
zonePart.Color = Color3.fromRGB(80, 220, 120)
zonePart.Parent = Workspace
local healZone = Zone.Create("HealZone", zonePart)
local healing: { [Player]: boolean } = {}
healZone.OnEntered:Connect(function(player: Player)
	print(`[HealZone] {player.Name} entered`)
	if healing[player] then return end -- a heal loop for this player is already running
	healing[player] = true
	while healZone:IsInside(player) do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + HEAL_PER_SECOND)
			print(`[HealZone] healed {player.Name} to {humanoid.Health}`)
		end
		task.wait(1)
	end
	healing[player] = nil
end)
healZone.OnLeft:Connect(function(player: Player)
	print(`[HealZone] {player.Name} left`)
end)
print("[HealZone] ready")
```

What it does: a player inside the green box gets 10 health every second. The `healing` table stops a second heal loop when a player leaves and re-enters quickly.

## Step 2 — Create a chest that gives Coins

Create a **Script** in **ServerScriptService** named **CoinChest**:

```lua
-- Script: ServerScriptService/CoinChest
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

for _, package in { "Interaction", "Cooldown", "Economy" } do
	assert(GaxiaServer.IsInstalled(package), `CoinChest needs the {package} package: install it (playbooks/start/01-install-packages.md)`)
end
local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local Cooldown = GaxiaServer.Cooldown
local Interaction = GaxiaServer.Interaction
local CHEST_COINS = 50
local CHEST_COOLDOWN = 30 -- seconds, per player

-- Create the WorldMessage remote now (server -> client only). Without this line, WorldMessages (Step 4)
-- waits, with a warning, until a player uses the chest. Anything a client sends here is ignored.
Net.DeclareEvent("WorldMessage")
local chest = Instance.new("Part")
chest.Name = "CoinChest"
chest.Size = Vector3.new(4, 3, 3)
chest.Position = Vector3.new(14, 1.5, -24) -- 14 studs from the green box, on its +X side
chest.Anchored = true
chest.Color = Color3.fromRGB(150, 100, 50)
chest.Parent = Workspace
local function onChestOpened(player: Player)
	if not Data.IsLoaded(player) then
		Net.FireClient(player, "WorldMessage", "Your data is still loading")
		return
	end
	-- ConsumePlayer checks AND starts the cooldown in one call.
	if not Cooldown.ConsumePlayer(player, "CoinChest", CHEST_COOLDOWN) then
		local secondsLeft = math.ceil(Cooldown.GetPlayerRemaining(player, "CoinChest"))
		Net.FireClient(player, "WorldMessage", `The chest is empty. Come back in {secondsLeft} s`)
		return
	end
	if not Economy.Add(player, "Coins", CHEST_COINS) then -- Add returns false when it fails
		Cooldown.Clear(Cooldown.Key(player, "CoinChest")) -- give the cooldown back
		Net.FireClient(player, "WorldMessage", "Could not add Coins, try again")
		return
	end
	print(`[CoinChest] {player.Name} got {CHEST_COINS} Coins`)
	Net.FireClient(player, "WorldMessage", `+{CHEST_COINS} Coins! You have {Economy.Get(player, "Coins")}`)
end

-- HoldDuration: hold E for half a second. MaxDistance: the prompt shows within 10 studs.
local handle = Interaction.Register(chest, { ActionText = "Open", ObjectText = "Chest", HoldDuration = 0.5, MaxDistance = 10, OnTrigger = onChestOpened })
assert(handle, "CoinChest: could not put a prompt on the chest")
print("[CoinChest] ready")
```

What it does: holding **E** near the chest gives 50 Coins. The cooldown is per player and checked on the server.

## Step 3 — Create a door that opens with E

Create a **Script** in **ServerScriptService** named **OpenDoor**:

```lua
-- Script: ServerScriptService/OpenDoor
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Interaction"), "OpenDoor needs the Interaction package: install it (playbooks/start/01-install-packages.md)")
local Interaction = GaxiaServer.Interaction
local OPEN_SECONDS = 3
local door = Instance.new("Part")
door.Name = "OpenDoor"
door.Size = Vector3.new(6, 10, 1)
door.Position = Vector3.new(-14, 5, -24) -- 14 studs from the green box, on its -X side
door.Anchored = true
door.Color = Color3.fromRGB(110, 110, 130)
door.Parent = Workspace
local function onDoorOpened(player: Player)
	print(`[OpenDoor] opened by {player.Name}`)
	door.CanCollide = false
	door.Transparency = 0.8
	task.wait(OPEN_SECONDS)
	door.CanCollide = true
	door.Transparency = 0
end
local handle = Interaction.Register(door, { ActionText = "Open", ObjectText = "Door", MaxDistance = 8, OnTrigger = onDoorOpened })
assert(handle, "OpenDoor: could not put a prompt on the door")
-- Hide the prompt while the door is open, so nobody can press E again.
door:GetPropertyChangedSignal("CanCollide"):Connect(function()
	handle.Prompt.Enabled = door.CanCollide
end)
print("[OpenDoor] ready")
```

What it does: **E** makes the door see-through and walkable for 3 seconds, then it closes.

## Step 4 — Show the server's messages on the player's screen

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **WorldMessages**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/WorldMessages
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.Toast"), "WorldMessages needs the UI.Toast package: install it (playbooks/start/01-install-packages.md)")
local Toast = Gaxia.UI.Toast

Gaxia.Net.OnClient("WorldMessage", function(text: any)
	print(`[WorldMessages] {tostring(text)}`)
	Toast.Show({ Text = tostring(text), Variant = "info", Duration = 3 })
end)
print("[WorldMessages] ready")
```

## Check that it works

1. Press **Play** in Studio. Output shows `[HealZone] ready`, `[CoinChest] ready`, `[OpenDoor] ready` and `[WorldMessages] ready`, and no red errors.
2. Walk into the green box. It is 24 studs from the middle of the Baseplate (`0, 0, 0`), toward -Z. To find it, select **Workspace → HealZone** in Explorer: its Position is `0, 4, -24`. Output shows `[HealZone] <YourName> entered`. Walk out: `[HealZone] <YourName> left`.
3. Walk to the brown chest (14 studs from the box, toward +X) and hold **E**. Output shows `[CoinChest] <YourName> got 50 Coins` and a toast says `+50 Coins! You have 50`. Hold **E** again: the toast says `The chest is empty. Come back in 30 s` (or less).
4. Walk to the grey door (14 studs from the box, toward -X) and press **E**. Output shows `[OpenDoor] opened by <YourName>`. You can walk through it for 3 seconds.
5. (Healing) In the **Test** tab, click **Current: Client** so it shows **Current: Server**. In the **Command Bar** (View → Command Bar), run `game.Players:GetPlayers()[1].Character.Humanoid.MaxHealth = 200`. Stand in the green box. Output shows `[HealZone] healed <YourName> to 110` (about: Roblox also regenerates health), then a higher number every second. (Raising MaxHealth is a safe test. Lowering Health from the Command Bar makes AntiCheat warn `Combat`.)

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| A zone part 1 stud tall on the floor | A box tall enough to hold the body (`Size.Y` 8 or more) | Zone checks the HumanoidRootPart, about 3 studs above the floor. A flat part never contains it. |
| A zone 1 stud thick (a thin wall or gate) | At least 10 studs thick in the direction players walk (WalkSpeed 16 = 8 studs per check) | Zone checks every 0.5 seconds. A running player moves 8 studs between two checks and can skip a thinner part. Faster players need a thicker zone. |
| `zonePart.Touched:Connect(...)` | `Zone.Create(...).OnEntered:Connect(...)` | Touched fires many times and misses players who stand still. |
| `GaxiaServer.Zone` / `GaxiaServer.Interaction` in a LocalScript | Use them in a Script; send messages with `Net.FireClient` | They are server only. The client cannot require `Gaxia_Packages_Server`. |
| Only `Cooldown = 30` in the Interaction config for a reward | `Cooldown.ConsumePlayer(player, "CoinChest", 30)` inside `OnTrigger` | The Interaction `Cooldown` field silently ignores presses. ConsumePlayer lets you tell the player how long to wait. |
| Giving Coins without `Data.IsLoaded(player)` | Check `Data.IsLoaded` first, then check what `Economy.Add` returns | Coins live in the saved data. Before it loads, `Economy.Add` gives nothing and returns `false`. |
| A Model with no parts given to `Interaction.Register` | A BasePart, an Attachment, or a Model that has parts | Register warns `cannot mount a prompt` and returns `nil`. The `assert(handle, ...)` stops the script there. |
| `humanoid:TakeDamage(10)` alone in a damage zone | Call `RegisterDamage` first (see Change it) | AntiCheat treats every health drop it was not told about as a hard `Combat` cheat. By default it only warns. Once the game turns on enforcing (`GaxiaServer.EConfig.Set("AntiCheat.Enforce", true)`, see [anticheat-and-bans](anticheat-and-bans.md) Step 4) it kicks the player. |

## Change it

- Use a part you built in Studio: name it `HealZone`. In HealZone, delete the lines from `local zonePart = Instance.new("Part")` to `zonePart.Parent = Workspace` and write `local zonePart = Workspace:WaitForChild("HealZone") :: BasePart` (`::` tells Luau it is a part). In Studio, set that part's **Anchored** = true and **CanCollide** = false.
- A damage zone (lava): in HealZone, replace the whole block from `if humanoid and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then` to its `end` (4 lines) with this. `RegisterDamage` tells AntiCheat (optional package) the damage is allowed:
  ```lua
  -- fragment
  if humanoid and humanoid.Health > 0 then
  	local combat = if GaxiaServer.IsInstalled("AntiCheat") then GaxiaServer.AntiCheat.Combat else nil
  	if combat then combat.RegisterDamage(player, 10) end
  	humanoid:TakeDamage(10)
  end
  ```
- A safe zone (`TakeDamage` hurts nobody inside): in HealZone's `OnEntered`, right after its `print` line, add `local shield = Instance.new("ForceField"); shield.Name = "SafeZoneShield"; shield.Parent = player.Character`. In `OnLeft`, after its `print` line, add `local character = player.Character; local oldShield = if character then character:FindFirstChild("SafeZoneShield") else nil; if oldShield then oldShield:Destroy() end`.
- Who is inside now: `healZone:GetPlayers()`. One name per zone: `Zone.Create` with a used name destroys the old zone. Remove a zone: `healZone:Destroy()`. Remove a prompt: `handle.Destroy()`. A different key: add `KeyboardKeyCode = Enum.KeyCode.F` to the Register config. Press instead of hold: `HoldDuration = 0`.
- A cooldown shared by everyone (one chest for the whole server): `Cooldown.Consume("CoinChest", 30)` and `Cooldown.GetRemaining("CoinChest")`. Cooldowns live in server memory: leaving and rejoining resets them. For a once-a-day chest, save the time in player data ([player-data](player-data.md)) or use the `DailyReward` package ([live-ops](live-ops.md)).
- Slide the door instead of fading it: the optional `Motion3D` package moves parts smoothly ([effects-and-feel](effects-and-feel.md)).

## See also

- [API: Zone](../api/Zone.md) · [API: Interaction](../api/Interaction.md) · [API: Cooldown](../api/Cooldown.md) · [API: Economy](../api/Economy.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Client ↔ server](../start/04-client-server-communication.md) · [UI and toasts](ui.md) · [Troubleshooting](../troubleshooting.md) · [NPC dialog and cutscenes](npc-dialog-and-cutscenes.md)
