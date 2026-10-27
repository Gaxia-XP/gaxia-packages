# GaxiaPackages API Reference

> เอกสารนี้สร้างจาก public source ปัจจุบันของ repository และตั้งใจให้เป็น reference สำหรับทีมเกม Gaxia XP

## สถานะเอกสาร

- **Scope:** first-party modules ใต้ `src/ReplicatedStorage/Gaxia_Packages` และ `src/ServerStorage/Gaxia_Packages_Server` (ไม่รวมโค้ด dependency ใน `_Index`)
- **หลักการ:** server เป็น authoritative สำหรับ data/economy/inventory/social/anti-cheat; client ใช้ UI/input/presentation เท่านั้น
- **หมายเหตุ:** signature ด้านล่างดึงจาก declaration ใน source; ค่า default/validation ให้ยึด implementation และ Config ของ version ที่ใช้งาน

### Coverage contract

เอกสารนี้นับ public surface จาก loader และ first-party wrappers ไม่ใช่จากจำนวนไฟล์อย่างเดียว:

- Shared root: `src/ReplicatedStorage/Gaxia_Packages/init.lua`
- Server root: `src/ServerStorage/Gaxia_Packages_Server/init.lua`
- `.luau` wrappers ที่เป็น public require path รวมไว้ด้วย เช่น `Shared/Component/init.luau`, `Shared/Comm/init.luau`, `Shared/Janitor/init.luau`
- `Packages/_Index` และ `ServerPackages/_Index` เป็น third-party implementation dependency ไม่ใช่ first-party catalog
- ชื่อ alias ใน loader ต้องอ่านคู่กับ module จริง: `Net → NetService`, `State → ReplicatedState`, `Data → DataManager` เป็นต้น
- API ที่ขึ้นต้นด้วย `_` หรือ callback ภายใน options/profile ไม่ใช่ production API เว้นแต่ติดป้าย `test-only`/`internal` ชัดเจน

การตรวจ coverage ต้องยืนยันทั้งชื่อ loader key, source path, public member และ signature; จำนวน heading เท่ากับจำนวนไฟล์ไม่ถือเป็นหลักฐานเพียงพอ

## Verification status

- Reference นี้ยังไม่ใช่การรับรองว่าทุก public API มีรายละเอียดและตัวอย่างครบหรือผ่าน runtime test ทั้งหมด
- Smoke test ใน place ทดสอบผ่านสำหรับ packages ที่ติดตั้งอยู่: OSS suite, shared/server roots, client UI.Responsive/Input และ Janitor/Signal cleanup
- ผล runtime ข้างต้นไม่ได้ยืนยัน candidate loader/project changes ที่ยังไม่ได้ commit และไม่ได้ยืนยันตัวอย่างทุกบล็อกในเอกสาร
- Full bootstrap, persistence, cross-server services และ business RPC integration ยังต้องทดสอบแยก
- Build exit 0 อย่างเดียวไม่พอ: ตรวจว่ามี Packages/ServerPackages และ dependency aliases ครบ ห้ามพึ่งสำเนา untracked ใต้ src/

## Quick start

### Shared / client
```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Gaxia = require(ReplicatedStorage.Gaxia_Packages)

Gaxia.Logger:Info("Game booted")
local Tween = Gaxia.Tween(workspace.Panel, TweenInfo.new(0.25), {Transparency = 0})
```

### Server
```lua
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(ServerStorage.Gaxia_Packages_Server)

GaxiaServer.Lifecycle.Register({
    Name = "InventoryBootstrap",
    Start = function() print("ready") end,
})
GaxiaServer.Lifecycle.Start()
```

### Namespace map

| Context | Import | ตัวอย่าง |
|---|---|---|
| Shared | `ReplicatedStorage.Gaxia_Packages` | `Gaxia.Signal`, `Gaxia.Util.Math` |
| Client | same shared package ใน LocalScript | `Gaxia.UI.Toast`, `Gaxia.Input` |
| Server | `ServerStorage.Gaxia_Packages_Server` | `GaxiaServer.Data`, `GaxiaServer.Economy` |
| Server shared | `GaxiaServer.Shared` | `GaxiaServer.Shared.Signal` |

## Golden rules

1. อย่า require server package จาก LocalScript; loader จะ reject client-only context
2. ตรวจ payload และสิทธิ์ซ้ำบน server เสมอ แม้ client จะใช้ `Command`/`Net`
3. เรียก `Destroy`/ยกเลิก connection, Promise, Trove/Maid/Janitor เมื่อ owner หายไป
4. DataStore/MemoryStore/Teleport/Webhook ต้องทดสอบใน server และจัดการ failure/Retry อย่าง explicit
5. อย่าเอา private helper ที่ไม่ได้อยู่ในรายการนี้ไปเรียกใช้ เพราะไม่ถือเป็น compatibility contract

## Worked use cases

### Server-authoritative purchase flow
```lua
local Players = game:GetService("Players")
local G = require(game.ServerStorage.Gaxia_Packages_Server)

Players.PlayerAdded:Connect(function(player)
    if not G.Data.WaitFor(player, 10) then return end
    local ok, reason = G.Shop.Purchase(player, "HealthPotion")
    if not ok then G.Shared.Logger:Warn(`purchase rejected: {reason}`) end
end)
```

### Client input + replicated state + cleanup
```lua
local G = require(game.ReplicatedStorage.Gaxia_Packages)
local trove = G.Trove.new()
local state = G.State.Get("HUD")

trove:Add(G.Input.Bind("OpenInventory", {Enum.KeyCode.I}, function(_, inputState)
    if inputState == "Begin" then G.UI.MenuController.Open("Inventory") end
end))
trove:Add(state:OnChanged("Coins", function(value)
    print("coins", value)
end))
-- trove:Clean() เมื่อ HUD ถูกถอดออก
```

### Quest + reward composition
```lua
local Players = game:GetService("Players")
local G = require(game.ServerStorage.Gaxia_Packages_Server)
G.Quest.Register({
    id = "first_kill", name = "First Kill", description = "Defeat one Slime",
    goals = {{type = "kill", target = "Slime", count = 1}},
    reward = {currency = "Coins", amount = 100},
})
Players.PlayerAdded:Connect(function(player)
    G.Quest.Start(player, "first_kill")
    G.Quest.Track(player, "kill", "Slime", 1)
end)
```

## API catalog

## Shared APIs

โหลดผ่าน namespace ที่ระบุใน loader; หน้าที่หลัก: Shared.

### `CentralManager`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/CentralManager.lua`
- **Use case:** CentralManager API สำหรับระบบ shared ของเกม
- **Public API:**
  - `CentralManager.Register(self: InternalCentralManager, options: TaskOptions, callback: Callback)`
  - `CentralManager.Cancel(self: InternalCentralManager, name: string)`
  - `CentralManager.Pause(self: InternalCentralManager, name: string)`
  - `CentralManager.Resume(self: InternalCentralManager, name: string)`
  - `CentralManager.Destroy(self: InternalCentralManager)`

### `Command`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Command.lua`
- **Use case:** ลงทะเบียนคำสั่งที่ validate payload และส่งข้าม client/server
- **Public API:**
  - `Command.Register(name: string, def: Command)`
  - `Command.Unregister(name: string)`
  - `Command.IsRegistered(name: string)`
  - `Command.Send(name: string, payload: any?)`

### `Component`

- **Loader key:** `Gaxia_Packages.Component`
- **Public require path:** `Gaxia_Packages.Shared.Component`
- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Component/init.luau`
- **Boundary:** forwards to first-party `src/ReplicatedStorage/Gaxia_Packages/Packages/Component.luau`; this wrapper does not add methods or alter arguments
- **Use case:** require this name when migrating code that uses the shared Component compatibility path

### `Janitor` (wrapper)

- **Loader key:** `Gaxia_Packages.Janitor`
- **Public require path:** `Gaxia_Packages.Shared.Janitor`
- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Janitor/init.luau`
- **Boundary:** forwards to first-party `src/ReplicatedStorage/Gaxia_Packages/Packages/Janitor.luau`; use the forwarded module's documented constructor and cleanup methods

### `Comm` (compatibility wrapper)

- **Public require path:** `Gaxia_Packages.Shared.Comm`
- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Comm/init.luau`
- **Boundary:** forwards to first-party `src/ReplicatedStorage/Gaxia_Packages/Packages/Comm.luau`; it is not a top-level key in `Gaxia_Packages`
- **Use case:** legacy/shared code that requires the Comm wrapper directly

### `ComponentLegacy`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/ComponentLegacy.lua`
- **Use case:** ComponentLegacy API สำหรับระบบ shared ของเกม
- **Implementation:** first-party compatibility wrapper; ตรวจ implementation ที่ `Shared/Component/init.luau` และ `Packages/Component.luau`
- **Require path:** `Gaxia_Packages.Shared.Component` และ legacy aliasที่ loader expose
- **Common calls:** ใช้ API ของ `Packages/Component.luau` ตาม version ใน repository นี้; wrapper ไม่เพิ่ม behavior ใหม่

### `Constants`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Constants.lua`
- **Use case:** Constants API สำหรับระบบ shared ของเกม
- **Public API:** module export ไม่มี function declaration แบบ static; ตรวจค่าที่ return ใน source ก่อนใช้

### `Flags`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Flags.lua`
- **Use case:** feature flags และการ subscribe การเปลี่ยนค่า
- **Public API:**
  - `Flags.Set(name: string, value: any)`
  - `Flags.Get(name: string, default: any?)`
  - `Flags.IsEnabled(name: string)`
  - `Flags.OnChanged(name: string, fn: (new: any, old: any))`

### `Guard`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Guard.lua`
- **Use case:** Guard API สำหรับระบบ shared ของเกม
- **Implementation:** first-party compatibility wrapper; ตรวจ implementation ที่ `Shared/Guard.lua` และ dependency ที่ wrapper require จริง
- **Common calls:** ใช้เฉพาะ exports ที่ wrapper ส่งต่อ; `_Index` เป็น implementation dependency ไม่ใช่ first-party API

### `GuiCodec`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/GuiCodec.lua`
- **Use case:** GuiCodec API สำหรับระบบ shared ของเกม
- **Public API:**
  - `GuiCodec.Make(className: string, props: { [string]: any }?, children: { Instance }?)`
  - `GuiCodec.ToCode(root: Instance, opts: { varName: string? }?)`

### `Localization`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Localization.lua`
- **Use case:** ข้อความหลายภาษา
- **Public API:**
  - `Localization.Load(locale: string, entries: { [string]: string })`
  - `Localization.SetLocale(locale: string)`
  - `Localization.GetLocale()`
  - `Localization.T(key: string, vars: { [string]: any }?)`
  - `Localization.Has(key: string)`
  - `Localization.OnLocaleChanged(fn: (locale: string))`

