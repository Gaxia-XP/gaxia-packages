# Gaxia AntiCheat Hardening — Implementation Blueprint

> **Status:** P0, P1, raw-remote migration, and P2 traps are implemented in the
> current uncommitted worktree. `AntiCheat.Enforcement.Mode` remains `"observe"`
> by default.
>
> **Verified on 2026-09-04:** Rojo default/plugin builds, the static remote-surface
> audit, and the isolated Roblox Studio smoke test pass.
>
> **Deliberately deferred:** Blink and Roblox Server Authority remain decision-gated
> pilots. They are not enabled globally because both require game-specific workload,
> performance, and false-positive evidence first.
>
> **Operational gates still required before changing to `"enforce"`:** a live
> client/server playtest plus the load, fuzz, and false-positive matrix in §11.

## 1. เป้าหมาย

ทำให้ Gaxia Packages ป้องกันการโกงด้วยหลัก **server authority + safe enforcement**:

1. request ที่ไม่ปลอดภัยต้องถูกปฏิเสธก่อนถึง gameplay handler;
2. client ส่งได้เพียง “intent” และ server เป็นผู้ตรวจ permission/state/range/cooldown/value;
3. evidence จาก client เป็น telemetry เท่านั้น ไม่ใช่หลักฐานสำหรับ auto-kick/ban;
4. การลงโทษต้องรวมอยู่ในจุดเดียว มี dedupe, kill switch, audit และ rollout แบบ observe-only;
5. การพรางชื่อ Remote/ข้อมูลบนสายช่วยเพิ่มต้นทุนให้มือใหม่ แต่ห้ามนับเป็น authentication;
6. Blink และ Roblox Server Authority ต้องผ่าน pilot/benchmark ก่อนนำมาใช้จริงทั้งระบบ

### Definition of success

- ไม่มี client-triggered state mutation ที่ข้าม gateway หรือ server-side domain validation;
- malformed, oversized, non-finite, unauthorized, over-rate, concurrent และ replayed requests
  ไม่เรียก gameplay handler;
- client report เพียงอย่างเดียวไม่สามารถทำให้ผู้เล่นถูก kick/ban;
- มี enforcement consumer เพียงหนึ่งตัว;
- operator ปิด detector/action/RPC enforcement รายตัวได้โดยไม่ deploy ใหม่;
- ทุก rejection/action มี reason code ที่ audit ได้ โดยไม่ log payload ลับหรือ payload ขนาดใหญ่;
- ผ่าน unit, fuzz, replay, load, false-positive และ Studio integration gates ใน §11;
- Blink และ Server Authority ไม่ถูกเปิด production จนกว่าจะผ่าน decision gate ของตัวเอง

## 2. Security truth และ non-goals

Roblox client ที่ถูก exploit มีสิทธิ์อ่าน replicated code, inspect traffic, เรียก Remote ด้วย
argument ใดก็ได้ และเปลี่ยนพฤติกรรมของ LocalScript ได้ ดังนั้น **ไม่มีวิธีที่ client ส่ง secret
แล้ว server แยกได้อย่างสมบูรณ์ว่าเป็น “client ของเรา” หรือ executor**

สิ่งที่ session key, hashed remote name, codec หรือ Blink compression ทำได้คือ:

- ทำให้ RemoteSpy output อ่านยากขึ้น;
- ลดการ copy/paste exploit แบบพื้นฐาน;
- ทำให้ captured packet เก่าใช้ซ้ำยากขึ้นเมื่อมี nonce replay checks;
- ทำให้ malformed traffic ถูก reject ก่อน gameplay code

สิ่งที่มันทำไม่ได้:

- เก็บ secret ที่ executor บนเครื่องเดียวกันอ่านไม่ได้;
- ยืนยันว่า request เกิดจาก UI/LocalScript ที่แท้จริง;
- ทดแทน permission, context และ server-state validation;
- ซ่อน Remote หรือ traffic จาก attacker ที่ตั้งใจ reverse engineer อย่างถาวร

### Explicit non-goals

- ตรวจจับ executor ทุกชนิดหรือรับประกัน zero-cheat;
- permanent-ban จาก signature/client heartbeat เพียงอย่างเดียว;
- crypto protocol ที่อ้างว่า client key เป็น identity;
- ทำ kernel/device attestation;
- rewrite detector ทุกตัวพร้อมกัน;
- เปิด Server Authority ทั้ง framework ด้วย global toggle เดียว

หลักนี้ตรงกับ Roblox security guidance: server ต้องเป็น source of truth และข้อมูลจาก client
ทุกชิ้นต้องถือว่าแก้ไขหรือปลอมแปลงได้

## 3. Baseline audit ก่อน implementation (historical)

### สิ่งที่ทำได้ดีอยู่แล้ว

