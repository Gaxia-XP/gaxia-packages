# Pets: hatch from an egg, equip, and boost Coins

> Players buy an egg for 100 Coins (in the pet panel or at an egg in the world), get a random pet, equip up to 3 pets, and every equipped pet makes them earn more Coins. New players get a free Cat.

**Use this when** the user asks for: "pets", "eggs", "hatch an egg", "pet simulator", "equip pets", "pet boost", "pet multiplier", "pet inventory" (ไทย: "สัตว์เลี้ยง", "เพ็ท", "ไข่", "เปิดไข่", "ฟักไข่", "สุ่มเพ็ท", "ใส่เพ็ท", "เพ็ทเพิ่มเงิน", "ตัวคูณเงิน").
**Packages:** `Pet` and, for the egg in Step 3, `Interaction`. Picking `Pet` also installs the pet panel `UI.PetController` (and `Economy`, `Data`, `Loot`, `ItemDef`, `Codex`): nothing else to pick, and no `GaxiaClientFeatures` module is needed. The scripts stop with a clear message if a package is missing.
**You will create:** the Scripts `ServerScriptService/PetSetup`, `ServerScriptService/EggStand` and the LocalScript `StarterPlayer/StarterPlayerScripts/PetPanel`.

How it works:

- The Pet package has **one egg**, `BasicEgg`, and **8 pets** (table below). You cannot add your own pets or eggs from game code. Do not edit `PetService` (Update replaces it). Pets are **stats only**: no 3D pet follows the player. Owned and equipped pets are saved in the player's data.
- The pet panel is built in. Press **P** to open it (after Step 2). It shows the pets, the Coin multiplier and a **Buy Egg** button. Clicking a pet equips or unequips it. The server checks every click.
- Multiplier = 1 + the bonus of every equipped pet. One Cat equipped → x1.05. It boosts only the currency `Coins`, which every player's data has.
- The Pet package never gives Coins. **Quest** rewards and **Idle** payouts in `Coins` use the multiplier by themselves (see `QuestSystem` and `IdleService` in the source). Your own Coin rewards must multiply by `Pet.GetCoinMultiplier(player)` (Step 1).

| Rarity | Pet ids and Coin bonus | Chance per egg |
|---|---|---|
| common | `pet_Cat` +0.05, `pet_Dog` +0.05 | 39.6%, 29.7% |
| uncommon | `pet_Bunny` +0.10, `pet_Fox` +0.12 | 11.9%, 9.9% |
| rare | `pet_Panda` +0.20, `pet_Penguin` +0.25 | 4.0%, 3.0% |
| epic, legendary | `pet_Tiger` +0.40, `pet_Dragon` +1.00 | 1.5%, 0.5% (a Dragon is sure within 50 eggs) |

## Step 1 — Set the egg price, give new players a Cat, pay boosted Coins

Create a **Script** in **ServerScriptService** named **PetSetup**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/PetSetup
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Pet"), "PetSetup needs the Pet package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local Pet = GaxiaServer.Pet
local Economy = GaxiaServer.Economy
local EConfig = GaxiaServer.EConfig
local BASE_COINS = 20 -- Coins every PAYOUT_SECONDS, before the pet multiplier
local PAYOUT_SECONDS = 10
-- Coins per egg, and how many pets can be equipped at once. Runs when every server starts.
EConfig.Set("Pets.EggCost", 100)
EConfig.Set("Pets.MaxEquipSlots", 3)
-- One Output line for every new pet and every equip change.
Pet.OnPetGranted:Connect(function(player: Player, petId: string, uid: string)
	print(`[PetSetup] {player.Name} got {petId} ({uid})`)
end)
Pet.OnEquipChanged:Connect(function(player: Player, equipped: { string })
	print(`[PetSetup] {player.Name} has {#equipped} pet(s) equipped, Coins x{Pet.GetCoinMultiplier(player)}`)
end)