### `Logger`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Logger.lua`
- **Use case:** structured logging
- **Public API:**
  - `Logger:SetLevel(level: Level)`
  - `Logger:SetEnabled(level: Level, enabled: boolean)`
  - `Logger:Scope(context: string)`
  - `Logger:Debug(msg: string, ...: any)`
  - `Logger:Info(msg: string, ...: any)`
  - `Logger:Warn(msg: string, ...: any)`
  - `Logger:Error(msg: string, ...: any)`

### `Maid`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Maid.lua`
- **Use case:** Maid API สำหรับระบบ shared ของเกม
- **Implementation:** first-party compatibility wrapper; ตรวจ implementation ที่ `Shared/Maid.lua` และ dependency ที่ wrapper require จริง
- **Common calls:** ใช้เฉพาะ exports ที่ wrapper ส่งต่อ; `_Index` เป็น implementation dependency ไม่ใช่ first-party API

### `MockPlayer`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/MockPlayer.lua`
- **Use case:** MockPlayer API สำหรับระบบ shared ของเกม
- **Public API:**
  - `MockPlayer.new(opts: { name: string?, userId: number?, displayName: string? }?)`

### `NetProtocol`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/NetProtocol.lua`
- **Use case:** NetProtocol API สำหรับระบบ shared ของเกม
- **Public API:**
  - `NetProtocol.GetBudget(name: string?)`
  - `NetProtocol.IsBudgetName(value: any)`
  - `NetProtocol.IsValidNonce(value: any)`
  - `NetProtocol.NewReplayWindow(capacity: number?)`
  - `NetProtocol.RememberNonce(window: ReplayWindow, nonce: number)`
  - `NetProtocol.IsValidRequestId(value: any)`
  - `NetProtocol.NewRequestCache(capacity: number?, ttlSeconds: number?)`
  - `NetProtocol.GetCached(cache: RequestCache, requestId: string, now: number?)`
  - `NetProtocol.PutCached(cache: RequestCache, requestId: string, value: any, now: number?)`
  - `NetProtocol.ValidatePayload(value: any, budgetName: string?)`

### `NetService`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/NetService.lua`
- **Use case:** RPC/remote ที่มี schema, rate limit และ metrics
- **Public API:**
  - `Net.Server.GetMetrics(name: string?)`
  - `Net.OnServer(name: string, handler: (player: Player, ...any))`
  - `Net.OnInvoke(name: string, handler: (player: Player, ...any))`
  - `Net.FireClient(player: Player, name: string, ...: any)`
  - `Net.FireAllClients(name: string, ...: any)`
  - `Net.FireOtherClients(exceptPlayer: Player, name: string, ...: any)`
  - `Net.OnClient(name: string, handler: (...any))`
  - `Net.FireServer(name: string, ...: any)`
  - `Net.InvokeServer(name: string, ...: any)`
  - `Net.Server.RegisterEvent(name: string, definition: RpcDefinition)`
  - `Net.Server.RegisterFunction(name: string, definition: RpcDefinition)`
  - `Net.Client.Fire(name: string, payload: any, requestId: string?)`
  - `Net.Client.Invoke(name: string, payload: any, requestId: string?)`

### `Observers`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Observers.lua`
- **Use case:** Observers API สำหรับระบบ shared ของเกม
- **Implementation:** first-party module at `Shared/Observers.lua`; inspect its returned table/type for the exact contract
- **Common calls:** only the exports documented in this file are compatibility surface; transitive `_Index` dependencies are not first-party API

### `PerformanceBenchmark`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/PerformanceBenchmark.lua`
- **Use case:** PerformanceBenchmark API สำหรับระบบ shared ของเกม
- **Public API:**
  - `PerformanceBenchmark.Measure(label: string, fn: () -> (), iterations: number?) -> Result`
  - `PerformanceBenchmark.Compare(a: { label: string, fn: () -> () }, b: { label: string, fn: () -> () }, iterations: number?) -> Comparison`

### `PerformanceMonitor`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/PerformanceMonitor.lua`
- **Use case:** วัด FPS/memory/ping
- **Public API:**
  - `PerformanceMonitor.GetFPS()`
  - `PerformanceMonitor.GetMemoryMB()`
  - `PerformanceMonitor.GetPing(player: Player?)`
  - `PerformanceMonitor.Snapshot()`

### `Pool`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Pool.lua`
- **Use case:** object pooling
- **Public API:**
  - `Pool.new(factory: () -> any, reset: ((object: any) -> ())?) -> PoolObject`
  - `p.Get()`
  - `p.Return(obj: any)`
  - `p.PreWarm(n: number)`
  - `p.Clear()`
  - `p.Size()`

### `Promise`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Promise.lua`
- **Use case:** Promise API สำหรับระบบ shared ของเกม
- **Public API:**
  - `Error.new(options, parent)`
  - `Error.is(anything)`
  - `Error.isKind(anything, kind)`
  - `Error:extend(options)`
  - `Error:getErrorChain()`
  - `Error:__tostring()`
  - `Promise._new(traceback, callback, parent)`
  - `Promise.new(executor)`
  - `Promise:__tostring()`
  - `Promise.defer(executor)`
  - `Promise.resolve(...)`
  - `Promise.reject(...)`
  - `Promise._try(traceback, callback, ...)`
  - `Promise.try(callback, ...)`
  - `Promise._all(traceback, promises, amount)`
  - `Promise.all(promises)`
  - `Promise.fold(list, reducer, initialValue)`
  - `Promise.some(promises, count)`
  - `Promise.any(promises)`
  - `Promise.allSettled(promises)`
  - `Promise.race(promises)`
  - `Promise.each(list, predicate)`
  - `Promise.is(object)`
  - `Promise.promisify(callback)`
  - `Promise.delay(seconds)`
  - `Promise.prototype:timeout(seconds, rejectionValue)`
  - `Promise.prototype:getStatus()`
  - `Promise.prototype:_andThen(traceback, successHandler, failureHandler)`
  - `Promise.prototype:andThen(successHandler, failureHandler)`
  - `Promise.prototype:catch(failureHandler)`
  - `Promise.prototype:tap(tapHandler)`
  - `Promise.prototype:andThenCall(callback, ...)`
  - `Promise.prototype:andThenReturn(...)`
  - `Promise.prototype:cancel()`
  - `Promise.prototype:_consumerCancelled(consumer)`
  - `Promise.prototype:_finally(traceback, finallyHandler)`
  - `Promise.prototype:finally(finallyHandler)`
  - `Promise.prototype:finallyCall(callback, ...)`
  - `Promise.prototype:finallyReturn(...)`
  - `Promise.prototype:awaitStatus()`
  - `Promise.prototype:await()`
  - `Promise.prototype:expect()`
  - `Promise.prototype:_unwrap()`
  - `Promise.prototype:_resolve(...)`
  - `Promise.prototype:_reject(...)`
  - `Promise.prototype:_finalize()`
  - `Promise.prototype:now(rejectionValue)`
  - `Promise.retry(callback, times, ...)`
  - `Promise.retryWithDelay(callback, times, seconds, ...)`
  - `Promise.fromEvent(event, predicate)`
  - `Promise.onUnhandledRejection(callback)`

### `Random`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Random.lua`
- **Use case:** random stream ที่ทำซ้ำผลได้
- **Public API:**
  - `s.Int(min: number, max: number)`
  - `s.Float(min: number, max: number)`
  - `s.Number()`
  - `s.Bool(chance: number?)`
  - `s.Choice(list: { any })`
  - `s.Weighted(entries: { { item: any, weight: number } })`
  - `s.Shuffle(list: { any })`
  - `s.Raw()`
  - `RandomService.new(seed: number?)`
  - `RandomService.Stream(name: string, seed: number?)`

### `Raycaster`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Raycaster.lua`
- **Use case:** raycast แบบ chainable
- **Public API:**
  - `Raycaster.new()`
  - `Raycaster:Filter(instances: { Instance })`
  - `Raycaster:FilterType(kind: Enum.RaycastFilterType)`
  - `Raycaster:IgnoreWater(value: boolean)`
  - `Raycaster:CollisionGroup(name: string)`
  - `Raycaster:Cast(origin: Vector3, direction: Vector3)`
  - `Raycaster:CastFromCamera(distance: number)`
  - `Raycaster:CastFromMouse(distance: number)`
  - `Raycaster.Quick(origin: Vector3, direction: Vector3, ignoreList: { Instance }?)`

### `RemoteObfuscator`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/RemoteObfuscator.lua`
- **Use case:** RemoteObfuscator API สำหรับระบบ shared ของเกม
- **Public API:**
  - `RemoteObfuscator.Encode(key: number, value: any, nonce: number?)`
  - `RemoteObfuscator.Decode(key: number, envelope: any, limits: DecodeLimits?)`

### `ReplicatedState`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/ReplicatedState.lua`
- **Use case:** state ที่ replicate ผ่าน Folder/Attributes
- **Public API:**
  - `StateClass:Get(key: string)`
  - `StateClass:Set(key: string, value: any)`
  - `StateClass:SetTable(key: string, value: { [any]: any })`
  - `StateClass:GetTable(key: string)`
  - `StateClass:OnTableChanged(key: string, fn: (new: any, old: any))`
  - `StateClass:OnChanged(key: string, fn: (new: any, old: any))`
  - `StateClass:GetAll()`
  - `StateClass:Destroy()`
  - `State.Create(name: string, defaults: { [string]: any }?)`
  - `State.Get(name: string)`

### `Scheduler`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Scheduler.lua`
- **Use case:** ตั้งเวลา debounce/throttle
- **Public API:**
  - `Scheduler.After(delaySec: number, fn: ())`
  - `Scheduler.Every(intervalSec: number, fn: ())`
  - `Scheduler.Debounce(fn: (...any) -> (), waitSec: number) -> (...any) -> ()`
  - `Scheduler.Throttle(fn: (...any) -> (), waitSec: number) -> (...any) -> ()`
  - `Scheduler.Stopwatch()`
  - `Elapsed()`
  - `Reset()`

### `Serializer`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Serializer.lua`
- **Use case:** serialize ตารางสำหรับส่ง/เก็บข้อมูล
- **Public API:**
  - `Serializer.Encode(value: any)`
  - `Serializer.Decode(str: string)`
  - `Serializer.Pack(value: any)`
  - `Serializer.Unpack(value: any)`