- `NetService` มี per-player/per-RPC token bucket และ validator list;
- logical remote name ถูกแปลงเป็น hash ก่อนสร้าง Instance;
- `RemoteObfuscator` มี version, nonce, depth/node budget และ round-trip ของ packed nil;
- Pet RPCs ใช้ `Guard.strictInterface` และ domain service ตรวจ ownership/state ซ้ำ;
- AntiCheat มี detector kill switches, whitelist, flag decay, journal และ admin controls;
- `BanService` มี persistent join gate และ staff/creator exemption;
- client telemetry มี cooldown และ heartbeat มี join grace

### ช่องโหว่เชิงสถาปัตยกรรมเดิม (แก้แล้วใน worktree นี้)

| จุดปัจจุบัน | ปัญหา | ผลกระทบ | Phase |
|---|---|---|---|
| `AntiCheat/init.lua:recordFlag()` | `severity == "hard"` ยิง `OnAction` ทันที ไม่ได้รอ `HardFlagThreshold` | client สามารถ self-report kind ที่ map เป็น hard แล้วกระตุ้น action ได้ | P0 |
| `ExploitSignatureScanner` | payload มาจาก client แต่ `Synapse/Krnl/ScriptContext` ถูกจัดเป็น hard | untrusted telemetry กลายเป็น enforcement evidence | P0 |
| Bootstrap และ `BanService` | subscribe `OnAction` และลงโทษทั้งคู่ | duplicate enforcement, policy drift, audit ยาก | P0 |
| `RemoteRateLimiter.Wrap()` | เป็น listener อีกตัวบน `OnServerEvent`; listener อื่นยังได้รับ event | ชื่อฟังก์ชันบอกว่า drop แต่ไม่ได้ block handler จริง | P0/P1 |
| `NetService` validators | ตรวจเพียง positional predicates | ไม่มี universal string/table/buffer budget, finite-number walk, context, concurrency, replay | P1 |
| `RemoteObfuscator` nonce | nonce ไม่ถูกเก็บเป็น replay window | captured envelope ส่งซ้ำได้ | P1 |
| raw RemoteFunctions | Settings/Friend/Guild/Party/Admin มี connection ของตัวเอง | policy, rate, metrics และ malformed behavior ไม่สม่ำเสมอ | P1 |
| ClientAntiCheat heartbeat | client ปิดหรือ spoof ได้ | ใช้ได้เพียง liveness tripwire ไม่ใช่ proof of integrity | P0 |
| direct Remote returns | registration API คืน Remote Instance | consumer อาจต่อ bypass listener นอก gateway | P1 |

### Historical inbound surface inventory

ตารางนี้คือ baseline ก่อน migration. Static audit ปัจจุบันยืนยันว่า NetService
เป็นเจ้าของ C2S transport ทั้งหมด ยกเว้น RemoteTrap ที่ตรวจ wrong-direction
traffic อย่างจงใจ:

| Surface | ก่อน migration | Risk | Current state |
|---|---|---:|---|
| `Events.Net/*` | NetService — Command + Pet | medium/high | definition-based Net gateway |
| `Events.Gaxia_Settings` | raw `RemoteFunction` | low | `Settings.Read` / `Settings.Set` gateway RPCs |
| `Events/Friend/Action` | raw `RemoteFunction` | medium | logical Friend gateway RPCs |
| `Events/Party/InviteAction` | raw `RemoteFunction` | medium | logical Party gateway RPCs |
| `Events/Guild/Action` | raw `RemoteFunction`, รวม vault mutation | high | logical Guild gateway RPCs |
| `Events/Admin/Action` | raw privileged `RemoteFunction` | critical | logical Admin gateway RPCs |
| `Events/AntiCheat_Report` | raw client telemetry event | untrusted | `AntiCheat.Report` telemetry-only gateway RPC |
| `Events/System_Heartbeat` | raw client heartbeat event | untrusted | `AntiCheat.Heartbeat` liveness-only gateway RPC |
| Friend/Guild/Party/Admin `Inbound` | server→client events | outbound | reviewed wrong-direction trap listeners |
| Chat reply remote | server→client event | outbound | reviewed wrong-direction trap listener |

## 4. Target architecture

```text
Client intent
    │
    ▼
Transport / deterrent codec
    │  rate gate before expensive decode
    ▼
RPC Gateway (all gameplay C2S connection owner)
    ├─ codec version + per-player session key (deterrent only)
    ├─ bounded decode + structural budget + finite-number walk
    ├─ per-player/per-RPC nonce replay + request-id cache
    ├─ global/per-player/per-RPC rate + concurrency
    ├─ schema validation
    ├─ context/permission/server-state validation
    └─ invoke handler exactly once
           │
           ▼
    Domain service mutates authoritative state

Every reject / detector result
    │
    ▼
Evidence pipeline → dedupe/window/risk policy → Journal
                                      │
                                      ▼
                             single Enforcement service
```

### Ownership rules

