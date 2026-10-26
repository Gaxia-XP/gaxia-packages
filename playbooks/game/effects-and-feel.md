# Effects, sounds, animations and camera shake

> A red pad explodes every 8 seconds: everyone sees sparks and hears a boom. Players nearby also feel a camera shake, a FOV punch and a white flash.

**Use this when** the user asks for: "an explosion effect", "particles", "a sound effect", "play a sound", "music", "camera shake", "screen shake", "FOV effect", "a spinning part", "a moving platform", "play an animation", "ragdoll", "tween", "game feel", "juice" (ไทย: "เอฟเฟกต์", "เอฟเฟกต์ระเบิด", "พาร์ติเคิล", "เสียง", "เปิดเพลง", "กล้องสั่น", "จอสั่น", "ของหมุน", "แพลตฟอร์มเลื่อน", "เล่นท่า", "แอนิเมชัน", "ตัวละครล้ม", "tween").
**Packages:** server: `VFX`, `SFX`, `Motion3D`. Client: `Camera`, `TweenUtil`. The scripts below stop with a clear message if one is missing.
**You will create:** a Script `ServerScriptService/BoomPad` and a LocalScript `StarterPlayer/StarterPlayerScripts/BoomFeel`.

Who sees what:

| Package | Runs in | Use it for | Who sees / hears it |
|---|---|---|---|
| `GaxiaServer.VFX` | Script | Particle bursts at a point, effects stuck to a part | Everyone |
| `GaxiaServer.SFX` | Script | A sound at a point in the world (3D) or for everyone (2D) | Everyone |
| `GaxiaServer.Motion3D` | Script | Spinning, floating and moving parts (doors, platforms) | Everyone |
| `GaxiaServer.Anim` | Script | Play an animation on a character or NPC | Everyone |
| `GaxiaServer.Ragdoll` | Script | Make a character go limp, then stand up | Everyone |
| `Gaxia.Camera` | LocalScript | Camera shake, field of view (FOV) | Only this player |
| `Gaxia.Sound` | LocalScript | Music, UI clicks, sounds only this player hears | Only this player |
| `Gaxia.Effects` | LocalScript | Particle bursts only this player sees | Only this player |
| `Gaxia.TweenUtil`, `Gaxia.Spring` | Both | Smoothly change any property (GUI fade, size, colour) | Where it runs |

The pattern: the **server** decides that something happens. It plays the world effect (VFX, SFX) and calls `Net.FireAllClients`. Each **client** adds its own feel (camera, flash).

Assets: the scripts use particles and a sound built into Roblox, so they work with no uploads. To use your own sound, upload it (or pick one in the Toolbox) and copy its ID as `"rbxassetid://123456"`.

## Step 1 — Create the exploding pad on the server

Create a **Script** in **ServerScriptService** named **BoomPad**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/BoomPad
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("VFX"), "BoomPad needs the VFX package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("SFX"), "BoomPad needs the SFX package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Motion3D"), "BoomPad needs the Motion3D package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local VFX = GaxiaServer.VFX
local SFX = GaxiaServer.SFX
local Motion3D = GaxiaServer.Motion3D

local BOOM_EVERY = 8 -- seconds between two explosions
-- A sound built into Roblox. Replace it with your own: "rbxassetid://<number>".
local BOOM_SOUND_ID = "rbxasset://sounds/action_jump_land.mp3"

-- 1. The pad, and a gem that spins above it.
local pad = Instance.new("Part")
pad.Name = "BoomPad"
pad.Size = Vector3.new(8, 1, 8)
pad.Position = Vector3.new(0, 0.5, 24)
pad.Anchored = true
pad.Color = Color3.fromRGB(220, 60, 60)
pad.Parent = Workspace

local gem = Instance.new("Part")
gem.Name = "BoomGem"
gem.Shape = Enum.PartType.Ball
gem.Size = Vector3.new(2, 2, 2)
gem.Position = Vector3.new(0, 5, 24)
gem.Anchored = true -- Motion3D moves anchored parts
gem.CanCollide = false
gem.Material = Enum.Material.Neon
gem.Color = Color3.fromRGB(255, 210, 60)
gem.Parent = Workspace
Motion3D.Spin(gem, Vector3.yAxis, 120) -- 120 degrees per second, forever

-- 2. Register the effect and the sound ONCE, at the top. Play them by name later.
VFX.Register("Boom", function(holder: Instance)
	local emitter = Instance.new("ParticleEmitter") -- the default texture is built in
	emitter.Rate = 80 -- PlayAt turns the emitter on for Duration seconds
	emitter.Speed = NumberRange.new(10, 20)
	emitter.Lifetime = NumberRange.new(0.4, 0.8)
	emitter.SpreadAngle = Vector2.new(180, 180) -- every direction
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 160, 50))
	emitter.Parent = holder