### `Settings`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Settings.lua`
- **Use case:** Settings API สำหรับระบบ shared ของเกม
- **Public API:**
  - `Settings.Get(key: string)`
  - `Settings.GetAll()`
  - `Settings.Set(key: string, value: any)`

### `Signal`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Signal.lua`
- **Use case:** Signal API สำหรับระบบ shared ของเกม
- **Implementation:** first-party module at `Shared/Signal.lua`; inspect its returned table/type for the exact contract
- **Common calls:** only the exports documented in this file are compatibility surface; transitive `_Index` dependencies are not first-party API

### `Spring`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Spring.lua`
- **Use case:** Spring API สำหรับระบบ shared ของเกม
- **Implementation:** first-party module at `Shared/Spring.lua`; inspect its returned table/type for the exact contract
- **Common calls:** only the exports documented in this file are compatibility surface; transitive `_Index` dependencies are not first-party API

### `Symbol`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Symbol.lua`
- **Use case:** Symbol API สำหรับระบบ shared ของเกม
- **Implementation:** first-party module at `Shared/Symbol.lua`; inspect its returned table/type for the exact contract
- **Common calls:** only the exports documented in this file are compatibility surface; transitive `_Index` dependencies are not first-party API

### `TestRunner`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/TestRunner.lua`
- **Use case:** TestRunner API สำหรับระบบ shared ของเกม
- **Public API:**
  - `TestRunner.Expect(actual: any)`
  - `TestRunner.Suite(name: string, build: (suite: Suite))`
  - `TestRunner.RunAll(suites: { (suite: Suite) -> () }): { Result }`

### `Theme`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Theme.lua`
- **Use case:** Theme API สำหรับระบบ shared ของเกม
- **Public API:**
  - `Theme.Get()`
  - `Theme.Color(name: string)`
  - `Theme.Spacing(name: string)`
  - `Theme.Radius(name: string)`
  - `Theme.SetTheme(partial: { [string]: { [string]: any } })`
  - `Theme.OnThemeChanged(fn: (tokens: Tokens))`

### `Trove`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Trove.lua`
- **Use case:** Trove API สำหรับระบบ shared ของเกม
- **Implementation:** first-party module at `Shared/Trove.lua`; inspect its returned table/type for the exact contract
- **Common calls:** only the exports documented in this file are compatibility surface; transitive `_Index` dependencies are not first-party API

### `TweenUtil`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/TweenUtil.lua`
- **Use case:** สร้างและ chain tween
- **Public API:**
  - `TweenUtil.Create(instance: Instance, infoOrTable: TweenInfoLike, props: { [string]: any })`
  - `TweenUtil.Play(instance: Instance, infoOrTable: TweenInfoLike, props: { [string]: any })`
  - `TweenUtil.PlayAsync(instance: Instance, infoOrTable: TweenInfoLike, props: { [string]: any })`
  - `TweenUtil.Chain(steps: { ChainStep })`

### `Debug`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Util/Debug.lua`
- **Use case:** Debug API สำหรับระบบ shared ของเกม
- **Public API:**
  - `Debug.Stringify(value: any, indent: number?)`
  - `Debug.PrettyPrint(value: any, indent: number?)`
  - `Debug.Trace()`
  - `Debug.Watch(instance: Instance, propertyName: string)`
  - `Debug.Assert(condition: any, message: string?, level: number?)`

### `Instance`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Util/Instance.lua`
- **Use case:** Instance API สำหรับระบบ shared ของเกม
- **Public API:**
  - `InstanceUtil.WaitForDescendant(parent: Instance, name: string, timeout: number?)`
  - `InstanceUtil.GetTaggedDescendants(parent: Instance, tag: string)`
  - `InstanceUtil.SafeDestroy(instance: Instance?)`
  - `InstanceUtil.SetProperties(instance: Instance, props: {[string]: any})`
  - `InstanceUtil.Clone(instance: Instance, parent: Instance?, props: {[string]: any}?)`
  - `InstanceUtil.FindFirstAncestorWithTag(instance: Instance, tag: string)`
  - `InstanceUtil.GetAttributes(instance: Instance)`
  - `InstanceUtil.IsDescendantOfAny(instance: Instance, ancestors: {Instance})`

### `Math`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Util/Math.lua`
- **Use case:** Math API สำหรับระบบ shared ของเกม
- **Public API:**
  - `Math.Lerp(a: number, b: number, t: number)`
  - `Math.InverseLerp(a: number, b: number, v: number)`
  - `Math.Round(n: number, places: number?)`
  - `Math.RoundToNearest(n: number, multiple: number)`
  - `Math.Clamp(n: number, min: number, max: number)`
  - `Math.MapRange(value: number, inMin: number, inMax: number, outMin: number, outMax: number)`
  - `Math.RandomFloat(min: number, max: number)`
  - `Math.RandomInt(min: number, max: number)`
  - `Math.Sign(n: number)`
  - `Math.IsNaN(n: number)`
  - `Math.Approximately(a: number, b: number, epsilon: number?)`
  - `Math.Snap(n: number, gridSize: number)`

### `Player`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Util/Player.lua`
- **Use case:** Player API สำหรับระบบ shared ของเกม
- **Public API:**
  - `PlayerUtil.GetCharacter(player: Player, timeout: number?)`
  - `PlayerUtil.GetHumanoid(player: Player, timeout: number?)`
  - `PlayerUtil.GetHRP(player: Player, timeout: number?)`
  - `PlayerUtil.IsAlive(player: Player)`
  - `PlayerUtil.Teleport(player: Player, cframe: CFrame)`
  - `PlayerUtil.OnCharacterAdded(player: Player, fn: (Model))`
  - `PlayerUtil.ForEachPlayer(fn: (Player))`
  - `PlayerUtil.OnPlayerAdded(fn: (Player))`

### `String`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Util/String.lua`
- **Use case:** String API สำหรับระบบ shared ของเกม
- **Public API:**
  - `String.Trim(s: string)`
  - `String.TrimStart(s: string)`
  - `String.TrimEnd(s: string)`
  - `String.Split(s: string, sep: string)`
  - `String.StartsWith(s: string, prefix: string)`
  - `String.EndsWith(s: string, suffix: string)`
  - `String.Contains(s: string, sub: string)`
  - `String.FormatNumber(n: number)`
  - `String.FormatTime(seconds: number)`
  - `String.FormatCommas(n: number)`
  - `String.Pluralize(word: string, count: number)`
  - `String.Capitalize(s: string)`
  - `String.Lower(s: string)`
  - `String.Upper(s: string)`
  - `String.Repeat(s: string, n: number)`
  - `String.RandomString(length: number, charset: string?)`

### `Table`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Shared/Util/Table.lua`
- **Use case:** Table API สำหรับระบบ shared ของเกม
- **Implementation:** first-party module at `Shared/Util/Table.lua`; inspect its returned table/type for the exact contract
- **Common calls:** only the exports documented in this file are compatibility surface; transitive `_Index` dependencies are not first-party API

## Client APIs

โหลดผ่าน namespace ที่ระบุใน loader; หน้าที่หลัก: Client.

### `CameraController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/CameraController.lua`
- **Use case:** camera shake/FOV
- **Public API:**
  - `CameraController.GetCamera()`
  - `CameraController.Shake(intensity: number, duration: number)`
  - `CameraController.SetFOV(fov: number, duration: number?)`
  - `CameraController.ResetFOV(duration: number?)`

### `ChatFeedback`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/ChatFeedback.lua`
- **Use case:** ChatFeedback API สำหรับระบบ client ของเกม
- **Public API:** module export ไม่มี function declaration แบบ static; ตรวจค่าที่ return ใน source ก่อนใช้

### `ClientAntiCheat`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/ClientAntiCheat.lua`
- **Use case:** ClientAntiCheat API สำหรับระบบ client ของเกม
- **Public API:** module export ไม่มี function declaration แบบ static; ตรวจค่าที่ return ใน source ก่อนใช้

### `CutsceneSystem`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/CutsceneSystem.lua`
- **Use case:** ลำดับ cutscene
- **Public API:**
  - `Module.IsPlaying()`
  - `Module.Stop()`
  - `Module.Play(steps: { CutsceneStep })`

### `DebugConsole`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/DebugConsole.lua`
- **Use case:** DebugConsole API สำหรับระบบ client ของเกม
- **Public API:**
  - `DebugConsole.AddPanel(name: string, getValue: ())`
  - `DebugConsole.RemovePanel(name: string)`
  - `DebugConsole.Show()`
  - `DebugConsole.Hide()`
  - `DebugConsole.Toggle()`
  - `DebugConsole.SetToggleKey(keyCode: Enum.KeyCode)`

### `DialogSystem`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/DialogSystem.lua`
- **Use case:** บทสนทนาและ choice UI
- **Public API:**
  - `Module.IsOpen()`
  - `Module.Close()`
  - `Module.Show(config: DialogConfig)`

### `EffectsController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/EffectsController.lua`
- **Use case:** EffectsController API สำหรับระบบ client ของเกม
- **Public API:**
  - `EffectsController.EmitParticle(template: ParticleEmitter, atCFrame: CFrame, count: number?)`
  - `EffectsController.SpawnBeam(template : Beam, fromAttachment : Attachment, toAttachment : Attachment, lifetime : number?)`
  - `EffectsController.SpawnTrail(template : Trail, parent : BasePart, lifetime : number?)`
  - `EffectsController.ClearAll()`

### `InputManager`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/InputManager.lua`
- **Use case:** map input action เป็น callback
- **Public API:**
  - `InputManager.Bind(name : string, keys : { Enum.KeyCode | Enum.UserInputType }, callback : (name: string, state: ActionState))`
  - `InputManager.Unbind(name: string)`
  - `InputManager.Rebind(name: string, newKeys: { Enum.KeyCode | Enum.UserInputType })`
  - `InputManager.IsHeld(name: string)`
  - `InputManager.GetBindings()`

### `PromptManager`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/PromptManager.lua`
- **Use case:** PromptManager API สำหรับระบบ client ของเกม
- **Public API:**
  - `PromptManager.SetCurrentPrompt(self: PromptManager, prompt: ProximityPrompt?)`
  - `PromptManager.GetCurrentPrompt(self: PromptManager)`
  - `PromptManager.ManualHoldCurrent(self: PromptManager)`
  - `PromptManager.ManualStopHoldCurrent(self: PromptManager)`
  - `PromptManager.Clear(self: PromptManager)`
  - `PromptManager.Destroy(self: PromptManager)`