1. **Gateway owns every gameplay C2S connection.** Gameplay modules register definitions/handlers;
   ห้าม connect `OnServerEvent` หรือ assign `OnServerInvoke` เอง. `RemoteTrap`
   เป็นข้อยกเว้นที่ตรวจสอบแล้วสำหรับ wrong-direction outbound remotes เท่านั้น
2. **Gateway rejects; domain service decides.** Schema ผ่านไม่ได้แปลว่าซื้อ/โจมตี/ย้ายของได้
3. **AntiCheat observes gateway outcomes.** AntiCheat ไม่ควร decode packet หรือเรียก handler
4. **Enforcement is single-writer.** มีเพียง service เดียวที่เรียก Kick/Ban อัตโนมัติ
5. **BanService is an executor/store.** ไม่ควร subscribe evidence แล้วตัดสิน policy เอง
6. **Client anti-cheat is expendable.** เกมยังปลอดภัยเชิง state แม้ client module ถูกลบทิ้งทั้งหมด

## 5. Implemented contracts (current reference)

### 5.1 RPC definition

API ที่ใช้ปัจจุบันเป็น definition-based API และไม่คืน raw Remote:

```luau
Net.Server.RegisterEvent("PetBuyEgg", {
    schema = Guard.strictInterface({ egg = Guard.string }),
    budget = "small",
    rate = 4,
    burst = 8,
    concurrency = 1,
    mutation = true,
    validate = function(context, payload)
        -- permission/context/server-state validation
        return true
    end,
    handler = function(context, payload)
        -- calls authoritative PetService operation
    end,
})
```

Recommended public shape:

- `Net.Server.RegisterEvent(name, definition) -> RegistrationHandle`
- `Net.Server.RegisterFunction(name, definition) -> RegistrationHandle`
- `Net.Client.Fire(name, payload, requestId?)`
- `Net.Client.Invoke(name, payload, requestId?) -> Result`
- `RegistrationHandle:Destroy()` — cleanup registration; ไม่มี raw Remote access

`Destroy()` ปิด callback ของ registration เดิม; การ register ชื่อเดิมชนิดเดิมจะได้
replay/cache scope ใหม่ แต่ request ที่ handler เริ่มไปแล้วจะยังนับรวมใน concurrency
ของ logical RPC จนจบ. ไม่รองรับการสลับชนิด Event/Function สำหรับชื่อเดิม เพราะ wire
remote เดิมต้องคงชนิดเดิมไว้.

Definition-based registration must fail closed when:

- duplicate logical name;
- wire-name hash collision;
- event/function kind mismatch;
- ไม่มี schema สำหรับ client→server endpoint;
- mutation endpoint ไม่มี context validator หรือ `concurrency ~= 1`;
- rate/burst/concurrency ไม่เป็น finite positive numbers

Legacy `Net.OnServer` / `Net.OnInvoke` remain temporarily for external consumers,
but they share the same logical-name registry and cannot be registered alongside a
definition endpoint. `Net.Server.GetMetrics(name?)` exposes server-only received,
accepted, rejected-by-code, in-flight, handler-error, idempotent-hit, and latency
totals without retaining request payloads.

### 5.2 Codec envelope and replay

`RemoteObfuscator` ใช้ envelope แบบ exact dense array:

```text
{ codecVersion, nonce, encodedPackedArgs }
```

ฝั่ง server สร้าง session key ต่อ player, ล้างเมื่อ leave และ derive transport key
ต่อ logical RPC. Key กับ codec มีไว้เป็น deterrent เท่านั้น ไม่ใช่ authentication.
Definition API ส่ง argument เดียวที่มี shape exact `{ requestId, payload }`;
request ID ใช้กับ cache สำหรับ mutation/retryable request.

ข้อกำหนด:

- nonce เก็บใน bounded replay window แยกต่อ player + RPC; ไม่มี epoch/opcode/sequence
  field ใน protocol นี้;
- nonce ถูก remember หลัง decode/structural/schema validation สำเร็จ เพื่อให้ packet
  malformed ไม่ evict nonce ที่ valid แต่ยัง reject replay ก่อน handler;
- requestId cache แยก player + RPC, มี TTL และ bounded entry count;
- duplicate mutation request คืน cached result หรือ no-op โดยไม่ทำ side effect ซ้ำ;
- domain idempotency ยังจำเป็นสำหรับธุรกรรม durable เช่น receipt/trade — gateway cache
  ไม่ใช่ replacement เพราะหายเมื่อ server ปิด;
- error response เป็น code คงที่ เช่น `RATE_LIMITED`, `MALFORMED`, `SCHEMA`,
  `FORBIDDEN`, `BUSY`, `INTERNAL`; ห้ามส่ง stack trace กลับ client

### 5.3 Structural budget

ตรวจหลัง bounded decode แต่ก่อน schema:

- max argument count;
- max depth;
- max total nodes/table entries;
- max string bytes ต่อค่าและรวมทั้ง request;
- max buffer bytes;
- allowlisted Roblox datatypes เท่านั้น;
- number ทุกตัวต้อง finite รวมถึง components ของ Vector/CFrame ถ้า codec รองรับ;
- table key ต้องเป็นชนิดที่อนุญาต, ไม่เป็น NaN, ไม่มี metatable/cycle;
- Instance ต้อง reject โดย default; endpoint ที่จำเป็นต้องรับต้อง validate class,
  ancestry, ownership และ expected collection/tag อย่างเจาะจง

ใช้ named budget profiles (`tiny`, `small`, `medium`) เพื่อให้ config audit ง่าย แต่ทุก RPC
ต้องเห็นค่าที่ profile resolve เป็นจริงในเอกสาร/diagnostic output

### 5.4 Validation order

ลำดับต้องคงที่และมี test ยืนยันว่า handler ไม่ถูกเรียกเมื่อชั้นใดชั้นหนึ่ง fail:

1. global + per-RPC token-bucket rate gate;
2. bounded codec decode;
3. structural budget + finite checks;
4. argument-count + schema validation;
5. remember nonce / reject replay;
6. concurrency reservation;
7. v2 permission/context/server-state validation;
8. mutation request-id cache lookup;
9. protected domain handler invocation;
10. release concurrency slot, record metrics, and cache successful mutation result

Rate-limited packet ไม่ควรถูก decode เพื่อกัน CPU amplification. Handler error คือ server fault;
ต้อง log แยกและ **ห้ามนับเป็น cheat evidence**

## 6. P0 — Enforcement safety (implemented)

ทำ phase นี้ก่อนแตะ Blink, traps หรือเพิ่ม detector

### P0.1 แยก evidence ออกจาก action

contract ที่ implement คือ:

```luau
AntiCheat.Flag(player, reason, severity?, source?)
-- source: "server" | "transport" | "trap" | "client" | "client_liveness"
```

กฎบังคับ:

- ทุก source เข้า journal/flag count ได้ แต่ `client`, `client_liveness`, source ที่
  omitted และ source ที่ไม่รู้จักไม่เพิ่ม trusted candidate count และไม่มีวัน fire
  automatic-action candidate;
- `server`, `transport`, และ `trap` ใช้ candidate count แยกจาก telemetry **และแยก
  soft/hard severity** ก่อนต้องถึง threshold ของตัวเองจึง fire `OnAction`;
- enforcement รับ hard candidate จาก trusted sources เท่านั้น, เริ่มต้น `observe`,
  และ dedupe action ที่ apply ต่อ player/reason ด้วย cooldown;
- reject request กับ punish player เป็นคนละ decision — invalid request ถูก drop ได้ทันที
  โดยไม่จำเป็นต้อง kick;
- journal เก็บ reason/source/decision ที่ bounded และไม่เก็บ raw request payload.

structured confidence/weight/correlation/risk-window scoring เป็นงาน future design;
ห้ามอ้างว่า implementation ปัจจุบันมี contract เหล่านั้น

### P0.2 Single enforcement owner

`AntiCheatEnforcement` เป็น subscriber เพียงตัวเดียวที่ทำ automatic action:

- ย้าย default kick logic ออกจาก `Gaxia_ServerBootstrap.server.lua`;
- ย้ายการตัดสิน escalation ออกจาก `BanService`;
- ให้ `BanService` เหลือ `IsBanned/Ban/Unban/ListBans` และ join gate;
- `AntiCheatJournal` และ webhook เป็น observer เท่านั้น;
- enforcement dedupe action ต่อ player/reason/cooldown และ re-check creator/staff
  exemption กับ current Player identity ก่อน action;
- ก่อน kick ตรวจ `player.Parent`; ไม่มี delayed-action queue ใน implementation นี้

### P0.3 Initial policy

ค่าเริ่มต้นสำหรับ rollout แรก:

- `Mode = "observe"`;
- auto permanent ban = off;
- auto temporary ban = off จน false-positive gate ผ่าน;
- client evidence = journal only;
- malformed/schema/rate/replay = reject request + journal แบบ dedupe;
- server invariant violation ความมั่นใจสูง = eligible for kick หลัง policy calibration;
- permanent ban default เป็น manual admin action แม้ production enforcement เปิดแล้ว;
- kill switches: global, detector, evidence category, action type และ RPC

### P0.4 P0 acceptance

- ยิง `AntiCheat_Report("Synapse")` 1,000 ครั้งแล้วไม่มี Kick/Ban;
- evidence ถูก dedupe และ memory bounded;
- มี subscriber ที่ลงโทษอัตโนมัติเพียงหนึ่งตำแหน่งจาก `rg` audit;
- bootstrap ไม่ถือ policy state;
- BanService ไม่ subscribe `AntiCheat.OnAction`;
- observe mode ไม่เปลี่ยน gameplay outcome ยกเว้น request rejection ที่ handler เดิมก็ reject;
- staff/creator exemption tests ผ่านทั้ง sync role และ delayed role load

