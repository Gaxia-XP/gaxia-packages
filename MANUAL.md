# 📚 Gaxia_Packages — คู่มือใช้งานฉบับสมบูรณ์

> Framework ครบวงจรสำหรับสร้างเกม Roblox — Shared utilities, UI components, Server services, และระบบ Anti-Cheat

---

## 📑 สารบัญ

1. [ภาพรวม](#1-ภาพรวม)
2. [Quick Start ใน 5 นาที](#2-quick-start-ใน-5-นาที)
3. [โครงสร้าง Framework](#3-โครงสร้าง-framework)
4. [Master Loader](#4-master-loader-gaxia--gaxiaserver)
5. [Shared Modules](#5-shared-modules)
6. [Util Modules](#6-util-modules)
7. [Client UI](#7-client-ui)
8. [Server Services](#8-server-services) — **Config / EConfig / Flags** (อ่านก่อน) + 51 services จัดกลุ่ม:
   - **Core (8.1–8.15):** DataManager · PlayerService · ItemService · EconomyService · ToolService · ZonePlus · ChatCommandSystem · AdminCommands · QuestSystem · AchievementSystem · LevelSystem · DataMigration · LeaderboardService · CrossServerMessaging · WebhookService
   - **Moderation (8.16–8.21):** Ban · Analytics · Journal · AntiCheatAdmin · Protection · Lifecycle
   - **Economy (8.22–8.28):** Vault · Shop · Monetization · Trade · Inventory · Loot · ItemDef
   - **Live-ops (8.29–8.35):** Idle · DailyReward · Mail · Raid · Party · Event · Visit
   - **Social (8.50–8.52):** Friend · Guild · Party invites (extension of 8.33)
   - **Engines (8.36–8.42):** Codex · Refine · Placement · Teleport · Cooldown · Interaction · Settings
   - **Utility + Juice (8.43–8.49):** Memory · AI · VFX · SFX · Anim · Motion3D · Ragdoll
9. [AntiCheat System](#9-anticheat-system)
10. [Bootstrap & Setup](#10-bootstrap--setup)
11. [Recipes — สูตรเขียนเกม](#11-recipes--สูตรเขียนเกม)
12. [Troubleshooting](#12-troubleshooting)
13. [FAQ](#13-faq)

---

## 1. ภาพรวม

**Gaxia_Packages** คือ framework สำหรับสร้างเกม Roblox ที่ประกอบด้วย:

| หมวด | จำนวน | ใช้ทำอะไร |
|---|---|---|
| **Shared modules** | 11 | Signal, Maid, Promise, Tween ฯลฯ — ใช้ได้ทุก context |
| **Util** | 6 | Table, String, Math helpers |
| **Client UI** | 6 controllers + 10 templates | Notification, HealthBar, Menu, Inventory ฯลฯ |
| **Server services** | 14 | DataManager, Player, Item, Economy, Tool, Zone, Chat, Admin, Quest, Achievement, Level, Migration, Leaderboard, Messages |
| **AntiCheat** | 9 detectors + 1 client | Speed, Fly, NoClip, Teleport, Remote rate limit ฯลฯ |
| **Bootstrap** | 2 | ServerBootstrap + ClientBootstrap |

### หลักการใช้งานสำคัญ
- ทุก asset ถูก **tag ด้วย "Gaxia_Packages"** อัตโนมัติ (CollectionService) — query ได้ทั้งระบบ
- **Lazy loading** — module โหลดเมื่อเรียกใช้ครั้งแรก, ไม่กิน startup time
- **Type-annotated** — มี IntelliSense / autocomplete ใน Studio Script Editor
- **Anti-Cheat แยก server/client** — server เป็น authority, client เป็น "tripwire"

---

## 2. Quick Start ใน 5 นาที

### ขั้นที่ 1: ใช้ Server-side

สร้าง **Script** ใน `ServerScriptService` (ไฟล์ไหนก็ได้):

```lua
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(ServerStorage.Gaxia_Packages_Server.init)

-- ฟัง player join
GaxiaServer.Player.OnPlayerJoined:Connect(function(player)
    print(`{player.Name} เข้าเกมแล้ว`)
    GaxiaServer.Player.SetupLeaderstats(player, {
        Coins = 0,
        Gems = 0,
    })
end)

-- ฟัง data loaded
GaxiaServer.Data.OnLoaded:Connect(function(player, data)
    print(`{player.Name} โหลด data: Coins={data.Coins}`)
    -- Sync ค่า saved กลับ leaderstats
    GaxiaServer.Player.SetLeaderstat(player, "Coins", data.Coins)
end)

-- ทุก 10 วินาที แจกเหรียญ
while task.wait(10) do
    for _, player in ipairs(game.Players:GetPlayers()) do
        GaxiaServer.Economy.Add(player, "Coins", 100)
        GaxiaServer.Player.SetLeaderstat(player, "Coins", GaxiaServer.Economy.Get(player, "Coins"))
    end
end
```

### ขั้นที่ 2: ใช้ Client-side

สร้าง **LocalScript** ใน `StarterPlayerScripts`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Gaxia = require(ReplicatedStorage.Gaxia_Packages.init)

-- แสดง notification
Gaxia.UI.NotificationService.Notify("Welcome", "ยินดีต้อนรับสู่เกม!", 5, "success")

-- ใช้ utility
local formatted = Gaxia.Util.String.FormatNumber(1500)  -- "1.5K"
local formatted2 = Gaxia.Util.String.FormatCommas(1234567)  -- "1,234,567"

-- ทำ tween
local part = workspace:WaitForChild("MyPart")
Gaxia.Tween(part, TweenInfo.new(2), { Position = Vector3.new(0, 50, 0) })

-- Promise
local p = Gaxia.Promise.delay(3):andThen(function()
    print("3 วินาทีผ่านไป")
end)
```

จบ! ที่เหลือคือเรียนรู้ APIs แต่ละตัว

---

## 3. โครงสร้าง Framework

```
ReplicatedStorage/
├── Gaxia_Packages/              ← ใช้ได้ทั้ง server + client
│   ├── init                     ← Master Loader
│   ├── Shared/                  ← 11 modules
│   │   ├── Signal, Maid, Janitor, Trove, Promise
│   │   ├── TweenUtil, Raycaster, Spring
│   │   ├── Logger, Symbol, Constants
│   │   └── Util/                ← 6 utility modules
│   │       └── Table, String, Math, Instance, Player, Debug
│   └── Client/                  ← ใช้ได้แค่ client
│       ├── ClientAntiCheat
│       └── UI/                  ← 6 controllers + 1 templates module
│           ├── UIController, NotificationService
│           ├── HealthBarController, MenuController
│           ├── InventoryController, HUDController
│           └── Templates         ← 10 code-first builders (v16)
└── Events/                      ← 3 RemoteEvents
    ├── AntiCheat_Report
    ├── UI_Notify
    └── System_Heartbeat

ServerStorage/
└── Gaxia_Packages_Server/       ← server-only
    ├── init                     ← Server Master Loader
    ├── Lib/                     ← 14 services
    │   ├── DataManager, PlayerService
    │   ├── ItemService, EconomyService
    │   ├── ToolService, ZonePlus
    │   ├── ChatCommandSystem, AdminCommands
    │   ├── QuestSystem, AchievementSystem
    │   ├── LevelSystem, DataMigration
    │   ├── LeaderboardService, CrossServerMessaging
    └── AntiCheat/               ← orchestrator + 9 detectors
        ├── init                 ← orchestrator
        ├── SpeedDetector, FlyDetector
        ├── NoClipDetector, TeleportDetector
        ├── RemoteRateLimiter, StatGuard
        ├── ToolDuplicationGuard, AnimationGuard
        └── ExploitSignatureScanner

StarterGui/
└── Gaxia_UI/                    ← ScreenGui (auto-cloned to PlayerGui)
    ├── HUD/                     ← persistent HUD elements
    └── Overlays/                ← modal popups
    -- (Templates ย้ายมาเป็น code-first Luau module ที่
    --  ReplicatedStorage.Gaxia_Packages.Client.UI.Templates)

ServerScriptService/
└── Gaxia_ServerBootstrap        ← Script — รัน server stack

StarterPlayer/StarterPlayerScripts/
└── Gaxia_ClientBootstrap        ← LocalScript — รัน client stack
```

---

## 4. Master Loader: Gaxia + GaxiaServer

มี **2 entry points** — เรียกตามว่าอยู่ context ไหน:

### Client side / Shared (ใช้ในทุก context)
```lua
local Gaxia = require(game.ReplicatedStorage.Gaxia_Packages.init)
```

### Server side
```lua
local GaxiaServer = require(game.ServerStorage.Gaxia_Packages_Server.init)
```

### โครงสร้าง

| Path | คือ |
|---|---|
| `Gaxia.Signal` | Shared modules (flat) |
| `Gaxia.Util.Table` | Util submodules (nested) |
| `Gaxia.UI.NotificationService` | Client UI (client only) |
| `Gaxia.AntiCheat` | ClientAntiCheat (client only) |
| `Gaxia.Logger` | singleton logger |
| `Gaxia.Constants` | frozen constants |
| `Gaxia.Tween(inst, info, props)` | convenience tween |
| `GaxiaServer.Shared.<...>` | re-export ของ Gaxia ทั้งหมด |
| `GaxiaServer.Data` | DataManager |
| `GaxiaServer.Player` | PlayerService |
| `GaxiaServer.Item` | ItemService |
| `GaxiaServer.Economy` | EconomyService |
| `GaxiaServer.Tool` | ToolService |
| `GaxiaServer.Zone` | ZonePlus 3.2.0 (direct API) |
| `GaxiaServer.Chat` | ChatCommandSystem |
| `GaxiaServer.Admin` | AdminCommands |
| `GaxiaServer.Quest` | QuestSystem |
| `GaxiaServer.Achievement` | AchievementSystem |
| `GaxiaServer.Level` | LevelSystem |
| `GaxiaServer.Migration` | DataMigration |
| `GaxiaServer.Leaderboard` | LeaderboardService |
| `GaxiaServer.Messages` | CrossServerMessaging |
| `GaxiaServer.AntiCheat` | AntiCheat orchestrator |

> ⚠️ **อย่า require folder ตรงๆ** — ต้องเข้าผ่าน `.init`:
> ```lua
> require(game.ReplicatedStorage.Gaxia_Packages)        -- ❌ ผิด
> require(game.ReplicatedStorage.Gaxia_Packages.init)   -- ✅ ถูก
> ```

---

## 5. Shared Modules

### 5.1 Signal — Custom event

```lua
local Signal = Gaxia.Signal

local mySignal = Signal.new()

-- เชื่อม listener
local conn = mySignal:Connect(function(arg1, arg2)
    print("ได้ฟัง:", arg1, arg2)
end)

-- ฟังครั้งเดียวแล้วเลิกฟัง
mySignal:Once(function(x) print("ครั้งเดียว:", x) end)

-- ยิง event
mySignal:Fire("hello", 42)

-- รอ event (yield จนกว่าจะ fire)
local v = mySignal:Wait()

-- เลิกฟัง
conn:Disconnect()

-- เคลียร์ทั้งหมด
mySignal:DisconnectAll()
mySignal:Destroy()
```

**ใช้ตอนไหน:** สร้าง event ของตัวเอง — เช่น `OnEnemyKilled`, `OnQuestComplete`

### 5.2 Maid — Deprecated alias of Janitor

```lua
assert(Gaxia.Maid == Gaxia.Janitor)
local janitor = Gaxia.Maid.new()
janitor:Add(connection)
janitor:Cleanup()
```

ชื่อ `Maid` คงไว้เฉพาะช่วยย้ายโค้ด แต่ API คือ Janitor โดยตรง โค้ดใหม่ควรใช้ `Gaxia.Janitor`

### 5.3 Janitor — เหมือน Maid แต่มี named index

```lua
local Janitor = Gaxia.Janitor
local jan = Janitor.new()

-- เพิ่ม + ตั้งชื่อ index
jan:Add(part, nil, "MainPart")          -- ใช้ default :Destroy()
jan:Add(connection, nil, "MainConn")    -- auto-detect connection → :Disconnect()
jan:Add(myObj, "CustomCleanup", "OBJ")  -- เรียก myObj:CustomCleanup()

-- ลบ + cleanup task เฉพาะ index
jan:Remove("MainPart")

-- ดึง object คืน (ไม่ cleanup)
local part = jan:Get("MainPart")

-- เคลียร์ทั้งหมด
jan:Cleanup()

-- Auto-cleanup ตอน Instance ถูก :Destroy() (เช่น Character)
jan:LinkToInstance(player.Character)
```

**ใช้ตอนไหน:** ต้องการอ้างอิง / replace task ที่ track อยู่ — เหมาะกับ per-player state

### 5.4 Trove — Sleitnick style modern cleanup

```lua
local Trove = Gaxia.Trove
local trove = Trove.new()

-- Add (returns object for chaining)
local part = trove:Add(Instance.new("Part"))
part.Parent = workspace

-- Construct สำเร็จรูป
local janitor = trove:Construct(Gaxia.Janitor)

-- Connect signal helper
trove:Connect(workspace.ChildAdded, function(child)
    print("เพิ่ม:", child.Name)
end)

-- Child trove (cleanup ตอน parent clean)
local child = trove:Extend()
child:Add(someObj)

-- Remove without cleanup (transfer ownership)
trove:Remove(part)

-- Clean
trove:Clean()
-- หรือ
trove:Destroy()
```

**ใช้ตอนไหน:** เขียน class ใหม่ — ใช้ Trove เพราะ API สวยกว่า Maid

### 5.5 Promise — Async pattern

```lua
local Promise = Gaxia.Promise

-- สร้าง promise
local p = Promise.new(function(resolve, reject, onCancel)
    task.delay(2, function()
        resolve("done!")
    end)

    -- รับ cancel
    onCancel(function()
        print("ถูก cancel")
    end)
end)

-- Chain
p:andThen(function(value)
    print("ได้:", value)
    return "next value"
end):catch(function(err)
    warn("error:", err)
end):finally(function(status)
    print("จบ:", status)  -- "resolved" / "rejected" / "cancelled"
end)

-- Yield รอ result
local ok, value = p:await()

-- Throw error ถ้า reject
local value = p:expect()

-- Cancel
p:cancel()
```

**Static helpers:**
```lua
Promise.resolve(42)           -- already resolved
Promise.reject("oops")        -- already rejected
Promise.delay(3)              -- resolves after 3s

-- รอทุก promise (reject ถ้ามีตัวใด reject)
Promise.all({p1, p2, p3}):andThen(function(results)
    print(results[1], results[2], results[3])
end)

-- รอตัวแรกที่ resolve (reject ถ้าทุกตัว reject)
Promise.any({p1, p2})

-- ตัวแรกที่ settle (resolve OR reject)
Promise.race({p1, p2})
```

**ใช้ตอนไหน:** Async operations — API calls, timed sequences, parallel work

### 5.6 TweenUtil — Tween shortcuts

```lua
local TweenUtil = Gaxia.TweenUtil

-- Presets
TweenUtil.Presets.Linear     -- TweenInfo สำเร็จรูป
TweenUtil.Presets.Quick      -- 0.15s easing
TweenUtil.Presets.Smooth     -- 0.5s easing
TweenUtil.Presets.Bounce     -- bounce easing

-- Create + Play
local tween = TweenUtil.Play(part, TweenUtil.Presets.Smooth, {
    Position = Vector3.new(0, 50, 0),
    Transparency = 0.5,
})

-- async (resolve เมื่อจบ tween)
TweenUtil.PlayAsync(part, TweenUtil.Presets.Quick, {
    Position = goal
}):andThen(function()
    print("tween จบแล้ว")
end)

-- Chain (sequential)
TweenUtil.Chain({
    {instance = part, info = TweenUtil.Presets.Linear, props = {Transparency = 0}},
    {instance = part, info = TweenUtil.Presets.Smooth, props = {Position = Vector3.new(0, 10, 0)}},
    {instance = part, info = TweenUtil.Presets.Bounce, props = {Size = Vector3.new(2, 2, 2)}},
})
```

### 5.7 Raycaster — Builder pattern

```lua
local Raycaster = Gaxia.Raycaster

local ray = Raycaster.new()
    :Filter({character})                    -- exclude (default mode)
    :FilterType(Enum.RaycastFilterType.Exclude)
    :IgnoreWater(true)
    :CollisionGroup("Default")

local result = ray:Cast(origin, direction)
if result then
    print(`hit: {result.Instance.Name} at {result.Position}`)
end

-- Cast จาก camera (client เท่านั้น)
local result = ray:CastFromCamera(500)  -- 500 studs forward

-- Cast ตามตำแหน่ง mouse
local result = ray:CastFromMouse(500)

-- One-liner ไม่ต้อง builder
local result = Raycaster.Quick(origin, direction, {character})
```

### 5.8 Spring — Critically-damped physics spring

```lua
local Spring = Gaxia.Spring

-- รองรับ number / Vector2 / Vector3
local spring = Spring.new(Vector3.zero)
spring.Target = Vector3.new(0, 100, 0)
spring.Speed = 10        -- เร็วแค่ไหน
spring.Damper = 1        -- 1 = critical, <1 = overshoot

-- รัน loop
RunService.Heartbeat:Connect(function(dt)
    local pos = spring:Update(dt)
    camera.CFrame = CFrame.new(pos)
end)

-- กระแทกเพิ่ม
spring:Impulse(Vector3.new(0, 50, 0))
```

**ใช้ตอนไหน:** Camera shake, UI bounce animations, smooth physics-like motion

### 5.9 Logger — Leveled logging

```lua
local Logger = Gaxia.Logger

Logger:Info("Player {} joined with {} coins", player.Name, 100)
-- → [INFO 12:34:56] [GaxiaPackages] Player Bob joined with 100 coins

Logger:Warn("Low health: {}", hp)
Logger:Debug("Internal state: {}", state)
Logger:Error("Critical: {}", err)  -- จะ throw error เลย

-- ปรับ level (DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4)
Logger:SetLevel("WARN")  -- จะ print แค่ WARN + ERROR

-- ปิด/เปิด individual level
Logger:SetEnabled("DEBUG", false)

-- Scoped logger (สำหรับแยก module)
local combatLog = Logger:Scope("Combat")
combatLog:Info("Hit {} for {} dmg", target.Name, dmg)
-- → [INFO 12:34:56] [Combat] Hit Bob for 50 dmg
```

### 5.10 Symbol — Reference-equality unique IDs

```lua
local Symbol = Gaxia.Symbol

local s1 = Symbol("UNIQUE_KEY")
local s2 = Symbol("UNIQUE_KEY")

print(s1 == s2)         -- false (table identity, not name)
print(tostring(s1))     -- "Symbol(UNIQUE_KEY)"

-- เหมือน JS Symbol — ใช้เป็น "private key" ใน table
local SECRET = Symbol("secret")
myObj[SECRET] = "hidden value"  -- ไม่มีใครเดา key ได้
```

### 5.11 Constants — Frozen config values

```lua
local C = Gaxia.Constants

print(C.MAX_PLAYERS)                     -- 50
print(C.SPEED_TOLERANCE_MULTIPLIER)      -- 1.5
print(C.NOTIFICATION_DEFAULT_DURATION)   -- 3
-- ฯลฯ

-- table เป็น frozen — แก้ไม่ได้
C.MAX_PLAYERS = 100  -- error!
```

**Constants ทั้งหมด:**
- `REMOTE_RATE_LIMIT_DEFAULT` = 10 (network)
- `REMOTE_RATE_BURST` = 20
- `SPEED_TOLERANCE_MULTIPLIER` = 1.5 (anti-cheat)
- `FLY_VELOCITY_THRESHOLD` = 30
- `NOCLIP_RAYCAST_INTERVAL` = 1
- `TELEPORT_MAX_DELTA` = 50
- `SAMPLER_INTERVAL` = 0.5
- `SOFT_FLAG_THRESHOLD` = 3
- `HARD_FLAG_THRESHOLD` = 5
- `NOTIFICATION_DEFAULT_DURATION` = 3 (UI)
- `NOTIFICATION_MAX_STACK` = 5
- `UI_ANIMATION_TIME` = 0.25
- `CHARACTER_LOAD_TIMEOUT` = 10
- `MAX_PLAYERS` = 50

---

## 6. Util Modules

ใช้ผ่าน `Gaxia.Util.<name>`

### 6.1 Util.Table

```lua
local Table = Gaxia.Util.Table

-- Copy
Table.Copy(t)             -- one-level copy
Table.Copy(t, true)       -- recursive clone (ห้ามมี cycle)

-- Merge
Table.Assign(t1, t2)      -- new table, later tables win
local reconciled = Table.Reconcile(target, template) -- immutable; ต้องใช้ค่าที่ return

-- Functional
Table.Filter(t, function(v, k) return v > 0 end)
Table.Map(t, function(v) return v * 2 end)
Table.Reduce(t, function(acc, v) return acc + v end, 0)
Table.Find(t, function(v) return v.name == "Bob" end)  -- returns (value, key)
Table.Some(t, function(v) return v == target end)
Table.IsEmpty(t)

-- Keys / Values
Table.Keys(t)
Table.Values(t)

-- Array
Table.Reverse({1,2,3})         -- {3,2,1}
Table.Shuffle({1,2,3,4,5})     -- คืน array ใหม่ ไม่แก้ input
Table.Sample({1,2,3}, 1)[1]    -- random element
Table.Flat({1, {2, {3}}}, 2)   -- {1,2,3} (depth-limited)
```

### 6.2 Util.String

```lua
local String = Gaxia.Util.String

String.FormatNumber(1500)        -- "1.5K"
String.FormatNumber(2_500_000)   -- "2.5M"
String.FormatNumber(1_500_000_000) -- "1.5B"

String.FormatCommas(1234567)     -- "1,234,567"
String.FormatTime(3661)          -- "1:01:01"

String.Trim("  hello  ")         -- "hello"
String.Split("a,b,c", ",")       -- {"a","b","c"}
String.Pluralize("apple", 1)     -- "apple"
String.Pluralize("apple", 5)     -- "apples"
```

### 6.3 Util.Math

```lua
local Math = Gaxia.Util.Math

Math.Lerp(0, 100, 0.5)            -- 50
Math.Clamp(15, 0, 10)             -- 10
Math.MapRange(0.5, 0, 1, 0, 200)  -- 100
Math.Round(3.7)                   -- 4
Math.Round(3.456, 2)              -- 3.46
Math.RandomFloat(0, 1)            -- 0.0–1.0
```

### 6.4 Util.Instance

```lua
local InstanceUtil = Gaxia.Util.Instance

InstanceUtil.WaitForDescendant(workspace, "MyPart", 5)  -- WaitForChild ลึก
InstanceUtil.GetTaggedDescendants(workspace, "Enemy")    -- find by tag
InstanceUtil.SafeDestroy(inst)  -- pcall-protected
```

### 6.5 Util.Player

```lua
local PlayerUtil = Gaxia.Util.Player

PlayerUtil.GetCharacter(player, 10)   -- yield จนกว่าจะมี character (timeout 10s)
PlayerUtil.GetHumanoid(player)        -- nil-safe
PlayerUtil.IsAlive(player)            -- bool
PlayerUtil.Teleport(player, cframe)
```

### 6.6 Util.Debug

```lua
local Debug = Gaxia.Util.Debug

-- Pretty print
Debug.Stringify({a=1, b={c=2}})      -- string ที่อ่านง่าย
Debug.PrettyPrint({nested = {deep = true}})

-- Stack trace
Debug.Trace()  -- print stack

-- Timing
Debug.Time("loadData", function()
    -- code...
end)  -- → "[loadData] took 0.234s"

-- Property watch
local stop = Debug.Watch(part, "Position")
-- print ทุกครั้ง position เปลี่ยน
-- เรียก stop() เพื่อเลิก watch

-- Assert
Debug.Assert(value ~= nil, "value cannot be nil")
```

---

## 7. Client UI

> ⚠️ ใช้ได้แค่ **client (LocalScript)** เท่านั้น

### 7.1 UIController — ตัวกลาง

```lua
local UI = Gaxia.UI

-- Clone template
local frame = UI.UIController.CloneTemplate("ButtonTemplate", parent)
-- ถ้าไม่ส่ง parent → ใช้ active ScreenGui

-- ตัวอ้างอิงที่สำคัญ
local screen = UI.UIController.GetActiveScreen()  -- PlayerGui.Gaxia_UI
local hud = UI.UIController.HUD()                  -- HUD folder
local overlays = UI.UIController.Overlays()        -- Overlays folder
```

### 7.2 NotificationService — Toast

```lua
local Notif = Gaxia.UI.NotificationService

-- ประเภท: "info" | "success" | "warn" | "error"
Notif.Notify("Welcome", "เข้าเกมแล้ว", 3, "success")
Notif.Notify("Warning", "HP ต่ำ!", 5, "warn")
Notif.Notify("Error", "Save failed", 4, "error")
```

- Slide-in จากขวา + auto-dismiss
- Max stack 5 (เก่าสุดจะ dismiss ก่อน)
- UIStroke สีตามประเภท

### 7.3 HealthBarController — แสดง HP

```lua
local HB = Gaxia.UI.HealthBarController

-- ผูกกับ humanoid
local controller = HB.Attach(humanoid, parent)
-- ถ้าไม่ส่ง parent → ใช้ HUD folder

-- เปลี่ยนสีอัตโนมัติ: green (>60%) → yellow (30-60%) → red (<30%)
-- update เมื่อ humanoid.Health เปลี่ยน

-- ลบ
controller.Destroy()
```

### 7.4 MenuController — Modal popup

```lua
local Menu = Gaxia.UI.MenuController

-- เปิด menu พร้อม content
local frame = Menu.Open("Settings", function(content)
    -- เพิ่ม UI elements ใน content (เป็น ScrollingFrame)
    for i, optName in ipairs({"Music", "SFX", "Camera"}) do
        local btn = Instance.new("TextButton")
        btn.Text = optName
        btn.Size = UDim2.new(1, -8, 0, 36)
        btn.Position = UDim2.new(0, 4, 0, (i-1) * 40)
        btn.Parent = content
    end
    content.CanvasSize = UDim2.new(0, 0, 0, 120)
end)

-- ปิด
Menu.Close("Settings")
```

### 7.5 InventoryController — Grid 

```lua
local Inv = Gaxia.UI.InventoryController

Inv.Open({
    {name = "Sword", icon = "rbxassetid://1234", count = 1},
    {name = "Coin",  icon = "rbxassetid://5678", count = 999},
    {name = "Gem",   icon = "",                  count = 5},
})

Inv.Close()
```

### 7.6 HUDController — Persistent HUD

```lua
local HUD = Gaxia.UI.HUDController

-- เพิ่ม text label ที่ auto-update
HUD.AddText("CoinCounter", function()
    return `Coins: {Gaxia.Util.String.FormatCommas(myCoins)}`
end, UDim2.new(0, 20, 0, 20))

-- ลบ
HUD.Remove("CoinCounter")

-- ปิด/เปิดทั้ง HUD folder
HUD.SetVisible(false)
```

### 7.7 GUI Templates 10 แบบ (Code-first, v16)

> 🔁 **เปลี่ยนจาก v15** — เคยเป็น `StarterGui.Gaxia_UI.Templates` (Instances ใน .rbxm binary). ตอนนี้เป็น **Luau module** ที่ `ReplicatedStorage/Gaxia_Packages/Client/UI/Templates` — diff-able, parameterizable, ไม่มี binary blob

| Template | ใช้ทำอะไร |
|---|---|
| `ButtonTemplate` | TextButton พร้อม UIStroke + UICorner |
| `FrameTemplate` | Base container |
| `HealthBarTemplate` | HP bar (มี Fill + Label) |
| `NotificationTemplate` | Toast (Icon + Title + Message) |
| `MenuTemplate` | Modal (TitleBar + Content ScrollingFrame) |
| `InventoryTemplate` | Grid (ScrollingFrame) |
| `DialogTemplate` | NPC dialog (Portrait + Name + Message + Continue) |
| `TooltipTemplate` | Hover hint (follow mouse) |
| `LoadingScreenTemplate` | Full-screen (Logo + ProgressBar + Status) |
| `ConfirmDialogTemplate` | Modal Yes/No |

**สองวิธีใช้:**

```lua
-- A) ผ่าน UIController (เหมือนเดิม — call sites ไม่ต้องแก้)
local frame = Gaxia.UI.UIController.CloneTemplate("ButtonTemplate", parent)
frame.Text = "Play"  -- mutate properties หลัง spawn

-- B) เรียก builder ตรงๆ (กรณีต้อง customize ก่อน parent)
local Templates = require(game.ReplicatedStorage.Gaxia_Packages.Client.UI.Templates)
local btn = Templates.ButtonTemplate()  -- ไม่ parent
btn.BackgroundColor3 = Color3.fromRGB(255, 100, 100)
btn.Text = "Danger!"
btn.Visible = true
btn.Parent = parent
```

**Code-first ข้อดี:** สร้าง variant ใหม่ง่าย — copy/paste builder, แก้ properties, ได้ template ใหม่. ไม่ต้องเปิด Studio ไม่ต้อง save .rbxm

---

## 8. Server Services

ใช้ผ่าน `GaxiaServer.<Name>` — รัน **server context เท่านั้น**

### Config / EConfig / Flags — runtime tunables (อ่านก่อน)

ทุก service ใน framework ใช้ **two-layer config**: ค่า default static อยู่ใน `Config.lua` (server-private, ไม่ replicate — secrets/balance) + resolver `EConfig` ที่ overlay ด้วย runtime `Flags` (shared, replicate ผ่าน ReplicatedState attributes, session-scoped). Admin command (`/flag set …`) แก้ flag ได้ live ระหว่าง server รัน — ไม่ต้อง restart; รีบูต = revert กลับ Config default ทันที.

**ทำไมแบบนี้:** secrets (DataStore names, webhook URLs, AntiCheat thresholds) อยู่ใน Config ฝั่ง server เท่านั้น — cheat client เห็นไม่ได้. ค่าที่ "ปรับขณะรัน" ปลอดภัย (drop rate, cooldown, prices) วางใน Flags — replicate ไป client ได้สำหรับ UI sync.

**Server-side read (ใน service):**
```lua
local s = server() -- lazy require Gaxia_Packages_Server (cyclic-dep-safe — :: any cast)
-- effective = Flag override → Config default → fallback
local cap     = s.EConfig.Get("Economy.MaxTransaction", (s.Config.Economy or {}).MaxTransaction or 1e6)
local enabled = s.EConfig.Enabled("AntiCheat.Enabled", s.Config.AntiCheat.Enabled)
```

**Admin write (chat command — ดู §8.19 AntiCheatAdmin):**
```
/flag set Raid.LootFraction 0.2      -- live override (raid ถัดไปใช้ 0.2 เลย)
/flag get Raid.LootFraction
/flag clear Raid.LootFraction        -- กลับ Config default
/ac off                              -- shortcut: AntiCheat master off
/ac off Speed                        -- per-detector off
/ac reset                            -- ล้าง override AntiCheat ทั้งหมด
```

**Programmatic write:**
```lua
GaxiaServer.EConfig.Set("Raid.LootFraction", 0.2)   -- = Flags.Set (replicate ทันที)
GaxiaServer.EConfig.Clear("Raid.LootFraction")
local overridden = GaxiaServer.EConfig.IsOverridden("Raid.LootFraction")
```

**Shared client read (flag ที่ public):**
```lua
local Gaxia = require(ReplicatedStorage.Gaxia_Packages)   -- shared
local mult = Gaxia.Flags.Get("Economy.GlobalMultiplier", 1)
Gaxia.Flags.OnChanged:Connect(function(key, value) end)
```

**Naming:** flag key = dot-path เทียบ Config section — `Economy.MaxTransaction`, `AntiCheat.Speed.ToleranceMultiplier`, `Webhook.Enabled`, ฯลฯ. ทุก service section ด้านล่างที่มี **Config** block แสดง key ที่อ่าน — wrap ด้วย `EConfig.Get("Section.Key", default)` ที่ call-time ก็ได้ live override.

**Session-scoped:** Flag เก็บเป็น `ReplicatedState` attributes — restart server = reset. ตั้งใจ (ไม่ persist override กัน typo รอดข้ามรอบ); ถ้าต้องการถาวร — แก้ที่ Config.

---

### 8.1 DataManager — ProfileService wrapper

```lua
local Data = GaxiaServer.Data

-- Schema เริ่มต้น
print(Data.DEFAULT_PROFILE)  -- {Coins=0, Gems=0, Level=1, Inventory={}, ...}

-- รอ profile โหลด
Data.OnLoaded:Connect(function(player, data)
    print(`{player.Name}: Coins={data.Coins} Level={data.Level}`)
end)

-- Read
local coins = Data.Get(player, "Coins")
local all = Data.Get(player)   -- whole table

-- Write (auto-save ผ่าน ProfileService)
Data.Set(player, "Coins", 500)

-- Yield รอโหลด
local data = Data.WaitFor(player, 10)  -- 10s timeout

-- Check
if Data.IsLoaded(player) then ... end

-- Force save (ProfileService ก็ auto-save อยู่แล้ว — แค่ nudge)
Data.Save(player)

-- ฟัง data change
Data.OnDataChanged:Connect(function(player, key, value)
    print(`{player.Name}.{key} = {value}`)
end)

-- ฟัง release
Data.OnReleased:Connect(function(player) end)
```

> **Schema อยู่ใน DataManager.lua** — แก้ `DEFAULT_PROFILE` ได้, มี `Reconcile` ทำให้ field ใหม่ใส่ค่า default อัตโนมัติ

### 8.2 PlayerService — Player lifecycle

```lua
local PS = GaxiaServer.Player

-- ฟัง events
PS.OnPlayerJoined:Connect(function(player) end)
PS.OnPlayerLeft:Connect(function(player) end)
PS.OnCharacterAdded:Connect(function(player, character) end)

-- Leaderstats
PS.SetupLeaderstats(player, {
    Coins = 0,
    Gems = 0,
    Level = 1,
})
-- จะสร้าง player.leaderstats Folder + IntValue ทุก key อัตโนมัติ

PS.SetLeaderstat(player, "Coins", 100)
local coins = PS.GetLeaderstat(player, "Coins")

-- Character helpers
PS.SetWalkSpeed(player, 16)
PS.SetJumpPower(player, 50)
PS.Teleport(player, CFrame.new(0, 50, 0))

-- Iterate
PS.ForEach(function(player)
    print(player.Name)
end)
```

### 8.3 ItemService — Inventory

```lua
local Item = GaxiaServer.Item

-- ต้องโหลด Data ก่อน (ใช้ profile.Inventory)
Item.Give(player, "Sword", 1)
Item.Give(player, "Coin", 100)

-- Remove (false ถ้าไม่พอ)
local ok = Item.Remove(player, "Coin", 50)

-- Check
Item.Has(player, "Sword", 1)       -- bool
Item.Count(player, "Coin")          -- number

-- Get full inventory (shallow copy — แก้ไม่ได้)
local inv = Item.GetInventory(player)

-- Clear ทั้งหมดของ item นั้น
Item.Clear(player, "Sword")

-- ฟัง change
Item.OnItemChanged:Connect(function(player, itemId, newCount, delta)
    print(`{player.Name} {itemId}: {newCount} (delta={delta})`)
end)
```

**Anti-exploit:** `count` ถูก clamp ที่ MAX_ITEM_COUNT = 999,999 อัตโนมัติ

### 8.4 EconomyService — Currency

```lua
local Eco = GaxiaServer.Economy

-- Add (clamp ที่ MAX_TRANSACTION = 1M ต่อครั้ง)
Eco.Add(player, "Coins", 500)

-- Spend (atomic — fail ถ้าเงินไม่พอ)
local ok = Eco.Spend(player, "Coins", 100)

-- Get
local coins = Eco.Get(player, "Coins")

-- Set (admin override — ไม่เช็ค min/max)
Eco.Set(player, "Coins", 0)

-- Transfer (atomic ระหว่าง 2 player)
Eco.Transfer(from, to, "Coins", 50)

-- ฟัง transaction
Eco.OnTransaction:Connect(function(player, currency, delta, newBalance, kind)
    -- kind: "add" | "spend" | "set" | "transfer"
    print(`{player.Name} {currency} {delta:+} → {newBalance} ({kind})`)
end)
```

**ผูกกับ DataManager** — currency อยู่ใน profile.Coins, profile.Gems ฯลฯ

### 8.5 ToolService — Tool + Anti-Dupe

```lua
local Tool = GaxiaServer.Tool

-- สร้าง tool ใหม่ (UID + ItemId attributes)
local sword = Tool.Create("Sword", {
    GripPos = Vector3.new(0, 0, -1),
    -- ฯลฯ properties อื่นๆ
})
sword.Parent = workspace

-- Give to player
local tool = Tool.Give(player, "Sword")

-- Track existing tool (เช่น mock tool ที่ใส่ใน workspace มาก่อน)
Tool.Track(existingTool)

-- Check ถูก track ไหม
Tool.IsTracked(tool)  -- bool

-- ฟัง duplicate detection
Tool.OnDuplicate:Connect(function(dupe)
    -- dupe ถูก destroy แล้วก่อนที่ event นี้จะ fire
    warn("Duplicate tool detected!")
end)
```

**กลไก:**
- Tool ทุกตัวมี `UID` attribute (GUID)
- ถ้า UID ซ้ำ → destroy + fire OnDuplicate
- WeakTable registry → tool ที่ถูก destroy จริงๆ จะ evict อัตโนมัติ

### 8.6 ZonePlus — Trigger zones

```lua
local Zone = GaxiaServer.Zone

-- สร้าง zone จาก BasePart/Model/Folder
local part = workspace.SafeZoneRegion  -- ตั้งเป็น Anchored, CanCollide=false, Transparent
local safeZone = Zone.new(part)

-- ฟัง enter / leave
safeZone.playerEntered:Connect(function(player)
    print(`{player.Name} เข้าโซนปลอดภัย`)
end)

safeZone.playerExited:Connect(function(player)
    print(`{player.Name} ออกจากโซน`)
end)

-- Query
safeZone:findPlayer(player) -- bool
safeZone:getPlayers()       -- array of players in zone

-- Destroy
safeZone:destroy()
```

`GaxiaServer.Zone` คือ ZonePlus 3.2.0 โดยตรง ไม่มี named-zone registry ของ Gaxia แล้ว

### 8.7 ChatCommandSystem — Slash commands

```lua
local Chat = GaxiaServer.Chat  -- (or require ตรงๆ)

-- Register command (role-gated)
Chat.Register("announce", {
    roles = { "admin" },
    args  = { "string" },
    help  = "Broadcast a message",
}, function(caller: Player, args: { string }): string?
    -- args[1] = message text
    print(`[Admin] {caller.Name}: {args[1]}`)
    return `Sent: {args[1]}`
end)

-- Run manually (e.g. from server console)
Chat.Run(player, "/announce hello")

-- Listen to all command dispatches
Chat.OnCommand:Connect(function(caller, name, args, success)
    print(caller.Name, name, success)
end)

-- Parse typed args
local parsed = Chat.ParseArgs({"player", "number"}, {"Bob", "50"})
-- → { Player<Bob>, 50 }  (nil ถ้า parse ล้มเหลว)
```

**Built-in (ใช้ได้ทันที):**
- `/help [cmd]` — แสดง list คำสั่ง หรือ help ของคำสั่งนั้น
- `/credits` — แสดง framework credits

**Chat integration:** รองรับ TextChatService (modern) + Legacy Chat อัตโนมัติ
คำสั่งที่ขึ้นต้น `/` จะถูก redact จาก chat (ไม่โชว์ให้คนอื่นเห็น)

---

### 8.8 AdminCommands — Role-gated moderation

```lua
local Admin = GaxiaServer.Admin

-- ── Roles ──
-- "default" < "moderator" < "admin" < "owner"
Admin.GetRole(player)                          -- string
Admin.IsAtLeast(player, "moderator")           -- bool
Admin.SetRole(player.UserId, "admin")          -- persist to DataStore

-- ── Register custom command ──
-- Handler คืน (message, failed?) — คืน string เฉย ๆ = สำเร็จ (toast เขียว / ✓ ใน
-- Audit); คืน (message, true) = rejection (toast แดง "Blocked" / ✗ ใน Audit).
-- ถ้าคืนแค่ string ตอน fail คำสั่งจะถูกนับเป็น "สำเร็จ" ใน audit feed!
Admin.Register("nuke", {
    role = "owner",
    help = "Clear workspace",
}, function(caller: Player, args: { string }): (string?, boolean?)
    if args[1] ~= "confirm" then
        return "พิมพ์ /nuke confirm เพื่อยืนยัน", true  -- rejection
    end
    return "nuked"                                      -- success
end)

-- ── Run programmatically ──
-- ok = true เฉพาะเมื่อคำสั่ง "ทำงานสำเร็จจริง" (handler error และ rejection = false)
local ok, message = Admin.Run(caller, "speed", {"PlayerName", "200"})

-- ── Listen ──
Admin.OnCommand:Connect(function(caller, name, args, success, message)
    print(`{caller.Name} ran /{name} → {success} ({message})`)
end)
```

**Built-in commands:**

| Command | Role | Syntax | ทำอะไร |
|---|---|---|---|
| `/kick` | moderator | `/kick <player> [reason]` | Kick player |
| `/ban` | admin | `/ban <player> [reason]` | Ban + kick (persistent DataStore) |
| `/unban` | admin | `/unban <userId>` | Remove ban |
| `/give` | admin | `/give <player> <itemId> [count]` | Give items |
| `/teleport` | moderator | `/teleport <who> <to>` | Teleport A → B |
| `/speed` | admin | `/speed <player> <number>` | Set WalkSpeed |
| `/heal` | moderator | `/heal <player>` | Heal to full HP |
| `/respawn` | moderator | `/respawn <player>` | Force respawn |
| `/role` | owner | `/role <player> <roleName>` | Set player role |

**Moderation guard (ban / kick / role):** `/ban` `/kick` และ `/role` ปฏิเสธเป้าหมายที่เป็น (ก) ตัวเอง — กัน "เผลอแบนตัวเองแล้ว lock out" และกัน "/role me" ที่เคย demote ตัวเองถาวร, (ข) เจ้าของเกม (place creator), (ค) คนที่ role เท่ากันหรือสูงกว่า — admin แบน admin/owner ไม่ได้. ใช้ guard ตัวเดียวกันทั้ง chat และ Admin Panel (ปุ่มใน Players tab จะขึ้น toast บอกเหตุผลแทนที่จะ lock out). ถ้าเผลอแบนใครไปจริง: ให้ admin อีกคนสั่ง `/unban <userId>` หรือใน Studio รัน `GaxiaServer.Ban.Unban(userId)` (ต้องเปิด Studio Access to API Services).

**กฎเพิ่มของ `/role`:** ต้องระบุ role เสมอ (ไม่มี default), ตั้ง role ที่เท่ากับ/สูงกว่าตัวเองไม่ได้ (กันการสร้าง owner คู่ที่ย้อนมา demote คนตั้ง — เพิ่ม owner ผ่าน `Config.Admin.Bootstrap`), และ demote คนที่ถูก Bootstrap floor ไว้จะถูกปฏิเสธพร้อมเหตุผล (เพราะ floor จะ re-apply ตอน join รอบหน้าอยู่ดี — แก้ที่ Config).

**Targeting ไม่เดามั่ว:** ชื่อเป้าหมายว่าง/เว้นวรรค → ปฏิเสธ ("No target player specified."), prefix ที่ match หลายคน → ปฏิเสธพร้อมรายชื่อ ("Ambiguous target … matches N players"), DisplayName match เฉพาะ prefix. เมื่อก่อนช่องว่างจะ match ผู้เล่นคนแรกของเซิร์ฟเวอร์ — `/ban` เปล่า ๆ เคยแบนใครก็ไม่รู้.

**`/ban` `/unban` บอกตรง ๆ เมื่อ DataStore fail:** ถ้า persist ไม่สำเร็จ ข้อความจะมี "WARNING: not persisted (session-only)" — แบนจะหายตอนเซิร์ฟเวอร์ปิด. `Ban.Ban`/`Ban.Unban` คืน `persisted: boolean` ให้โค้ดเช็คได้ด้วย.

**`/give` ตรวจของจริง:** count ต้องเป็นจำนวนเต็มบวก (ไม่รับ NaN/inf/เศษส่วน — NaN เคยทะลุไป corrupt profile จน DataStore save ไม่ได้), itemId ที่ไม่อยู่ใน catalog ถูกปฏิเสธ (เฉพาะเกมที่ register `Gaxia.ItemDef` ไว้), และข้อความรายงาน "จำนวนที่ได้จริง" (stack เต็ม → "(requested N, stack clamped)").

**Self-aliases:** ใช้ `me`, `self`, หรือ `.` แทนชื่อตัวเองในทุกคำสั่ง
```
/speed me 200       → set your own speed
/heal .             → heal yourself
/teleport self Bob  → teleport yourself to Bob
```
> ⚠️ Alias เป็น **exact match** (`"me"` เท่านั้น) — ชื่อผู้เล่นที่มี "me" ในชื่อ เช่น "Mehmet" จะไม่โดนแทน

**Chat integration:** ทุกคำสั่งใช้ผ่าน in-game chat ได้ทันที (role-gated อัตโนมัติ) — ผลลัพธ์ตอบกลับใน chat ของคนสั่ง (system message เห็นคนเดียว ผ่าน `Events/Chat/SystemMessage` + module `Gaxia.ChatFeedback`), alias จาก `Config.Admin.Aliases` (`/sp`, `/tp`) ใช้ได้จริง, ใช้ได้ทุก channel (team chat / whisper — เมื่อก่อนพิมพ์ใน team chat คำสั่งไม่ทำงานแถมข้อความดิบหลุดให้เพื่อนร่วมทีมเห็น), และ reason หลายคำไม่ต้องใส่ quote (`/ban Bob exploiting speed hacks` เก็บ reason เต็มประโยค)
```
/speed P_pang001 999      ← พิมพ์ใน chat ได้เลย
/heal me                  ← heal ตัวเอง
```

**Anti-Cheat whitelist:** ทุกครั้งที่ admin run command → ทั้ง caller + target ถูก whitelist จาก anti-cheat ทุกตัว 30 วินาที (flag counts ถูก clear ด้วย) ป้องกัน anti-cheat kick admin หลังสั่ง `/speed`. การ match เป็นแบบ family — entry "HumanoidState" ครอบ "HumanoidState:Climbing" ฯลฯ. ยกเว้น `ClientReport:*` (exploit signature จาก client) ที่จงใจ **ไม่** whitelist — admin command ต้อง mask การตรวจ executor ไม่ได้.

**Auto-grant owner:** game creator (UserId == game.CreatorId) ได้ role "owner" อัตโนมัติทุกครั้งที่ join (เฉพาะ User-owned place)

**ปิดทั้งระบบ:** `Config.Admin.Enabled = false` ปิด admin ทั้งหมด — ไม่ register คำสั่ง, ไม่สร้าง remote `Events/Admin`, ไม่มี chat bridge, ไม่ auto-grant creator, `Admin.Run` ตอบ "Admin system is disabled."

**ตรวจสอบสิทธิ์ใน custom code:**
```lua
if Admin.IsAtLeast(player, "admin") then
    -- allow admin-only feature
end
```

#### Admin Panel (GUI)

GUI แบบ role-gated ที่ครอบ command registry เดิม — ไม่มี command list แยกให้ดูแล. เปิดด้วยปุ่ม 🛡 Admin บน toolbar (โชว์เฉพาะ moderator+) หรือกด **F2**.

- **Players tab** — ผู้เล่นออนไลน์ทุกคนพร้อม role badge; คลิกคนนึงเพื่อดู action ที่ role เราทำได้ (Kick / Ban / Heal / Teleport / …). คำสั่งที่มี arg เดียว (เช่น `/heal <player>`) สั่งได้ทันที; คำสั่งหลาย arg เปิด form โดย lock ช่อง player ไว้ที่เป้าหมาย
- **Commands tab** — คำสั่งที่ *role เรารันได้* (server กรองให้) พร้อม help; คลิกเพื่อได้ form หนึ่งช่องต่อหนึ่ง argument (`player` → dropdown ค้นหาได้, `number`/`string` → text field) แล้วกด Run
  - **`/unban` พิเศษ:** เปิดเป็นรายการ ban ที่ยัง active อยู่ (`ชื่อ (userId) — reason · permanent/เหลือ Xh`) พร้อมปุ่ม Unban ต่อแถว — กดแล้วรายการ refresh ทันที. มีช่องกรอก userId เองด้านล่างสำหรับ record ที่เกิน cap (`Config.Admin.BanListLimit`, default 50). ข้อมูลมาจาก `Gaxia.Ban.ListBans()` (session cache + DataStore `ListKeysAsync`)
- **Audit tab** — feed สดของ 50 คำสั่งล่าสุดทั้ง server (caller, คำสั่ง, args, สำเร็จ/ไม่) — เห็นเฉพาะ moderator+

**Server surface:** `ReplicatedStorage/Events/Admin/Action` (RemoteFunction — envelope `{type="schema"|"players"|"bans"|"run"|"role", …}`; `bans` ต้อง admin+) + `Events/Admin/Inbound` (RemoteEvent — audit broadcast + role hint). Panel เป็น convenience ล้วน: ทุก `run` วิ่งผ่าน `AdminCommands.Run` ที่เช็ค role แบบ authoritative → client ปลอมแปลงไม่ได้. `schema` ถูกกรองตาม role — client ของ moderator ไม่เคยรับรู้ว่ามีคำสั่ง owner-only อยู่.

**Client access:** `Gaxia.UI.AdminPanel.Open() / .Close() / .Toggle()` (toolbar + F2 wire ให้อัตโนมัติตอน client boot)

---

### 8.9 QuestSystem — Quest registry + progress tracking

```lua
local Quest = GaxiaServer.Quest

-- Register quest definition (ทำครั้งเดียวตอนเริ่ม server)
Quest.Register({
    id = "kill_10_zombies",
    name = "Zombie Hunter",
    description = "Kill 10 zombies",
    goals = {
        { type = "kill", target = "Zombie", count = 10 },
    },
    reward = {
        currency = "Coins",
        amount   = 100,
        items    = { HealthPotion = 2 },
    },
})

-- Start quest for player
Quest.Start(player, "kill_10_zombies")

-- Track progress (เรียกตอนเกิด event)
Quest.Track(player, "kill", "Zombie", 1)   -- delta=1 (default)
Quest.Track(player, "collect", "Gold", 5)  -- delta=5

-- Read
local active = Quest.GetActive(player)       -- table { [id] = {progress, started} }
local done   = Quest.IsComplete(player, "kill_10_zombies")
Quest.Abandon(player, "kill_10_zombies")

-- Signals
Quest.OnQuestStart:Connect(function(player, questId) end)
Quest.OnGoalProgress:Connect(function(player, questId, goalKey, current, target) end)
Quest.OnQuestComplete:Connect(function(player, questId, reward)
    -- reward paid automatically via Economy + Item before this fires
end)
```

**Goal types:** `"kill"` · `"collect"` · `"reach"` · `"time_played"`

> Quests persist ใน `Profile.Quests` อัตโนมัติ (DataManager) — completion grants reward ผ่าน EconomyService + ItemService

---

### 8.10 AchievementSystem — Unlock + reward

```lua
local Ach = GaxiaServer.Achievement

-- Register
Ach.Register({
    id = "first_kill",
    name = "First Blood",
    description = "Get your first kill",
    reward = { currency = "Gems", amount = 5 },
    -- Optional auto-unlock condition
    condition = function(player, eventType, ...)
        return eventType == "kill"
    end,
})

-- Award explicitly (idempotent — repeat unlocks no-op)
Ach.Award(player, "first_kill")

-- Or fire-and-forget event → conditions matching auto-unlock
Ach.Track(player, "kill", target, weapon)

-- Read
Ach.IsUnlocked(player, "first_kill")       -- bool
Ach.GetUnlocked(player)                     -- { "id1", "id2", ... }

-- Signal
Ach.OnUnlocked:Connect(function(player, id, def)
    print(`{player.Name} unlocked {def.name}`)
end)
```

> Unlocks persist ใน `Profile.Achievements` (`{ [id] = true }` map)

---

### 8.11 LevelSystem — XP / Level progression

```lua
local Level = GaxiaServer.Level

-- Default curve: floor(100 * level ^ 1.5)
-- Custom curve
Level.SetCurve(function(level: number): number
    return math.floor(50 * level ^ 2)   -- harder progression
end)

-- Award XP (handles multi-level-up loop)
Level.AddXP(player, 250)

-- Read
local lvl    = Level.GetLevel(player)        -- 1..N
local xp     = Level.GetXP(player)           -- current XP toward next level
local toNext = Level.GetXPToNext(player)     -- XP remaining to level up

-- Admin override (resets XP to 0)
Level.SetLevel(player, 50)

-- Signals
Level.OnXPGained:Connect(function(player, amount, newTotal) end)
Level.OnLevelUp:Connect(function(player, newLevel, oldLevel)
    print(`{player.Name} → Lv.{newLevel}`)
end)
```

> Persists ใน `Profile.Level` + `Profile.Experience`

---

### 8.12 DataMigration — Schema versioning

```lua
local Migration = GaxiaServer.Migration

-- ตั้งเลข version ปัจจุบันของ schema เกม
Migration.SetCurrentVersion(3)

-- ลงทะเบียน migration แต่ละ step (v1→v2, v2→v3, ...)
Migration.Register(1, 2, function(data)
    -- เปลี่ยน old field name → new
    data.coins = data.gold
    data.gold = nil
end)

Migration.Register(2, 3, function(data)
    -- เพิ่ม field ใหม่ที่ Reconcile ทำไม่ได้ (computed)
    data.legacyBonus = (data.coins or 0) * 0.1
end)

-- เรียกหลัง ProfileService Reconcile (ใน DataManager.OnLoaded)
GaxiaServer.Data.OnLoaded:Connect(function(player, data)
    Migration.Migrate(data)
end)

-- Read
Migration.GetCurrentVersion()    -- 3

-- Signal — fired ทุกครั้งที่ profile migrate สำเร็จ
Migration.OnMigrated:Connect(function(player, startVersion, endVersion) end)
```

**กลไก:**
- Profile ใส่ `__version` field เก็บ schema version
- `Migrate(data)` วน chain ทีละ step จนถึง currentVersion
- Step ที่ throw → log warn + หยุด chain (ของเก่าไม่หาย)

---

### 8.13 LeaderboardService — Global Top-N (OrderedDataStore)

```lua
local LB = GaxiaServer.Leaderboard

-- Update score
LB.Update("WeeklyCoins", player.UserId, 1500)

-- Get top N (cache 60s — ปลอดภัยกับ DataStore quota)
local top = LB.GetTop("WeeklyCoins", 100)
for _, entry in ipairs(top) do
    -- entry = { userId, name, value, rank }
    print(`#{entry.rank} {entry.name} — {entry.value}`)
end

-- Get rank ของผู้เล่น (scan top-100; nil ถ้าไม่ติด top)
local rank = LB.GetRank("WeeklyCoins", player.UserId)

-- Raw store access
local store = LB.GetStore("WeeklyCoins")  -- OrderedDataStore

-- Signal
LB.OnUpdate:Connect(function(name, userId, value) end)
```

**กลไก:**
- Cache top-N 60 วินาที — invalidate เมื่อ `Update()`
- Username resolution ผ่าน `UserService:GetUserInfosByUserIdsAsync` (best-effort)

---

### 8.14 CrossServerMessaging — MessagingService wrapper

```lua
local Msg = GaxiaServer.Messages

-- Subscribe ทำตอน server start
local conn = Msg.Subscribe("GlobalChat", function(data, sentTimestamp)
    print(`[Global] {data.player}: {data.text}  (sent {sentTimestamp})`)
end)

-- Publish — token-bucket rate limited (2/sec sustained, burst 10)
Msg.Publish("GlobalChat", {
    player = player.Name,
    text = "Hello world!",
})

-- รองรับ primitive ด้วย (string/number/boolean) — auto-wrapped/unwrapped
Msg.Publish("ServerCount", 42)

-- Error signal (failures ไม่ throw)
Msg.OnError:Connect(function(topic, message)
    warn(`[CSM] {topic}: {message}`)
end)

-- เลิก subscribe
conn:Disconnect()
```

**ขีดจำกัด:**
- MessagingService cap ~150 msg/min/server → token bucket จำกัด 2/sec
- Burst 10 messages (refill 2/sec)
- Rate-limited publish → drop + fire OnError (ไม่ throw)
- JSON encode/decode อัตโนมัติ

---

### 8.15 WebhookService — Discord / outbound webhooks

ส่ง webhook ออกนอก (Discord เป็นหลัก แต่ส่ง JSON ไป URL ไหนก็ได้). มี queue ต่อ channel + retry เมื่อโดน rate-limit (HTTP 429) — report ไม่หาย ไม่บล็อกเกม. **Server-only**: URL เป็น secret อยู่ใน `Config.Webhook.Channels` (ไม่ replicate) — **ห้ามเรียกผ่าน RemoteEvent จาก client** (client ยิง webhook มั่ว = abuse).

> ต้องเปิด **Game Settings → Security → Allow HTTP Requests** ก่อน ไม่งั้น webhook ปิดเงียบ (warn ครั้งเดียว).

**Config** (`Config.Webhook` — server-private):
```lua
Webhook = {
    Enabled = true,
    Channels = {                                              -- ชื่อ channel → URL (secret)
        BanReports = "https://discord.com/api/webhooks/...",
        ShopStock  = "https://discord.com/api/webhooks/...",
    },
    AutoReport = { Bans = "BanReports", AntiCheat = "BanReports" }, -- channel name หรือ nil
    RateLimit  = { MinInterval = 2, MaxQueue = 100, MaxRetries = 3 },
    Username   = "Gaxia",
}
```

```lua
local WH = GaxiaServer.Webhook

-- Discord embed (สร้าง JSON ให้อัตโนมัติ)
WH.Discord("BanReports", {
    title = "🔨 Player Banned",
    description = "P_pang001 ถูกแบน",
    color = Color3.fromRGB(231, 76, 60),                       -- หรือเลข decimal
    fields = {
        { name = "UserId", value = 12345, inline = true },
        { name = "Reason", value = "Exploiting" },
    },
})

WH.Send("ShopStock", { content = "Stock updated: Apple x20" }) -- raw JSON → channel ที่ตั้งไว้
WH.SendUrl("https://discord.com/api/webhooks/...", { content = "hi" }) -- ad-hoc URL ตรงๆ

if WH.IsConfigured("BanReports") then end                     -- เช็คก่อนส่ง

WH.OnSend:Connect(function(channel, ok) end)                  -- observability
WH.OnError:Connect(function(channel, reason) warn(reason) end)
```

**Auto-report (zero-wiring):** ตั้ง `AutoReport.Bans` / `AutoReport.AntiCheat` ให้ชี้ channel ที่มี URL → ส่ง report อัตโนมัติเมื่อ `Ban.OnBan`/`Ban.OnUnban` ยิง และเมื่อ AntiCheat ทำ **hard action**. ถ้า channel ที่ชี้ไม่มี URL → เงียบ (ไม่ subscribe). WebhookService ถูก eager-load ตอน boot เพื่อให้ auto-report ทำงานทันที.

**Use case — shop stock (manual):**
```lua
-- เรียกในโค้ดเกมตอน stock เปลี่ยน
GaxiaServer.Webhook.Discord("ShopStock", {
    title = "Stock updated",
    fields = {
        { name = "Apple", value = 20, inline = true },
        { name = "Sword", value = 3,  inline = true },
    },
})
```

**กลไก:**
- Queue ต่อ channel (FIFO) + drain coroutine เดียว, เว้น `MinInterval` วินาทีระหว่างส่ง
- 429 → รอ `Retry-After` แล้ว retry (≤ `MaxRetries`); transient → backoff; เกิน → drop + OnError + warn
- Queue เต็ม (`MaxQueue`) → drop เก่าสุด · async ทั้งหมด (task.spawn) ไม่บล็อกเกม
- ค่าใน `RateLimit`/`Enabled`/`Username` override runtime ได้ผ่าน `/flag set Webhook.<Key>` (EConfig)
- เทส: `WH.SetTransport(fn)` แทนตัวส่ง HTTP จริง (จับ payload โดยไม่ยิงเน็ต)

---

### 8.16 Ban — Persistent bans + auto-escalation จาก AntiCheat

```lua
local Ban = GaxiaServer.Ban

Ban.Ban(player.UserId, "Exploiting", 3600)        -- 1 ชม. (nil = permanent)
local banned, reason, expiresAt = Ban.IsBanned(player.UserId)
Ban.Unban(userId)
Ban.OnBan:Connect(function(userId, ban) end)      -- ban = { reason, expiresAt, time }
Ban.OnUnban:Connect(function(userId) end)
```

**กลไก:**
- บันทึกลง DataStore (`Config.Admin.Stores.Bans`, fallback `"GaxiaBans"`) + session cache — Studio ไม่มี real DataStore ก็ทำงานได้ (in-memory)
- `PlayerAdded` gate — kick อัตโนมัติทันทีที่ player เข้า ถ้ายังแบนอยู่
- Auto-escalation: subscribe `AntiCheat.OnAction` (hard) → นับ strikes → kick → temp-ban → perm-ban ตาม `Config.AntiCheat.BanPolicy`

**Role ระดับสูงโดน auto-ban / auto-kick ไม่ได้:**
- Escalation **ข้าม** place creator (เช็ค `game.CreatorId` แบบ sync — ไม่รอ role โหลด) และทุกคนที่ role ≥ `Config.AntiCheat.BanPolicy.ExemptRole` (default `"admin"`) — ได้แค่ warn ลง console ว่า "would have acted on: …" ตั้ง `ExemptRole = false` ถ้าจะเหลือแค่ creator; ตั้ง `"moderator"` ได้แต่จะเสีย auto-ban deterrent กับ staff tier ล่างสุด
- Kick อัตโนมัติใน `Gaxia_ServerBootstrap` (default OnAction handler) เช็ค `Ban.IsEscalationExempt(userId)` ตัวเดียวกัน — exempt = ไม่โดนทั้ง ban ทั้ง kick
- ⚠️ ข้อจำกัด: role ที่ได้จาก `/role` (DataStore) โหลด async ตอนเข้าเกม — hard-flag รัวภายในวินาทีแรก ๆ อาจ strike admin ที่ role ยังโหลดไม่เสร็จ (creator กับ role จาก `Config.Admin.Bootstrap` ปลอดภัยเพราะเช็ค/seed แบบ sync)
- `PlayerAdded` gate **self-heal**: ถ้า creator มี ban record ค้าง (เช่น auto-ban ที่เกิดก่อนมี exemption) ระบบจะลบ record + warn แทนการ kick — เจ้าของเกมล็อกตัวเองออกจากเกมไม่ได้อีก (เฉพาะ creator: staff tier ต่ำกว่ายังโดนแบนโดย admin ได้จริง gate จึงต้องเตะตามปกติ)
- เส้นทาง manual (`/ban`, `/acban`) ใช้ `protectTarget` เหมือนเดิม: ห้าม self / ห้าม creator / ห้าม rank เท่ากันหรือสูงกว่า — admin ยังตั้งใจแบน moderator ที่ rank ต่ำกว่าได้
- `Gaxia.Ban.Ban(userId, …)` ตรง ๆ จากโค้ดเกม **ไม่** ผ่าน exemption — เป็น API ระดับล่างที่นักพัฒนาเรียกเอง (เช็คเองได้ด้วย `Ban.IsEscalationExempt(userId)`)

---

### 8.17 Analytics — Typed event funnel พร้อม pluggable sink

```lua
local Analytics = GaxiaServer.Analytics

Analytics.SetSink(function(player, event, props)
    MyBackend.log(player.UserId, event, props)
end)
Analytics.Track(player, "tutorial_step", { step = 3 })
Analytics.OnEvent:Connect(function(player, event, props) end)
```

**กลไก:**
- Default sink = `print` — ไม่ต้อง config อะไรเพื่อ debug
- Auto-subscribe สาม signal ของ framework: `Economy.OnTransaction` → `currency_change`, `Level.OnLevelUp` → `level_up`, `Quest.OnQuestComplete` → `quest_complete` (zero wiring)
- sink error ไม่ throw — warn + ทำงานต่อ

---

### 8.18 Journal — AntiCheat audit log (ring buffer + pluggable sink)

```lua
local Journal = GaxiaServer.Journal

Journal.SetSink(function(entry) postToDiscord(entry) end)

for _, e in ipairs(Journal.GetForPlayer(player)) do
    print(`{e.reason} ({e.severity})`)
end

local recent = Journal.GetRecent(50)
Journal.Clear()                        -- reset buffer (สำหรับ test)
```

**กลไก:**
- Subscribe `AntiCheat.OnFlag` + `AntiCheat.OnAction` อัตโนมัติ (deferred)
- Ring buffer 250 entries ใน memory + per-player history table
- Default sink = `warn` — entry ไม่หายแม้ sink error

---

### 8.19 AntiCheatAdmin — Chat commands สำหรับ moderator/admin

```lua
local _ = GaxiaServer.AntiCheatAdmin    -- touch ตอน boot — register ให้อัตโนมัติ
GaxiaServer.AntiCheatAdmin.Register()   -- หรือ explicit (idempotent)
```

คำสั่ง chat ที่ถูก register (ผ่าน `AdminCommands`, role-gated):

| คำสั่ง | Role | ทำอะไร |
|---|---|---|
| `/acflags <player>` | moderator | ดู flags ของ player |
| `/acclear <player>` | admin | ล้าง flags |
| `/acban <player> <reason> [secs]` | admin | แบน (temp หรือ perm) |
| `/acunban <userId>` | admin | ยกแบน |
| `/ac <on\|off\|status\|reset> [Detector]` | admin | toggle AntiCheat / detector |
| `/flag <set\|get\|clear> <key> [value]` | admin | runtime flag override (EConfig) |

**กลไก:**
- ทุก write action บันทึก audit trail (server log + `Analytics.Track("admin_config", …)`)
- `Register()` idempotent — call ซ้ำกี่ครั้งก็ได้; warn ถ้า `AdminCommands` ไม่พร้อม
- `/acban` ใช้ guard ชุดเดียวกับ `/ban` (`AdminCommands.ProtectTarget`): ห้าม self / creator / rank เท่ากันหรือสูงกว่า — ถ้า guard หายไป (Lib คนละเวอร์ชัน) คำสั่ง **ปฏิเสธ** (fail closed)
- resolver ชื่อผู้เล่นใช้กติกาเดียวกับ `/ban`: ปฏิเสธช่องว่าง/ชื่อกำกวม, exact match ชนะ prefix; `[seconds]` ของ `/acban` กัน NaN/ติดลบ/inf; ผลลัพธ์แจ้ง WARNING เมื่อ DataStore write ไม่สำเร็จ (session-only)

---

### 8.20 Protection — Time-boxed immunity shield (PvP / Raid gate)

```lua
local Prot = GaxiaServer.Protection

local untilTs = Prot.Grant(player, 600)    -- shield 10 นาที (คืน timestamp)

if Prot.IsProtected(target) then return "shielded" end   -- RaidService / PvP gate

local secs = Prot.GetRemaining(player)
Prot.Clear(player)                          -- ยกเลิก shield ก่อนหมดอายุ
```

**กลไก:**
- เก็บ `ProtectedUntil` (os.time timestamp) ใน player profile ผ่าน `DataService` — รอด rejoin + เช็ค offline ได้
- Expiry check แบบ lazy — ไม่มี timer loop; ตรวจเมื่อ `IsProtected()` ถูกเรียก
- `OnProtected` / `OnExpired` signals สำหรับ UI badge หรือ webhook

---

### 8.21 Lifecycle — Two-phase boot (Init → Start) สำหรับ services ที่ต้องการ ordering

```lua
local LC = GaxiaServer.Lifecycle

LC.RegisterMany({ require(DataSvc), require(EconomySvc), require(ShopSvc) })  -- dep order
LC.Start()    -- Phase 1: Init() ทุก service → Phase 2: Start() ทุก service
LC.OnStarted(function() print("all services up") end)
local ready = LC.IsStarted()
```

**กลไก:**
- `Start()` เรียก `Init()` ทุก service ก่อน แล้วค่อยเรียก `Start()` — รับประกันว่า service B ใช้ service A ใน `Start()` ได้อย่างปลอดภัย
- pcall-isolated — service เดียวพัง ไม่ abort ที่เหลือ; warn ระบุชื่อ
- Idempotent — `Start()` call ซ้ำ = no-op; `Register()` หลัง `Start()` = warn + ignored
- Services ที่ self-initialise อยู่แล้วไม่ต้อง migrate — additive only

---

### 8.22 Vault — Capacity-bounded "bank" storage แยกจาก carry inventory

**Config** (`Config.Vault` — server-private):
```lua
Vault = {
    DefaultCapacity  = 100,     -- slots เริ่มต้นต่อผู้เล่น
    MaxCapacity      = 10000000,
    DefaultItemValue = 1,       -- คะแนน GetValue ถ้าไม่ได้ SetItemValue
}
```

```lua
local Vault = GaxiaServer.Vault

Vault.SetItemValue("Diamond", 100)
local ok, err = Vault.Deposit(player, "Diamond", 3)
local ok2, err2 = Vault.Withdraw(player, "Diamond", 1)
local value = Vault.GetValue(player)        -- sum(count × itemValue) — heist loot-cap
Vault.AddCapacity(player, 50)
```

**กลไก:**
- Deposit/Withdraw เป็น atomic — `Item.Remove` ก่อน แล้วค่อย write vault; ถ้า credit ล้มเหลวจะ refund
- `GetValue` รวม `count × perItemValue` — ใช้เป็น leaderboard score หรือ heist loot-cap
- Capacity persisted แยกใน `"VaultCapacity"` — upgrade ไม่หาย reload
- Override runtime ได้ผ่าน EConfig (`/flag set Vault.DefaultCapacity`)

---

### 8.23 Shop — Server-authoritative soft-currency / Robux catalog

```lua
local Shop = GaxiaServer.Shop

Shop.RegisterItem("SpeedBoost", {
    cost = 250, currency = "Coins", levelReq = 3,
    grant = function(p) applyBoost(p) end,
})
local ok, reason = Shop.Purchase(player, "SpeedBoost")
-- reason ∈ unknown_item / requires_gamepass / level_too_low /
--           prompted_robux / insufficient_funds / grant_failed
local catalog = Shop.GetCatalog()
```

**กลไก:**
- `Purchase` validate ทุก gate server-side (gamepass, level, funds) ก่อน debit — ไม่เชื่อ client
- Robux item (`devProductId`) → `Monetization.PromptProduct`; grant จริงอยู่ใน `RegisterProduct`
- Economy.Spend atomic — refund อัตโนมัติถ้า `grant` throw

---

### 8.24 Monetization — GamePass + Developer Product with idempotent ProcessReceipt

```lua
local Mon = GaxiaServer.Monetization

Mon.RegisterProduct(123456, function(player, receipt)
    GaxiaServer.Economy.Add(player, "Gems", 100)
end)
Mon.PromptProduct(player, 123456)
if Mon.OwnsGamePass(player, 9999) then end
Mon.OnPurchase:Connect(function(player, productId, receipt) end)
```

**กลไก:**
- `HandleReceipt` ตรวจ `ProcessedReceipts` ใน profile ก่อน — ถ้าเคย grant แล้วคืน `PurchaseGranted` ทันที (ไม่ double-grant)
- PurchaseId persist + `Data.Save` nudge ก่อน return — crash ก็ไม่หาย
- `OwnsGamePass` cache per-player (weak table) — ไม่ yield ซ้ำบน server loop
- `MarketplaceService.ProcessReceipt` ผูกตอน module load → ต้อง touch `Gaxia.Monetization` ตอน boot

---

### 8.25 Trade — Two-party atomic item+currency swap กัน dupe-proof

```lua
local Trade = GaxiaServer.Trade

local id = Trade.Request(playerA, playerB)
Trade.AddItem(playerA, id, "Sword", 1)
Trade.AddCurrency(playerB, id, "Coins", 500)
Trade.Confirm(playerA, id)
local ok, executed, msg = Trade.Confirm(playerB, id) -- executed=true → swap ทำงาน
Trade.Cancel(playerA, id)
Trade.OnComplete:Connect(function(tradeId, success) end)
```

**กลไก:**
- ทุก `AddItem`/`AddCurrency` reset confirm ทั้งสองฝั่ง — แก้ offer หลัง partner lock ไม่ได้
- Swap: re-validate ownership → debit A+B → credit B+A ใน pass เดียว ไม่ yield
- ถ้า debit หรือ credit ขั้นใดล้มเหลว → refund ทั้งหมด (rollback สมบูรณ์)
- ผู้เล่นละ 1 trade session เท่านั้น (`playerTrade` guard)

---

### 8.26 Inventory — Instance-based RPG inventory พร้อม equip slots

```lua
local Inv = GaxiaServer.Inventory

Inv.DefineItem("Sword", { EquipSlot = "Weapon" })
Inv.DefineItem("Potion", { Stackable = true, MaxStack = 99 })

local uid = Inv.Add(player, "Sword", { Props = { atk = 12 } })  -- mint UID
Inv.Equip(player, uid)
local inst = Inv.GetEquipped(player, "Weapon")     -- { id, itemId, count, props }
Inv.Remove(player, uid)                            -- auto-unequip ก่อน remove
```

**กลไก:**
- Non-stackable → mint UID `i_N` ต่อชิ้น (rolled stats ต่างกันได้); stackable → stack เดียว `s_{itemId}`
- Equip ผูก UID กับ slot — replace ของเดิม (ของเดิมยังอยู่ใน bag)
- `Remove` auto-unequip + fire `OnEquip(player, slot, nil)` ให้ client sync
- Persisted ใน key `"Inv"` (seq + items + equipped รวม blob เดียว)

---

### 8.27 Loot — Weighted drop table พร้อม persisted pity guarantee

```lua
local Loot = GaxiaServer.Loot

Loot.DefineTable("Chest", {
    { Item = "Common", Weight = 80 },
    { Item = "Epic",   Weight = 1, Pity = 50 },   -- guarantee ภายใน 50 rolls
})
local drop = Loot.Roll(player, "Chest")           -- { Item, viaPity }
local rates = Loot.GetDropRates("Chest")          -- { Common=0.988, Epic=0.012 }
local misses = Loot.GetPity(player, "Chest", "Epic")
```

**กลไก:**
- Miss counter persist ใน profile (`"LootPity"`) — ไม่ reset เมื่อ rejoin
- ถ้า counter ≥ `Pity` → forced drop; reset counter เฉพาะ item นั้น
- `PickWeighted` pure function (seed-testable) — แยกออกจาก RNG state
- Roll ทุกครั้ง fire `Codex.Discover` อัตโนมัติ (collection log sync)

---

### 8.28 ItemDef — Central item definition registry (single source of truth)

```lua
local ItemDef = GaxiaServer.ItemDef

ItemDef.RegisterMany({
    Sprout = { rarity = "common", category = "Seed", sellPrice = 5, stackable = true },
    Sword  = { rarity = "rare",   category = "Weapon", footprint = Vector2.new(1,1) },
})
local def   = ItemDef.Get("Sprout")
local price = ItemDef.GetField("Sprout", "sellPrice", 0)
local seeds = ItemDef.GetByCategory("Seed")
```

**กลไก:**
- Pure registry — ไม่มี runtime state, ไม่มี external dependency
- `Register` เก็บ defensive copy — caller แก้ table หลัง register ไม่กระทบ
- `GetField(id, field, default)` safe read — ไม่ต้อง nil-check ทุกจุด
- ใช้เป็น single source of truth สำหรับ Vault, Loot, Refine, Placement — ไม่ drift แยก

---

### 8.29 Idle — Passive / offline earnings สำหรับ idle & tycoon games

**Config** (`Config.Idle` — server-private):
```lua
Idle = {
    DefaultRate   = 1,      -- currency units per second (ถ้าไม่ Configure() เอง)
    MaxOffline    = 28800,  -- cap elapsed ไม่เกิน 8 ชั่วโมง
}
```

```lua
local Idle = GaxiaServer.Idle

Idle.Configure(player, { Rate = 5, Currency = "Coins", Cap = 50000 })

local earned, secs = Idle.Collect(player)         -- เก็บ earnings
local pending, _   = Idle.GetPending(player)      -- preview ไม่ consume
Idle.OnOfflineEarnings:Connect(function(p, amt, elapsed) end)
```

**กลไก:**
- `Collect()` คำนวณ `elapsed = now − lastSeen` แล้ว clamp ด้วย `MaxOffline` — คนหายไปเดือนก็ได้แค่ 8 ชม.
- Payout = `floor(Rate × elapsed)` อีก clamp ด้วย `Cap` — ป้องกัน economy ระเบิด
- ถ้า `Currency == "Coins"` payout จะคูณ **pet multiplier** (`Pet.GetCoinMultiplier`) แล้ว re-clamp ด้วย `Cap` อีกที — pet ช่วยให้ถึง cap **เร็วขึ้น** ไม่ทะลุ cap (best-effort: ไม่มี Pet service → ×1.0). Quest reward ที่จ่าย `"Coins"` ก็คูณเช่นกัน; **Raid loot ไม่คูณ** (zero-sum transfer)
- `lastSeen` เซฟใน profile ผ่าน `Data.Set` → รอดระหว่าง rejoin
- `Currency` ตั้งใน `Configure()` → `Economy.Add` อัตโนมัติ; ถ้าไม่ตั้ง — เกมรับ `OnOfflineEarnings` แล้วจัดเอง
- ค่าที่ `Economy.Add` / `OnOfflineEarnings:Fire` / `Collect` return = ยอด **หลังคูณ pet** (post-multiplier) — UI โชว์ยอดจริงที่ได้

---

### 8.30 DailyReward — Login-streak daily rewards — retention hook ราคาถูกสุด

**Config** (`Config.Daily` — server-private):
```lua
Daily = {
    DaySeconds  = 86400,   -- ความยาว "หนึ่งวัน" (ปรับสำหรับ dev/test ได้)
    ResetWindow = 172800,  -- เกิน 2 วันไม่ claim → streak reset
}
```

```lua
local DR = GaxiaServer.DailyReward

DR.DefineLadder({ {Coins=100}, {Coins=250}, {Gems=5} }, { Cycle = true })

local result, err = DR.Claim(player)  -- {day, streak, reward} หรือ nil + reason
if result then Economy.Add(player, "Coins", result.reward.Coins or 0) end

local secs = DR.GetTimeUntilNext(player)
DR.OnClaim:Connect(function(p, res) end)
```

**กลไก:**
- `Claim()` gate ด้วย `lastClaim + DaySeconds` — เรียกซ้ำใน session เดียวไม่ผ่าน
- Streak เพิ่มถ้า claim อยู่ใน window 24–48 ชม.; เกิน `ResetWindow` → กลับ 1
- Ladder cycling (`Cycle = true`) → วนซ้ำหลังครบ; `false` → cap ที่ index สุดท้าย
- State (`lastClaim`, `streak`) เซฟใน profile — farm ด้วย rejoin ไม่ได้

---

### 8.31 Mail — Persistent player inbox พร้อม claimable reward attachments

**Config** (`Config.Mail` — server-private):
```lua
Mail = {
    MaxMail = 50,  -- จำนวน mail สูงสุดใน inbox (overflow → ลบเก่าสุด)
}
```

```lua
local Mail = GaxiaServer.Mail

local id = Mail.Send(player, {
    Subject = "ขอโทษ downtime!",
    Body    = "ชดเชย 500 gems",
    Attachments = { Gems = 500 },
    ExpiresAt = os.time() + 86400 * 7,  -- หมดอายุ 7 วัน
})

local att, err = Mail.Claim(player, mailId)   -- claim ได้ครั้งเดียว
if att then Economy.Add(player, "Gems", att.Gems) end

local inbox = Mail.GetMailbox(player)         -- { Mail } เรียงใหม่ก่อน ไม่รวม expired
Mail.OnReceive:Connect(function(p, mail) end)
```

**กลไก:**
- Mail เก็บใน profile (`Mailbox` key) → รอได้แม้ผู้เล่น offline
- `Claim()` mark `claimed = true` แล้วคืน attachments — double-claim ไม่ผ่าน
- Expired mail ถูก filter ออกใน `GetMailbox()` โดยอัตโนมัติ
- Inbox เกิน `MaxMail` → trim oldest (`sentAt` น้อยสุด) ออกก่อน

---

### 8.32 Raid — Raid / heist state machine — highest-exploit-surface system

**Config** (`Config.Raid` — server-private):
```lua
Raid = {
    Currency          = "Coins",
    Cooldown          = 300,    -- วินาทีก่อน attacker raid ได้อีก
    RevengeProtection = 600,    -- shield ที่ defender ได้หลังถูก raid
    LootFraction      = 0.1,    -- สัดส่วน vault value ที่ขโมยได้
    MaxLoot           = 1000000,
}
```

```lua
local Raid = GaxiaServer.Raid

local raidId, err = Raid.Start(attacker, defender)
-- … minigame / countdown …
local ok, summary = Raid.Resolve(raidId, true)  -- true = attacker wins

local targets = Raid.GetRevengeTargets(player)  -- { userId } เรียงล่าสุดก่อน
Raid.OnRaidEnd:Connect(function(att, def, success, loot) end)
```

**กลไก:**
- `Start()` ตรวจ: ไม่ raid ตัวเอง / defender ต้องไม่มี Protection / attacker ต้องไม่ติด Cooldown / ทั้งคู่ต้องว่างจาก raid อื่น
- `Resolve()` ย้าย loot แบบ atomic — `Spend(defender)` ก่อน; ถ้า `Add(attacker)` ล้มเหลว → refund ทันที ไม่มี dupe/loss
- Defender ได้ revenge shield (`Protection.Grant`); attacker ติด cooldown (`Cooldown.Start`) อัตโนมัติหลัง resolve
- Revenge list (max 20) persist ใน profile ของ defender

---

### 8.33 Party — Grouping + matchmaking สำหรับ co-op / lobby flows

**Config** (`Config.Party` — server-private):
```lua
Party = {
    MaxSize       = 4,    -- จำนวน member สูงสุดต่อ party
    PoolTTL       = 120,  -- วินาทีที่ entry อยู่ใน matchmaking pool
    PoolScanLimit = 50,   -- จำนวน entry สูงสุดที่ PollMatch scan ต่อครั้ง
}
```

```lua
local Party = GaxiaServer.Party

local pid = Party.Create(leader)
Party.Join(p2, pid)
Party.QueueForMatch(pid, "Duel", placeId)

local match = Party.PollMatch("Duel", 2)
if match then Party.StartMatch(pid, placeId) end
```

**กลไก:**
- Party state อยู่ใน memory; leader ออก → promote `members[1]` อัตโนมัติ
- Matchmaking pool เก็บใน `Gaxia.Memory` (cross-server sorted map) — FIFO ตาม enqueue time
- `PollMatch()` pull oldest จนครบ `neededPlayers` แล้ว remove ออกจาก pool + `Teleport.ReserveServer`
- `StartMatch()` teleport members จริงด้วย `Teleport.ToPrivate` พร้อม `partyId` ใน join data

---

### 8.34 Event — Seasonal / timed live-ops windows — one clock สำหรับทุก event

**Config** (`Config.Event` — server-private):
```lua
Event = {
    TickInterval = 5,  -- วินาทีระหว่าง poll transition (override runtime ได้ทันที)
}
```

```lua
local Ev = GaxiaServer.Event

Ev.Define("DoubleXP", {
    StartsAt = 1750000000,
    EndsAt   = 1750086400,
    Data     = { mult = 2 },
})

if Ev.IsActive("DoubleXP") then xp = xp * Ev.GetData("DoubleXP").mult end

local secs = Ev.GetTimeRemaining("DoubleXP")
Ev.OnEventStart:Connect(function(id, data) end)
Ev.OnEventEnd:Connect(function(id, data) end)
```

**กลไก:**
- Background ticker (`task.spawn` loop) เรียก `PollTransitions()` ทุก `TickInterval` วินาที — fire `OnEventStart`/`OnEventEnd` ครั้งเดียวต่อ transition
- `IsActive()` ใช้ absolute `os.time()` → ตรงกันทุก server โดยไม่ต้องซิงค์
- `GetActive()` คืน array ของ event ที่กำลัง on อยู่ ณ ปัจจุบัน (เรียงชื่อ)
- `TickInterval` อ่านใหม่ทุก loop — Flag override มีผลทันทีโดยไม่ต้อง restart

---

### 8.35 Visit — Read-only base/island visiting พร้อม write-guard

```lua
local Visit = GaxiaServer.Visit

Visit.Start(visitor, hostUserId)    -- เริ่ม visit (คืน false ถ้า visit ตัวเอง)
Visit.End(visitor)                  -- กลับบ้าน

-- write-guard — ทุก build / economy action ต้องผ่านนี้ก่อน
if not Visit.CanModify(player, baseOwnerUserId) then return end

local visitors = Visit.GetVisitorsOf(hostUserId)  -- { userId }
Visit.OnVisitStart:Connect(function(p, hostId) end)
```

**กลไก:**
- State เป็น in-memory (`visitorUserId → hostUserId`) — reset อัตโนมัติเมื่อ `PlayerRemoving`
- `CanModify(player, owner)` คืน `true` ก็ต่อเมื่อ: ไม่ได้กำลัง visit ใคร **และ** `owner == player.UserId`
- Visiting ตัวเองถูก block ใน `Start()` — "อยู่บ้าน" ไม่นับเป็น visit

---

### 8.36 Codex — Collection / Pokédex registry สำหรับ collect-em-all genre

```lua
local Codex = GaxiaServer.Codex

Codex.RegisterMany({ Goldfish = { Rarity = "Common", Set = "Pond" }, Koi = { Rarity = "Rare", Set = "Pond" } })
Codex.DefineSet("Pond", { "Goldfish", "Koi" }, { Coins = 500 })

local r = Codex.Discover(player, "Goldfish")   -- { isNew, count }
local pct = Codex.GetCompletion(player)        -- 0..1
Codex.OnSetComplete:Connect(function(p, setName, reward) end)
```

**กลไก:**
- Catalog เป็น global (register ตอน boot); per-player data persist ใต้ profile key `"Codex"`
- `Discover()` auto-register entry ที่ไม่รู้จัก — drops ไม่ drop; ถ้า entry ใหม่ จะ trigger `checkSets` ทันที
- `OnSetComplete` ยิงครั้งเดียวต่อ set ต่อ player (guard ด้วย `__sets` sub-table)

---

### 8.37 Refine — Crafting / transmuting engine แบบ atomic

```lua
local Refine = GaxiaServer.Refine

Refine.DefineRecipe("Bronze", { Inputs = { Copper = 1, Tin = 1 }, Outputs = { Bronze = 1 } })
Refine.DefineRecipe("Steel",  { Inputs = { Iron = 2 }, Outputs = { Steel = 1 }, Duration = 30, RequiresLevel = 5 })

local ok, err = Refine.Craft(player, "Bronze")          -- instant
local jobId   = Refine.Begin(player, "Steel")           -- timed — consume now
local done    = Refine.IsReady(player, jobId)
Refine.Claim(player, jobId)                             -- grant outputs
```

**กลไก:**
- `Craft()` — instant recipes เท่านั้น; timed recipes บังคับ `Begin/Claim`
- Inputs ตรวจสอบและหักล้าง atomic: ถ้า consume บางส่วนแล้วล้มเหลว จะ refund ทั้งหมด ไม่มีทาง half-apply
- Timer ใช้ `os.time()` — นับต่อแม้ player offline; jobs persist ใต้ profile key `"RefineJobs"`
- `RequiresLevel` gate ผ่าน `GaxiaServer.Level` — ถ้าไม่มี LevelSystem → ผ่านเสมอ

---

### 8.38 Placement — Grid-based building placement (tycoon / base-builder / farm)

```lua
local Placement = GaxiaServer.Placement

Placement.DefineObject("House", { Footprint = Vector2.new(2, 2) })
Placement.AssignPlot(player, { Origin = Vector3.new(0,0,0), Cells = Vector2.new(8,8), CellSize = 4 })

local id, err = Placement.Place(player, "House", 0, 0)  -- gx=0, gz=0
Placement.OnPlace:Connect(function(p, placement) spawnModel(placement) end)
Placement.Rebuild(player)   -- replay saves on join → re-fires OnPlace ทุก entry
```

**กลไก:**
- Server-authoritative: `Place()` validate in-bounds + no overlap ก่อนบันทึก — client ไม่สามารถ stack หรือวางนอก plot
- Framework เก็บ **data** เท่านั้น; game เป็นคนจัดการ spawn model ผ่าน `OnPlace`/`OnRemove`
- Footprint หมุน 90°/270° ได้ (width/depth swap) — ส่ง `rot` เป็น parameter
- `SnapToGrid` / `WorldToCell` / `CellToWorld` เป็น pure helpers สำหรับ client preview ไม่ยุ่ง data

---

### 8.39 Teleport — Hardened TeleportAsync wrapper พร้อม retry

**Config** (`Config.Teleport.Retry`):
```lua
Teleport = {
    Retry = { MaxAttempts = 4, BaseDelay = 1, MaxDelay = 15 },
}
```

```lua
local TP = GaxiaServer.Teleport

TP.To(player, 123456, { Data = { fromLobby = true } })     -- ส่ง player (หรือ list)

local code = TP.ReserveServer(123456)                       -- Reserved server flow
TP.ToPrivate({ p1, p2 }, 123456, code)

local data = TP.GetArrivingData(player)                     -- ฝั่งรับ
TP.OnTeleportFailed:Connect(function(players, placeId, err) end)
```

**กลไก:**
- Retry exponential backoff ≤ `MaxAttempts`; ล้มเหลวทุก attempt → fire `OnTeleportFailed` (ไม่ throw)
- `pcall`-guarded ทุก call → return `(false, err)` ใน Studio แทน error
- Dependency ของ PartyService (§8.33)

---

### 8.40 Cooldown — Server-authoritative cooldown / debounce primitive

```lua
local CD = GaxiaServer.Cooldown

-- Per-player: atomic gate + arm ในคำสั่งเดียว — anti-spam
if CD.ConsumePlayer(player, "DailyReward", 86400) then grantDaily(player) end

-- Cross-player (global boss spawn)
CD.Start("GlobalBoss", 300)
local secs = CD.GetRemaining("GlobalBoss")

CD.IsPlayerActive(player, "Attack")  -- เช็คโดยไม่ arm
```

**กลไก:**
- `Consume()` / `ConsumePlayer()` — atomic: check + arm ใน single call ไม่มี TOCTOU window สำหรับ spam exploit
- Key ต่อ player ใช้ `"P:{userId}:{action}"` — cooldown แยกอิสระต่อคน
- Player leave → sweep per-player keys ทันที; background sweep ทุก `SweepInterval` วินาที ล้าง expired keys
- Cross-player cooldown ใช้ bare string key (ไม่มี player prefix)

---

### 8.41 Interaction — ProximityPrompt wrapper สำหรับ "press E to X"

**Config** (`Config.Interaction`):
```lua
Interaction = {
    DefaultMaxDistance = 10,  -- studs; override ต่อ prompt ได้
}
```

```lua
local Int = GaxiaServer.Interaction

local handle = Int.Register(stationModel, {
    ActionText = "Refine", ObjectText = "Sunwell",
    HoldDuration = 0.5, MaxDistance = 8, Cooldown = 1,
    OnTrigger = function(player) refine(player) end,
})
handle:Destroy()    -- ถอดออกเมื่อ object ถูกลบ
```

**กลไก:**
- `Register()` mount `ProximityPrompt` บน BasePart / Attachment / Model (ใช้ PrimaryPart หรือ FindFirstChild อัตโนมัติ)
- `Cooldown` เป็น per-player debounce ใน memory (os.clock) — ไม่ persist
- `OnTrigger` ถูก `pcall` — error ไม่ทำให้ prompt หยุดทำงาน
- คืน Handle ที่มี `.Prompt` + `.Destroy()` — เรียก Destroy เมื่อ object ถูกลบเพื่อ disconnect listener

---

### 8.42 Settings — Server-authoritative player settings bridge

```lua
local Cfg = GaxiaServer.Settings

Cfg.RegisterSetting("Quality", function(v) return typeof(v) == "number" end)

Cfg.Set(player, "Music", false)
local val = Cfg.Get(player, "Music")
local all = Cfg.GetAll(player)   -- { Music=false, SFX=true, … }
```

**กลไก:**
- Whitelist-gated: key ที่ไม่ได้ `RegisterSetting` หรือ value ผิด type → reject + warn (anti-exploit)
- Default whitelist: `Music` (boolean), `SFX` (boolean) — เพิ่มด้วย `RegisterSetting`
- Client bridge ผ่าน `RemoteFunction ReplicatedStorage.Events.Gaxia_Settings` — ops: `"get"`, `"getAll"`, `"set"` — สร้างอัตโนมัติตอน module load
- Persist ใต้ profile key `"Settings"` ผ่าน DataManager

---

### 8.43 Memory — Cross-server ephemeral storage (MemoryStoreService + fallback)

```lua
local Mem = GaxiaServer.Memory

-- Sorted map: เก็บ score + ดึง top-N (highest first)
Mem.MapSet("ranks", tostring(userId), { name = "P_pang" }, 3600, score)
local top = Mem.MapRange("ranks", 10, false)  -- { key, value, sortKey }[]

-- Priority queue: matchmaking intake
Mem.QueueAdd("mmPool", { userId = userId, mmr = 1200 }, 60, priority)
local players, readId = Mem.QueueRead("mmPool", 10)
Mem.QueueRemove("mmPool", readId)  -- ack หลัง process เสร็จ
```

**กลไก:**
- Auto-probe ครั้งแรก — ถ้า MemoryStoreService ยิงไม่ได้ (Studio / no API access) จะ fallback เป็น in-process table โดยอัตโนมัติ
- Fallback ทำ TTL + sortKey ให้ครบ — code ไม่ต้องแก้ แต่ cross-server replication ไม่มี
- Backs `Cooldown` (§8.40) + `Party` (§8.33) — ไม่ควร bypass ผ่าน raw MemoryStoreService

---

### 8.44 AI — NPC pathfinding (PathfindingService wrapper)

```lua
local AI = GaxiaServer.AI

-- เดินไปจุดหมาย (yields จนถึงหรือ cancel)
AI.MoveTo(npcModel, Vector3.new(0, 5, 40))

-- Wander รอบ spawn; คืน stop()
local stop = AI.Roam(npcModel, spawnPos, 30)

-- ไล่ตาม target ทุก 0.5 วินาที; คืน stop()
local unfollow = AI.Follow(npcModel, player.Character, { StopDistance = 6 })

AI.OnReached:Connect(function(model, target) end)  -- fired เมื่อ MoveTo สำเร็จ
```

**กลไก:**
- Token ต่อ model — `MoveTo` / `Roam` / `Follow` ใหม่ cancel loop เก่าอัตโนมัติ
- รองรับ Jump waypoints (`PathWaypointAction.Jump` → `ChangeState Jumping`)
- `Stop()` หยุดทันที + clear target ใน Humanoid:MoveTo
- `ComputePath()` expose ไว้แยกต่างหาก — ใช้ unit-test geometry ได้โดยไม่มี model

---

### 8.45 VFX — Pooled visual effects (server-side → replicates)

```lua
local VFX = GaxiaServer.VFX

-- Register ครั้งเดียวตอน boot
VFX.Register("Hit", function(p)
    local e = Instance.new("ParticleEmitter")
    e.Rate = 0; e.Parent = p
end)

-- One-shot ที่ตำแหน่ง world
VFX.PlayAt("Hit", hrp.Position, { EmitCount = 30, Duration = 1.5 })

-- Continuous — คืน stop()
local stop = VFX.Attach("BurnAura", hrp)
```

**กลไก:**
- Pool (`Gaxia.Pool`) ต่อ effect name — holder ถูก recycle ไม่ทิ้ง Instance ทุกครั้ง
- `PlayAt` emit แล้ว disable children หลัง Duration → `pool.Return(holder)`
- `Attach` สร้าง Attachment บน host โดยตรง — stop() ทำ `att:Destroy()`
- `PreWarm(name, n)` ใช้ pre-allocate pool ก่อน burst เพื่อไม่ hitch

---

### 8.46 SFX — Sound bank + 3D positional audio

```lua
local SFX = GaxiaServer.SFX

-- Register ครั้งเดียว
SFX.Register("Explosion", {
    SoundId = "rbxassetid://12222200",
    PitchVariation = 0.2,
    Category = "SFX",
    RollOffMaxDistance = 80,
})

SFX.PlayAt("Explosion", hrp.Position)   -- 3D ที่ตำแหน่ง world
SFX.Play2D("MenuClick")                 -- Global / UI
SFX.Duck("Music", 0.2, 3)               -- ลดเสียง Music 3 วินาที (cutscene)
```

**กลไก:**
- Pitch randomization — `base ± variation` ทุกครั้งที่เล่น ป้องกัน robotic repeats
- Volume = `def.Volume × categoryVolume[Category]` — `SetCategoryVolume` scale ทุก sound ใน bus
- Auto-clean: `Sound.Ended` → destroy holder; fallback `task.delay(10)` กัน Sound ไม่ fire Ended
- Category volume เชื่อมกับ `SettingsService` (§8.42) สำหรับ audio options menu

---

### 8.47 Anim — Named animation playback (server → replicates)

```lua
local Anim = GaxiaServer.Anim

Anim.Register("Swing", "rbxassetid://123456")
Anim.RegisterMany({ Idle = "rbxassetid://111", Run = "rbxassetid://222" })

local track = Anim.Play(npc, "Swing", { Priority = Enum.AnimationPriority.Action, Speed = 1.4 })
Anim.OnMarker(track, "Hit", function() applyDamage() end)   -- keyframe marker
Anim.Stop(npc, "Swing", 0.2)
```

**กลไก:**
- Track cache ต่อ `(model, name)` — `LoadAnimation` เรียกครั้งเดียว ต่อมาใช้ track เดิม
- Auto-create Animator ถ้าไม่มี — รองรับทั้ง Humanoid และ AnimationController
- Raw `animationId` string ใส่ใน `Play()` ได้โดยตรง ถ้าไม่ต้องการ register ก่อน

---

### 8.48 Motion3D — World object motion (platforms, doors, idle FX)

```lua
local M3D = GaxiaServer.Motion3D

M3D.To(doorModel, openCFrame, 0.5, Enum.EasingStyle.Back)        -- door open (Part/Model)
M3D.Path(platform, { wp1, wp2, wp3 }, 1.5, Enum.EasingStyle.Sine) -- moving platform

local stopSpin = M3D.Spin(gemPart, Vector3.yAxis, 90)             -- idle loops; คืน stop()
local stopFloat = M3D.Float(coinPart, 1.5, 2)
```

**กลไก:**
- Model tween ใช้ `CFrameValue` proxy + `PivotTo` — ไม่ต้องหา PrimaryPart
- `Spin` / `Float` ใช้ `RunService.Heartbeat` — auto-disconnect เมื่อ part ถูก remove
- `Path` spawn task + `task.wait(dur)` ต่อ segment — หลีกเลี่ยง race กับ `Completed` event
- Server-driven ทุก call → replicate ไปทุก client อัตโนมัติ

---

### 8.49 Ragdoll — Physics ragdoll toggle (combat knockdown / death)

```lua
local Rag = GaxiaServer.Ragdoll

Rag.Enable(character)            -- knockdown
task.wait(2)
Rag.Disable(character)           -- stand up

Rag.AutoRagdollOnDeath(character)  -- auto-ragdoll เมื่อตาย
Rag.OnRagdoll:Connect(function(char) end)
Rag.OnRecover:Connect(function(char) end)
```

**กลไก:**
- `Enable()` swap Motor6D ทุกตัวเป็น BallSocketConstraint (C0/C1 attachments) + `PlatformStand = true`
- `Disable()` destroy constraint/attachment ที่มี flag `__GaxiaRagdollPart` แล้ว re-enable Motor6D ทั้งหมด
- Attribute `__GaxiaRagdolled` กัน double-enable — `IsRagdolled()` / `Toggle()` ใช้ตรวจสอบ

---

### 8.50 Friend — In-game buddy list + blocks + cross-server invites

Per-player buddy list + block list + invite delivery — เก็บใน `profile.Social.Friends` / `profile.Social.Blocks` (ใช้ DataManager profile, ไม่ใช่ DataStore แยก). Online status สองชั้น: **same-server** (instant ผ่าน `PlayerService.OnPlayerJoined/Left`) + **cross-server** cache `Player:GetPresenceAsync` (TTL `OnlineCacheSec`). Invite cross-server ส่งผ่าน `InviteQueue` helper (MemoryStoreSortedMap คีย์ตาม target userId, drain ตอน `PlayerAdded`). Block เป็น **bidirectional + unilateral** — user ที่ถูก block ไม่สามารถส่ง invite, มองเห็น online status, หรือถูก Party/Guild-invite ได้.

**Access:** `Gaxia.Friend` (server) · `ReplicatedStorage/Events/Friend/Action` (RemoteFunction envelope `{type=..., ...}`)

**Config** (`Config.Social.Friend` — server-private):
```lua
Social = {
    Friend = {
        MaxFriends         = 200,
        MaxBlocks          = 100,
        RequestCooldownSec = 10,    -- gate per (from, to) ผ่าน CooldownService
        OnlineCacheSec     = 60,    -- TTL ของ GetPresenceAsync cache ต่อ userId
        InviteQueueTTLDays = 7,     -- TTL ของ MemoryStore invite queue
    },
    -- ...
}
```

```lua
local Friend = GaxiaServer.Friend

Friend.SendRequest(from, toUserId)                    -- → (ok, reason?)
Friend.AcceptRequest(player, fromUserId)
Friend.DeclineRequest(player, fromUserId)
Friend.Remove(player, otherUserId)
Friend.Block(player, otherUserId)                     -- ดึง friendship + pending ทั้งสองทางออกอัตโนมัติ
Friend.Unblock(player, otherUserId)
Friend.SetFavorite(player, otherUserId, true)
Friend.GetList(player)                                -- → { FriendRecord } พร้อม online flag
Friend.GetBlocks(player)                              -- → { BlockRecord }
Friend.IsBlocked(player, otherUserId)                 -- → boolean
Friend.RefreshPresence(player)                        -- forced presence call (ใช้ตอนเปิด panel)

Friend.OnRequest:Connect(function(toPlayer, fromUserId, fromName) end)
Friend.OnAccepted:Connect(function(player, otherUserId) end)
Friend.OnRemoved:Connect(function(player, otherUserId) end)
Friend.OnBlocked:Connect(function(player, otherUserId) end)
```

**กลไก:**
- Data dual-side: `PendingOut` เก็บใน profile ผู้ส่งเท่านั้น; `PendingIn` ไม่ persist — delivery ผ่าน MemoryStore queue ตอน join + drain เข้า RAM
- Cap enforcement ทั้งสองฝั่ง: ไม่ accept ได้ถ้าฝ่ายใดฝ่ายหนึ่ง `#Friends ≥ MaxFriends`
- Block flow: ลบ friendship เดิม + drop pending requests ทุกทิศทาง + mark block ใน profile ตัวเอง (อีกฝ่ายเช็คผ่าน `IsBlocked` ตอน server-side validate)
- ค่า `MaxFriends`/`MaxBlocks`/`RequestCooldownSec`/`OnlineCacheSec` override runtime ได้ผ่าน `/flag set Social.Friend.<Key>` (EConfig)

---

### 8.51 Guild — Persistent guilds + 3 roles + shared vault + cross-server live roster

Persistent guild roster — **per-guild DataStore key** `guild:<guildId>` (ไม่ใช้ ProfileService session-claim เพราะ guild มีหลาย member ในหลาย server). Roles 3 ชั้น (Owner / Officer / Member); officer cap = `Config.Social.Guild.OfficerCap` (default 5). Shared **vault** อยู่ใน DataStore key `vault:<guildId>` แยกอีกตัว. ทุก mutation serialize ข้าม server ผ่าน **`GuildLock` MemoryStore mutex** (kick, promote, deposit/withdraw — race-prone ทั้งหมด). `Guild.Create/Disband/Transfer` ถูก auto-report ไปยัง `Webhook.AutoReport.Guild = "GuildEvents"` channel ถ้าตั้งไว้ (no-op ถ้าไม่ได้ config).

**Access:** `Gaxia.Guild` (server) · `ReplicatedStorage/Events/Guild/Action` (RemoteFunction envelope `{type=..., ...}`)

**Config** (`Config.Social.Guild` — server-private):
```lua
Social = {
    Guild = {
        MaxMembers      = 50,
        MaxNameLen      = 24,
        MaxTagLen       = 4,
        MaxDescLen      = 280,
        GuildsPerPlayer = 1,
        OfficerCap      = 5,    -- promote cap (Owner is separate)
        VaultCapacity   = 500,
        CreateCost      = 0,    -- Economy currency; 0 = free
        VaultLockTTLSec = 5,    -- MemoryStore mutex TTL
    },
    -- ...
}

Admin.Stores.Guilds      = "GaxiaGuilds"        -- per-guild DataStore (key: guild:<guildId>)
Admin.Stores.GuildVaults = "GaxiaGuildVaults"   -- per-guild vault DataStore (key: vault:<guildId>)
Webhook.AutoReport.Guild = "GuildEvents"        -- channel name หรือ nil
```

**Role × capability matrix:**

| Capability | Owner | Officer | Member |
|---|:-:|:-:|:-:|
| Invite | ✓ | ✓ | — |
| Kick (Member) | ✓ | ✓ | — |
| Kick (Officer) | ✓ | — | — |
| Promote → Officer | ✓ | — | — |
| Demote Officer → Member | ✓ | — | — |
| Vault Deposit | ✓ | ✓ | ✓ |
| Vault Withdraw | ✓ | ✓ | — |
| Edit Description | ✓ | ✓ | — |
| Disband | ✓ | — | — |
| Transfer Ownership | ✓ | — | — |

```lua
local Guild = GaxiaServer.Guild

-- Lifecycle
Guild.Create(leader, "Dawnseekers", "DAWN")           -- → (ok, guildIdOrReason)
Guild.Disband(player)                                  -- owner only
Guild.Leave(player)                                    -- owner ต้อง Transfer/Disband ก่อน
Guild.Invite(officer, targetUserId)
Guild.AcceptInvite(player, guildId)
Guild.DeclineInvite(player, guildId)
Guild.Kick(actor, targetUserId)
Guild.Promote(owner, userId)                           -- → Officer
Guild.Demote(owner, userId)                            -- Officer → Member
Guild.Transfer(owner, newOwnerUserId)
Guild.SetDescription(actor, text)

-- Reads (no lock — DataStore direct + per-process cache)
Guild.GetGuild(player)                                 -- → GuildSummary | nil
Guild.GetById(guildId)
Guild.GetMembers(guildId)
Guild.IsMember(player, guildId?)
Guild.RoleOf(player)                                   -- "Owner" | "Officer" | "Member" | nil
Guild.GetPendingInvites(player)                        -- → { {guildId, name, fromName, expiresAt} }

-- Vault (delegates ผ่าน GuildLock + DataStore atomic)
Guild.VaultGetContents(player)                         -- → { [itemId]: number }
Guild.VaultGetCapacity(player) / .VaultGetUsed(player)
Guild.VaultDeposit(player, "Diamond", 3)               -- → (ok, reason?)
Guild.VaultWithdraw(player, "Diamond", 1)

-- Signals
Guild.OnCreate:Connect(function(guildId, ownerUserId) end)
Guild.OnDisband:Connect(function(guildId, byUserId) end)
Guild.OnMemberJoin:Connect(function(guildId, userId) end)
Guild.OnMemberLeave:Connect(function(guildId, userId, reason) end)  -- reason: "left"|"kicked"
Guild.OnRoleChange:Connect(function(guildId, userId, newRole) end)
Guild.OnVaultChange:Connect(function(guildId, itemId, delta) end)
```

**กลไก:**
- **Mutation flow:** `GuildLock.WithLock(guildId, function() ... end, 5)` → `DataStore:UpdateAsync(key, transform)` → release lock → broadcast `CrossServerMessaging.Publish("guild:event", {guildId, kind, ...})` (subscribers re-read on demand; ไม่ ship state ผ่าน message)
- **Lock fail** surface เป็น `"busy — try again"` ไม่ swallow — `GuildLock.Acquire` retry 3 ครั้ง backoff 50/150/300 ms ก่อน fail
- **Read paths** (GetMembers/GetGuild/...) **ไม่** acquire lock — DataStore ตรง + per-process cache (invalidate ผ่าน "guild:event" message)
- **Cross-server live roster:** MemoryStoreSortedMap คีย์ `guildId`, slot ต่อ `jobId` → `{[userId]=name}`; prune ตอน `BindToClose`, expire 60s ถ้า server crash; ใช้ทำ "Bob is in server X" + route cross-server invite
- **Webhook auto-report:** `WebhookService.autoSubscribe()` subscribe `Guild.OnCreate/OnDisband/OnRoleChange` (เฉพาะ Owner transfers) → embed ส่งเข้า `Webhook.AutoReport.Guild` channel
- ค่า `MaxMembers`/`OfficerCap`/`VaultCapacity`/`VaultLockTTLSec` override runtime ผ่าน `/flag set Social.Guild.<Key>` (EConfig)

---

### 8.52 Party invites — extension of PartyService

ส่วนเพิ่มของ `Gaxia.Party` (ส่วน Grouping + matchmaking core ดู [§8.33 Party](#833-party--grouping--matchmaking-สำหรับ-co-op--lobby-flows)). Pending invites เป็น **RAM-only** (module-state) — ไม่ persist ข้าม restart, TTL `Config.Social.Party.InviteTTL` (default 60s). Cross-server delivery ผ่าน parallel queue ใน `InviteQueue` helper (ใช้คนละคีย์กับ Friend เพราะ TTL คนละช่วง: Friend 7 วัน vs Party 60 วินาที — รวม queue ทำให้ expiry ยุ่ง).

**Access:** `Gaxia.Party` (server) · `ReplicatedStorage/Events/Party/InviteAction` (RemoteFunction envelope `{type=..., ...}`)

**Config** (`Config.Social.Party` — server-private):
```lua
Social = {
    Party = {
        InviteTTL  = 60,    -- วินาที — invite ที่ไม่ accept หมดอายุ
        MaxPending = 10,    -- จำนวน pending invite สูงสุดต่อ target player (รวมทุก party)
    },
    -- ...
}
```

```lua
local Party = GaxiaServer.Party

Party.Invite(leader, targetUserId)                   -- → (ok, reason?) — leader-only
Party.AcceptInvite(player, partyId)
Party.DeclineInvite(player, partyId)
Party.CancelInvite(leader, targetUserId)             -- leader ดึง invite กลับ
Party.GetPendingInvites(player)                      -- → { {partyId, fromName, expiresAt} }

Party.OnInvite:Connect(function(toPlayer, partyId, fromName) end)
Party.OnInviteResponded:Connect(function(leader, targetUserId, accepted) end)
```

**Invariants:**
- เฉพาะ **leader** invite ได้ — `PartyService.IsLeader(leader)` ต้องผ่าน
- Size cap: `#GetMembers(partyId) + #pendingInvites < MaxSize` (นับ pending ด้วย กัน over-invite)
- **Block check:** `Friend.IsBlocked(target, leader)` — target ที่ block leader invite ไม่ได้ (server return generic `"could not invite"` ให้ leader, ไม่ leak ว่าโดน block)
- Expired invite auto-clean ตอน accept/decline หรือเมื่อมี invite ใหม่เข้ามา

---

### 8.53 Pet — Stat-boost pets (egg/gacha → equip → Coins multiplier)

**Config** (`Config.Pets` — server-private):
```lua
Pets = {
    EggCost       = 100,  -- Coins ต่อการฟัก BasicEgg หนึ่งครั้ง
    MaxEquipSlots = 3,    -- จำนวน pet ที่ใส่พร้อมกันได้ (multiplier stack แบบบวก)
}
```

```lua
local Pet = GaxiaServer.Pet

-- ฟักไข่: spend Coins → Loot.Roll (weighted + pity) → grant; refund ถ้า roll/grant พัง
local ok, petIdOrReason = Pet.BuyEgg(player)   -- (true, "pet_Fox") | (false, "not enough Coins")

-- equip / unequip ด้วย uid ของ pet ที่เป็นเจ้าของ (server re-validate ทุกครั้ง)
Pet.Equip(player, uid)                         -- (false, "all slots full") ถ้าเต็ม
Pet.Unequip(player, uid)

-- THE core API: faucet เอาไปคูณ coin grant ของตัวเอง (Idle / Quest ต่อให้แล้ว)
local mult = Pet.GetCoinMultiplier(player)     -- 1 + Σ coinBonus ของ pet ที่ equip

-- queries / snapshot
local owned    = Pet.GetOwned(player)          -- { {petId, uid}, … }
local equipped = Pet.GetEquipped(player)       -- { uid, … }
local snap     = Pet.Snapshot(player)          -- {owned, equipped, multiplier, slots, eggCost, defs, order}

Pet.OnPetGranted:Connect(function(p, petId, uid) end)
Pet.OnEquipChanged:Connect(function(p, equipped) end)
```

**Roster** (8 ตัว, `coinBonus` บวกกัน):
| Pet | Rarity | coinBonus | Weight | Pity |
|-----|--------|:---:|:---:|:---:|
| Cat / Dog | common | +0.05 | 40 / 30 | — |
| Bunny / Fox | uncommon | +0.10 / +0.12 | 12 / 10 | — |
| Panda / Penguin | rare | +0.20 / +0.25 | 4 / 3 | — |
| Tiger | epic | +0.40 | 1.5 | — |
| Dragon | legendary | +1.00 | 0.5 | **50** |

**กลไก:**
- **Server-authoritative ทั้งหมด** — client ไม่เคยส่ง bonus/cost; `PET_DEFS` คือ source of truth ฝั่ง server. ทุก remote ผ่าน `Net` rate-limit + `Guard.strictInterface`
- ฟักผ่าน `Loot.Roll` (pity ของ Dragon = 50) → auto-log เข้า `Codex` (set `"Pets"`) ฟรี
- owned (map `uid → {petId}`) + equipped (list uid) + `__seq` เซฟเป็น blob เดียวใต้ profile key `"Pets"` (นอก `DEFAULT_PROFILE` แบบเดียวกับ Inventory)
- `GetCoinMultiplier` คืน `1.0` ถ้า profile ยังไม่โหลด (กัน error ช่วง join); uid ที่ equip ไว้แต่ไม่ owned แล้วถูกข้าม — equipped list ที่ corrupt เพิ่ม multiplier ไม่ได้
- **Faucet wiring:** `IdleService.Collect` + `QuestSystem.grantReward` คูณ `GetCoinMultiplier` ให้ coin grant อัตโนมัติ (gate `== "Coins"`); **`RaidService` ไม่คูณ** (zero-sum transfer — คูณแล้วเงินจะเฟ้อ)

**Client remotes** (PetController ใช้): `PetGetState` (RF → snapshot) · `PetBuyEgg {egg}` → ตอบ `PetHatch {ok, petId, reason}` + push `PetSync` · `PetEquip {uid}` / `PetUnequip {uid}` → push `PetSync`

**Invariants / anti-exploit:**
- equip เกิน `MaxEquipSlots` ไม่ได้ · equip ซ้ำ uid ไม่ได้ · equip pet ที่ไม่ owned ไม่ได้
- uid ยาวเกิน 64 ตัวอักษรถูก reject ก่อน lookup (กัน attacker payload)
- `EggCost` / slots floor ที่ 1 (cost 0 จะทำให้ไข่ซื้อไม่ได้แบบเงียบ — ดูเหมือน "เงินไม่พอ")
- ฟักพัง (Loot ว่าง / bad drop) → refund Coins, warn ดังถ้า refund เองก็พัง (เงินไม่หายเงียบ)

---

## 9. AntiCheat System

### 9.1 Orchestrator API

```lua
local AC = GaxiaServer.AntiCheat

-- ส่ง flag manually (gameplay code ก็ใช้ได้)
AC.Flag(player, "CustomReason", "soft")  -- หรือ "hard"

-- ดู count
local count = AC.GetFlagCount(player, "Speed")

-- เคลียร์
AC.ClearFlags(player, "Speed")     -- เฉพาะ reason นี้
AC.ClearFlags(player)               -- ทั้งหมด

-- Whitelist temp (เช่น admin ขอ test)
AC.Whitelist(player, "Speed", 60)   -- ยกเว้น 60 วินาที
AC.Whitelist(player, "Fly")          -- ตลอดไป

-- ฟัง flag events
AC.OnFlag:Connect(function(player, reason, severity, count)
    -- ทุกครั้งที่ flag เพิ่ม
    print(`FLAG: {player.Name} {reason} {severity} (#{count})`)
end)

-- ฟัง action triggers (threshold ถึง)
AC.OnAction:Connect(function(player, reason, kind)
    -- kind = "soft" (count = SOFT_THRESHOLD = 3) | "hard" (count = HARD_THRESHOLD = 5)
    -- ServerBootstrap จะ kick ตรงนี้ — นาย override ได้
end)

-- ── เข้าถึง detector-specific APIs ผ่าน orchestrator ──
-- ทุก detector ที่ register แล้ว access ตรงจาก AC.<Name> ได้เลย
AC.Combat.RegisterDamage(victim, 25)         -- รายงาน damage ที่ valid (CombatGuard)
AC.Animation.Allow("rbxassetid://507766388") -- whitelist anim id (AnimationGuard)
AC.Stat.Expect(player, "Coins", newValue)    -- บอก StatGuard ก่อนเขียน leaderstats
AC.GetDetector("Combat")                     -- defensive lookup (returns module or nil)
```

### 9.2 Detectors 9 ตัว

| Detector | ทำอะไร | Severity | ปรับ threshold ได้ |
|---|---|---|---|
| **SpeedDetector** | HRP horizontal speed > WalkSpeed × 1.5 | soft | `Constants.SPEED_TOLERANCE_MULTIPLIER` |
| **FlyDetector** | Y velocity > 30 ขณะไม่ใช่ Jumping/Freefall/Climbing | soft | `Constants.FLY_VELOCITY_THRESHOLD` |
| **NoClipDetector** | HRP chest อยู่ใน CanCollide=true part (ยกเว้น Climb/Swim/Sit) | soft | streak 4 ticks (~2s) |
| **TeleportDetector** | Position delta > 50 studs/sample | **hard** | `Constants.TELEPORT_MAX_DELTA` |
| **RemoteRateLimiter** | RemoteEvent fire เกิน 10/sec (burst 20) | soft | `REMOTE_RATE_LIMIT_DEFAULT` |
| **StatGuard** | Leaderstats เปลี่ยนนอกเหนือ EconomyService | **hard** | — |
| **ToolDuplicationGuard** | Tool UID ซ้ำ | **hard** | — |
| **AnimationGuard** | AnimationId ไม่อยู่ใน whitelist | soft | **opt-in** — ปิดถ้า whitelist ว่าง |
| **ExploitSignatureScanner** | รับ report จาก client | depends | — |

### 9.3 ปรับ AnimationGuard

```lua
-- ใน server script (หลัง require GaxiaServer)
local AC = GaxiaServer.AntiCheat

-- เปิดใช้งานโดย whitelist animation IDs ของเกม
AC.Animation.Allow("rbxassetid://507766388")  -- Roblox R15 idle
AC.Animation.Allow("rbxassetid://507777826")  -- R15 walk
AC.Animation.Allow("rbxassetid://1234567890") -- custom anim ของเกม

-- หรือใส่ Animation instances ลง ServerStorage.Assets / ReplicatedStorage.Assets
-- จะ seed อัตโนมัติ
```

> 📌 **Opt-in mode:** ถ้า whitelist ว่างเปล่า → AnimationGuard **ไม่ทำงาน** (ป้องกัน false-positive จาก Roblox default animations)

### 9.4 EconomyService + StatGuard

ถ้าใช้ leaderstats เก็บค่า currency — ต้องบอก StatGuard ทุกครั้งที่เขียน:

```lua
-- ใน scriptที่อัพเดต leaderstats นอกเหนือจาก EconomyService.Set
local AC = GaxiaServer.AntiCheat

local function awardCoins(player, amount)
    local current = player.leaderstats.Coins.Value
    local newVal = current + amount

    AC.Stat.Expect(player, "Coins", newVal)  -- บอก guard ก่อน
    player.leaderstats.Coins.Value = newVal
end
```

ถ้าลืม → StatGuard จะ flag เพราะคิดว่ามี exploit เขียนค่าตรงๆ

### 9.5 ClientAntiCheat

โหลดเองโดย Gaxia_ClientBootstrap — ไม่ต้อง config

**ตรวจสอบ:**
- `_G` / `shared` global pollution
- Executor markers (Synapse, Krnl, secure_call, getsynasm, KRNL_LOADED, getexecutorname, ...)
- `getfenv`/`getrenv` mutation (`tostring(print)` heuristic)
- Foreign ScreenGui injection (Synapse, Krnl, Executor, Dex names)

ส่ง report ผ่าน `AntiCheat_Report` RemoteEvent (1 report / kind / 30s)

> **สำคัญ:** Client AntiCheat เป็น **bonus tripwire** — server detectors เป็น authority

---

## 10. Bootstrap & Setup

### 10.1 Gaxia_ServerBootstrap

```lua
-- ServerScriptService.Gaxia_ServerBootstrap (Script)
-- รันอัตโนมัติเมื่อ server start
```

ทำอะไร:
1. Require GaxiaServer
2. Force-load ทุก Lib service ตามลำดับ: Data → Player → Item → Economy → Tool → Zone → **Chat** → **Admin**
   - **Chat ต้องโหลดก่อน Admin** — AdminCommands.Register() ลงทะเบียน chat bridge ทันทีที่ load, ถ้า Chat ยังไม่ถูก require ตอนนั้น bridge จะหายไป
   - Admin load แล้ว auto-grant owner role ให้ game creator
3. Require AntiCheat orchestrator → detectors load อัตโนมัติ
4. ผูก `AC.OnAction` กับ default action:
   - `soft` → warn player ใน output
   - `hard` → kick player (with reason)
5. Dedupe kick — ไม่ kick ซ้ำ reason เดียวกัน

### 10.2 Gaxia_ClientBootstrap

```lua
-- StarterPlayer.StarterPlayerScripts.Gaxia_ClientBootstrap (LocalScript)
-- รันอัตโนมัติเมื่อ player join
```

ทำอะไร:
1. Require Gaxia
2. Force-load ClientAntiCheat → sampler เริ่มทำงาน
3. Pre-warm namespaces: `Gaxia.UI`, `Gaxia.Input`, `Gaxia.Camera`, `Gaxia.Sound`

### 10.3 Custom Bootstrap

อยาก override default behavior? ลบ Gaxia_ServerBootstrap แล้วเขียนเอง:

```lua
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(ServerStorage.Gaxia_Packages_Server.init)

-- Custom kick logic (e.g. log to Discord, then kick)
GaxiaServer.AntiCheat.OnAction:Connect(function(player, reason, kind)
    if kind == "hard" then
        -- Log to external service
        myDiscordLogger:Log(player.Name, reason)
        -- Then kick
        player:Kick(`Banned for: {reason}`)
    elseif kind == "soft" then
        -- Show warning to player
        WarningRemote:FireClient(player, reason)
    end
end)
```

---

## 11. Recipes — สูตรเขียนเกม

### Recipe 1: ระบบ Simulator (clicker → coin)

```lua
-- ServerScriptService/ClickerLogic (Script)
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GaxiaServer = require(ServerStorage.Gaxia_Packages_Server.init)

-- สร้าง RemoteEvent
local clickRE = Instance.new("RemoteEvent")
clickRE.Name = "Click"
clickRE.Parent = ReplicatedStorage.Events

-- Rate-limit ผ่าน AntiCheat
clickRE.OnServerEvent:Connect(function(player)
    -- AntiCheat's RemoteRateLimiter ดูแลแล้ว
    GaxiaServer.Economy.Add(player, "Coins", 1)
    GaxiaServer.Player.SetLeaderstat(player, "Coins", GaxiaServer.Economy.Get(player, "Coins"))
end)

-- Setup leaderstats ตอน player join
GaxiaServer.Player.OnPlayerJoined:Connect(function(player)
    GaxiaServer.Player.SetupLeaderstats(player, {Coins = 0})
end)

-- Sync จาก saved data เมื่อโหลดเสร็จ
GaxiaServer.Data.OnLoaded:Connect(function(player, data)
    GaxiaServer.Player.SetLeaderstat(player, "Coins", data.Coins)
end)
```

```lua
-- StarterPlayer/StarterPlayerScripts/ClickerUI (LocalScript)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Gaxia = require(ReplicatedStorage.Gaxia_Packages.init)
local clickRE = ReplicatedStorage.Events.Click

-- ทำปุ่ม Click
local btn = Gaxia.UI.UIController.CloneTemplate("ButtonTemplate")
btn.Text = "Click!"
btn.Size = UDim2.new(0, 200, 0, 60)
btn.Position = UDim2.new(0.5, -100, 0.5, -30)
btn.AnchorPoint = Vector2.new(0.5, 0.5)
btn.MouseButton1Click:Connect(function()
    clickRE:FireServer()
end)
```

### Recipe 2: ระบบ Shop

```lua
-- Server: ShopService.lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(ServerStorage.Gaxia_Packages_Server.init)

local SHOP_ITEMS = {
    Sword     = {price = 100, currency = "Coins"},
    GoldArmor = {price = 50,  currency = "Gems"},
}

local buyRE = Instance.new("RemoteEvent")
buyRE.Name = "ShopBuy"
buyRE.Parent = ReplicatedStorage.Events

buyRE.OnServerEvent:Connect(function(player, itemId)
    -- Validation (server side ทุกครั้ง)
    local item = SHOP_ITEMS[itemId]
    if not item then return end
    if not GaxiaServer.Data.IsLoaded(player) then return end

    -- Atomic check + deduct
    if GaxiaServer.Economy.Spend(player, item.currency, item.price) then
        GaxiaServer.Item.Give(player, itemId, 1)
        Gaxia.Logger:Info("Player {} bought {}", player.Name, itemId)
    end
end)
```

### Recipe 3: ระบบ Quest

```lua
-- Server: QuestService.lua
local GaxiaServer = require(...)
local Gaxia = require(...)

local activeQuests = {}  -- [player] = {questId = progress}

GaxiaServer.Data.OnLoaded:Connect(function(player, data)
    activeQuests[player] = data.Quests or {}
end)

-- Listen for kills (จาก gameplay code)
local function onEnemyKilled(player, enemyType)
    local quests = activeQuests[player]
    if not quests then return end

    -- Check active "kill X of Y" quests
    for questId, progress in pairs(quests) do
        if questId:match(`^Kill_{enemyType}_`) then
            progress.count += 1
            if progress.count >= progress.target then
                -- เสร็จ!
                GaxiaServer.Economy.Add(player, "Coins", progress.reward)
                quests[questId] = nil
                Gaxia.UI_Notify:FireClient(player, "Quest Complete!", questId)
            end
        end
    end

    -- Save progress
    GaxiaServer.Data.Set(player, "Quests", quests)
end
```

### Recipe 4: Safe Zone (Trigger Zone)

```lua
local GaxiaServer = require(...)

-- สร้าง Part ใน workspace ที่จะใช้เป็น region (Anchored, CanCollide=false, Transparent)
local regionPart = workspace.SafeZoneRegion
local zone = GaxiaServer.Zone.new(regionPart)

zone.playerEntered:Connect(function(player)
    -- ลด WalkSpeed
    GaxiaServer.Player.SetWalkSpeed(player, 8)
    -- Whitelist anti-cheat speed ระหว่างอยู่ในโซน
    GaxiaServer.AntiCheat.Whitelist(player, "Speed", math.huge)
end)

zone.playerExited:Connect(function(player)
    GaxiaServer.Player.SetWalkSpeed(player, 16)
    GaxiaServer.AntiCheat.ClearFlags(player, "Speed")  -- เอา whitelist ออก
end)
```

### Recipe 5: Async API call

```lua
local Gaxia = require(...)

-- Wrap HttpService ด้วย Promise
local HttpService = game:GetService("HttpService")

local function fetch(url)
    return Gaxia.Promise.new(function(resolve, reject)
        local ok, result = pcall(HttpService.GetAsync, HttpService, url)
        if ok then
            resolve(result)
        else
            reject(result)
        end
    end)
end

-- ใช้
fetch("https://api.example.com/data")
    :andThen(function(body)
        print("got:", body)
        return HttpService:JSONDecode(body)
    end)
    :andThen(function(data)
        print("parsed:", data.someField)
    end)
    :catch(function(err)
        warn("failed:", err)
    end)
```

### Recipe 6: Per-character cleanup

```lua
-- ทุกครั้งที่ character spawn ใหม่ ต้อง cleanup ของเก่า
local Gaxia = require(...)
local Players = game:GetService("Players")

Players.PlayerAdded:Connect(function(player)
    local janitor

    player.CharacterAdded:Connect(function(character)
        -- เคลียร์ของรอบที่แล้ว
        if janitor then janitor:Cleanup() end
        janitor = Gaxia.Janitor.new()

        -- ผูก task กับ character ใหม่
        janitor:Add(character.Humanoid.Died:Connect(function()
            print(`{player.Name} died`)
        end))
        janitor:Add(character)  -- character ถูก Destroy ตอน cleanup
    end)
end)
```

---

## 12. Troubleshooting

### "Attempted to call require with invalid argument(s)"
**ผิด:** `require(game.ReplicatedStorage.Gaxia_Packages)`
**ถูก:** `require(game.ReplicatedStorage.Gaxia_Packages.init)`

Roblox runtime ไม่ auto-resolve `Folder/init` (Rojo convention only)

### "Infinite yield possible on ..."
ที่ใช้ `WaitForChild` ในที่ที่ instance ยังไม่ replicate
**แก้:** ใช้ `FindFirstChild` + retry หรือเพิ่ม timeout
```lua
local part = workspace:WaitForChild("MyPart", 10)
if not part then warn("timeout") end
```

### "attempt to yield across metamethod/C-call boundary"
เกิดเมื่อใส่ `WaitForChild`/`task.wait` ใน `__index` metamethod
**แก้:** Framework แก้แล้ว — ถ้าเจอใน custom code ใช้ `FindFirstChild` แทน

### Player โดน kick ตอนยืนนิ่ง
1. ดู console ว่า reason อะไร
2. ถ้า `Animation` → AnimationGuard whitelist ว่าง ปิดแล้วใน opt-in mode
3. ถ้า `NoClip` → ปรับ probe (อยู่ใน NoClipDetector.lua)
4. ถ้า `Speed` → ลด `SPEED_TOLERANCE_MULTIPLIER` หรือ Whitelist player

### Admin โดน kick หลังสั่ง /speed หรือ /teleport
Anti-cheat ตรวจจับว่าค่า stat เปลี่ยนผิดปกติ
- Framework ทำ whitelist อัตโนมัติ 30s ทุกครั้งที่ admin run command — ถ้ายัง kick อยู่:
  1. ตรวจว่า `Chat` โหลดก่อน `Admin` ใน `LIB_SERVICES` ของ Bootstrap
  2. ตรวจว่า `GaxiaServer.Chat` ไม่ nil (console: `print(GaxiaServer.Chat)`)
  3. ถ้า whitelist แค่ 30s ไม่พอสำหรับ test: ตั้ง `Config.Admin.ActionWhitelistSeconds` หรือ runtime `/flag set Admin.ActionWhitelistSeconds 120` (ค่าต้องเป็นตัวเลข — ค่าที่ไม่ใช่ตัวเลขจะถูก fallback เป็น default อัตโนมัติ)

### /speed ใน chat ไม่ทำงาน (คำสั่งไม่ถูกรับ)
ตรวจสอบ load order ของ Bootstrap — `"Chat"` ต้องอยู่ก่อน `"Admin"` ใน LIB_SERVICES
```lua
local LIB_SERVICES = {
    "Data", "Player", "Item", "Economy", "Tool", "Zone",
    "Chat",   -- ← ก่อน Admin เสมอ
    "Admin",
    ...
}
```
ถ้า order สลับกัน — AdminCommands load ก่อน ChatCommandSystem → chat bridge ไม่ register

### Autocomplete ไม่ขึ้น
- ลึก 2 ระดับขึ้นไป (`Gaxia.Util.Table.Copy`) — ดู Section 12.1 แก้ guard
- ลึก 1 ระดับ (`Gaxia.Signal.new`) ขึ้นปกติ — Studio Script Editor รองรับ

### ProfileService error: "Missing or invalid Name parameter"
DataManager ของ Gaxia แก้ตอน v1 แล้ว — ใช้ `.GetProfileStore` (period) ไม่ใช่ `:GetProfileStore` (colon) เพราะ user's ProfileService implementation

### State หายตอน Play Mode → Stop
ของที่ **สร้างใน Play Mode** จะ revert เมื่อ Stop — เป็นปกติของ Roblox Studio
ของที่สร้างใน **Edit Mode** จะ persist ปกติ

---

## 13. FAQ

**Q: ใช้กับ Rojo / external workflow ได้ไหม?**
A: ได้ ต้องสร้าง `default.project.json` map paths ให้ตรง. Source code อยู่ใน `G:\My Drive\roblox-multi-ai\src\`

**Q: Anti-Cheat กิน performance ไหม?**
A: ใช้ shared sampler 0.5s loop ตัวเดียว iterate players → snapshot → dispatch. Event-driven detectors zero idle cost. ตามที่ทดสอบ — < 1% CPU

**Q: ใช้กับ DataStore ตัวอื่น (ไม่ใช่ ProfileService) ได้ไหม?**
A: ได้ — เขียน wrapper module ของ Data ใหม่. Lib/DataManager.lua ใช้ ProfileService ของ existing user — แก้เป็น MockDataManager หรือ Suphi's DataStoreModule ได้

**Q: เพิ่ม detector ใหม่ของตัวเองได้ไหม?**
A: ได้! สร้าง ModuleScript ใหม่ใน `AntiCheat/` folder ที่ return:
```lua
return {
    Name = "MyDetector",
    Init = function(orchestrator) end,  -- optional
    Sample = function(player, snapshot) end,  -- optional, called every 0.5s
}
```
Orchestrator จะ auto-discover เมื่อโหลด

**Q: ต้องใช้ทุก service / detector ไหม?**
A: ไม่ — ลบโมดูลที่ไม่ใช้ออกจาก Studio ได้ Master Loader ใช้ FindFirstChild → ไม่ error ถ้าหาย

**Q: ทำไมต้องมี Maid + Janitor + Trove (3 ตัว)?**
A: รสนิยม:
- **Maid** — ง่ายสุด, LIFO order
- **Janitor** — มี named index
- **Trove** — modern, สวยสุด, `:Construct()` + `:Extend()` ทำ child cleanup

ใช้ตัวที่ชอบ — ทั้ง 3 มี `:Destroy()` เหมือนกัน

**Q: ทำไม Gaxia.UI ใช้ใน server ไม่ได้?**
A: UI controllers access `Players.LocalPlayer` ที่ server เป็น nil → crash UI proxies จึงสร้างเฉพาะ client side. Server ใช้ `GaxiaServer.Shared.Util` ก็พอสำหรับ utility

**Q: เปลี่ยน scheme ของ DEFAULT_PROFILE ได้ไหม?**
A: ได้ แต่ระวัง — ProfileService Reconcile จะใส่ field ใหม่ให้ player ที่มี data อยู่แล้ว แต่ **ลบ field เก่าออกจาก saved data ไม่ทำ** — ต้อง migrate manually

**Q: Studio plugin disconnect บ่อย?**
A: คลิก **Claude > Connect** บน toolbar Studio
หรือ restart Studio + Claude Code (ถ้าเป็น MCP server issue)

---

## 📞 ขอความช่วยเหลือ

- **Source code:** `G:\My Drive\roblox-multi-ai\src\`
- **Backup files (.bak):** ของเดิมก่อน v2 update
- **Tag query:** `game:GetService("CollectionService"):GetTagged("Gaxia_Packages")` — list ทุก asset ของ framework

🎮 **Happy coding!** — Gaxia_Packages พร้อมให้นายลุยสร้างเกมแล้ว ✨