### `SoundController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/SoundController.lua`
- **Use case:** เล่นเสียงและจัดการ music/category
- **Public API:**
  - `SoundController.Preload(soundIds: { string })`
  - `SoundController.Play(soundId: string, props: { [string]: any }?)`
  - `SoundController.PlayOnce(soundId: string, props: { [string]: any }?)`
  - `SoundController.SetCategoryVolume(category: Category, volume: number)`
  - `SoundController.GetCategoryVolume(category: Category)`
  - `SoundController.StopAll(category: Category?)`
  - `SoundController.PlayMusic(soundId: string, fadeIn: number?)`
  - `SoundController.StopMusic(fadeOut: number?)`

### `TooltipSystem`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/TooltipSystem.lua`
- **Use case:** tooltip บน GUI
- **Public API:**
  - `Module.SetDelay(seconds: number)`
  - `Module.Attach(target: GuiObject, text: string | ())`
  - `Module.Detach(target: GuiObject)`

### `Accessibility`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/Accessibility.lua`
- **Use case:** การตั้งค่าการเข้าถึง
- **Public API:**
  - `Accessibility.SetColorblindMode(mode: string)`
  - `Accessibility.SetTextScale(scale: number)`
  - `Accessibility.GetTextScale()`
  - `Accessibility.SetHighContrast(on: boolean)`
  - `Accessibility.SetReducedMotion(on: boolean)`
  - `Accessibility.ReducedMotion()`
  - `Accessibility.Get()`
  - `Accessibility.OnChanged(fn: (s: Settings))`
  - `SetColorblindMode()`
  - `SetTextScale()`
  - `GetTextScale()`
  - `SetHighContrast()`
  - `SetReducedMotion()`
  - `ReducedMotion()`
  - `Get()`
  - `OnChanged()`

### `AdminPanel`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/AdminPanel.lua`
- **Use case:** AdminPanel API สำหรับระบบ client ของเกม
- **Public API:**
  - `Panel.Open()`
  - `Panel.Close()`
  - `Panel.Toggle()`
  - `Panel.SetRole(roleHint: any)`
  - `Open()`
  - `Close()`
  - `Toggle()`
  - `SetRole(_)`
  - `OnClick()`
  - `OnChanged(_index: number, name: string)`
  - `Render(item: any, _index: number, frame: Frame)`

### `Components`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/Components.lua`
- **Use case:** Components API สำหรับระบบ client ของเกม
- **Public API:**
  - `Components.Button(props: ButtonProps)`
  - `Components.Toggle(props: ToggleProps)`
  - `Components.Slider(props: SliderProps)`
  - `Components.TextInput(props: TextInputProps)`
  - `Components.Dropdown(props: DropdownProps)`
  - `Components.Tabs(props: TabsProps)`
  - `Components.ScrollList(props: ScrollListProps)`
  - `Components.Modal(props: ModalProps)`

### `FriendListPanel`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/FriendListPanel.lua`
- **Use case:** FriendListPanel API สำหรับระบบ client ของเกม
- **Public API:**
  - `Panel.Open()`
  - `Panel.Close()`
  - `Panel.Toggle()`
  - `Open()`
  - `Close()`
  - `Toggle()`

### `GamepadNav`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/GamepadNav.lua`
- **Use case:** GamepadNav API สำหรับระบบ client ของเกม
- **Public API:**
  - `GamepadNav.SolveLinks(centers: { Vector2 })`
  - `GamepadNav.AutoLink(elements: { GuiObject })`
  - `GamepadNav.Focus(e: GuiObject)`
  - `GamepadNav.Clear()`
  - `GamepadNav.Current()`
  - `GamepadNav.IsGamepadActive()`
  - `GamepadNav.OnInputTypeChanged(fn: (isGamepad: boolean))`
  - `AutoLink()`
  - `Focus()`
  - `Clear()`
  - `Current()`
  - `IsGamepadActive()`
  - `OnInputTypeChanged()`

### `GuildPanel`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/GuildPanel.lua`
- **Use case:** GuildPanel API สำหรับระบบ client ของเกม
- **Public API:**
  - `Panel.Open()`
  - `Panel.Close()`
  - `Panel.Toggle()`
  - `Open()`
  - `Close()`
  - `Toggle()`

### `Haptics`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/Haptics.lua`
- **Use case:** Haptics API สำหรับระบบ client ของเกม
- **Public API:**
  - `Haptics.IsSupported()`
  - `Haptics.IsEnabled()`
  - `Haptics.SetEnabled(on: boolean)`
  - `Haptics.Stop()`
  - `Haptics.Pulse(intensity: number, duration: number?)`
  - `Haptics.Play(name: string)`
  - `Haptics.RegisterPattern(name: string, steps: { Step })`
  - `Haptics.GetPatterns()`
  - `Pulse()`
  - `Play()`
  - `Stop()`
  - `SetEnabled()`
  - `IsEnabled()`
  - `IsSupported()`
  - `RegisterPattern()`
  - `GetPatterns()`

### `HealthBarController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/HealthBarController.lua`
- **Use case:** HealthBarController API สำหรับระบบ client ของเกม
- **Public API:**
  - `HealthBarController.Attach(humanoid: Humanoid, parent: GuiBase2d?)`
  - `Update(_: number, _: number)`
  - `Destroy()`
  - `Update(current: number, max: number)`

### `HUDController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/HUDController.lua`
- **Use case:** HUDController API สำหรับระบบ client ของเกม
- **Public API:**
  - `HUDController.AddText(name: string, getValue: ())`
  - `HUDController.Remove(name: string)`
  - `HUDController.SetVisible(visible: boolean)`

### `InventoryController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/InventoryController.lua`
- **Use case:** InventoryController API สำหรับระบบ client ของเกม
- **Public API:**
  - `InventoryController.Close()`
  - `InventoryController.Open(items: { InventoryItem })`

### `InviteToast`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/InviteToast.lua`
- **Use case:** InviteToast API สำหรับระบบ client ของเกม
- **Public API:** module export ไม่มี function declaration แบบ static; ตรวจค่าที่ return ใน source ก่อนใช้

### `LoadingScreenController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/LoadingScreenController.lua`
- **Use case:** LoadingScreenController API สำหรับระบบ client ของเกม
- **Public API:**
  - `LoadingScreenController.Show()`
  - `LoadingScreenController.Hide()`
  - `LoadingScreenController.SetProgress(alpha: number)`
  - `LoadingScreenController.SetStatus(text: string)`
  - `Show()`
  - `Hide()`
  - `SetProgress(_: number)`
  - `SetStatus(_: string)`

### `MenuController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/MenuController.lua`
- **Use case:** MenuController API สำหรับระบบ client ของเกม
- **Public API:**
  - `MenuController.Open(menuName: string, builder: ((content: ScrollingFrame) -> ())?) -> Frame?`
  - `Close(menuName: string)`

### `Motion`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/Motion.lua`
- **Use case:** Motion API สำหรับระบบ client ของเกม
- **Public API:**
  - `Motion.FadeIn(gui: GuiObject, dur: number?)`
  - `Motion.FadeOut(gui: GuiObject, dur: number?)`
  - `Motion.SlideIn(gui: GuiObject, direction: string?, dur: number?)`
  - `Motion.Pop(gui: GuiObject, dur: number?)`
  - `Motion.Shake(gui: GuiObject, intensity: number?, dur: number?)`
  - `Motion.Sequence(steps: { () -> () }, onComplete: (() -> ())?) -> ()`
  - `Motion.Stagger(guis: { GuiObject }, presetFn: (gui: GuiObject) -> Tween, gap: number?) -> ()`

### `NotificationService`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/NotificationService.lua`
- **Use case:** NotificationService API สำหรับระบบ client ของเกม
- **Public API:**
  - `NotificationService.Notify(title: string, message: string, duration: number?, notifType: string?)`

### `PetController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/PetController.lua`
- **Use case:** PetController API สำหรับระบบ client ของเกม
- **Public API:**
  - `PetController.Close()`
  - `PetController.Open()`
  - `PetController.Toggle()`
  - `Open()`
  - `Close()`
  - `Toggle()`

### `RebindMenu`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/RebindMenu.lua`
- **Use case:** RebindMenu API สำหรับระบบ client ของเกม
- **Public API:**
  - `RebindMenu.KeyName(key: any)`
  - `RebindMenu.CaptureNext(onCaptured: (key: any, cancelled: boolean))`
  - `RebindMenu.Build(opts: BuildOpts?)`
  - `CaptureNext()`
  - `Build()`

### `Responsive`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/Responsive.lua`
- **Use case:** Responsive API สำหรับระบบ client ของเกม
- **Public API:**
  - `Responsive.ComputeScale(viewport: Vector2, ref: Vector2?)`
  - `Responsive.ClassifyDevice(viewportX: number, touch: boolean, tenFoot: boolean)`
  - `Responsive.GetViewport()`
  - `Responsive.GetDeviceClass()`
  - `Responsive.Apply(gui: Instance) -> UIScale`
  - `Responsive.OnChanged(fn: () -> ()) -> RBXScriptConnection?`
  - `Responsive.SafeArea()`

### `Router`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/Router.lua`
- **Use case:** Router API สำหรับระบบ client ของเกม
- **Public API:**
  - `Router.Register(name: string, builder: (props: any))`
  - `Router.Push(name: string, props: any?)`
  - `Router.Pop()`
  - `Router.Replace(name: string, props: any?)`
  - `Router.Clear()`
  - `Router.Current()`
  - `Router.IsOpen(name: string)`
  - `Router.Depth()`
  - `Register()`
  - `Push()`
  - `Pop()`
  - `Replace()`
  - `Clear()`
  - `Current()`
  - `IsOpen()`
  - `Depth()`

### `StateBinding`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/StateBinding.lua`
- **Use case:** StateBinding API สำหรับระบบ client ของเกม
- **Public API:**
  - `StateBinding.Bind(gui: Instance, property: string, state: any, key: string, transform: ((value: any) -> any)?) -> Unbind`
  - `StateBinding.BindText(label: Instance, state: any, key: string, format: ((value: any) -> string)?) -> Unbind`
  - `Bind()`
  - `BindText()`

### `Templates`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/Templates.lua`
- **Use case:** Templates API สำหรับระบบ client ของเกม
- **Public API:**
  - `Templates.ButtonTemplate(parent: Instance?)`
  - `Templates.FrameTemplate(parent: Instance?)`
  - `Templates.HealthBarTemplate(parent: Instance?)`
  - `Templates.NotificationTemplate(parent: Instance?)`
  - `Templates.MenuTemplate(parent: Instance?)`
  - `Templates.InventoryTemplate(parent: Instance?)`
  - `Templates.DialogTemplate(parent: Instance?)`
  - `Templates.TooltipTemplate(parent: Instance?)`
  - `Templates.LoadingScreenTemplate(parent: Instance?)`
  - `Templates.ConfirmDialogTemplate(parent: Instance?)`