## 7. P1 — RPC gateway และ migration (implemented)

### P1.1 Pure protocol core

แนะนำแยก pure/bounded logic ออกจาก Roblox connections เพื่อทดสอบง่าย:

- `Shared/NetProtocol.lua` — envelope validation, budget walker, result/error codes;
- `Shared/NetService.lua` — transport ownership, registry, dispatch, client API;
- `Shared/RemoteObfuscator.lua` — deterrent codec หลัง interface ของ protocol;
- AntiCheat รับ outcome ผ่าน public evidence API ไม่ถูก require กลับเป็น cycle

อย่าเพิ่ม abstraction มากกว่านี้จนกว่าจะมี consumer จริง

### P1.2 Replace ineffective limiter

- ห้ามใช้ `RemoteRateLimiter.Wrap()` เป็น blocking control เพราะมัน block listener อื่นไม่ได้;
- gateway ต้อง consume token แล้ว `return` ก่อนเรียก handler ของตัวเอง;
- หลัง inbound surface ย้ายครบ ให้ลบ detector `RemoteRateLimiter.lua` หรือเปลี่ยนชื่อ/หน้าที่เป็น
  metrics-only อย่างชัดเจน; ไม่เก็บ API `Wrap` ที่สื่อว่าป้องกันได้;
- rate state ต้อง cleanup ตอน player leave และ registration destroy;
- จำกัด global per-player budget เพิ่มอีกชั้น กัน spam หลาย RPC พร้อมกันเพื่อหลบ per-RPC bucket

### P1.3 Migration order

ห้ามต่อ old handler และ gateway handler พร้อมกัน เพราะ side effect อาจเกิดสองครั้ง

1. **Settings canary** — `get/getAll/set`; เพิ่ม schema ต่อ operation, key allowlist,
   rate/concurrency และ context validation;
2. **Command + Pet** — อยู่บน NetService แล้ว; ย้าย definition/API และเพิ่ม request budget/replay;
3. **Friend + Party** — แยก schema ตาม action แทน envelope กว้างชนิดเดียว;
4. **Guild** — แยก read/membership/vault mutations; vault ต้องมี requestId และ domain
   idempotency/atomicity;
5. **Admin** — role check ก่อน expensive list/DataStore work, strict action schemas,
   aggressive rate/concurrency, redacted audit;
6. **AntiCheat report + heartbeat** — route ผ่าน gateway แต่ mark source client และไม่มี
   enforcement authority;
7. **Outbound-only remotes** — register direction metadata และ wrong-direction listener;
8. `rg` audit รอบสุดท้าย: raw inbound connection ที่เหลือต้องอยู่ใน explicit allowlist พร้อมเหตุผล

แต่ละ endpoint migration ต้องเป็น commit/changeset แยกและผ่าน tests ก่อนย้ายตัวถัดไป

### P1.4 Context validation checklist ต่อ mutation RPC

- player/character/profile พร้อมจริง;
- feature/runtime flag เปิด;
- player มี permission/role/ownership;
- target เป็น server-known identifier ไม่ใช้ client-supplied price/stat;
- distance/line-of-sight/state/alive/team ตรวจจาก server state;
- cooldown และ action state ถูกต้อง;
- inventory/currency capacity และ lower/upper bounds;
- target player/item/guild/party ยังอยู่ใน relationship ที่อนุญาต;
- side effect atomic หรือมี rollback;
- duplicate request ไม่ให้ผลซ้ำ;
- result ที่ broadcast ไป client อื่นสร้างจาก server result ไม่ relay payload เดิม

### P1.5 P1 acceptance

- test พิสูจน์ว่า validation ทุกชั้น fail แล้ว handler counter ยังเป็นศูนย์;
- duplicate nonce/requestId ทำ side effect หนึ่งครั้ง;
- malformed payload ใช้ CPU/memory แบบ bounded และไม่ throw ออกจาก connection;
- handler error คืน `INTERNAL`, release concurrency slot และไม่ flag player;
- rate limit block จริง ไม่ใช่แค่ journal;
- scanner test ยืนยันไม่มี raw inbound Remote นอก allowlist;
- all migrated UI/controllers ทำงานเท่าเดิมใน Studio client/server playtest;
- มี metrics ต่อ RPC: received/accepted/rejected-by-code/in-flight/latency

## 8. P2 — Detection traps (implemented, observe-first)

เพิ่มหลัง gateway enforce request boundaries ได้แล้วเท่านั้น

### Honeypot Remote

