# Obby checkpoints, kill bricks and a saved stage

> An obby (obstacle course): players touch numbered checkpoints, lava kills them, they respawn at their last checkpoint, the stage is saved and shown on the leaderboard, and they can buy "Skip stage" with Robux.

**Use this when** the user asks for: "obby", "checkpoints", "save the stage", "respawn at checkpoint", "kill brick", "lava", "stage on the leaderboard", "skip stage" (ไทย: "ออบบี้", "เช็คพอยต์", "เซฟด่าน", "เกิดที่เช็คพอยต์", "บล็อกฆ่า", "ลาวา", "โชว์ด่านบน leaderboard", "ข้ามด่าน").
**Packages:** `Data` and `Player`. Only for Steps 4–5 (skip stage with Robux): `Monetization`. The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/ObbyCourse`, `ServerScriptService/ObbyCheckpoints`, `ServerScriptService/ObbySkipStage` and a LocalScript `StarterPlayer/StarterPlayerScripts/ObbySkipButton`.

How it works:

- A checkpoint is any Part with the **tag** `Checkpoint` and a number **attribute** `Stage` (1, 2, 3 …). A kill brick is any Part with the tag `KillBrick`.
- The stage is saved in player data as `ObbyStage` (`Data.SetDefaults`). A player moves up only to the **next** stage (`ObbyStage + 1`).
- Each time a character spawns, the server waits for the data and moves it to its checkpoint with `GaxiaServer.Player.Teleport` (so the anti-cheat does not flag it).
- The `Stage` column in the player list follows `ObbyStage` (`Data.OnDataChanged`).

## Step 1 — Build a test course

Create a **Script** in **ServerScriptService** named **ObbyCourse**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/ObbyCourse
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local STAGE_COUNT = 6
local SPACING = 16 -- studs from one checkpoint to the next (a 6 stud jump)
local FIRST = Vector3.new(0, 2, -20) -- checkpoint 1, 20 studs from the middle of the Baseplate
local course = Instance.new("Folder")
course.Name = "ObbyCourse"
course.Parent = Workspace
for stage = 1, STAGE_COUNT do
	local pad = Instance.new("Part")
	pad.Name = `Checkpoint{stage}`
	pad.Size = Vector3.new(10, 4, 10)
	pad.Position = FIRST + Vector3.new(0, 0, -(stage - 1) * SPACING)
	pad.Anchored = true
	pad.Color = if stage == STAGE_COUNT then Color3.fromRGB(255, 200, 40) else Color3.fromRGB(80, 200, 120)
	pad:SetAttribute("Stage", stage) -- the stage number ObbyCheckpoints reads
	CollectionService:AddTag(pad, "Checkpoint")
	pad.Parent = course
end
-- One lava floor under the jumps (from the far edge of checkpoint 1 to the end).
local length = (STAGE_COUNT - 1) * SPACING
local lava = Instance.new("Part")
lava.Name = "Lava"
lava.Size = Vector3.new(40, 1, length)
lava.Position = Vector3.new(FIRST.X, 0.5, FIRST.Z - 5 - length / 2)
lava.Anchored = true
lava.Material = Enum.Material.Neon
lava.Color = Color3.fromRGB(255, 60, 30)
CollectionService:AddTag(lava, "KillBrick")
lava.Parent = course
print(`[ObbyCourse] ready, {STAGE_COUNT} stages`)
```

What it does: it makes 6 green blocks in a line (the last one gold) with red lava between them. It works in an empty Baseplate.

## Step 2 — Save the stage, respawn at the checkpoint, kill on lava

Create a **Script** in **ServerScriptService** named **ObbyCheckpoints**:

```lua
-- Script: ServerScriptService/ObbyCheckpoints
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Data"), "ObbyCheckpoints needs the Data package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Player"), "ObbyCheckpoints needs the Player package: install it (playbooks/start/01-install-packages.md)")
local Data = GaxiaServer.Data
local PlayerService = GaxiaServer.Player -- the Gaxia "Player" package (Players above is Roblox's service)
local Trove = Gaxia.Trove
-- The saved stage. Every player starts at stage 1.
Data.SetDefaults({ ObbyStage = 1 })
local checkpoints: { [number]: BasePart } = {} -- stage number -> checkpoint part
local troves: { [Player]: typeof(Trove.new()) } = {}
-- The player whose living character touched `hit`, or nil.
local function getAlivePlayer(hit: BasePart): (Player?, Humanoid?)
	local character = hit:FindFirstAncestorOfClass("Model")
	local player = if character then Players:GetPlayerFromCharacter(character) else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if player == nil or humanoid == nil or humanoid.Health <= 0 then
		return nil, nil
	end
	return player, humanoid
end
local function onCheckpointTouched(checkpoint: BasePart, hit: BasePart)
	local player, humanoid = getAlivePlayer(hit)
	if player == nil or humanoid == nil or not Data.IsLoaded(player) then
		return
	end
	-- Exploiters can fake touches: the body must really be ON the checkpoint
	-- (over its top, within 3 studs of its edges), not just somewhere near it.
	local root = humanoid.RootPart
	if root == nil then
		return
	end
	local rel = checkpoint.CFrame:PointToObjectSpace(root.Position) -- the root, seen from the checkpoint
	local half = checkpoint.Size / 2
	if math.abs(rel.X) > half.X + 3 or math.abs(rel.Z) > half.Z + 3 or rel.Y < -half.Y or rel.Y > half.Y + 8 then
		return
	end
	local stage = checkpoint:GetAttribute("Stage")
	local current = Data.Get(player, "ObbyStage")
	-- Only the NEXT stage counts: no skipping ahead, no going back.
	if typeof(stage) ~= "number" or typeof(current) ~= "number" or stage ~= current + 1 then
		return
	end
	if Data.Set(player, "ObbyStage", stage) then
		print(`[ObbyCheckpoints] {player.Name} reached stage {stage}`)
	end
end
local function onKillBrickTouched(hit: BasePart)
	local player, humanoid = getAlivePlayer(hit)
	if player == nil or humanoid == nil then
		return
	end
	-- Tell AntiCheat (optional package) this health drop is allowed, then kill.
	local combat = if GaxiaServer.IsInstalled("AntiCheat") then GaxiaServer.AntiCheat.Combat else nil
	if combat then
		combat.RegisterDamage(humanoid, humanoid.Health)
	end
	humanoid.Health = 0
	print(`[ObbyCheckpoints] {player.Name} touched a kill brick`)
end
local function addCheckpoint(part: Instance)
	local stage = part:GetAttribute("Stage")
	if not part:IsA("BasePart") or typeof(stage) ~= "number" then
		warn(`[ObbyCheckpoints] {part:GetFullName()} has the Checkpoint tag but is not a Part with a number attribute "Stage"`)
		return
	end
	checkpoints[stage] = part
	part.Touched:Connect(function(hit: BasePart)
		onCheckpointTouched(part, hit)
	end)
end
local function addKillBrick(part: Instance)
	if part:IsA("BasePart") then
		part.Touched:Connect(onKillBrickTouched)
	end
end
-- Parts tagged now, and parts tagged later (for example by ObbyCourse).
for _, part in CollectionService:GetTagged("Checkpoint") do
	addCheckpoint(part)
end
CollectionService:GetInstanceAddedSignal("Checkpoint"):Connect(addCheckpoint)
for _, part in CollectionService:GetTagged("KillBrick") do
	addKillBrick(part)
end
CollectionService:GetInstanceAddedSignal("KillBrick"):Connect(addKillBrick)
-- The checkpoint for `stage`, or the closest one below it (if a stage was removed).
local function getCheckpoint(stage: number): BasePart?
	for s = stage, 1, -1 do
		if checkpoints[s] then
			return checkpoints[s]
		end
	end
	return nil
end
local function onCharacterAdded(player: Player, character: Model)
	if character:WaitForChild("HumanoidRootPart", 10) == nil or Data.WaitFor(player) == nil then
		return -- no body, or the player left before the data loaded
	end
	task.wait() -- let Roblox finish placing the character on the SpawnLocation first
	if player.Character ~= character then
		return -- the player respawned again while we waited
	end
	local stage: number = Data.Get(player, "ObbyStage")
	local checkpoint = getCheckpoint(stage)
	if checkpoint == nil then
		warn("[ObbyCheckpoints] no checkpoint parts found: run ObbyCourse or tag your parts (see Change it)")
		return
	end
	-- Stand on top of the checkpoint (3 studs above its top surface).
	PlayerService.Teleport(player, checkpoint.CFrame + Vector3.new(0, checkpoint.Size.Y / 2 + 3, 0))
	print(`[ObbyCheckpoints] {player.Name} spawned at stage {stage}`)
end
-- The Stage column follows the saved stage (also when ObbySkipStage changes it).
Data.OnDataChanged:Connect(function(player: Player, key: string, value: any)
	if key == "ObbyStage" then
		PlayerService.SetLeaderstat(player, "Stage", value)
	end
end)
local function onPlayerAdded(player: Player)
	local trove = Trove.new()
	troves[player] = trove
	trove:Connect(player.CharacterAdded, function(character: Model)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
	if Data.WaitFor(player) == nil then
		return
	end
	PlayerService.SetupLeaderstats(player, { Stage = Data.Get(player, "ObbyStage") })
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player: Player)
	local trove = troves[player]
	if trove then
		trove:Clean()
		troves[player] = nil
	end
end)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
print("[ObbyCheckpoints] ready")
```