### `Toast`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/Toast.lua`
- **Use case:** Toast API สำหรับระบบ client ของเกม
- **Public API:**
  - `Toast.Show(opt: ToastOpts)`
  - `Toast.SetMaxVisible(n: number)`
  - `Toast.Clear()`
  - `Toast.Stats()`
  - `Show()`
  - `SetMaxVisible()`
  - `Clear()`
  - `Stats()`

### `UIController`

- **Source:** `src/ReplicatedStorage/Gaxia_Packages/Client/UI/UIController.lua`
- **Use case:** lifecycle ของ UI
- **Public API:**
  - `UIController.GetActiveScreen()`
  - `UIController.HUD()`
  - `UIController.Overlays()`
  - `UIController.CloneTemplate(templateName: string, parent: Instance?)`

## Server APIs

โหลดผ่าน namespace ที่ระบุใน loader; หน้าที่หลัก: Server.

### `AchievementSystem`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/AchievementSystem.lua`
- **Use case:** AchievementSystem API สำหรับระบบ server ของเกม
- **Public API:**
  - `AchievementSystem.Register(def: AchievementDef)`
  - `AchievementSystem.Award(player: Player, id: string)`
  - `AchievementSystem.IsUnlocked(player: Player, id: string)`
  - `AchievementSystem.GetUnlocked(player: Player)`
  - `AchievementSystem.Track(player: Player, eventType: string, ...: any)`

### `AdminCommands`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/AdminCommands.lua`
- **Use case:** AdminCommands API สำหรับระบบ server ของเกม
- **Public API:**
  - `AdminCommands.GetRole(player: Player)`
  - `AdminCommands.SetRole(userId: number, role: string)`
  - `AdminCommands.IsAtLeast(player: Player, role: string)`
  - `AdminCommands.GetRoleForUserId(userId: number)`
  - `AdminCommands.IsUserIdAtLeast(userId: number, role: string)`
  - `AdminCommands.Register(name: string, opts: CommandOpts, handler: (caller: Player, args: { string }))`
  - `AdminCommands.Run(caller: Player, name: string, argList: { string })`
  - `AdminCommands.ProtectTarget(caller: Player, target: Player)`

### `AIService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/AIService.lua`
- **Use case:** AIService API สำหรับระบบ server ของเกม
- **Public API:**
  - `AIService.ComputePath(from: Vector3, to: Vector3, agentParams: { [string]: any }?)`
  - `AIService.MoveTo(model: Model, target: Vector3, agentParams: { [string]: any }?)`
  - `AIService.Stop(model: Model)`
  - `AIService.IsMoving(model: Model)`
  - `AIService.Roam(model: Model, center: Vector3, radius: number)`
  - `AIService.Follow(model: Model, target: Instance, opts: { Interval: number?, StopDistance: number? }?)`

### `AnalyticsService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/AnalyticsService.lua`
- **Use case:** AnalyticsService API สำหรับระบบ server ของเกม
- **Public API:**
  - `Analytics.SetSink(fn: (player: Player, event: string, props: { [string]: any }))`
  - `Analytics.Track(player: Player, event: string, props: { [string]: any }?)`

### `AnimationService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/AnimationService.lua`
- **Use case:** AnimationService API สำหรับระบบ server ของเกม
- **Public API:**
  - `AnimationService.Register(name: string, animationId: string)`
  - `AnimationService.RegisterMany(map: { [string]: string })`
  - `AnimationService.Play(model: Instance, name: string, opts: PlayOpts?)`
  - `AnimationService.Stop(model: Instance, name: string, fadeTime: number?)`
  - `AnimationService.StopAll(model: Instance, fadeTime: number?)`
  - `AnimationService.IsPlaying(model: Instance, name: string)`
  - `AnimationService.OnMarker(track: AnimationTrack, markerName: string, fn: (value: string?))`

### `AntiCheatAdmin`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/AntiCheatAdmin.lua`
- **Use case:** AntiCheatAdmin API สำหรับระบบ server ของเกม
- **Public API:**
  - `AntiCheatAdmin.Register()`

### `AntiCheatEnforcement`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/AntiCheatEnforcement.lua`
- **Use case:** AntiCheatEnforcement API สำหรับระบบ server ของเกม
- **Public API:**
  - `Enforcement.GetMode()`
  - `Enforcement.SetMode(nextMode: string)`
  - `Enforcement.Start(antiCheat: any, ban: BanAdapter)`

### `AntiCheatJournal`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/AntiCheatJournal.lua`
- **Use case:** AntiCheatJournal API สำหรับระบบ server ของเกม
- **Public API:**
  - `Journal.SetSink(fn: (entry: Entry))`
  - `Journal.GetRecent(n: number?)`
  - `Journal.GetForPlayer(player: Player)`
  - `Journal.Clear()`

### `BanService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/BanService.lua`
- **Use case:** BanService API สำหรับระบบ server ของเกม
- **Public API:**
  - `BanService.IsBanned(userId: number)`
  - `BanService.Ban(userId: number, reason: string, durationSec: number?)`
  - `BanService.Unban(userId: number)`
  - `BanService.ListBans(maxCount: number?)`
  - `BanService.IsEscalationExempt(userId: number)`

### `ChatCommandSystem`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/ChatCommandSystem.lua`
- **Use case:** ChatCommandSystem API สำหรับระบบ server ของเกม
- **Public API:**
  - `ChatCommandSystem.ParseArgs(typeList: { string }, argList: { string })`
  - `ChatCommandSystem.Register(name: string, opts: CmdOpts, handler: (caller: Player, args: { string }))`
  - `ChatCommandSystem.Run(caller: Player, raw: string)`

### `CodexService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/CodexService.lua`
- **Use case:** CodexService API สำหรับระบบ server ของเกม
- **Public API:**
  - `CodexService.Register(entryId: string, def: EntryDef?)`
  - `CodexService.RegisterMany(defs: { [string]: EntryDef })`
  - `CodexService.DefineSet(setName: string, entryIds: { string }, reward: any?)`
  - `CodexService.IsRegistered(entryId: string)`
  - `CodexService.GetCatalogSize()`
  - `CodexService.Discover(player: Player, entryId: string, amount: number?)`
  - `CodexService.Has(player: Player, entryId: string)`
  - `CodexService.GetCount(player: Player, entryId: string)`
  - `CodexService.GetEntry(player: Player, entryId: string)`
  - `CodexService.GetDiscoveredCount(player: Player)`
  - `CodexService.GetCompletion(player: Player)`
  - `CodexService.IsSetComplete(player: Player, setName: string)`

### `CooldownService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/CooldownService.lua`
- **Use case:** cooldown ต่อผู้เล่น/การกระทำ
- **Public API:**
  - `CooldownService.Start(key: string, duration: number)`
  - `CooldownService.IsActive(key: string)`
  - `CooldownService.GetRemaining(key: string)`
  - `CooldownService.Consume(key: string, duration: number)`
  - `CooldownService.Clear(key: string)`
  - `CooldownService.Key(player: Player, action: string)`
  - `CooldownService.ConsumePlayer(player: Player, action: string, duration: number)`
  - `CooldownService.IsPlayerActive(player: Player, action: string)`
  - `CooldownService.GetPlayerRemaining(player: Player, action: string)`

### `CrossServerMessaging`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/CrossServerMessaging.lua`
- **Use case:** CrossServerMessaging API สำหรับระบบ server ของเกม
- **Public API:**
  - `CrossServerMessaging.Subscribe(topic: string, handler: (data: any, sentTimestamp: number))`
  - `CrossServerMessaging.Publish(topic: string, data: any)`

### `DailyRewardService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/DailyRewardService.lua`
- **Use case:** DailyRewardService API สำหรับระบบ server ของเกม
- **Public API:**
  - `DailyRewardService.ComputeClaim(lastClaim: number, now: number, currentStreak: number, dayLen: number, resetWindow: number?)`
  - `DailyRewardService.DefineLadder(rewards: { any }, opts: { Cycle: boolean? }?)`
  - `DailyRewardService.LadderDay(streak: number)`
  - `DailyRewardService.GetStreak(player: Player)`
  - `DailyRewardService.CanClaim(player: Player)`
  - `DailyRewardService.GetTimeUntilNext(player: Player)`
  - `DailyRewardService.Claim(player: Player)`

### `DataManager`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/DataManager/init.lua`
- **Use case:** โหลด/อ่าน/เขียน profile data
- **Public API:**
  - `DataManager.Get(player: Player, key: string?)`
  - `DataManager.Set(player: Player, key: string, value: any)`
  - `DataManager.WaitFor(player: Player, timeout: number?)`
  - `DataManager.IsLoaded(player: Player)`
  - `DataManager.Save(player: Player)`
  - `DataManager._SeedForTest(player: any, data: { [string]: any }?)` — **test-only; ห้ามใช้ใน production**
### `DataMigration`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/DataMigration.lua`
- **Use case:** DataMigration API สำหรับระบบ server ของเกม
- **Public API:**
  - `DataMigration.Register(fromVersion: number, toVersion: number, fn: MigrationFn)`
  - `DataMigration.SetCurrentVersion(v: number)`
  - `DataMigration.GetCurrentVersion()`
  - `DataMigration.Migrate(data: { [string]: any })`

### `EconomyService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/EconomyService.lua`
- **Use case:** เงินและธุรกรรมที่ตรวจสอบฝั่ง server
- **Public API:**
  - `EconomyService.Get(player: Player, currency: string)`
  - `EconomyService.Add(player: Player, currency: string, amount: number)`
  - `EconomyService.Spend(player: Player, currency: string, amount: number)`
  - `EconomyService.Set(player: Player, currency: string, amount: number)`
  - `EconomyService.Transfer(from: Player, to: Player, currency: string, amount: number)`

### `EffectiveConfig`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/EffectiveConfig.lua`
- **Use case:** EffectiveConfig API สำหรับระบบ server ของเกม
- **Public API:**
  - `EConfig.Get(flagKey: string, default: any)`
  - `EConfig.Enabled(flagKey: string, default: boolean)`
  - `EConfig.IsOverridden(flagKey: string)`
  - `EConfig.Set(flagKey: string, value: any)`
  - `EConfig.Clear(flagKey: string)`

