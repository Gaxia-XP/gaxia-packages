# 🗺️ Gaxia_Packages — Roadmap สู่ความสมบูรณ์แบบ (Phase 17+)

> **เป้าหมาย:** พัฒนา **GaxiaPackages (in-game framework)** ให้สมบูรณ์ — จาก "framework ที่ดีมาก" → "framework ที่ shippable ระดับ production ทุกมิติ"
> **สถานะปัจจุบัน:** Phase 1–16 COMPLETE (ดู git history). ช่องว่าง = **correctness wiring · breadth · production-ops** ไม่ใช่ rewrite
> **เอกสารนี้ supersede** ร่าง Phase 17+ เดิม (marketplace/replication/telemetry ถูกดูดเข้า phase ด้านล่าง)
> **ที่มา:** สังเคราะห์จากการ survey source จริง 5 มิติ (Lib · Client/UI · Shared/AntiCheat · DX · genre-fit)

---

## หลักการจัด Phase

1. **Correctness ก่อนเสมอ** — ห้ามต่อยอดบนของที่พัง (Phase 17)
2. **Foundation ที่ปลดล็อกหลายอย่าง มาก่อน** — shared primitives, networking/state (Phase 18–19)
3. **Pillars ที่เกมทุกแนวต้องใช้** — monetization, AntiCheat durability, UI breadth (Phase 20–22)
4. **Genre packs = add-on ทางเลือก** — reusable แต่ไม่ใช่แกนกลาง (Phase 23–24)
5. **Dependency-aware** — ระบบที่ "ขยับของมีค่า" (heist/trade) อยู่ท้ายสุดเสมอ (exploit surface สูงสุด)

> **Boundary:** Rojo / CI / install / release = เลเยอร์ **MCP/tooling** **ไม่ใช่ framework phase** — แยกไว้ท้ายเอกสาร (§Tooling track) ตามที่ตกลงกันไว้

> **ทุก phase exit ต้องมี:** TestRunner suite ของ module ใหม่ + `--!strict` ผ่าน + อัป `MANUAL.md` + เพิ่ม `DataVersion` ถ้าแตะ profile schema

---