What it does: touching the next checkpoint saves the stage (only when the body is really near it). Lava kills. Every spawn moves the player to their saved checkpoint.

## Step 3 — (Optional) Create the Skip Stage product on Roblox

Skip Steps 3–5 if you do not sell skips. Steps 1–2 work alone.

1. Publish the place (**File → Publish to Roblox**).
2. Open **create.roblox.com → Creations**, pick your experience, open **Monetization → Developer Products**, click **Create**. Name it `Skip Stage`, set a price, save.
3. Copy its **Product ID** (a number). You paste it in Step 4.

## Step 4 — (Optional) Sell Skip Stage on the server

Create a **Script** in **ServerScriptService** named **ObbySkipStage**. Paste your Product ID on the `SKIP_PRODUCT_ID` line. `0` is fine until then: the script starts, and the button only shows "Skip is not set up yet".

```lua
-- Script: ServerScriptService/ObbySkipStage
local CollectionService = game:GetService("CollectionService")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
assert(GaxiaServer.IsInstalled("Data"), "ObbySkipStage needs the Data package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Monetization"), "ObbySkipStage needs the Monetization package: install it (playbooks/start/01-install-packages.md)")
local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Monetization = GaxiaServer.Monetization
local SKIP_PRODUCT_ID = 0 -- your Product ID from Step 3. 0 = not set yet.
-- Server -> client messages for the button (Step 5).
Net.DeclareEvent("ObbyMessage")
-- The highest Stage attribute of all checkpoints.
local function getLastStage(): number
	local last = 1
	for _, part in CollectionService:GetTagged("Checkpoint") do
		local stage = part:GetAttribute("Stage")
		if typeof(stage) == "number" and stage > last then
			last = stage
		end
	end
	return last
end
-- Runs once per purchase. error() means "not given yet": Roblox retries later.
if SKIP_PRODUCT_ID ~= 0 then
	Monetization.RegisterProduct(SKIP_PRODUCT_ID, function(player: Player, receipt)
		local stage = Data.Get(player, "ObbyStage")
		if typeof(stage) ~= "number" then
			error("ObbyStage is not loaded")
		end
		if stage >= getLastStage() then
			-- They reached the last stage on foot before paying. The skip is used up.
			print(`[ObbySkipStage] {player.Name} was already on the last stage (purchase {receipt.PurchaseId})`)
			return
		end
		local newStage = stage + 1
		if not Data.Set(player, "ObbyStage", newStage) then
			error("Data.Set failed")
		end
		print(`[ObbySkipStage] {player.Name} skipped to stage {newStage} (purchase {receipt.PurchaseId})`)
		-- Respawn after the purchase is recorded. ObbyCheckpoints moves the new body to the new stage.
		task.defer(function()
			if player.Parent then
				player:LoadCharacterAsync()
			end
		end)
	end)
end
-- The client only asks. The server checks, then opens the Robux window.
Net.OnServer("ObbySkip", function(player: Player)
	if SKIP_PRODUCT_ID == 0 then
		warn("[ObbySkipStage] SKIP_PRODUCT_ID is 0: paste your Developer Product ID into ObbySkipStage (Step 4)")
		Net.FireClient(player, "ObbyMessage", "Skip is not set up yet")
		return
	end
	local stage = Data.Get(player, "ObbyStage")
	if typeof(stage) ~= "number" then
		Net.FireClient(player, "ObbyMessage", "Your data is still loading")
		return
	end
	if stage >= getLastStage() then
		Net.FireClient(player, "ObbyMessage", "You are on the last stage")
		return
	end
	Monetization.PromptProduct(player, SKIP_PRODUCT_ID)
end, { rate = 2, burst = 4 })
print("[ObbySkipStage] ready")
```