### `EventService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/EventService.lua`
- **Use case:** EventService API สำหรับระบบ server ของเกม
- **Public API:**
  - `EventService.Define(eventId: string, def: EventDef)`
  - `EventService.GetData(eventId: string)`
  - `EventService.IsActive(eventId: string)`
  - `EventService.GetActive()`
  - `EventService.GetTimeRemaining(eventId: string)`
  - `EventService.GetTimeUntilStart(eventId: string)`
  - `EventService.PollTransitions()`

### `FriendService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/FriendService.lua`
- **Use case:** FriendService API สำหรับระบบ server ของเกม
- **Public API:**
  - `Friend.IsBlocked(player: any, otherUserId: number)`
  - `Friend.IsBlockedByUserId(blockerUserId: number, otherUserId: number)`
  - `Friend.SendRequest(from: any, toUserId: number)`
  - `Friend.AcceptRequest(player: any, fromUserId: number)`
  - `Friend.DeclineRequest(player: any, fromUserId: number)`
  - `Friend.Remove(player: any, otherUserId: number)`
  - `Friend.Block(player: any, otherUserId: number)`
  - `Friend.Unblock(player: any, otherUserId: number)`
  - `Friend.SetFavorite(player: any, otherUserId: number, fav: boolean)`
  - `Friend.GetList(player: any)`
  - `Friend.GetBlocks(player: any)`
  - `Friend.RefreshPresence(player: any)`

### `GuildLock`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/GuildLock.lua`
- **Use case:** GuildLock API สำหรับระบบ server ของเกม
- **Public API:**
  - `GuildLock.Acquire(guildId: string, ttlSec: number?)`
  - `GuildLock.Renew(guildId: string, ownerId: string, ttlSec: number)`
  - `GuildLock.Release(guildId: string, ownerId: string)`
  - `GuildLock.WithLock(guildId: string, fn: ())`

### `GuildService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/GuildService.lua`
- **Use case:** guild membership/role/vault
- **Public API:**
  - `Guild.Create(leader: any, name: string, tag: string)`
  - `Guild.GetGuild(player: any)`
  - `Guild.GetById(guildId: string)`
  - `Guild.GetMembers(guildId: string)`
  - `Guild.IsMember(player: any, guildId: string?)`
  - `Guild.RoleOf(player: any)`
  - `Guild.Invite(officer: any, targetUserId: number)`
  - `Guild.GetPendingInvites(player: any)`
  - `Guild.AcceptInvite(player: any, guildId: string)`
  - `Guild.DeclineInvite(player: any, guildId: string)`
  - `Guild.Kick(actor: any, targetUserId: number)`
  - `Guild.Promote(owner: any, userId: number)`
  - `Guild.Demote(owner: any, userId: number)`
  - `Guild.Transfer(owner: any, newOwnerUserId: number)`
  - `Guild.Leave(player: any)`
  - `Guild.Disband(player: any)`
  - `Guild.SetDescription(actor: any, text: string)`
  - `Guild.VaultGetContents(player: any)`
  - `Guild.VaultGetUsed(player: any)`
  - `Guild.VaultGetCapacity(_player: any)`
  - `Guild.VaultDeposit(player: any, itemId: string, count: number?)`
  - `Guild.VaultWithdraw(player: any, itemId: string, count: number?)`

### `IdleService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/IdleService.lua`
- **Use case:** IdleService API สำหรับระบบ server ของเกม
- **Public API:**
  - `IdleService.ComputeOffline(lastSeen: number, now: number, rate: number, maxOffline: number, cap: number)`
  - `IdleService.Configure(player: Player, cfg: IdleConfig)`
  - `IdleService.SetRate(player: Player, rate: number)`
  - `IdleService.GetRate(player: Player)`
  - `IdleService.GetPending(player: Player)`
  - `IdleService.Collect(player: Player)`
  - `IdleService.RecordSeen(player: Player)`

### `InteractionService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/InteractionService.lua`
- **Use case:** InteractionService API สำหรับระบบ server ของเกม
- **Public API:**
  - `InteractionService.Register(target: Instance, config: InteractionConfig)`
  - `handle.Destroy()`

### `InventoryService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/InventoryService.lua`
- **Use case:** ไอเท็มแบบ instance/stack/equipment
- **Public API:**
  - `InventoryService.DefineItem(itemId: string, def: ItemDef)`
  - `InventoryService.Add(player: Player, itemId: string, opts: AddOpts?)`
  - `InventoryService.Remove(player: Player, instanceId: string, count: number?)`
  - `InventoryService.Get(player: Player, instanceId: string)`
  - `InventoryService.List(player: Player)`
  - `InventoryService.GetByItemId(player: Player, itemId: string)`
  - `InventoryService.Equip(player: Player, instanceId: string, slot: string?)`
  - `InventoryService.Unequip(player: Player, slot: string)`
  - `InventoryService.GetEquipped(player: Player, slot: string)`
  - `InventoryService.IsEquipped(player: Player, instanceId: string)`
  - `InventoryService.GetEquipment(player: Player)`

### `InviteQueue`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/InviteQueue.lua`
- **Use case:** InviteQueue API สำหรับระบบ server ของเกม
- **Public API:**
  - `InviteQueue.Push(kind: string, toUserId: number, item: any, ttlSec: number)`
  - `InviteQueue.DrainFor(kind: string, userId: number)`

### `ItemDefinitionService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/ItemDefinitionService.lua`
- **Use case:** ItemDefinitionService API สำหรับระบบ server ของเกม
- **Public API:**
  - `ItemDefinitionService.Register(id: string, def: { [string]: any })`
  - `ItemDefinitionService.RegisterMany(map: { [string]: { [string]: any } })`
  - `ItemDefinitionService.Get(id: string)`
  - `ItemDefinitionService.Has(id: string)`
  - `ItemDefinitionService.GetField(id: string, field: string, default: any)`
  - `ItemDefinitionService.GetAll()`
  - `ItemDefinitionService.GetByCategory(category: string)`
  - `ItemDefinitionService.GetByRarity(rarity: string)`
  - `ItemDefinitionService.Count()`

### `ItemService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/ItemService.lua`
- **Use case:** ไอเท็มแบบจำนวนรวม
- **Public API:**
  - `ItemService.Give(player: Player, itemId: string, count: number?)`
  - `ItemService.Remove(player: Player, itemId: string, count: number?)`
  - `ItemService.Has(player: Player, itemId: string, count: number?)`
  - `ItemService.Count(player: Player, itemId: string)`
  - `ItemService.GetInventory(player: Player)`
  - `ItemService.Clear(player: Player, itemId: string)`

### `LeaderboardService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/LeaderboardService.lua`
- **Use case:** ordered leaderboard
- **Public API:**
  - `LeaderboardService.GetStore(name: string)`
  - `LeaderboardService.Update(name: string, userId: number, value: number)`
  - `LeaderboardService.GetTop(name: string, count: number?)`
  - `LeaderboardService.GetRank(name: string, userId: number)`

### `LevelSystem`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/LevelSystem.lua`
- **Use case:** XP/level
- **Public API:**
  - `LevelSystem.SetCurve(fn: (level: number) -> number)`
  - `LevelSystem.GetCurve()`
  - `LevelSystem.GetLevel(player: Player)`
  - `LevelSystem.GetXP(player: Player)`
  - `LevelSystem.GetXPToNext(player: Player)`
  - `LevelSystem.AddXP(player: Player, amount: number)`
  - `LevelSystem.SetLevel(player: Player, level: number)`

### `LootService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/LootService.lua`
- **Use case:** weighted loot/pity
- **Public API:**
  - `LootService.PickWeighted(weights: { number }, roll01: number)`
  - `LootService.DefineTable(tableId: string, entries: { LootEntry })`
  - `LootService.GetTable(tableId: string)`
  - `LootService.GetDropRates(tableId: string)`
  - `LootService.GetPity(player: Player, tableId: string, item: string)`
  - `LootService.Roll(player: Player, tableId: string)`

### `MailService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/MailService.lua`
- **Use case:** จดหมายและ claim attachment
- **Public API:**
  - `MailService.Send(toPlayer: Player, input: MailInput)`
  - `MailService.GetMailbox(player: Player)`
  - `MailService.GetUnreadCount(player: Player)`
  - `MailService.MarkRead(player: Player, mailId: string)`
  - `MailService.Claim(player: Player, mailId: string)`
  - `MailService.Delete(player: Player, mailId: string)`

### `MemoryStore`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/MemoryStore.lua`
- **Use case:** MemoryStore API สำหรับระบบ server ของเกม
- **Public API:**
  - `Memory.IsUsingFallback()`
  - `Memory.MapSet(mapName: string, key: string, value: any, ttl: number, sortKey: number?)`
  - `Memory.MapGet(mapName: string, key: string)`
  - `Memory.MapRemove(mapName: string, key: string)`
  - `Memory.MapRange(mapName: string, count: number, ascending: boolean?)`
  - `Memory.QueueAdd(queueName: string, value: any, ttl: number, priority: number?)`
  - `Memory.QueueRead(queueName: string, count: number)`
  - `Memory.QueueRemove(queueName: string, readId: string)`

### `MonetizationService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/MonetizationService.lua`
- **Use case:** developer product/game pass
- **Public API:**
  - `Monetization.RegisterProduct(productId: number, grantFn: (player: Player, receipt: any))`
  - `Monetization.PromptProduct(player: Player, productId: number)`
  - `Monetization.PromptGamePass(player: Player, gamePassId: number)`
  - `Monetization.OwnsGamePass(player: Player, gamePassId: number)`
  - `Monetization.HandleReceipt(receiptInfo: any)`

### `Motion3DService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/Motion3DService.lua`
- **Use case:** Motion3DService API สำหรับระบบ server ของเกม
- **Public API:**
  - `Motion3D.To(target: Instance, goal: CFrame, dur: number?, easing: Enum.EasingStyle?)`
  - `Motion3D.Path(target: Instance, waypoints: { CFrame }, durPerSegment: number?, easing: Enum.EasingStyle?)`
  - `Motion3D.Spin(part: BasePart, axis: Vector3?, degPerSec: number?)`
  - `Motion3D.Float(part: BasePart, amplitude: number?, period: number?)`