end)
SFX.Register("Boom", { SoundId = BOOM_SOUND_ID, Volume = 1, PitchVariation = 0.1, RollOffMaxDistance = 100 })

-- 3. Create the server -> client remote now, so the client's Net.OnClient("BoomFx") finds it.
Net.OnServer("BoomFx", function() end)

print("[BoomPad] ready")

-- 4. Explode forever. This loop never ends, so it is the last thing in the script.
while true do
	task.wait(BOOM_EVERY)
	local position = pad.Position + Vector3.new(0, 2, 0)
	VFX.PlayAt("Boom", position, { EmitCount = 40, Duration = 0.3 })
	SFX.PlayAt("Boom", position)
	Net.FireAllClients("BoomFx", position) -- every client adds its own camera shake
	print("[BoomPad] boom")
end
```

What it does: it builds the pad and the spinning gem, then explodes every 8 seconds. VFX and SFX objects go in `Workspace.Effects` and clean themselves up.

## Step 2 — Add camera shake, FOV punch and a flash on each client

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **BoomFeel**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/BoomFeel
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("Camera"), "BoomFeel needs the Camera package: install it (playbooks/start/01-install-packages.md)")
assert(Gaxia.IsInstalled("TweenUtil"), "BoomFeel needs the TweenUtil package: install it (playbooks/start/01-install-packages.md)")

local Camera = Gaxia.Camera
local TweenUtil = Gaxia.TweenUtil
local player = Players.LocalPlayer

local MAX_DISTANCE = 60 -- players farther than this feel nothing

-- A white frame over the whole screen, invisible until a boom.
local flashGui = Instance.new("ScreenGui")
flashGui.Name = "BoomFlash"
flashGui.ResetOnSpawn = false
flashGui.IgnoreGuiInset = true -- also cover the top bar
flashGui.Parent = player:WaitForChild("PlayerGui")

local flash = Instance.new("Frame")
flash.Size = UDim2.fromScale(1, 1)
flash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
flash.BackgroundTransparency = 1
flash.BorderSizePixel = 0
flash.Parent = flashGui

Gaxia.Net.OnClient("BoomFx", function(position: any)
	if typeof(position) ~= "Vector3" then
		return
	end
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not root or not root:IsA("BasePart") then
		return -- no character right now (dead or loading)
	end
	local distance = (root.Position - position).Magnitude
	if distance > MAX_DISTANCE then
		return
	end
	local strength = 1 - distance / MAX_DISTANCE -- 1 = right next to it, 0 = far away

	Camera.Shake(4 * strength, 0.5) -- size (degrees), seconds
	Camera.SetFOV(70 + 15 * strength, 0.1) -- quick zoom out...
	task.delay(0.15, function()
		Camera.ResetFOV(0.4) -- ...and back to 70
	end)
	flash.BackgroundTransparency = 1 - 0.7 * strength
	TweenUtil.Play(flash, { Time = 0.5 }, { BackgroundTransparency = 1 })
	print(`[BoomFeel] boom at {math.floor(distance)} studs, strength {math.floor(strength * 100)}%`)
end)

print("[BoomFeel] ready")
```

What it does: the closer the player stands, the stronger the shake, FOV punch and flash.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[BoomPad] ready` and `[BoomFeel] ready`, and no red errors. A yellow ball spins above a red pad.
3. Every 8 seconds Output shows `[BoomPad] boom`. Orange sparks burst from the pad and a thud plays.
4. Stand near the pad. Output shows `[BoomFeel] boom at 24 studs, strength 59%` (your numbers differ). The camera shakes and the screen flashes white.
5. Walk more than 60 studs away. `[BoomPad] boom` still prints, but `[BoomFeel]` does not, and the camera stays still.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Gaxia.Camera.Shake(...)` in a Script | Camera, Sound and Effects in a LocalScript; the server sends `Net.FireAllClients` | Client modules are empty on the server: the call errors. |
| `GaxiaServer.VFX.PlayAt(...)` in a LocalScript | VFX, SFX, Motion3D, Anim, Ragdoll in a Script | Server packages cannot be required on the client. |
| `VFX.PlayAt("Boom", ...)` before `VFX.Register("Boom", ...)` | Register every effect and sound once, at the top | PlayAt warns `[VFX] no effect 'Boom'` and shows nothing. Same for SFX: `[SFX] no sound 'Boom'`. |
| A long sound or music with `SFX.PlayAt` | `Gaxia.Sound.PlayMusic(id)` on the client | SFX deletes every sound after 10 seconds. |
| `Motion3D.Spin(part)` and `Motion3D.Float(part)` on the same part | One of them per part | Float resets the part's rotation every frame, so the spin never shows. |
| An emitter with `Rate = 0` in `VFX.Register` | A `Rate` above 0 (here 80) | PlayAt turns the emitter on for `Duration` seconds. With `Rate = 0` only the one-time `EmitCount` burst plays, in the same frame the effect appears, so other players can miss it. |
| `Camera.ResetFOV()` when the game uses another normal FOV | `Camera.SetFOV(yourFov, 0.4)` | ResetFOV always goes back to 70. |
| `SoundId = "123456"` | `SoundId = "rbxassetid://123456"` | A plain number is not loaded. A wrong ID plays nothing and Output shows a red asset error. |
| `Anim.Play` with an animation you found online | An animation owned by the game's owner (you or your group) | Roblox only loads animations the place owner may use. Others fail to load and nothing plays. |

