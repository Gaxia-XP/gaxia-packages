# NPC dialog with choices, and a short cutscene

> A Guide NPC stands in the world. Press **E** to talk: a dialog box types out text and shows 3 choices. "Can I have some Coins?" gives 25 Coins (checked on the server). "Show me the village" plays a camera tour that always gives control back.

**Use this when** the user asks for: "NPC dialog", "talk to an NPC", "NPC conversation", "dialog choices", "quest giver", "press E to talk", "cutscene", "camera tour", "intro camera", "story scene" (ไทย: "คุยกับ NPC", "บทสนทนา NPC", "ตัวเลือกคำตอบ", "กด E คุย", "คัตซีน", "กล้องพาชมแมพ", "ฉากเล่าเรื่อง").
**Packages:** on the server `Interaction`, `Cooldown`, `Economy` (it also installs `Data`). On the client `Dialog`, `Cutscene` (it also installs `Dialog`) and `UI.Toast`. The scripts stop with a clear message if one is missing.
**You will create:** a ModuleScript `ReplicatedStorage/GameShared/NpcDialogs`, a Script `ServerScriptService/NpcDialog`, a ModuleScript `StarterPlayer/StarterPlayerScripts/VillageTour` and a LocalScript `StarterPlayer/StarterPlayerScripts/NpcDialogUI`.

How it works (the scripts build their own NPC, so they work in an empty Baseplate):

- The server puts a "Talk" prompt (`GaxiaServer.Interaction.Register`) on the NPC. When a player uses it, the server remembers "this player talks to Guide" and tells the client to open the dialog.
- The client shows the dialog with `Gaxia.Dialog.Show`. It returns a Promise: `andThen` gets the number of the clicked choice.
- The client sends only the NPC id and the choice id. The server checks that both exist, that the player pressed **E** on that NPC, and that the player is still close. Then it acts.
- The tour uses `Gaxia.Cutscene.Play` (camera moves, fades, subtitles). A **Skip** button, a 20 second safety timer and a respawn check always stop it. When it ends, for any reason, the camera and walking come back.

## Step 1 — Write what the NPC says

In **ReplicatedStorage**, find the **Folder** **GameShared**. If it is not there, create it (other playbooks use the same folder; do not make a second one). In it, create a **ModuleScript** named **NpcDialogs**. Paste this whole block into it:

```lua
-- ModuleScript: ReplicatedStorage/GameShared/NpcDialogs
-- What every NPC says. The server and the client both read this table.
-- The client shows the text. The server checks that a choice id is real.
export type Choice = { id: string, text: string }
export type Npc = { name: string, position: Vector3, lines: { string }, choices: { Choice } }

local NpcDialogs: { [string]: Npc } = {
	Guide = {
		name = "Guide",
		position = Vector3.new(0, 3, 40), -- 40 studs from the middle of the Baseplate, toward +Z
		lines = { "Hello, traveller! Welcome to the village.", "What can I do for you?" },
		choices = {
			{ id = "coins", text = "Can I have some Coins?" },
			{ id = "tour", text = "Show me the village" },
			{ id = "bye", text = "Goodbye" },
		},
	},
}

return NpcDialogs
```

What it does: one table for every NPC. The client reads the text. The server reads the choice ids to check requests.

## Step 2 — Create the NPC and check every choice on the server

Create a **Script** in **ServerScriptService** named **NpcDialog**:

```lua
-- Script: ServerScriptService/NpcDialog
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local NpcDialogs = require(game:GetService("ReplicatedStorage"):WaitForChild("GameShared"):WaitForChild("NpcDialogs"))

for _, package in { "Interaction", "Cooldown", "Economy" } do
	assert(GaxiaServer.IsInstalled(package), `NpcDialog needs the {package} package: install it (playbooks/start/01-install-packages.md)`)
end
local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local Cooldown = GaxiaServer.Cooldown
local Interaction = GaxiaServer.Interaction
local TALK_DISTANCE = 15 -- studs: a choice counts only while the player stands this close to the NPC
local COIN_GIFT = 25
local COIN_COOLDOWN = 60 -- seconds, per player

local npcParts: { [string]: BasePart } = {} -- npcId -> the NPC's body
local talkingTo: { [Player]: string } = {} -- player -> the npcId they pressed E on

-- Create the remote now (server -> client only). Anything a client sends here is ignored.
Net.DeclareEvent("NpcDialogOpen")

-- Builds a simple NPC: a body, a head and a Humanoid (it shows the name above the head).
local function makeNpc(npcId: string, npc: NpcDialogs.Npc): Model
	local model = Instance.new("Model")
	model.Name = npc.name
	local body = Instance.new("Part")
	body.Name = "Torso"
	body.Size = Vector3.new(2, 4, 1)
	body.Position = npc.position
	body.Anchored = true
	body.Color = Color3.fromRGB(60, 120, 200)
	body.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.Position = npc.position + Vector3.new(0, 2.5, 0)
	head.Anchored = true
	head.Color = Color3.fromRGB(240, 200, 160)
	head.Parent = model
	Instance.new("Humanoid").Parent = model
	model.PrimaryPart = body
	model.Parent = Workspace
	npcParts[npcId] = body
	return model
end

local function isNear(player: Player, npcId: string): boolean
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local body: BasePart? = npcParts[npcId]
	if root == nil or not root:IsA("BasePart") or body == nil then
		return false
	end
	return (root.Position - body.Position).Magnitude <= TALK_DISTANCE
end

local function hasChoice(npc: NpcDialogs.Npc, choiceId: string): boolean
	for _, choice in npc.choices do
		if choice.id == choiceId then
			return true
		end
	end
	return false
end

local function giveCoins(player: Player): (boolean, string)
	if not Data.IsLoaded(player) then
		return false, "Your data is still loading"
	end
	if not Cooldown.ConsumePlayer(player, "NpcCoins", COIN_COOLDOWN) then
		local secondsLeft = math.ceil(Cooldown.GetPlayerRemaining(player, "NpcCoins"))
		return false, `Come back in {secondsLeft} s for more Coins`
	end
	if not Economy.Add(player, "Coins", COIN_GIFT) then
		Cooldown.Clear(Cooldown.Key(player, "NpcCoins")) -- give the cooldown back
		return false, "Could not add Coins, try again"
	end
	print(`[NpcDialog] {player.Name} got {COIN_GIFT} Coins`)
	return true, `+{COIN_GIFT} Coins! You have {Economy.Get(player, "Coins")}`
end

-- The client sends only WHICH NPC and WHICH choice. The server checks everything.
Net.OnInvoke("NpcDialogChoose", function(player: Player, npcId: any, choiceId: any): (boolean, string)
	if typeof(npcId) ~= "string" or typeof(choiceId) ~= "string" then
		return false, "Bad request"
	end
	local npc = NpcDialogs[npcId]
	if npc == nil or not hasChoice(npc, choiceId) then
		return false, "Bad request"
	end
	if talkingTo[player] ~= npcId then
		return false, `Press E on {npc.name} first`
	end
	if not isNear(player, npcId) then
		return false, "You walked too far away"
	end
	talkingTo[player] = nil -- one choice per talk: press E again to talk again
	print(`[NpcDialog] {player.Name} chose {choiceId}`)
	if choiceId == "coins" then
		return giveCoins(player)
	elseif choiceId == "tour" then
		return true, "Enjoy the tour!"
	end
	return true, "Goodbye!"
end, { rate = 2, burst = 4 })

for npcId, npc in NpcDialogs do
	local model = makeNpc(npcId, npc)
	local handle = Interaction.Register(model, {
		ActionText = "Talk",
		ObjectText = npc.name,
		MaxDistance = 10,
		OnTrigger = function(player: Player)
			talkingTo[player] = npcId
			print(`[NpcDialog] {player.Name} talks to {npcId}`)
			Net.FireClient(player, "NpcDialogOpen", npcId)
		end,
	})
	assert(handle, `NpcDialog: could not put a prompt on {npcId}`)
end

Players.PlayerRemoving:Connect(function(player: Player)
	talkingTo[player] = nil
end)
print("[NpcDialog] ready")
```

What it does: it builds the Guide at `0, 3, 40` with a "Talk" prompt. `NpcDialogChoose` refuses anything the client should not ask for. The Coins choice works once every 60 seconds per player.

## Step 3 — Make the camera tour (cutscene)

In **StarterPlayer → StarterPlayerScripts**, create a **ModuleScript** (not a LocalScript) named **VillageTour**:

```lua
-- ModuleScript: StarterPlayer/StarterPlayerScripts/VillageTour
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

local Cutscene = Gaxia.Cutscene
local player = Players.LocalPlayer
local MAX_SECONDS = 20 -- safety: the tour always ends after this many seconds

local VillageTour = {}

-- Stops the player from walking. Returns a function that gives walking back.
local function freezePlayer(): () -> ()
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		return function() end
	end
	local walkSpeed, jumpPower, jumpHeight = humanoid.WalkSpeed, humanoid.JumpPower, humanoid.JumpHeight
	humanoid.WalkSpeed, humanoid.JumpPower, humanoid.JumpHeight = 0, 0, 0
	return function()
		humanoid.WalkSpeed, humanoid.JumpPower, humanoid.JumpHeight = walkSpeed, jumpPower, jumpHeight
	end
end

-- A "Skip" button on top of the cutscene. It stops the cutscene at once.
local function makeSkipButton(): ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "TourSkipGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 1000 -- above the black fade of the cutscene
	local button = Instance.new("TextButton")
	button.Name = "Skip"
	button.Size = UDim2.fromOffset(120, 44)
	button.Position = UDim2.new(1, -140, 0, 20)
	button.Text = "Skip"
	button.TextScaled = true
	button.Parent = screenGui
	button.Activated:Connect(function()
		print("[VillageTour] skipped")
		Cutscene.Stop()
	end)
	screenGui.Parent = player:WaitForChild("PlayerGui")
	return screenGui
end

-- Plays a short camera tour around `center`, then gives control back to the player.
function VillageTour.Play(center: Vector3)
	if Cutscene.IsPlaying() then
		return
	end
	local unfreeze = freezePlayer()
	local trove = Gaxia.Trove.new() -- everything this tour makes; cleaned when it ends
	trove:Add(makeSkipButton())
	-- If the player dies or respawns, stop the tour.
	trove:Connect(player.CharacterAdded, function()
		Cutscene.Stop()
	end)
	print("[VillageTour] started")
	local tour = Cutscene.Play({
		{ type = "fade", to = 1, duration = 0.5 },
		{ type = "camera", cframe = CFrame.lookAt(center + Vector3.new(0, 25, 45), center), duration = 0.1 },
		{ type = "fade", to = 0, duration = 0.5 },
		{ type = "subtitle", text = "This is our village.", duration = 2 },
		{ type = "camera", cframe = CFrame.lookAt(center + Vector3.new(45, 20, 0), center), duration = 3 },
		{ type = "subtitle", text = "Come and talk to me any time!", duration = 2 },
		{ type = "fade", to = 1, duration = 0.5 },
	})
	-- Safety: if the tour is still playing after MAX_SECONDS, stop it.
	local safety = task.delay(MAX_SECONDS, function()
		warn("[VillageTour] took too long, stopping it")
		Cutscene.Stop()
	end)
	tour:catch(function(reason: any)
		print(`[VillageTour] stopped early: {tostring(reason)}`)
	end):finally(function()
		task.cancel(safety)
		trove:Destroy()
		unfreeze()
		-- Always give the camera back to the player, whatever happened.
		local camera = Workspace.CurrentCamera
		local character = player.Character
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = if character then character:FindFirstChildOfClass("Humanoid") else nil
		print("[VillageTour] control is back")
	end)
end

return VillageTour
```

What it does: it stops walking, shows a **Skip** button and plays the steps. `finally` runs when the tour ends in any way (finished, skipped, timed out, respawned). It cleans up and gives the camera back.

## Step 4 — Show the dialog on the client

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **NpcDialogUI**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/NpcDialogUI
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local NpcDialogs = require(game:GetService("ReplicatedStorage"):WaitForChild("GameShared"):WaitForChild("NpcDialogs"))
local VillageTour = require(script.Parent:WaitForChild("VillageTour"))

for _, package in { "Dialog", "Cutscene", "UI.Toast" } do
	assert(Gaxia.IsInstalled(package), `NpcDialogUI needs the {package} package: install it (playbooks/start/01-install-packages.md)`)