- สร้าง outbound-visible Remote ที่ legitimate client code ไม่เคย fire/invoke;
- ไม่อ้างอิงชื่อใน UI flow และไม่มี gameplay handler;
- client firing มันสร้าง `source="trap"`, high-confidence evidence;
- handler ทำ O(1): rate limit, dedupe, journal; ห้าม parse attacker payload;
- ชื่อจะ stable hash หรือสุ่มต่อ server ก็ได้ แต่ถือเป็น deterrent เท่านั้น;
- trap must never grant, mutate, echo หรือ perform expensive work

### Wrong-direction detection

- Remote ที่ประกาศ server→client only สามารถมี minimal `OnServerEvent` listener เพื่อจับ
  client ที่ fire ย้อนทิศ;
- listener ต้องอยู่ใน transport/gateway ownership ไม่กระจายตาม service;
- legitimate client test ต้องยืนยัน zero events;
- version mismatch หรือ internal tooling ต้องไม่ใช้ production outbound remote ย้อนทิศ

### Trap enforcement policy

- rollout แรก journal only;
- trap ไม่เพิ่ม strike ladder สำหรับ temp/permanent ban;
- หลัง false-positive window ผ่าน จึงอนุญาต kick เมื่อ trap evidence ตรงกับ session และ
  ผ่าน dedupe;
- temp/permanent ban ต้องมาจาก server/explicit trusted-transport evidence ตาม policy;
- admin dashboard แสดง trap code, count, first/last seen และ server job id

## 9. P2 — Blink pilot (decision gate, ไม่ใช่ security dependency)

Blink เป็น IDL compiler สำหรับ buffer networking ที่ generate validation และลด bandwidth/CPU;
compression ทำให้ traffic อ่านยากขึ้น แต่ยังไม่ใช่ authentication

### Pilot scope

- ใช้ **Settings เท่านั้น** หลัง Settings ผ่าน Net v2 canary แล้ว;
- ทำบน spike branch/isolated commit ที่ถอดกลับได้;
- pin exact Blink version/commit และบันทึก license;
- เพิ่ม compiler/install step แบบ deterministic เข้า toolchain;
- ห้าม migrate endpoint อื่นก่อนจบ report;
- ห้ามปล่อย Blink และ legacy transport สำหรับ Settings คู่กันใน production

### Benchmark matrix

เก็บ baseline และ Blink ด้วย payload/จำนวนครั้งเดียวกัน:

- encoded bytes/request และ response;
- encode/decode CPU average, p95, max;
- end-to-end invoke latency p50/p95;
- server memory หลัง sustained load;
- malformed payload behavior;
- type coverage รวม optional/nested/enum/string limits;
- generated code size/build time;
- Studio debugging, stack traces และความง่ายในการเพิ่ม RPC;
- compatibility กับ Rojo, Wally/Rokit toolchain และ release artifact;
- maintenance health, pinned-version reproducibility และ upgrade cost

ก่อน benchmark ต้องเติม expected production peak และ regression budget ลง report; ห้ามเลือก
Blink จากคำว่า “เร็ว/ปลอดภัยกว่า” โดยไม่มีตัวเลขของ repo นี้

### Go / no-go

**Go** เมื่อ:

- behavior/tests เทียบเท่า Net v2;
- receiver validation เท่ากันหรือเข้มกว่า;
- มี bandwidth หรือ CPU win ที่มีนัยสำคัญกับ payload จริง;
- latency/memory ไม่เกิน budget;
- build/release reproducible และ DX รับได้;
- ทีมยอม migrate แล้วลบ transport เดิม ไม่ดูแลสองระบบถาวร

**No-go** เมื่อ security benefit หลักมีเพียง “RemoteSpy อ่านยาก”, generated workflow เปราะ,
performance ไม่ดีขึ้นกับ payload จริง หรือ migration cost สูงกว่าประโยชน์ เก็บ Net v2 + codec เดิมได้

## 10. P3 — Roblox Server Authority pilot

แยกจาก RPC hardening เพราะเป็น physics/simulation architecture ไม่ใช่ remote encryption

### Scope gate

- inventory movement/combat/vehicle/custom controller ที่ต้อง authoritative จริง;
- default avatars/simple physics ทดลองใน test place ก่อน;
- ห้ามเปิด `Workspace.AuthorityMode = Server` ใน production place โดยไม่ได้ audit prerequisites;
- ใช้ feature flag/place copy/percentage cohort ที่ rollback ได้

### Audit ก่อนเปิด

- InputAction coverage ของ input ที่กระทบ simulation;
- logic ที่ต้องย้ายเข้า `RunService:BindToSimulation()` ทั้ง client/server;
- state ที่ต้องเก็บใน synchronized Attributes เพราะ plain Luau variables ไม่ rollback;
- side effects ใน simulation callback เช่น sound, VFX, Remote, analytics, reward;
- callbacks/signals ที่อาจยิงซ้ำระหว่าง rollback/resimulation;
- use of Heartbeat/RenderStepped/delta-time assumptions;
- network ownership ของ character/vehicles/unanchored critical parts;
- streaming prerequisites และ low-end device/server CPU budget;
- misprediction instrumentation และ correction UX

