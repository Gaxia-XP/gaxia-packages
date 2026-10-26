# Areas that react when players enter, and "press E" prompts

> A green area heals players who stand in it. A chest gives 50 Coins when a player holds **E**, once every 30 seconds. A door opens with **E** for 3 seconds.

**Use this when** the user asks for: "a zone", "an area that does something when you walk in", "a healing area", "a safe zone", "press E to open", "a prompt", "ProximityPrompt", "a chest that gives coins", "a door that opens" (ไทย: "โซน", "เดินเข้าพื้นที่แล้วให้ทำอะไร", "โซนฮีล", "เซฟโซน", "กด E", "ปุ่มกด E เปิด", "หีบสมบัติให้เงิน", "ประตูเปิดได้").
**Packages:** `Zone`, `Interaction`, `Cooldown`, `Economy` (it also installs `Data`) on the server, and `UI.Toast` on the client. The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/HealZone`, `ServerScriptService/CoinChest`, `ServerScriptService/OpenDoor` and a LocalScript `StarterPlayer/StarterPlayerScripts/WorldMessages`.

How it works:

- `GaxiaServer.Zone.Create(name, part)` watches a part. Every 0.5 seconds it checks each player's **HumanoidRootPart** (the middle of the body). It fires `OnEntered(player)` and `OnLeft(player)`. Dying or leaving the game also fires `OnLeft`.
- `GaxiaServer.Interaction.Register(part, config)` puts a "press E" prompt (a ProximityPrompt) on a part. `OnTrigger(player)` runs on the server when a player uses it.
- `GaxiaServer.Cooldown.ConsumePlayer(player, action, seconds)` returns `true` and starts the cooldown, or `false` while it is still running.
- All three are **server only**. To show a message, the server sends it to the player's client (Step 4). The scripts create their own parts, so they work in an empty Baseplate.

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
zonePart.Position = Vector3.new(0, 4, -24)
zonePart.Anchored = true
zonePart.CanCollide = false -- players walk through it
zonePart.CanQuery = false
zonePart.CanTouch = false
zonePart.Transparency = 0.7
zonePart.Color = Color3.fromRGB(80, 220, 120)
zonePart.Parent = Workspace

local healZone = Zone.Create("HealZone", zonePart)
local healing: { [Player]: boolean } = {}

healZone.OnEntered:Connect(function(player: Player)
	print(`[HealZone] {player.Name} entered`)
	if healing[player] then
		return -- a heal loop for this player is already running
	end
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

assert(GaxiaServer.IsInstalled("Interaction"), "CoinChest needs the Interaction package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Cooldown"), "CoinChest needs the Cooldown package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "CoinChest needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local Cooldown = GaxiaServer.Cooldown
local Interaction = GaxiaServer.Interaction

local CHEST_COINS = 50
local CHEST_COOLDOWN = 30 -- seconds, per player

-- Create the server -> client remote now, so the client's Net.OnClient("WorldMessage") finds it.
Net.OnServer("WorldMessage", function() end)

local chest = Instance.new("Part")
chest.Name = "CoinChest"
chest.Size = Vector3.new(4, 3, 3)
chest.Position = Vector3.new(14, 1.5, -24)
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
	Economy.Add(player, "Coins", CHEST_COINS)
	print(`[CoinChest] {player.Name} got {CHEST_COINS} Coins`)
	Net.FireClient(player, "WorldMessage", `+{CHEST_COINS} Coins! You have {Economy.Get(player, "Coins")}`)
end

local handle = Interaction.Register(chest, {
	ActionText = "Open",
	ObjectText = "Chest",
	HoldDuration = 0.5, -- hold E for half a second
	MaxDistance = 10,
	OnTrigger = onChestOpened,
})
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
door.Position = Vector3.new(-14, 5, -24)
door.Anchored = true
door.Color = Color3.fromRGB(110, 110, 130)
door.Parent = Workspace

local handle = Interaction.Register(door, {
	ActionText = "Open",
	ObjectText = "Door",
	MaxDistance = 8,
	OnTrigger = function(player: Player)
		print(`[OpenDoor] opened by {player.Name}`)
		door.CanCollide = false
		door.Transparency = 0.8
		task.wait(OPEN_SECONDS)
		door.CanCollide = true
		door.Transparency = 0
	end,
})
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

1. Press **Play** in Studio.
2. Output shows `[HealZone] ready`, `[CoinChest] ready`, `[OpenDoor] ready` and `[WorldMessages] ready`, and no red errors.
3. Walk into the green box (in front of the spawn). Output shows `[HealZone] <YourName> entered`. Walk out: `[HealZone] <YourName> left`.
4. Walk to the brown chest and hold **E**. Output shows `[CoinChest] <YourName> got 50 Coins` and a toast says `+50 Coins! You have 50`. Hold **E** again: the toast says `The chest is empty. Come back in 30 s` (or less).
5. Walk to the grey door and press **E**. Output shows `[OpenDoor] opened by <YourName>`. You can walk through it for 3 seconds.
6. (Healing) In the **Command Bar** (View → Command Bar), with **Server** selected at the top of Studio, run `game.Players:GetPlayers()[1].Character.Humanoid.MaxHealth = 200`. Stand in the green box. Output shows `[HealZone] healed <YourName> to 110`, then 120, …. (Raising MaxHealth is a safe test. Lowering Health from the Command Bar makes AntiCheat warn `Combat`.)

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| A zone part 1 stud tall on the floor | A box tall enough to hold the body (`Size.Y` 8 or more) | Zone checks the HumanoidRootPart, about 3 studs above the floor. A flat part never contains it. |
| A zone 1 stud thick (a thin wall or gate) | At least 6 studs thick | Zone checks every 0.5 seconds. A running player crosses a thin part between two checks. |
| `zonePart.Touched:Connect(...)` | `Zone.Create(...).OnEntered:Connect(...)` | Touched fires many times and misses players who stand still. |
| `GaxiaServer.Zone` / `GaxiaServer.Interaction` in a LocalScript | Use them in a Script; send messages with `Net.FireClient` | They are server only. The client cannot require `Gaxia_Packages_Server`. |
| Only `Cooldown = 30` in the Interaction config for a reward | `Cooldown.ConsumePlayer(player, "CoinChest", 30)` inside `OnTrigger` | The Interaction `Cooldown` field silently ignores presses. ConsumePlayer lets you tell the player how long to wait. |
| Giving Coins without `Data.IsLoaded(player)` | Check `Data.IsLoaded` first | Coins live in the saved data. Before it loads, `Economy.Add` gives nothing and returns `false`. |
| A Model with no parts given to `Interaction.Register` | A BasePart, an Attachment, or a Model that has parts | Register warns `cannot mount a prompt` and returns `nil`. The `assert(handle, ...)` stops the script there. |
| Two `Zone.Create("HealZone", ...)` calls | One name per zone | Creating a zone with a used name destroys the old zone and its connections. |
| `humanoid:TakeDamage(10)` alone in a damage zone | Call `RegisterDamage` first (see Change it) | AntiCheat treats every health drop it was not told about as a hard `Combat` cheat. With `Enforce = true` it kicks the player. |

## Change it

- Use a part you built in Studio: name it (for example `HealZone`), delete the `Instance.new("Part")` lines, and write `local zonePart = Workspace:WaitForChild("HealZone") :: BasePart`.
- A damage zone (lava): in the loop of `HealZone`, replace the two healing lines with these. `RegisterDamage` tells AntiCheat the damage is allowed:
  ```lua
  -- fragment
  local combat = if GaxiaServer.IsInstalled("AntiCheat") then GaxiaServer.AntiCheat.Combat else nil
  if combat then combat.RegisterDamage(player, 10) end
  humanoid:TakeDamage(10)
  ```
- A safe zone (no damage inside): in `OnEntered` add a `ForceField` to the character; in `OnLeft` destroy it. Check `healZone:IsInside(player)` in your damage code.
- Who is inside now: `healZone:GetPlayers()`. Remove a zone: `healZone:Destroy()`. Remove a prompt: `handle.Destroy()`.
- A different key: add `KeyboardKeyCode = Enum.KeyCode.F` to the Register config. Press instead of hold: `HoldDuration = 0`.
- A cooldown shared by everyone (one chest for the whole server): `Cooldown.Consume("CoinChest", 30)` and `Cooldown.GetRemaining("CoinChest")`.
- Cooldowns live in server memory: leaving and rejoining resets them. For a once-a-day chest, save the time in player data ([player-data](player-data.md)) or use the `DailyReward` package ([live-ops](live-ops.md)).
- Slide the door instead of fading it: the `Motion3D` package moves parts smoothly ([effects-and-feel](effects-and-feel.md)).

## See also

- [API: Zone](../api/Zone.md) · [API: Interaction](../api/Interaction.md) · [API: Cooldown](../api/Cooldown.md) · [API: Economy](../api/Economy.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Client ↔ server](../start/04-client-server-communication.md) · [UI and toasts](ui.md) · [Troubleshooting](../troubleshooting.md)