local function onPlayerAdded(player: Player)
	-- Pets are in the saved data: wait until it is loaded (nil = the player left, or it took over 120 seconds).
	if Data.WaitFor(player, 120) == nil then
		print(`[PetSetup] {player.Name}: data not loaded, no free Cat this time`)
		return
	end
	-- A brand-new player owns no pets: give a Cat and equip it.
	if #Pet.GetOwned(player) == 0 then
		local uid = Pet.GrantPet(player, "pet_Cat")
		if uid then
			Pet.Equip(player, uid)
		end
	end
	print(`[PetSetup] {player.Name} owns {#Pet.GetOwned(player)} pet(s), Coins x{Pet.GetCoinMultiplier(player)}`)
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[PetSetup] ready")

-- Coin payout. This loop never ends, so it is the last thing in the script.
while true do
	task.wait(PAYOUT_SECONDS)
	for _, player in Players:GetPlayers() do
		-- Multiply first, then round down: Economy only adds whole numbers.
		local amount = math.floor(BASE_COINS * Pet.GetCoinMultiplier(player))
		-- Add returns false (and gives nothing) while the player's data is still loading.
		if Economy.Add(player, "Coins", amount) then
			print(`[PetSetup] {player.Name} +{amount} Coins, now {Economy.Get(player, "Coins")}`)
		end
	end
end
```

What it does: a new player gets a Cat, equipped (multiplier 1.05). Every 10 seconds each player gets 20 Coins × their multiplier: 21 with the Cat. Leaderboard: [currency-and-leaderstats](currency-and-leaderstats.md).

## Step 2 — Make the pet panel show, and add a Pets button

The panel opens in the middle of the screen, inside `PlayerGui.Gaxia_UI`: Gaxia makes that ScreenGui (with its `HUD` and `Overlays` folders) by itself. This script adds a **Pets** button to its `HUD` folder (phones have no **P** key).

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **PetPanel**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/PetPanel
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.PetController"), "PetPanel needs the Pet package: install it (playbooks/start/01-install-packages.md)")

local PetController = Gaxia.UI.PetController
-- 1. PlayerGui.Gaxia_UI.HUD: Gaxia's layer for things that stay on the screen.
-- Gaxia makes it the first time it is asked for (and keeps it after the player dies).
local hud = Gaxia.UI.UIController.HUD()
assert(hud, "PetPanel: PlayerGui.Gaxia_UI has no HUD folder")

-- 2. A blue Pets button on the left of the screen.
local button = Instance.new("TextButton")
button.Text = "Pets"
button.TextSize = 20
button.Size = UDim2.fromOffset(110, 44)
button.AnchorPoint = Vector2.new(0, 0.5)
button.Position = UDim2.new(0, 12, 0.5, 0)
button.BackgroundColor3 = Color3.fromRGB(70, 140, 245)
button.Parent = hud
button.Activated:Connect(function()
	PetController.Toggle()
end)

print("[PetPanel] ready")
```

## Step 3 — Put an egg in the world

Create a **Script** in **ServerScriptService** named **EggStand**:

```lua
-- Script: ServerScriptService/EggStand
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Pet"), "EggStand needs the Pet package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Interaction"), "EggStand needs the Interaction package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Pet = GaxiaServer.Pet
local Interaction = GaxiaServer.Interaction
local egg = Instance.new("Part")
egg.Name = "BasicEgg"
egg.Shape = Enum.PartType.Ball
egg.Size = Vector3.new(4, 5, 4)
egg.Position = Vector3.new(-24, 2.5, 0) -- 24 studs from the middle of the Baseplate, toward -X
egg.Anchored = true
egg.Parent = Workspace
local function onEggUsed(player: Player)
	if not Data.IsLoaded(player) then
		return
	end
	-- BuyEgg takes the Coins, rolls a pet and saves it. It takes nothing when it fails.
	-- result = the new pet's id (like "pet_Cat") when ok, or the reason when not.
	local ok, result = Pet.BuyEgg(player, "BasicEgg")
	print(`[EggStand] {player.Name}: {if ok then "hatched " .. result else "failed: " .. result}`)
	-- The Pet package creates the remotes PetHatch and PetSync. The panel reads exactly
	-- these fields (ok, petId, reason) for its toast, and refreshes from the snapshot.
	Net.FireClient(player, "PetHatch", { ok = ok, petId = if ok then result else nil, reason = if ok then nil else result })
	Net.FireClient(player, "PetSync", Pet.Snapshot(player))
end

-- No price in the text: the price is set only in PetSetup, so the two never disagree.
local handle = Interaction.Register(egg, { ActionText = "Hatch Egg", ObjectText = "Egg", HoldDuration = 0.5, MaxDistance = 10, OnTrigger = onEggUsed })
assert(handle, "EggStand: could not put a prompt on the egg")

print("[EggStand] ready")
```