### Implementation rules สำหรับ pilot ภายหลัง

- simulation callback ต้อง deterministic และใช้ synchronized APIs;
- poll `InputAction:GetState()` ใน simulation loop แทนพึ่ง edge signal สำหรับ critical input;
- side effects ต้องออกหลัง confirmed state หรือมี idempotency guard;
- use `RunService:IsResimulating()`/prediction diagnostics เพื่อไม่ยิง effect/remote ซ้ำ;
- วัด misprediction frequency, correction magnitude, server frame time, client frame time,
  bandwidth และ responsiveness;
- failure ของ pilot ต้อง rollback ได้โดยไม่แตะ RPC gateway

### Server Authority go/no-go

- ผ่าน gameplay parity และ no-duplicate-side-effect tests;
- misprediction/correction อยู่ใน UX budget;
- server/client performance ผ่าน target devices;
- exploit tests แสดงว่า server state ไม่รับ client physics เป็น truth;
- owner อนุมัติ rollout ต่อระบบ — ไม่ใช้ global all-games toggle

## 11. Verification plan

### Unit tests

- codec-version and exact-envelope parsing;
- budget walker: depth, nodes, strings, buffers, key types, cycle, NaN, ±inf;
- token refill/burst/global budget แยก player/RPC;
- replay window: duplicate nonce, bounded-capacity rotation, and recently evicted nonce;
- requestId cache: one side effect, same cached result, TTL/eviction;
- concurrency: cap, normal completion, handler throw, player leave cleanup;
- validation order และ handler-not-called assertions;
- evidence source cap, dedupe, decay, distinct-source correlation;
- enforcement exemption, action dedupe, observe mode และ kill switches;
- client evidence never produces an automatic action;
- trap/wrong-direction creates evidence but performs no gameplay work

### Fuzz / malformed tests

- random nested envelopes อย่างน้อย 10,000 cases ต่อ deterministic seed;
- wrong tags/types/missing fields/extra huge fields;
- large sparse/dictionary tables;
- extreme integers/floats, NaN, infinities, negative zero;
- invalid encoded string/table nodes และ corrupt nonce/version;
- repeated duplicate packets, corrupt nonce, and request-cache rotation;
- assert: no unhandled throw, no handler call, bounded runtime, bounded retained memory

### Load tests

- expected peak player count × expected peak request rate;
- one abuser spam single RPC;
- one abuser rotate RPC เพื่อหลบ per-RPC rate;
- many concurrent invokes ที่ handler yield;
- 10-minute soak ตรวจ bucket/cache cleanup และ memory plateau;
- metrics sink failure ต้องไม่ block gameplay/gateway

### False-positive matrix

- high ping, jitter, packet loss และ temporary disconnect;
- server hitch/low FPS/client low FPS;
- respawn/death/teleport/streaming in-out;
- legitimate rapid UI clicks/gamepad/mobile touch;
- admin speed/teleport/dev commands;
- custom movement whitelist and expiry;
- server version/place transitions;
- client telemetry absent ทั้ง session;
- Studio test with 1 server + multiple clients

### Static/build gates

- `stylua --check` changed Luau files;
- `selene` changed Luau files;
- `luau-lsp analyze` with Roblox definitions/sourcemap;
- `rojo build default.project.json`;
- `rojo build plugin.project.json`;
- `git diff --check`;
- scanner test for raw inbound connections;
- update `MANUAL.md`, `CHANGELOG.md`, configuration docs and third-party notices if needed

## 12. Rollout and observability

### Required modes

- `off` — component inactive;
- `observe` — calculate would-reject/would-act and journal metrics, but no automatic punishment;
- `enforce` — reject gateway request according to policy;
- action policy มี observe/enforce แยกจาก request enforcement เพื่อให้ block exploit ได้ก่อนเปิด ban

Malformed/over-budget packetsที่ไม่สามารถส่งต่ออย่างปลอดภัยอาจถูก drop แม้ action mode เป็น observe;
คำว่า observe ใช้กับ punishment และ policy calibration ไม่ใช่คำสั่งให้เรียก handler ด้วยข้อมูลอันตราย

### Rollout stages

1. **Baseline:** เก็บ request rate/latency/rejection baseline จากโค้ดเดิม;
2. **P0 observe:** deploy evidence + single enforcement โดย automatic actions off;
3. **Gateway canary:** Settings observe → enforce;
4. **Medium risk:** Command/Pet/Friend/Party ทีละ endpoint;
5. **High risk:** Guild แล้ว Admin;
6. **Telemetry channels:** AntiCheat report/heartbeat ผ่าน gateway;
7. **Traps observe:** รอ false-positive window ที่กำหนดก่อน kick eligibility;
8. **Policy calibration:** เปิด kick เฉพาะ evidence class ที่ผ่าน review;
9. **Blink report:** owner ตัดสิน go/no-go;
10. **Server Authority pilot:** separate test place/cohort และ owner sign-off