> **PROGRESS:** ✅ Phase 17 · ✅ Config A/B/C · ✅ **Phase 18** (Lifecycle/Component/Guard + Cooldown/ItemDef/Interaction/RNG/Pool/Scheduler/Serializer/Settings) · ✅ **Phase 19** (Guard↔Net · ReplicatedState v2 nested · Command pattern · StateBinding) · ✅ **Phase 20** (Monetization idempotent receipts + ShopService) · ✅ **Phase 21** (BanService · Journal · AntiCheatAdmin dashboard · FeatureFlags · Analytics · WorldBounds+flag-decay · Heuristic) · ✅ **Phase 22** (22a Theme/Responsive/Router/Localization · 22b Components/GamepadNav/RebindMenu · 22c Accessibility/Toast/Haptics) · ✅ **Phase 23** (genre pack: Codex/Refine/Vault/Placement/Idle/Loot/AI/Raid+Protection) · ✅ **Phase 24** (retention: DailyReward/Mail/Trade/Inventory-depth/Event+Visit/Teleport/MemoryStore/Party) · ✅ **Phase 25** (juice: VFX/SFX/Animation/MotionUI/Motion3D/Ragdoll) — **🎉 FRAMEWORK PHASES 17–25 COMPLETE (v1.0.0)** · ▶️ **Tooling track partial:** ✅ Gaxia.VERSION+CHANGELOG · ✅ GuiCodec (GUI⇄code) · ✅ scaffold.mjs (service generator) · ✅ **Rojo adopted (CLI 7.7.0-rc.1; `default.project.json` + `plugin.project.json`; renamed framework `init.lua` → `loader.lua` to dodge Rojo's `init.*` $path constraint)** · ✅ **Gaxia Companion Studio plugin** (UI↔Script converter + 1-click Install Gaxia in `plugin/src/`) · ⏸️ CI / sample game
>
> **POST-v1.0.0 (this session — 2026-06-08):** ✅ **WebhookService** (`Gaxia.Webhook` — Discord/generic, queue+429 retry, auto-report Bans+AntiCheat) · ✅ **Two-layer Config** (server-private Config + runtime Flags via `EConfig.Get/Enabled/Set/Clear` + `/flag` `/ac` admin commands) · ✅ **Config sweep** (13 services wired, BanService→`Config.Admin.Stores.Bans` bug closed, XP curve + Inventory.MaxItemCount + 11 other knobs moved to Config) · ✅ **luau-lsp cyclic-dep fix** (31 services use Instance-typed local + `:: any` cast to break loader↔service false-positive) · ✅ **ProfileStore adopted** (superseding the earlier ProfileService bundle; data persists in production, not just the Studio mock) · ✅ **MANUAL.md full sweep** (15 → 49 services documented; new "Config / EConfig / Flags" preamble in §8)
>
> **POST-v1.0.0 (2026-06-13 → 06-17):** ✅ **PetService** (stat-boost pets — egg/gacha via `Loot`+pity, 3 equip slots, additive `GetCoinMultiplier`, persisted under `Pets` profile key) + **PetController** UI · ✅ **Coin-multiplier faucet wiring** (`Idle.Collect` + `Quest.grantReward` consume `GetCoinMultiplier`, gated to the `"Coins"` currency, ceiling cap policy; **Raid excluded** — zero-sum transfer would mint) · ✅ **repo Claude-only** (Multi-AI bridge → Claude rename; Gemini/Codex stripped)

## 🚧 Post-v1.0 — AntiCheat hardening (CORE IMPLEMENTED; PILOTS REMAIN)

> **Trust boundary:** client telemetry และการพราง Remote เป็นเพียง tripwire/deterrent; server ต้องเป็นผู้ตรวจ intent/state และตัดสินผลลัพธ์ทุกครั้ง
>
> **Detailed implementation blueprint:** [`ANTICHEAT_HARDENING_PLAN.md`](ANTICHEAT_HARDENING_PLAN.md)

- [x] **P0 — Enforcement safety:** รวม enforcement ให้เหลือทางเดียว; client report เป็น observe-only; ไม่มี single hard flag → auto-ban; เพิ่ม dedupe/cooldown, proportional action และ per-detector kill switch. ค่าเริ่มต้นยังเป็น `observe`.
- [x] **P1 — RPC gateway:** บล็อกก่อนถึง handler ด้วย schema/size/finite/context/permission/server-state validation, rate/concurrency limits, idempotency และ nonce replay protection; ย้าย raw remotes เข้า boundary เดียว
- [ ] **P2 — Blink pilot:** ทดลองกับ RPC ความเสี่ยงต่ำหนึ่งชุด (เช่น Settings), วัด compatibility/latency/payload/debuggability แล้วตัดสินใจว่าจะใช้ Blink หรือคง transport เดิม; ห้ามเดินสอง production transports ถาวร
- [x] **P2 — Detection traps:** เพิ่ม honeypot และ wrong-direction remote พร้อม journal/evidence; ยังไม่ permanent-ban จน false-positive tests ผ่าน
- [ ] **P2 — Verification:** static remote-surface audit, Rojo build และ isolated Studio smoke test ผ่านแล้ว; ยังต้องทำ malformed/fuzz, load, false-positive และ live client/server integration ก่อนเปิด enforcement
- [ ] **P3 — Server Authority (opt-in):** audit/migrate InputAction, fixed simulation, deferred signals, `BindToSimulation()` และ prediction; ห้ามเปิดทั่วทุกเกมด้วย toggle เดียว

## ✅ Phase 17 — Hardening & Integrity (DONE)

🎯 **เป้า:** ปิด bug/data-loss ที่ซ่อนอยู่ ก่อนสร้างอะไรเพิ่ม — ทั้งหมดตัวเล็ก impact สูง

| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 17.1 | สร้าง `AntiCheat_Report` + `System_Heartbeat` RemoteEvent ตอน boot (ใต้ `ReplicatedStorage.Events` ก่อน detector Init) + self-check warn ถ้า detector ตัวไหน self-disable | S | 🔥high |
| 17.2 | **DataStore resilience layer** — pcall + exponential backoff + `GetRequestBudgetForRequestType` throttle รอบทุก external write (DataManager ไม่มี retry เลย) — **prerequisite ของ 17.3** | M | 🔥high |
| 17.3 | `DataManager`: `game:BindToClose()` flush ทุก loadedProfiles + backup write ตอน release (ผ่าน 17.2) | S | 🔥high |
| 17.4 | เรียก `DataMigration.Migrate(profile.Data)` ใน load path (หลัง Reconcile) — dead code + บังคับ convention `DataVersion` | S | 🔥high |
| 17.5 | แก้ double rate-limiter: `RemoteRateLimiter` ข้าม remote ใต้ `Events.Net` (NetService นับ bucket เองอยู่แล้ว) → กัน false-positive | S | med |
| 17.6 | `LoadingScreenController` — ขับ `LoadingScreenTemplate` ที่มีอยู่แต่ไม่มีตัวคุม (SetProgress/SetStatus/Show/Hide) | S | med |

✅ **Exit:** boot log สะอาด 0 detector self-disabled · ไม่เสียข้อมูลตอน shutdown · schema เก่าอัปตอน load

---

## 🧩 Phase 18 — Foundation: Architecture + Shared Primitives (ปลดล็อก service layer)

🎯 **เป้า:** architectural layer + module เล็ก ที่ทุก phase ถัดไปต้องพึ่ง — สร้างก่อนกัน boot-order bug / โค้ดซ้ำ / drift

**▸ Architecture (ทำก่อนในเฟส):**
| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 18.1 | **ServiceLifecycle / registry** — Init→Start ordering + dependency order + "all-ready" barrier. loader ตอนนี้เป็น lazy `__index` ล้วน **ไม่มี boot order** → cross-service bug เมื่อเพิ่ม ~25 service (17.1 ที่ต้อง "สร้าง remote ก่อน detector Init" = symptom ของช่องนี้) — **ช่องสถาปัตยกรรมใหญ่สุด** | M | 🔥high |
| 18.2 | **ComponentService (tag-binding)** — bind class/behavior เข้า instance ที่มี CollectionService tag + auto-cleanup ตอน removed (Sleitnick Component / Matter pattern). Zone/Placement/Loot/Raid ใช้ | M | 🔥high |
| 18.3 | **Schema/guard lib** (`t.number/string/array/strictInterface`) — validate payload shape. **gate ของ 19.1 + receipt 20.1 + ทุก remote handler** (ดึงมาทำต้นเฟส) | M | 🔥high |

**▸ Utilities:**
| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 18.4 | **CooldownService** — server-auth cooldown/debounce (`Consume` atomic) + global (backed by MemoryStore 24.7). กัน spam-claim ทั้งคลาส | S | 🔥high |
| 18.5 | **ItemDefinitionService** — registry กลาง item/deco (rarity/category/footprint/sellPrice) = source of truth ให้ Codex/Refine/Vault/Loot/Placement | S | 🔥high |
| 18.6 | **InteractionService** — ProximityPrompt wrapper + interactable registry (shop/NPC/vault/pickup). DialogSystem + genre pack ใช้ | S | high |
| 18.7 | **Seeded RNG** (`Shared/Random`) — Int/Float/Range/Choice/Weighted/Shuffle + named streams (test ได้) | S | med |
| 18.8 | **Object Pool** (`Shared/Pool`) — Get/Return/PreWarm ลด instance churn | S | med |
| 18.9 | **Scheduler/Timer** — Debounce/Throttle/Every/After/Stopwatch บน Heartbeat เดียว | M | med |
| 18.10 | **Serializer** — nested table ⇄ attribute/JSON + round-trip Vector3/CFrame/Color3 + version (ปิดช่อง nested ReplicatedState) | M | med |
| 18.11 | **SettingsService** — bridge `Profile.Settings` (Get/Set + whitelist key+type) ปลดล็อก settings UI | S | med |

✅ **Exit:** lifecycle คุม boot order ทุก service · แต่ละ module มี TestRunner suite · service ถัดไปเรียกใช้แทน re-implement

---

## 🔌 Phase 19 — Networking, State & Validation (ดูด "Replication framework" เดิม)

🎯 **เป้า:** client-server + replication ระดับสูง ปลอดภัย

| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 19.1 | Wire **schema-guard (18.7) เข้า NetService** — validate ทุก remote payload (reject table ผิด shape ที่ขอบ) | M | 🔥high |
| 19.2 | **ReplicatedState v2** — รองรับ nested table ผ่าน Serializer (18.6) + จัดการ intermediate-value | M | med |
| 19.3 | **Replication pattern ระดับสูง** — snapshot/command แทน RemoteEvent ดิบ | L | med |
| 19.4 | **UI state-binding layer** — `Bind(gui, prop, observable)` แทน HUD polling 0.2s / RenderStepped loops | M | med |

✅ **Exit:** remote ปฏิเสธ payload ผิดรูป · nested state replicate ได้ · HUD เลิก poll

---

## 💰 Phase 20 — Monetization & Economy Correctness (pillar ที่ขาดที่สุด)

🎯 **เป้า:** framework รับ Robux ได้ — อย่างปลอดภัย (ตอนนี้ทั้ง repo ไม่มี `MarketplaceService` เลย)

| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 20.1 | **MonetizationService** — idempotent `ProcessReceipt` (persist `PurchaseId` ใน profile กัน double-grant) + `PromptGamePass/Product` + `OwnsGamePass` cache + `OnPurchase` signal + grant ผ่าน Economy/Item | M | 🔥high |
| 20.2 | **ShopService** — catalog server-authoritative: validate price/level/ownership → debit Economy → grant Item / prompt DevProduct (exploit surface #2 รองจาก trade) | M | high |

✅ **Exit:** receipt idempotent (ไม่ dupe/หาย) · ซื้อใน shop ผ่าน server validation · มี test coverage

---

## 🛡️ Phase 21 — AntiCheat Durability & Observability (ดูด "Telemetry" เดิม)

🎯 **เป้า:** จาก "ตรวจจับ" → "moderation ที่ persist + audit ได้ + คุม runtime ได้" (ตอนนี้ flag หายตอน server ตาย, kick แล้ว rejoin ทันที, ไม่มี kill-switch)

| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 21.1 | **Ban policy + persistence** — per-reason escalation (warn/kick/temp/perm) reuse `AdminCommands` ban infra + DataManager + PlayerAdded gate | M | 🔥high |
| 21.2 | **Logger sink + flag journal** — flush flag ลง DataStore/Messaging/webhook (bootstrap มี stub "plug Discord logger here" อยู่แล้ว) | M | high |
| 21.3 | **Admin flag dashboard** — `/flags` `/clearflags` `/acban` บน `GetFlagCount`/`GetAllFlagged` ที่มี 80% แล้ว | M | med |
| 21.4 | **FeatureFlags** บน ReplicatedState — runtime enable/disable detector + override threshold (Constants frozen ใช้แทนไม่ได้) | M | med |
| 21.5 | **AnalyticsService** — typed event funnel auto-subscribe `OnTransaction`/`OnLevelUp`/`OnQuestComplete` (signal ยิงอยู่แล้ว) | M | med |
| 21.6 | **World-bounds/kill-floor detector** + **flag-count time-decay** (sliding window ลด false-positive session ยาว) | S | med |
| 21.7 | *(optional)* **Heuristic/replay detector** บน rolling ring-buffer — จับ cheat ใต้ threshold | L | med |

> *แยก exit gate ได้: **21a moderation** (21.1–21.3, 21.6) · **21b telemetry/runtime** (21.4 FeatureFlags, 21.5 Analytics, 21.7 heuristic)*

✅ **Exit:** flag persist ข้าม restart · ban escalate · toggle detector ตอน runtime · analytics event ไหล

---

## 🎨 Phase 22 — Client UI Breadth & Shipping Polish *(แตก 22a/b/c — งานเยอะ = 3 เฟสย่อย)*

🎯 **เป้า:** เกม shippable บน mobile + console (ตอนนี้ controller เล่นเมนูไม่ได้, ทุก template เป็น raw pixel)

> ⚠️ **ลำดับสำคัญ:** Theme (22a.1) + i18n seam (22a.4) ต้องมาก่อน component kit — retrofit ทีหลังแพง

**▸ 22a — Foundation:**
| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 22a.1 | **Theme / design-token** (color/font/spacing/radius, `SetTheme`/`OnThemeChanged`) — palette hardcode ซ้ำ 6+ ไฟล์ | M | 🔥high |
| 22a.2 | **Responsive scaling** — UIScale/aspect/size constraint + device-class + safe-area (mobile/tablet/console) | M | high |
| 22a.3 | **Screen router + z-index manager** — Push/Pop/Replace + modal scrim + DisplayOrder รวม (แก้ z-fighting: Tooltip=1000/Cutscene=500/Dialog unset) | M | high |
| 22a.4 | **Localization / i18n seam** — LocalizationService bridge + localized-text helper/`Text(key)` (สร้าง seam ก่อน component kit bake text) | M | high |

**▸ 22b — Component kit + input:**
| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 22b.1 | **Component library** — Toggle/Slider/Dropdown/TextInput/Tabs/recycling ScrollList/Modal shell (ใช้ Theme + i18n seam) | L | high |
| 22b.2 | **Gamepad/controller navigation** — Selectable/NextSelection*/SelectedObject focus groups | L | high |
| 22b.3 | **Input-rebinding UI** + persist (InputManager.Rebind มี backend แล้ว) | M | med |

**▸ 22c — Polish:**
| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 22c.1 | **Accessibility** — text-scale, colorblind palette, reduce-motion (ถูกเมื่อมี Theme+i18n) | M | med |
| 22c.2 | **Toast/notification queue** (anchor/action/click-dismiss/sticky/progress) | S | med |
| 22c.3 | **Haptics helper** — HapticService Pulse + presets, wire CameraController.Shake | S | low |

✅ **Exit:** ทุก template themed + responsive + controller-navigable + แปลภาษาได้ · component kit reuse ได้

---

## 🌱 Phase 23 — Genre Engine Pack: Collection / Base / Heist *(optional, reusable)*

🎯 **เป้า:** ขยาย genre ที่ framework รองรับ (collection/farming/tycoon/raid) — เป็น engine reusable ไม่ใช่ content เกมใดเกมหนึ่ง

> **Dependency order:** ItemDefinition(18.2) → Collection + Vault + Refine → Placement + Idle → Loot → **Raid + Protection (ท้ายสุด เพราะขยับของมีค่า)** · ทุก path ที่ย้ายมูลค่า **ลอก `EconomyService.Transfer`** (hold→commit→rollback) + ใส่ AntiCheat hook

| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 23.1 | **CodexService** — Collection/Pokedex registry: per-entry count, rarity, first-seen, completion %, set reward *(ชื่อ Codex เลี่ยงชนกับ Roblox `CollectionService`)* | M | 🔥high |
| 23.2 | **RefineService** — atomic recipe/craft/transform engine (+ timed Begin/Claim variant) | M | high |
| 23.3 | **VaultService** — capacity-aware secure storage server-auth + `GetValue` (feed heist loot-cap + leaderboard) | M | high |
| 23.4 | **PlacementService** — per-player plot, grid snap, overlap/ownership validation, save & rebuild ตอน join | L | high |
| 23.5 | **IdleService** — offline/passive accrual + clamp `MAX_OFFLINE` + cap, `OnOfflineEarnings` | M | high |
| 23.6 | **LootService** — weighted table + persisted pity, drop-rate โปร่งใส, เรียก `Codex.Discover` | M | med |
| 23.7 | **RaidService + ProtectionService** — target-selection/cooldown/shield/revenge state machine + time-boxed immunity reusable | L | high |
| 23.8 | **AIService** — NPC mover + PathfindingService wrapper (roaming NPC, raid attacker/defender) — มี `Raycaster` แล้วแต่ไม่มี pathfinding | M | med |

✅ **Exit:** sample loop (collect→refine→vault→raid) boot เขียวด้วย framework service + config ล้วน

---

## 🤝 Phase 24 — Retention, Social & Live-Ops *(optional)*

🎯 **เป้า:** กลไก retention/social มาตรฐานที่ประกอบจาก primitive ที่มี

| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 24.1 | **DailyRewardService** — login streak + claim ladder (คู่กับ CooldownService 24h gate) | M | 🔥high |
| 24.2 | **MailService / NotificationInbox** — ข้อความ offline ถาวร + reward-attachment claim (compensation/gift) | M | med |
| 24.3 | **TradeService / GiftingService** — two-party both-confirm atomic swap (item+currency) — dupe surface #1, vet ครั้งเดียวให้แน่น | L | med |
| 24.4 | **Inventory depth** — unique item instance, stack, equip slot (ปลดล็อก RPG/gacha/crafting) | L | med |
| 24.5 | **EventService + VisitService** — seasonal/timed content + read-only base visiting | M | med |
| 24.6 | **TeleportService wrapper** — TeleportAsync retry + teleport-data + reserved-server + `GetPlayerPlaceInstanceAsync` (dependency ของ 24.8) — ไม่มี TeleportService ใน repo เลย | M | med |
| 24.7 | **MemoryStore wrapper** — queue/sorted-map cross-server ephemeral (matchmaking 24.8 + เป็น backing ของ global cooldown 18.4) | M | med |
| 24.8 | **PartyService** — grouping/matchmaking บน CrossServerMessaging + Teleport(24.6) → reserved server (ปลดล็อก co-op/lobby) | L | low |

✅ **Exit:** retention loop ประกอบจาก Economy/Item/Cooldown/Data ที่มี

---

## ✨ Phase 25 — Juice & Motion (VFX / SFX / Animation / Tween)

🎯 **เป้า:** เลเยอร์ "ความรู้สึก" — feedback ที่ทำให้เกมมีชีวิต. มี `EffectsController` / `SoundController` / `TweenUtil` / `Spring` เป็นฐานแล้ว → ยกเป็น service เต็ม

| # | งาน | Effort | Impact |
|---|-----|:---:|:---:|
| 25.1 | **VFXService** — preset particle/beam/trail/highlight, **pooled** (ใช้ Pool 18.4), one-shot + attached, auto-cleanup, registry ของ effect | M | 🔥high |
| 25.2 | **SFXService** — ยกระดับ SoundController: 3D positional, sound bank/registry, ducking, randomized pitch/variation, category volume (เชื่อม SettingsService 18.8) | M | high |
| 25.3 | **AnimationService** — play/stop server+client, track priority/blending, registry, event markers (keyframe signal) | M | med |
| 25.4 | **MotionService (UI)** — tween/spring preset, sequence/timeline, stagger, enter/exit transition (ยกระดับ TweenUtil/Spring + เชื่อม component library 22.3) | M | high |
| 25.5 | **MotionService (3D/World)** — tween Part/Model CFrame, path/waypoint, easing preset, looping idle (bob/spin/float) | M | med |
| 25.6 | **RagdollService** — toggle ragdoll/recover, hook HumanoidState (combat/raid/obby feel; HumanoidStateGuard ตรวจอย่างเดียว ไม่ขับ) | S | low |

> **Depends:** Pool(18.4) สำหรับ VFX · Theme(22.1)+components(22.3) สำหรับ UI motion · Settings(18.8) สำหรับ audio volume
> **หมายเหตุ:** เป็น presentation pillar — รันขนานกับ Phase 22 ได้

✅ **Exit:** effect/sound/anim/tween เรียกผ่าน service เดียว (preset + pooled) · ไม่มีใคร `Instance.new` particle/tween มือ

---

## 🛠️ Tooling Track *(เลเยอร์ MCP/tooling — ไม่นับเป็น framework phase)*

> ตาม boundary: Rojo/CI/install/release อยู่เลเยอร์ tooling ไม่ใช่ in-game framework. แยกไว้ที่นี่เพื่อ track
>
> **สถานะ (v1.0.0):** ✅ `Gaxia.VERSION` + `CHANGELOG.md` · ✅ **GuiCodec** (`Gaxia.GuiCodec` — `ToCode` Instance→Luau + `Make` code→Instance, verified) · ✅ **scaffold.mjs** (`new:service` generator + init wiring, verified dry-run)
> **⏸️ ค้าง — ต้องตัดสินใจ/ติดตั้งเครื่องมือก่อน:**
> - **Rojo `default.project.json`** — fork: ปัจจุบัน runtime คือ `Gaxia_Packages` (Folder) + `init` (ModuleScript child) ตามที่ MCP push สร้าง และโค้ดทั่ว framework `require(...):WaitForChild("init")`. แต่ Rojo เห็น `Gaxia_Packages/init.lua` = ทำให้ `Gaxia_Packages` เป็น **ModuleScript** (ไม่มี `init` child) → ต้อง refactor require ทุกที่ให้ require `Gaxia_Packages` ตรงๆ (ดูคอมเมนต์ใน server `init.lua` ที่ flag ไว้แล้ว). **เป็น decision repo-wide — รอ review**
> - **CI (luau-lsp/selene/stylua) + headless test runner** — เครื่องไม่มี rojo/selene/stylua ติดตั้ง → เขียน config ได้แต่ verify ไม่ได้ในรอบนี้
> - **build `.rbxm` deterministic · sample game `gaxia-starter` · Companion Plugin** — งานใหญ่/interactive (โดยเฉพาะ Companion Plugin = one-click install + editor tools) ควร build + ทดสอบใน Studio แบบ interactive ตอน review

- **Rojo `default.project.json` + toolchain** (aftman/rokit: rojo/luau-lsp/stylua/selene) — src/ เป็น Rojo shape อยู่แล้ว · เลิกพึ่ง MCP /submit อย่างเดียว
- **One-command bootstrap** — copy 2 bootstrap เข้า ServerScriptService/StarterPlayerScripts อัตโนมัติ (ฆ่ากับดักอันดับ 1)
- **GitHub Actions CI** — luau-lsp typecheck + selene + stylua --check ทุก push
- **Headless test runner** (lune / run-in-roblox) รัน `.spec.lua` suite ของ framework ใน CI
- **Scaffolding CLI** — `new:service` / `new:detector` ที่ patch `LIB_KEY_MAP` + type export + bootstrap load list ให้
- **Versioning + CHANGELOG + build `.rbxm` deterministic + `Gaxia.VERSION`** runtime
- **Generated API reference** จาก source + CI diff vs MANUAL (กัน doc drift ข้าม 4 ไฟล์)
- **Sample game `gaxia-starter`** (boot เขียว = CI integration smoke test) + **Creator Hub publish**
- **GUI ⇄ Code converter** — plugin/ModuleScript 2 ทาง: `code→Instance` (รัน Templates builder, มีแล้ว) + `Instance→code` (เดิน GUI subtree → emit `make(className, props, children)` เป็น Templates.lua). ได้ทั้งออกแบบใน Studio (Instance) + version control เป็น text
- **Gaxia Companion Plugin (สำเร็จรูป)** — plugin ที่ **install/update framework + เครื่องมือ editor** (ไม่ใช่แทน source): one-click install · วาง 2 bootstrap อัตโนมัติ (ฆ่ากับดักอันดับ 1) · GUI⇄code converter · scaffolding (new service/detector) · insert service on-demand. **คู่กับ Rojo source — plugin = delivery/DX layer, source = ความจริง**

---

## 📊 ภาพรวมลำดับ (critical path)

```
17 Hardening ─► 18 Foundation ─► 19 Net/State ─┬─► 20 Monetization
  (data+AC fix)   (lifecycle+component          ├─► 21 AntiCheat durability (21a/21b)
                   +schema+primitives)          └─► 22a→22b→22c UI ──► 25 Juice/Motion
                                                       │               (presentation, ขนานกับ 22)
        (optional) 23 Genre pack ◄─ ต้องมี 18.2(component)+18.6(interaction)+20-pattern+22-UI+25-VFX
                   24 Retention   ◄─ ต้องมี 18 + 20 (+ 24.6 Teleport ก่อน 24.8 Party)

Tooling track = ขนานได้ตลอด (Rojo+CI เร็วสุดเพื่อ unblock · GUI⇄code converter + Companion Plugin = DX layer)
```

**สรุปแนะนำ:** ทำ **17 → 18 → 19** เป็นแกน (correctness + foundation) แล้วเลือก pillar (20/21/22) ตามที่อยากปล่อยก่อน · genre pack (23/24) ไว้ทีหลังเมื่อแกนเสถียร

---

*สร้างจาก source survey จริง · framework-only scope*