### `PartyService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/PartyService.lua`
- **Use case:** party และ matchmaking
- **Public API:**
  - `PartyService.SetMaxSize(n: number)`
  - `PartyService.Create(leader: any)`
  - `PartyService.GetParty(player: any)`
  - `PartyService.GetMembers(partyId: string)`
  - `PartyService.GetLeader(partyId: string)`
  - `PartyService.IsLeader(player: any)`
  - `PartyService.Join(player: any, partyId: string)`
  - `PartyService.Leave(player: any)`
  - `PartyService.Disband(leader: any)`
  - `PartyService.QueueForMatch(partyId: string, matchType: string, placeId: number)`
  - `PartyService.Unqueue(partyId: string, matchType: string)`
  - `PartyService.PollMatch(matchType: string, neededPlayers: number)`
  - `PartyService.StartMatch(partyId: string, placeId: number)`
  - `PartyService.Invite(leader: any, targetUserId: number)`
  - `PartyService.GetPendingInvites(player: any)`
  - `PartyService.CancelInvite(leader: any, targetUserId: number)`
  - `PartyService.DeclineInvite(player: any, partyId: string)`
  - `PartyService.AcceptInvite(player: any, partyId: string)`

### `PetService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/PetService.lua`
- **Use case:** pet ownership/equip/egg
- **Public API:**
  - `PetService.GetCoinMultiplier(player: Player)`
  - `PetService.GetOwned(player: Player)`
  - `PetService.GetEquipped(player: Player)`
  - `PetService.GrantPet(player: Player, petId: string)`
  - `PetService.BuyEgg(player: Player, eggId: string?)`
  - `PetService.Equip(player: Player, uid: string)`
  - `PetService.Unequip(player: Player, uid: string)`
  - `PetService.Snapshot(player: Player)`

### `PlacementService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/PlacementService.lua`
- **Use case:** grid placement
- **Public API:**
  - `PlacementService.SnapToGrid(worldPos: Vector3, cellSize: number, origin: Vector3?)`
  - `PlacementService.WorldToCell(plot: Plot, worldPos: Vector3)`
  - `PlacementService.CellToWorld(plot: Plot, gx: number, gz: number, footprint: Vector2?)`
  - `PlacementService.AssignPlot(player: Player, plot: Plot)`
  - `PlacementService.GetPlot(player: Player)`
  - `PlacementService.DefineObject(objectId: string, def: ObjectDef)`
  - `PlacementService.CanPlace(player: Player, objectId: string, gx: number, gz: number, rot: number?)`
  - `PlacementService.Place(player: Player, objectId: string, gx: number, gz: number, rot: number?)`
  - `PlacementService.Remove(player: Player, placementId: string)`
  - `PlacementService.GetPlacements(player: Player)`
  - `PlacementService.Rebuild(player: Player)`

### `PlayerService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/PlayerService.lua`
- **Use case:** leaderstats และ player helpers
- **Public API:**
  - `PlayerService.SetupLeaderstats(player: Player, dict: { [string]: any })`
  - `PlayerService.GetLeaderstat(player: Player, name: string)`
  - `PlayerService.SetLeaderstat(player: Player, name: string, value: any)`
  - `PlayerService.SetWalkSpeed(player: Player, speed: number)`
  - `PlayerService.SetJumpPower(player: Player, power: number)`
  - `PlayerService.Teleport(player: Player, cframe: CFrame)`
  - `PlayerService.ForEach(fn: (player: Player))`

### `ProtectionService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/ProtectionService.lua`
- **Use case:** ProtectionService API สำหรับระบบ server ของเกม
- **Public API:**
  - `ProtectionService.Grant(player: Player, duration: number)`
  - `ProtectionService.IsProtected(player: Player)`
  - `ProtectionService.GetRemaining(player: Player)`
  - `ProtectionService.Clear(player: Player)`

### `QuestSystem`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/QuestSystem.lua`
- **Use case:** quest progression และ reward
- **Public API:**
  - `QuestSystem.Register(def: QuestDef)`
  - `QuestSystem.Start(player: Player, questId: string)`
  - `QuestSystem.Track(player: Player, eventType: GoalType, target: string, count: number?)`
  - `QuestSystem.GetActive(player: Player)`
  - `QuestSystem.IsComplete(player: Player, questId: string)`
  - `QuestSystem.Abandon(player: Player, questId: string)`

### `RagdollService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/RagdollService.lua`
- **Use case:** RagdollService API สำหรับระบบ server ของเกม
- **Public API:**
  - `RagdollService.Enable(character: Instance)`
  - `RagdollService.Disable(character: Instance)`
  - `RagdollService.IsRagdolled(character: Instance)`
  - `RagdollService.Toggle(character: Instance)`
  - `RagdollService.WatchState(humanoid: Humanoid, fn: (old: Enum.HumanoidStateType, new: Enum.HumanoidStateType))`
  - `RagdollService.AutoRagdollOnDeath(character: Instance)`

### `RaidService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/RaidService.lua`
- **Use case:** RaidService API สำหรับระบบ server ของเกม
- **Public API:**
  - `RaidService.ComputeLoot(vaultValue: number, defenderBalance: number, fraction: number, maxLoot: number)`
  - `RaidService.Configure(partial: { [string]: any })`
  - `RaidService.GetRevengeTargets(player: any)`
  - `RaidService.IsRaiding(player: any)`
  - `RaidService.GetActiveRaid(player: any)`
  - `RaidService.CanRaid(attacker: any, defender: any)`
  - `RaidService.Start(attacker: any, defender: any)`
  - `RaidService.Resolve(raidId: string, success: boolean)`

### `RefineService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/RefineService.lua`
- **Use case:** RefineService API สำหรับระบบ server ของเกม
- **Public API:**
  - `RefineService.DefineRecipe(id: string, recipe: Recipe)`
  - `RefineService.DefineMany(defs: { [string]: Recipe })`
  - `RefineService.GetRecipe(id: string)`
  - `RefineService.ListRecipes()`
  - `RefineService.CanCraft(player: Player, recipeId: string)`
  - `RefineService.Craft(player: Player, recipeId: string)`
  - `RefineService.Begin(player: Player, recipeId: string)`
  - `RefineService.GetJobs(player: Player)`
  - `RefineService.GetTimeRemaining(player: Player, jobId: string)`
  - `RefineService.IsReady(player: Player, jobId: string)`
  - `RefineService.Claim(player: Player, jobId: string)`

### `ServiceLifecycle`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/ServiceLifecycle.lua`
- **Use case:** ServiceLifecycle API สำหรับระบบ server ของเกม
- **Public API:**
  - `ServiceLifecycle.Register(service: Service)`
  - `ServiceLifecycle.RegisterMany(services: { Service })`
  - `ServiceLifecycle.Start()`
  - `ServiceLifecycle.IsStarted()`
  - `ServiceLifecycle.OnStarted(fn: ())`

### `SettingsService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/SettingsService.lua`
- **Use case:** SettingsService API สำหรับระบบ server ของเกม
- **Public API:**
  - `SettingsService.RegisterSetting(key: string, validator: (value: any))`
  - `SettingsService.Get(player: Player, key: string)`
  - `SettingsService.GetAll(player: Player)`
  - `SettingsService.Set(player: Player, key: string, value: any)`

### `SFXService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/SFXService.lua`
- **Use case:** server-side sound registry
- **Public API:**
  - `SFXService.ComputePitch(base: number, variation: number, roll01: number)`
  - `SFXService.Register(name: string, def: SoundDef)`
  - `SFXService.SetCategoryVolume(category: string, volume: number)`
  - `SFXService.GetCategoryVolume(category: string)`
  - `SFXService.Duck(category: string, factor: number, duration: number)`
  - `SFXService.PlayAt(name: string, position: Vector3)`
  - `SFXService.Play2D(name: string)`

### `ShopService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/ShopService.lua`
- **Use case:** ShopService API สำหรับระบบ server ของเกม
- **Public API:**
  - `Shop.RegisterItem(id: string, def: ShopItem)`
  - `Shop.Get(id: string)`
  - `Shop.GetCatalog()`
  - `Shop.Purchase(player: Player, id: string)`

### `TeleportService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/TeleportService.lua`
- **Use case:** teleport และ reserved server
- **Public API:**
  - `Teleport.Configure(partial: { [string]: any })`
  - `Teleport.ComputeBackoff(attempt: number, base: number, maxDelay: number)`
  - `Teleport.To(players: any, placeId: number, opts: TeleportOpts?)`
  - `Teleport.ReserveServer(placeId: number)`
  - `Teleport.ToPrivate(players: any, placeId: number, accessCode: string, opts: TeleportOpts?)`
  - `Teleport.GetArrivingData(player: Player)`
  - `Teleport.GetPlaceInstance(placeId: number, userId: number)`

### `ToolService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/ToolService.lua`
- **Use case:** ToolService API สำหรับระบบ server ของเกม
- **Public API:**
  - `ToolService.Create(itemId: string, props: { [string]: any }?)`
  - `ToolService.Give(player: Player, itemId: string, props: { [string]: any }?)`
  - `ToolService.Track(tool: Tool)`
  - `ToolService.IsTracked(tool: Tool)`

### `TradeService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/TradeService.lua`
- **Use case:** ข้อเสนอแลกเปลี่ยนแบบ confirm
- **Public API:**
  - `TradeService.Request(from: any, to: any)`
  - `TradeService.GetActiveTrade(player: any)`
  - `TradeService.GetTrade(tradeId: string)`
  - `TradeService.AddItem(player: any, tradeId: string, itemId: string, count: number)`
  - `TradeService.RemoveItem(player: any, tradeId: string, itemId: string, count: number?)`
  - `TradeService.AddCurrency(player: any, tradeId: string, currency: string, amount: number)`
  - `TradeService.RemoveCurrency(player: any, tradeId: string, currency: string, amount: number?)`
  - `TradeService.IsConfirmed(player: any, tradeId: string)`
  - `TradeService.Confirm(player: any, tradeId: string)`
  - `TradeService.Cancel(player: any, tradeId: string)`

### `VaultService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/VaultService.lua`
- **Use case:** VaultService API สำหรับระบบ server ของเกม
- **Public API:**
  - `VaultService.SetItemValue(itemId: string, value: number)`
  - `VaultService.GetItemValue(itemId: string)`
  - `VaultService.GetCapacity(player: Player)`
  - `VaultService.SetCapacity(player: Player, n: number)`
  - `VaultService.AddCapacity(player: Player, delta: number)`
  - `VaultService.GetContents(player: Player)`
  - `VaultService.GetCount(player: Player, itemId: string)`
  - `VaultService.GetUsed(player: Player)`
  - `VaultService.GetFree(player: Player)`
  - `VaultService.GetValue(player: Player)`
  - `VaultService.Deposit(player: Player, itemId: string, count: number?)`
  - `VaultService.Withdraw(player: Player, itemId: string, count: number?)`