What it does: a paid skip adds 1 to `ObbyStage` and respawns the player there. Players on the last stage are never asked to pay. If a player reaches the last stage on foot while the Robux window is open and then buys, the skip is used up and Output shows `was already on the last stage`.

## Step 5 — (Optional) Add the Skip Stage button

Do Step 4 first. This button needs the ObbySkipStage script.

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **ObbySkipButton**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/ObbySkipButton
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local Net = Gaxia.Net
local player = Players.LocalPlayer
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ObbySkipGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")
local button = Instance.new("TextButton")
button.Size = UDim2.fromOffset(200, 50)
button.Position = UDim2.new(0, 20, 0, 120)
button.TextScaled = true
button.Text = "Skip stage"
button.Parent = screenGui
local message = Instance.new("TextLabel")
message.Size = UDim2.fromOffset(300, 30)
message.Position = UDim2.new(0, 20, 0, 175)
message.BackgroundTransparency = 1
message.TextScaled = true
message.Text = ""
message.Parent = screenGui
button.Activated:Connect(function()
	Net.FireServer("ObbySkip") -- send nothing else: the server knows the stage and the price
	print("[ObbySkipButton] asked to skip")
end)
Net.OnClient("ObbyMessage", function(text: any)
	message.Text = tostring(text)
	print(`[ObbySkipButton] {tostring(text)}`)
end)
print("[ObbySkipButton] ready")
```

## Check that it works

1. Press **Play**. Output shows `[ObbyCourse] ready, 6 stages`, `[ObbyCheckpoints] ready` (and `[ObbySkipStage] ready`, `[ObbySkipButton] ready` if you did Steps 4–5), and no red errors.
2. Within a few seconds Output shows `[ObbyCheckpoints] <YourName> spawned at stage 1`. You stand on the first green block. The player list has a **Stage** column showing 1.
3. Jump to the next block. Output shows `[ObbyCheckpoints] <YourName> reached stage 2` and **Stage** shows 2.
4. Fall into the red lava. Output shows `[ObbyCheckpoints] <YourName> touched a kill brick`. After the respawn: `spawned at stage 2`, on block 2.
5. With **Enable Studio Access to API Services** on ([player-data](player-data.md)), stop and press **Play** again: you spawn at your saved stage.
6. (Steps 4–5) Click **Skip stage**. With the ID still `0` the label shows `Skip is not set up yet`. With your ID, buy in the test window: Output shows `[ObbySkipStage] <YourName> skipped to stage 3 (purchase ...)`, then `spawned at stage 3`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `character.HumanoidRootPart.CFrame = checkpoint.CFrame` | `GaxiaServer.Player.Teleport(player, cframe)` | A big jump in position is flagged by AntiCheat as `Teleport`. `Player.Teleport` tells it the move is allowed. |
| Teleport right away in `PlayerAdded` | Teleport in `CharacterAdded`, after `Data.WaitFor` | The body spawns again after every death. The data is not loaded yet when the first body spawns. |
| `humanoid.Health = 0` alone in a kill brick | `Combat.RegisterDamage(humanoid, humanoid.Health)` first | AntiCheat treats every health drop it was not told about as a hard `Combat` cheat. |
| `Data.Set(player, "ObbyStage", stage)` whenever any checkpoint is touched | Only when `stage == current + 1` | Touching an old checkpoint would send the player back. A far checkpoint would skip stages. |
| Trusting `Touched` alone, or only a distance (`Magnitude < 20`) | Check that the body is over the checkpoint's top (`PointToObjectSpace`, Step 2) | Exploiters can fake touches. With a loose distance they fake a touch on the next checkpoint from their own, reset, and finish the obby without one jump. The footprint check stops that; it cannot stop a flying exploiter, which is the anti-cheat's job. |
| Adding the Step 5 button without Step 4 | Do Step 4 first | Output warns `is still waiting: the server has not created remote 'ObbyMessage'` and the button does nothing. |
| Saving the checkpoint Part in data | Save the stage number | DataStores cannot save Instances. |
| A checkpoint with the tag but no `Stage` attribute (or a string `"3"`) | A **number** attribute `Stage` | ObbyCheckpoints warns and ignores the part. |
| `player.leaderstats.Stage.Value = stage` | `Data.Set` (Step 2 copies it to the leaderboard) | Leaderstats are not saved, and AntiCheat flags direct writes (`StatTamper`). |
| Client sends `Net.FireServer("ObbySkip", 5)` or a product ID | Client sends nothing; the server reads the stage | A cheater can send any value. |
| `MarketplaceService.ProcessReceipt = ...` | `Monetization.RegisterProduct` | Monetization owns ProcessReceipt. Yours replaces it and purchases can be lost. |
| A data field named `Stage` or `Level` | `ObbyStage` | `Level` is built in. A short name can clash with another script's field. |

## Change it

- Use your own course: delete `ObbyCourse`. Select each checkpoint Part, open **Properties → Tags**, add `Checkpoint`. Under **Attributes** click **+**, name `Stage`, type **Number**, value 1, 2, 3 …. Tag lava Parts `KillBrick`. Set **Anchored** on all of them.
- Allow jumping over a checkpoint: in `onCheckpointTouched` change `stage ~= current + 1` to `stage <= current`.
- More stages in the test course: change `STAGE_COUNT = 6`.
- Give Coins at each new stage: after the `reached stage` print, add `GaxiaServer.Economy.Add(player, "Coins", 10)` (install `Economy`, see [currency-and-leaderstats](currency-and-leaderstats.md)).
- Reset a player (admin, testing): `Data.Set(player, "ObbyStage", 1)`, then `player:LoadCharacterAsync()`.

## See also

- [API: Data](../api/Data.md) · [API: Player](../api/Player.md) · [API: Monetization](../api/Monetization.md) · [API: AntiCheat](../api/AntiCheat.md)
- [Player data](player-data.md) · [Robux purchases](robux-purchases.md) · [Zones and interactions](zones-and-interactions.md) · [Anti-cheat and bans](anticheat-and-bans.md) · [Troubleshooting](../troubleshooting.md)