## Change it

- Music for one player (crossfades, loops): `Gaxia.Sound.PlayMusic("rbxassetid://<id>", 2)`. Stop: `Gaxia.Sound.StopMusic(1)`. Volume: `Gaxia.Sound.SetCategoryVolume("music", 0.5)`.
- A click sound on a button: `Gaxia.Sound.PlayOnce("rbxassetid://<id>", { category = "ui", volume = 0.6 })`.
- Sparks only this player sees (client): create a `ParticleEmitter` once as a template, then `Gaxia.Effects.EmitParticle(template, CFrame.new(position), 30)`.
- A floating coin: `Motion3D.Float(coin, 1, 2)` (1 stud up and down, every 2 seconds). Every Spin/Float returns a stop function: `local stop = Motion3D.Float(coin, 1, 2)`, later `stop()`.
- A door that slides up (server): `Motion3D.To(door, door.CFrame * CFrame.new(0, 10, 0), 0.6, Enum.EasingStyle.Back)`.
- A moving platform: `Motion3D.Path(platform, { cframeA, cframeB, cframeA }, 2)` (2 seconds per part of the path; it runs once).
- Knock a player down for 2 seconds (server, package `Ragdoll`):
  ```lua
  -- fragment
  GaxiaServer.Ragdoll.Enable(character)
  task.delay(2, function() GaxiaServer.Ragdoll.Disable(character) end)
  ```
- Ragdoll when a character dies: set `humanoid.BreakJointsOnDeath = false` first, then call `GaxiaServer.Ragdoll.AutoRagdollOnDeath(character)` in `CharacterAdded`. With the default `true`, Roblox removes the joints before Ragdoll runs and nothing happens.
- An animation (server, package `Anim`): `GaxiaServer.Anim.Register("Wave", "rbxassetid://<id>")` once, then `GaxiaServer.Anim.Play(character, "Wave", { Priority = Enum.AnimationPriority.Action })`.
- Damage from an explosion: call `AntiCheat.Combat.RegisterDamage(player, amount)` before `humanoid:TakeDamage(amount)`, as in [zones-and-interactions](zones-and-interactions.md). Otherwise AntiCheat flags the hit as a cheat.
- Smooth GUI motion: `TweenUtil.Play(frame, TweenUtil.Presets.Bounce, { Size = UDim2.fromOffset(200, 60) })` (presets: `Linear`, `Quick`, `Smooth`, `Bounce`). Menus: `Gaxia.UI.Motion` ([ui](ui.md)).
- A value that follows a moving target smoothly (client): `local spring = Gaxia.Spring.new(0, 0.3)` (start value, seconds to settle). Set `spring.Target = 1` when the goal changes. In `RunService.RenderStepped`, use the result of `spring:Update(dt)` (for example as a frame's transparency).

## See also

- [API: VFX](../api/VFX.md) · [API: SFX](../api/SFX.md) · [API: Motion3D](../api/Motion3D.md) · [API: Anim](../api/Anim.md) · [API: Ragdoll](../api/Ragdoll.md)
- [API: Camera](../api/Camera.md) · [API: Sound](../api/Sound.md) · [API: Effects](../api/Effects.md) · [API: TweenUtil](../api/TweenUtil.md) · [API: Spring](../api/Spring.md)
- [Client ↔ server](../start/04-client-server-communication.md) · [Zones and interactions](zones-and-interactions.md) · [Troubleshooting](../troubleshooting.md)