### `VFXService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/VFXService.lua`
- **Use case:** effect registry/pool
- **Public API:**
  - `VFXService.Register(name: string, build: EffectBuilder)`
  - `VFXService.PreWarm(name: string, n: number)`
  - `VFXService.GetPoolSize(name: string)`
  - `VFXService.PlayAt(name: string, where: any, opts: PlayOpts?)`
  - `VFXService.Attach(name: string, host: BasePart, opts: PlayOpts?)`

### `VisitService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/VisitService.lua`
- **Use case:** VisitService API สำหรับระบบ server ของเกม
- **Public API:**
  - `VisitService.Start(visitor: Player, hostUserId: number)`
  - `VisitService.End(visitor: Player)`
  - `VisitService.IsVisiting(visitor: Player)`
  - `VisitService.GetHost(visitor: Player)`
  - `VisitService.GetVisitorsOf(hostUserId: number)`
  - `VisitService.CanModify(player: Player, baseOwnerUserId: number)`

### `WebhookService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/WebhookService.lua`
- **Use case:** WebhookService API สำหรับระบบ server ของเกม
- **Public API:**
  - `Webhook.SetTransport(fn: (url: string, body: string))`
  - `Webhook.SendUrl(url: string, payload: any)`
  - `Webhook.Send(channel: string, payload: any)`
  - `Webhook.IsConfigured(channel: string)`
  - `Webhook.Embed(opts: EmbedOpts)`
  - `Webhook.Discord(channel: string, opts: DiscordOpts)`

### `ZoneService`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/Lib/ZoneService.lua`
- **Use case:** ZoneService API สำหรับระบบ server ของเกม
- **Implementation:** compatibility wrapper; API มาจาก dependency ที่ถูก pin ใน `Packages/_Index`
- **Common calls:** ดู dependency module/type ที่ wrapper ชี้ไปก่อนใช้งาน

## AntiCheat APIs

โหลดผ่าน namespace ที่ระบุใน loader; หน้าที่หลัก: AntiCheat.

> **Boundary:** `GaxiaServer.AntiCheat` คือ orchestrator ที่ loader expose โดยตรงเท่านั้น. Modules ด้านล่างเป็น internal detector modules ที่ orchestrator โหลดภายใน; ไม่ใช่ `GaxiaServer.<DetectorName>` และห้าม require เป็น production contract โดยตรง. รายการนี้มีไว้เพื่ออธิบาย implementation/extension boundary เท่านั้น.

### `AnimationGuard`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/AnimationGuard.lua`
- **Use case:** AnimationGuard API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `AnimationGuard.Allow(id: string)`
  - `AnimationGuard.Init(orchestrator: any)`

### `BackpackGuard`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/BackpackGuard.lua`
- **Use case:** BackpackGuard API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `BackpackGuard.Init(orchestrator: any)`

### `CombatGuard`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/CombatGuard.lua`
- **Use case:** CombatGuard API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `CombatGuard.RegisterDamage(victim: Player | Humanoid, amount: number)`
  - `CombatGuard.Init(orchestrator: any)`

### `ExploitSignatureScanner`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/ExploitSignatureScanner.lua`
- **Use case:** ExploitSignatureScanner API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `ExploitSignatureScanner.Init(orchestrator: any)`

### `FlyDetector`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/FlyDetector.lua`
- **Use case:** FlyDetector API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `FlyDetector.Sample(player: Player, snapshot: any)`

### `HeartbeatGuard`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/HeartbeatGuard.lua`
- **Use case:** HeartbeatGuard API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `HeartbeatGuard.Init(_orchestrator: any)`
  - `HeartbeatGuard.Sample(player: Player, snapshot: any)`

### `HeuristicDetector`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/HeuristicDetector.lua`
- **Use case:** HeuristicDetector API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `HeuristicDetector.Sample(player: Player, snapshot: any)`

### `HumanoidStateGuard`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/HumanoidStateGuard.lua`
- **Use case:** HumanoidStateGuard API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `HumanoidStateGuard.Init(orchestrator: any)`

### `AntiCheat` (public orchestrator)

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/init.lua`
- **Use case:** ตรวจจับ/flag/enforcement
- **Public API:**
  - `AntiCheat.Flag(player: Player, reason: string, severity: string?, source: EvidenceSource?)`
  - `AntiCheat.IsEnabled()`
  - `AntiCheat.SetEnabled(on: boolean)`
  - `AntiCheat.IsDetectorEnabled(name: string)`
  - `AntiCheat.SetDetectorEnabled(name: string, on: boolean)`
  - `AntiCheat.ClearOverrides()`
  - `AntiCheat.GetDetectorNames()`
  - `AntiCheat.Whitelist(player: Player, reason: string, duration: number?)`
  - `AntiCheat.GetFlagCount(player: Player, reason: string)`
  - `AntiCheat.ClearFlags(player: Player, reason: string?)`
  - `AntiCheat.RegisterDetector(detector: Detector)`
  - `AntiCheat.GetDetector(name: string)`
  - `AntiCheat._decayFlags(amount: number)` — **internal; ห้ามเรียกจาก game code**

### `NoClipDetector`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/NoClipDetector.lua`
- **Use case:** NoClipDetector API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `NoClipDetector.Sample(player: Player, snapshot: any)`

### `RemoteTrap`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/RemoteTrap.lua`
- **Use case:** RemoteTrap API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `RemoteTrap.Init(orchestrator: any)`

### `SpeedDetector`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/SpeedDetector.lua`
- **Use case:** SpeedDetector API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `SpeedDetector.Sample(player: Player, snapshot: any)`

### `StatGuard`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/StatGuard.lua`
- **Use case:** StatGuard API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `StatGuard.Expect(player: Player, statName: string, newValue: number)`
  - `StatGuard.Init(orchestrator: any)`

### `TeleportDetector`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/TeleportDetector.lua`
- **Use case:** TeleportDetector API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `TeleportDetector.Sample(player: Player, snapshot: any)`

### `ToolDuplicationGuard`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/ToolDuplicationGuard.lua`
- **Use case:** ToolDuplicationGuard API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `ToolDuplicationGuard.Init(orchestrator: any)`

### `WorldBoundsDetector`

- **Source:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/WorldBoundsDetector.lua`
- **Use case:** WorldBoundsDetector API สำหรับระบบ anticheat ของเกม
- **Internal API (orchestrator-only):**
  - `WorldBoundsDetector.Sample(player: Player, snapshot: any)`

## Server semantic keys

ชื่อ key ที่ใช้เรียกจาก `GaxiaServer` ไม่จำเป็นต้องตรงชื่อไฟล์:

| Key | Module |
|---|---|
| `AntiCheat` | `AntiCheat/init.lua` orchestrator |
| `Config` | `Config/init.lua` |
| `Data` | `Lib/DataManager/init.lua` |
| `Player` | `Lib/PlayerService.lua` |
| `Item` | `Lib/ItemService.lua` |
| `Economy` | `Lib/EconomyService.lua` |
| `Tool` | `Lib/ToolService.lua` |
| `Zone` | `Lib/ZoneService.lua` |
| `Cooldown` | `Lib/CooldownService.lua` |
| `ItemDef` | `Lib/ItemDefinitionService.lua` |
| `Interaction` | `Lib/InteractionService.lua` |
| `Settings` | `Lib/SettingsService.lua` |
| `Lifecycle` | `Lib/ServiceLifecycle.lua` |
| `Monetization` | `Lib/MonetizationService.lua` |
| `Shop` | `Lib/ShopService.lua` |
| `Analytics` | `Lib/AnalyticsService.lua` |
| `Webhook` | `Lib/WebhookService.lua` |
| `Journal` | `Lib/AntiCheatJournal.lua` |
| `Ban` | `Lib/BanService.lua` |
| `Enforcement` | `Lib/AntiCheatEnforcement.lua` |
| `AntiCheatAdmin` | `Lib/AntiCheatAdmin.lua` |
| `Codex` | `Lib/CodexService.lua` |
| `Refine` | `Lib/RefineService.lua` |
| `Vault` | `Lib/VaultService.lua` |
| `Placement` | `Lib/PlacementService.lua` |
| `Idle` | `Lib/IdleService.lua` |
| `Loot` | `Lib/LootService.lua` |
| `AI` | `Lib/AIService.lua` |
| `Protection` | `Lib/ProtectionService.lua` |
| `Raid` | `Lib/RaidService.lua` |
| `DailyReward` | `Lib/DailyRewardService.lua` |
| `Mail` | `Lib/MailService.lua` |
| `Inventory` | `Lib/InventoryService.lua` |
| `Event` | `Lib/EventService.lua` |
| `Visit` | `Lib/VisitService.lua` |
| `Teleport` | `Lib/TeleportService.lua` |
| `Memory` | `Lib/MemoryStore.lua` |
| `Trade` | `Lib/TradeService.lua` |
| `Party` | `Lib/PartyService.lua` |
| `VFX` | `Lib/VFXService.lua` |
| `SFX` | `Lib/SFXService.lua` |
| `Anim` | `Lib/AnimationService.lua` |
| `Motion3D` | `Lib/Motion3DService.lua` |
| `Ragdoll` | `Lib/RagdollService.lua` |
| `EConfig` | `Lib/EffectiveConfig.lua` |
| `Admin` | `Lib/AdminCommands.lua` |
| `Chat` | `Lib/ChatCommandSystem.lua` |
| `Quest` | `Lib/QuestSystem.lua` |
| `Achievement` | `Lib/AchievementSystem.lua` |
| `Level` | `Lib/LevelSystem.lua` |
| `Migration` | `Lib/DataMigration.lua` |
| `Leaderboard` | `Lib/LeaderboardService.lua` |
| `Messages` | `Lib/CrossServerMessaging.lua` |
| `Friend` | `Lib/FriendService.lua` |
| `Guild` | `Lib/GuildService.lua` |
| `GuildLock` | `Lib/GuildLock.lua` |
| `InviteQueue` | `Lib/InviteQueue.lua` |
| `Pet` | `Lib/PetService.lua` |
## Versioning and source of truth

- Loader exposes `VERSION`; ตรวจ runtime ด้วย `Gaxia.VERSION` / `GaxiaServer.VERSION`
- เอกสารนี้ไม่สัญญา behavior ที่ไม่ได้อยู่ใน public export
- เมื่อเพิ่ม/ลบ API ให้แก้ source declaration และ regenerate/ตรวจเอกสารพร้อมกัน

## Verification checklist

- [ ] ตัวอย่าง shared รันได้ใน Script/LocalScript ที่ถูก context
- [ ] ตัวอย่าง server รันหลัง DataManager/Config พร้อม
- [ ] ทุก remote mutation validate บน server
- [ ] ทุก resource มี cleanup path
- [ ] ทดสอบ failure ของ external services และ rate limits