end
local Net = Gaxia.Net
local Dialog = Gaxia.Dialog
local Cutscene = Gaxia.Cutscene
local Toast = Gaxia.UI.Toast
local player = Players.LocalPlayer
local WALK_AWAY_DISTANCE = 14 -- studs: the dialog closes when the player walks this far from the NPC. Keep it smaller than TALK_DISTANCE (15) in the NpcDialog Script.

local function distanceTo(position: Vector3): number
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root and root:IsA("BasePart") then
		return (root.Position - position).Magnitude
	end
	return math.huge
end

-- Sends the choice to the server. The server checks it and answers (ok, message).
local function choose(npcId: string, choiceId: string)
	local called, ok, message = pcall(Net.InvokeServer, "NpcDialogChoose", npcId, choiceId)
	if not called or ok == nil then
		ok, message = false, "No answer, try again"
	end
	print(`[NpcDialogUI] {npcId}/{choiceId}: {tostring(ok)} {tostring(message)}`)
	Toast.Show({ Text = tostring(message), Variant = if ok then "success" else "error", Duration = 3 })
	if ok and choiceId == "tour" then
		VillageTour.Play(NpcDialogs[npcId].position)
	end
end

Net.OnClient("NpcDialogOpen", function(npcId: any)
	local npc = if typeof(npcId) == "string" then NpcDialogs[npcId] else nil
	if npc == nil or Dialog.IsOpen() or Cutscene.IsPlaying() then
		return -- unknown NPC, or already talking / watching a cutscene
	end
	local lines = {}
	for _, text in npc.lines do
		table.insert(lines, { speaker = npc.name, text = text })
	end
	local choices = {}
	for _, choice in npc.choices do
		table.insert(choices, { text = choice.text })
	end
	print(`[NpcDialogUI] talking to {npcId}`)
	local talk = Dialog.Show({ lines = lines, choices = choices })
	-- Close the dialog when the player walks away, so it never stays on the screen.
	task.spawn(function()
		while talk:getStatus() == "Started" do
			if distanceTo(npc.position) > WALK_AWAY_DISTANCE then
				print("[NpcDialogUI] walked away, dialog closed")
				talk:cancel()
			end
			task.wait(0.5)
		end
	end)
	talk:andThen(function(index: number)
		local choice = npc.choices[index]
		if choice then
			task.spawn(choose, npcId, choice.id)
		end
	end):catch(function(reason: any)
		print(`[NpcDialogUI] dialog ended: {tostring(reason)}`)
	end)
end)
print("[NpcDialogUI] ready")
```

What it does: it opens the dialog when the server says so, sends the clicked choice to the server, and shows the answer in a toast. After "Show me the village" it plays the tour.

## Check that it works

1. Press **Play** in Studio. Output shows `[NpcDialog] ready` and `[NpcDialogUI] ready`, and no red errors.
2. Walk to the blue NPC named **Guide**. It is 40 studs from the middle of the Baseplate (`0, 0, 0`), toward +Z. From the spawn, walk straight forward along +Z (about 40 studs) to a blue block with the name **Guide** above it. If you cannot see it: in Explorer, select **Workspace → Guide**, then press **F** in the 3D view to move the camera to it.
3. Stand next to it and press **E** (**Talk**). Output shows `[NpcDialog] <YourName> talks to Guide` and `[NpcDialogUI] talking to Guide`. A dialog box types `Hello, traveller! ...`.
4. Click **Continue** until the 3 choice buttons show. Click **Can I have some Coins?**. A toast says `+25 Coins! You have 25` (more if you already had Coins). Output shows `[NpcDialog] <YourName> got 25 Coins`.
5. Talk again and pick **Can I have some Coins?** again. The toast says `Come back in <number> s for more Coins`.
6. Talk again and pick **Show me the village**. The screen fades to black, the camera flies above the NPC and subtitles show. You cannot walk. Output shows `[VillageTour] started`. After about 9 seconds, Output shows `[VillageTour] control is back` and you can walk and turn the camera again.
7. Start the tour again and click **Skip** (top right). Output shows `[VillageTour] skipped`, `[VillageTour] stopped early: cancelled` and `[VillageTour] control is back`.
8. Talk again, then walk away without choosing. After about 14 studs the dialog closes and Output shows `[NpcDialogUI] walked away, dialog closed`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Client sends `"NpcDialogChoose", "Guide", "coins", 25` (an amount) | Client sends only the NPC id and the choice id | The server decides the reward. A cheater can send any number. |
| The server gives the reward without checking `talkingTo[player]` and the distance | Keep both checks in `NpcDialogChoose` | A cheater can call the remote from anywhere, without pressing **E**. |
| `GaxiaServer.Interaction` in a LocalScript, or `Gaxia.Dialog` in a Script | Prompts in the Script, dialog and cutscene in the LocalScript | Interaction is server only. Dialog and Cutscene are client only (nil on the server). |
| `Cutscene.Play(...)` with no Skip, no timer and no `finally` | Use `VillageTour.Play` as written | Without them, a mistake in a step can leave the camera stuck and the player frozen. |
| `Dialog.Close()` to close a dialog you opened | `talk:cancel()` on the Promise from `Dialog.Show` | `Close` hides the box but the Promise never ends: `andThen`, `catch` and `finally` never run. |
| `talk:andThen(function(index) Net.InvokeServer(...) end)` | `task.spawn(choose, npcId, choice.id)` inside `andThen` | `InvokeServer` waits for the server. In its own thread, a slow answer does not hold up the Promise. |
| `VillageTour` as a LocalScript | A **ModuleScript** named `VillageTour` | `NpcDialogUI` `require`s it. A LocalScript cannot be required. |

## Change it

- To change the words: edit `lines` and the `text` of each choice in `NpcDialogs`. Keep the `id`s: the server uses them.
- To add an NPC: in `NpcDialogs`, add one more entry inside the table, below the `Guide = { ... },` entry. The server builds it and puts a prompt on it. Every NPC needs at least one line and one choice. For example:

  ```lua
  -- fragment
  	Baker = {
  		name = "Baker",
  		position = Vector3.new(20, 3, 40),
  		lines = { "Fresh bread! Come back tomorrow for more." },
  		choices = {
  			{ id = "bye", text = "Goodbye" },
  		},
  	},
  ```
- To add a choice: add `{ id = "heal", text = "Heal me" },` to the NPC's `choices` in `NpcDialogs`. Then, in the `NpcDialog` Script, in `NpcDialogChoose`, paste these lines directly above the line `end` that comes just before `return true, "Goodbye!"`:

  ```lua
  -- fragment
  	elseif choiceId == "heal" then
  		local humanoid = if player.Character then player.Character:FindFirstChildOfClass("Humanoid") else nil
  		if humanoid then
  			humanoid.Health = humanoid.MaxHealth
  		end
  		return true, "Healed!"
  ```
- To use your own NPC model: name it `Guide`, put it in **Workspace**, and in `makeNpc` replace everything from `local model = Instance.new("Model")` to `model.Parent = Workspace` with `local model = Workspace:WaitForChild(npc.name) :: Model` and `local body = model.PrimaryPart :: BasePart`. Set the model's **PrimaryPart** in Studio, and set `position` in `NpcDialogs` to where the model stands (the client uses it for the tour and the walk-away check).
- To change the tour: edit the steps in `Cutscene.Play`. Step types: `camera` (`cframe`, `duration`), `fade` (`to` 1 = black, 0 = clear), `subtitle` (`text`, `duration`), `wait` (`duration`), `action` (`fn`, a function). Keep the whole tour shorter than `MAX_SECONDS`.
- To play the tour when a player joins (an intro): in `NpcDialogUI`, paste these lines above the last `print`. They wait for the character first, so the player is frozen and the tour is not cut off by the spawn:

  ```lua
  -- fragment
  task.spawn(function()
  	local character = player.Character or player.CharacterAdded:Wait()
  	character:WaitForChild("Humanoid")
  	task.wait(1)
  	VillageTour.Play(Vector3.new(0, 3, 40))
  end)
  ```
- To shake the camera in the tour: install the `Camera` package and add the step `{ type = "action", fn = function() Gaxia.Camera.Shake(1, 0.3) end }`.

## See also

- [API: Dialog](../api/Dialog.md) · [API: Cutscene](../api/Cutscene.md) · [API: Interaction](../api/Interaction.md) · [API: Cooldown](../api/Cooldown.md) · [API: Economy](../api/Economy.md)
- ["Press E" prompts and zones](zones-and-interactions.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Signals, cleanup and promises](signals-cleanup-and-timing.md) · [UI and toasts](ui.md) · [Troubleshooting](../troubleshooting.md)