### Metrics ห้ามขาด

- requests received/accepted/rejected by RPC + reason code;
- rate/concurrency/replay rejects;
- handler latency/error count;
- evidence counts by source/detector/code;
- deduped vs unique evidence;
- would-kick/would-ban vs actual action;
- exemption/kill-switch use;
- trap hits;
- job id, place version และ policy version;
- ไม่มี raw payload, session key หรือ personal text ใน log

### Rollback

- request policy/RPC enforce ปรับเป็น observe รายตัวได้;
- automatic action ปิดแยกได้โดยไม่ปิด request rejection;
- trap ปิดแยกได้;
- Blink pilot revert ได้ทั้ง changeset;
- Server Authority ใช้ test place/cohort และมี documented property/config rollback;
- rollback ไม่ควรกลับไปเปิด raw bypass handler

## 13. Suggested implementation changesets for Luna (historical)

ให้ทำตามลำดับและหยุดเมื่อ gate ของ changeset ไม่ผ่าน:

1. **AC-01 tests/baseline:** เพิ่ม tests ที่ reproduce single client hard-report action และ
   duplicate enforcement โดยยังไม่เปลี่ยน behavior;
2. **AC-02 evidence contract:** evidence source/confidence/dedupe/window + journal schema migration;
3. **AC-03 single enforcement:** one consumer, remove bootstrap/BanService policy duplication,
   observe defaults;
4. **NET-01 protocol core:** envelope/budget/result/replay/idempotency pure tests;
5. **NET-02 gateway dispatch:** exclusive connection ownership, rate/concurrency, metrics;
6. **NET-03 Settings canary:** migrate client/server, Studio test, enable enforce;
7. **NET-04 existing Net consumers:** Command + Pet;
8. **NET-05 social:** Friend + Party;
9. **NET-06 critical:** Guild + Admin;
10. **NET-07 telemetry/outbound:** AntiCheat report, heartbeat, direction metadata;
11. **NET-08 cleanup:** remove ineffective limiter/raw bypasses; inventory test must pass;
12. **TRAP-01 observe:** honeypot + wrong-direction + journal/admin visibility;
13. **BLINK-01 spike/report:** no production adoption without explicit owner go;
14. **AUTH-01 audit/pilot:** separate test place; no global production enable

ทุก changeset ต้องมี tests ของ behavior ใหม่ และห้ามรวม adjacent refactor ที่ไม่เกี่ยวข้อง

## 14. Stop conditions / decisions Luna ต้องส่งกลับให้ owner

หยุดและขอการตัดสินใจเมื่อ:

- พบ inbound Remote ที่ไม่อยู่ใน inventory และไม่รู้ domain invariant;
- migration ต้องเปลี่ยน public gameplay behavior หรือ persisted schema;
- จะเปิด auto temp/permanent ban;
- Blink benchmark เสร็จและต้องตัดสิน go/no-go;
- จะเพิ่ม/เปลี่ยน external dependency หรือ compiler ใน release pipeline;
- จะเปิด Server Authority/required Workspace properties ใน production place;
- false-positive test พบ legitimate flow ถูก reject;
- performance เกิน budget ที่บันทึกไว้ก่อนเริ่ม benchmark

## 15. Final completion checklist

- [x] P0 client evidence cannot trigger automatic action
- [x] exactly one automatic enforcement owner
- [x] request rejection and punishment are separate controls
- [x] every inbound state-changing path is gateway-owned
- [x] every RPC has schema, budget, rate, concurrency and context policy
- [x] replay/idempotency tests pass
- [x] no raw inbound connections outside reviewed allowlist
- [ ] traps ran observe-only through the agreed false-positive window
- [x] automatic permanent ban remains off unless owner explicitly enables it
- [ ] Blink has a written measured go/no-go report
- [x] no permanent dual transport
- [ ] Server Authority has a separate measured pilot and rollback plan
- [ ] all unit/fuzz/load/false-positive/Studio/static/build gates pass
- [x] docs, config, changelog and third-party notices are current

## 16. Primary references

- [Roblox — Security and cheat mitigation tactics](https://create.roblox.com/docs/scripting/security/security-tactics)
- [Roblox — Securing the client-server boundary](https://create.roblox.com/docs/scripting/security/client-server-boundary)
- [Blink source repository](https://github.com/1Axen/blink)
- [Roblox — AuthorityMode](https://create.roblox.com/docs/reference/engine/enums/AuthorityMode)
- [Roblox — RunService / BindToSimulation](https://create.roblox.com/docs/reference/engine/classes/RunService)