What it does: holding **E** at the egg buys one egg at the `Pets.EggCost` price. The player sees the same toast as the panel's **Buy Egg** button.

## Check that it works

1. Press **Play** in Studio. Output shows `[PetSetup] ready`, `[PetPanel] ready`, `[EggStand] ready`, and no red errors.
2. Output shows `[PetSetup] <YourName> got pet_Cat (u_1)`, then `[PetSetup] <YourName> owns 1 pet(s), Coins x1.05` (only the first time; later it shows the saved pets).
3. After 10 seconds Output shows `[PetSetup] <YourName> +21 Coins, now 21`.
4. Press **P** (or click **Pets**). The panel shows `Coin Multiplier: x1.05`, `Equipped 1/3` and the Cat with `✓ Equipped`. Wait until a `[PetSetup] ... Coins` line says `now 100` or more (about 50 seconds the first time): enough for one egg.
5. Open the panel and click **Buy Egg (100 Coins)**. A toast says `Egg Hatched! You got <Pet>!` and Output shows `[PetSetup] <YourName> got pet_<Name> (u_2)`. Click the new pet: Output shows `[PetSetup] <YourName> has 2 pet(s) equipped, Coins x...`.
6. Walk to the white egg (24 studs from the middle of the Baseplate, toward -X) and hold **E**. Output shows `[EggStand] <YourName>: failed: not enough Coins` (you spent them in 5), or `hatched pet_<Name>` once you have 100 Coins again.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Skipping Step 2 | Keep the `PetPanel` LocalScript | Phones and tablets have no **P** key: without the **Pets** button they cannot open the panel. |
| A new pet or egg: `Pet.GrantPet(player, "pet_Unicorn")`, `Pet.BuyEgg(player, "GoldenEgg")` | Only the 8 pet ids above and `"BasicEgg"` | An unknown pet warns `GrantPet: unknown petId` and returns `nil`. An unknown egg returns `false, "unknown egg"`. |
| `Economy.Add(player, "Coins", 20)` and expecting pets to help | `math.floor(20 * Pet.GetCoinMultiplier(player))` | Pets only boost Quest and Idle Coins by themselves. Your rewards must multiply. |
| Calling `Pet.BuyEgg` from server code without the two `Net.FireClient` lines | Send `PetHatch` and `PetSync` like Step 3 | Only the panel's own button refreshes the panel. Otherwise an open panel shows old pets. |
| Equipping a 4th pet | Unequip one first, or raise `Pets.MaxEquipSlots` | `Pet.Equip` returns `false, "all slots full"`. |

## Change it

- Egg price or equip slots: change `EConfig.Set("Pets.EggCost", 100)` (minimum 1) or `EConfig.Set("Pets.MaxEquipSlots", 3)` in `PetSetup`. The panel shows the new numbers.
- Give a pet as a reward (quest, code, Robux): `Pet.GrantPet(player, "pet_Dragon")` on the server. It returns the new pet's uid, or `nil`.
- Equip from server code: `Pet.Equip(player, uid)` returns `true, "equipped"` or `false` and the reason (`"not owned"`, `"already equipped"`, `"all slots full"`). Undo: `Pet.Unequip(player, uid)`. List pets: `Pet.GetOwned(player)` (`{ petId, uid }` rows), `Pet.GetEquipped(player)` (uids).
- Open the panel from a LocalScript: `Gaxia.UI.PetController.Open()` / `Close()` / `Toggle()`.
- Boost Idle and quests ([progression](progression.md)): Idle with `Currency = "Coins"` and a quest with `reward = { currency = "Coins", amount = 100 }` pay `× multiplier` by themselves.

## See also

- [API: Pet](../api/Pet.md) · [API: Economy](../api/Economy.md) · [API: Interaction](../api/Interaction.md) · [API: Loot](../api/Loot.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Progression](progression.md) · [Areas and press-E prompts](zones-and-interactions.md) · [Config and flags](config-and-flags.md)
