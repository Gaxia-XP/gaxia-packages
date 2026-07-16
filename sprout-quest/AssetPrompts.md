# Sprout Quest — Asset Upgrade Prompts

> เอกสารนี้สำหรับ user (หรือ artist) ที่อยากปลด visual quality เลเยอร์ถัดไป — ทุก asset ที่ code-built ตอนนี้สามารถถูกแทนด้วย mesh จริง (custom-made) หรือ Toolbox model. ใช้ prompt ด้านล่างกับ Midjourney / Stable Diffusion / Roblox AI Generator / commission artist

> **Pipeline:** generate image → import as MeshPart (ใน Studio ใช้ AssetService:CreateMeshPartAsync) หรือ commission 3D model → replace the code-built placeholder via `mcp__roblox__insert_model` (asset id) หรือ manual import

---

## ระดับความสำคัญ

🔥 **High impact** — ปรับแล้วผู้เล่นเห็นชัดที่สุด
⭐ **Medium** — ปรับเสริม polish
🌱 **Low** — nice-to-have

---

## 🔥 Sprout (collectible) — `tag: Sprout` × 6 + `Sprout_Gold` × 2

**ปัจจุบัน:** Neon green/gold sphere (1.5–2 stud) + PointLight + Beam + sparkle particles. Idle bob animation.

**ทำไมต้องอัพ:** Sprout คือ object ที่ผู้เล่นเก็บที่สุด — ใช้งาน +6×N ครั้งตลอด session. ต้องดูสวย + memorable

**Image prompt:**
> low-poly 3D model of a glowing magical sprout, two small leaves emerging from a tiny seed, soft pastel green core with bioluminescent edge glow, cute friendly aesthetic for cozy farming game, 3-stud tall, transparent background, isometric 3/4 view, soft rim light. style: roblox stylized, similar to Adopt Me garden plants

**Gold variant prompt:**
> same as above but with shimmering 24k gold leaves, warm amber bioluminescent glow, slightly larger, treasure-feel, similar to Pokemon shiny variants

**Acquisition:**
- Best: commission 2 unique meshes (normal + gold)
- Free: Toolbox search "magical plant" / "glowing sprout" — pick stylized low-poly
- Quick: keep code-built version (current state acceptable for MVP)

---

## 🔥 Gardener Pip NPC — `tag: Pip_NPC`

**ปัจจุบัน:** Classic Roblox R6 avatar (userId=1) with bubble nameplate "🌾 Gardener Pip / Press E to talk"

**ทำไมต้องอัพ:** NPC คือคนคุย — character ที่จะอยู่ใน memory ของผู้เล่นที่สุด. avatar ตอนนี้ดูเหมือน default Roblox user ไม่มี personality

**Approach options:**
1. **Custom-clothed avatar** — สร้าง outfit pack: straw hat + green overalls + brown work boots + gardener gloves. Upload as bundle, set HumanoidDescription
2. **Custom rig** — commission unique character mesh (R15 compatible)
3. **Asset ID swap** — find a popular farmer NPC bundle from Creator Store

**Image prompt for outfit reference:**
> friendly elderly gardener man, weathered face with kind eyes, wide-brim straw sun hat, dirty green denim overalls over a tan shirt, brown leather work boots, holding a small wooden trowel, low-poly Roblox stylized character, full body front view, friendly NPC aesthetic, similar to Stardew Valley character art style

**HumanoidDescription template (Lua):**
```lua
local desc = Instance.new("HumanoidDescription")
desc.HatAccessory      = "<Roblox AccessoryId for straw hat>"
desc.Shirt             = "<Shirt asset ID — overalls>"
desc.Pants             = "<Pants asset ID>"
desc.SkinColor         = Color3.fromRGB(220, 180, 140)
desc.HairAccessory     = "<gray hair AccessoryId>"
humanoid:ApplyDescription(desc)
```

---

## ⭐ Pip's Hut — `Workspace.Map.PipsHut`

**ปัจจุบัน:** 5 wood-material walls + slate roof, brown/red palette. Rectangular box shape, no windows.

**ทำไมต้องอัพ:** สถานที่ landmark ของเกม — ต้องดูเหมือนบ้านที่มีคนอยู่ ไม่ใช่ box ไม้

**Image prompt:**
> cozy small wooden cottage with red tile roof, low-poly stylized 3D model, single front door slightly ajar, two small square windows with cross-pattern frames, hanging flower pot beside door, small chimney with smoke, surrounded by grass tufts and a wooden barrel of vegetables, isometric front 3/4 view, warm afternoon lighting, similar style to Animal Crossing buildings

**Free model search keywords:**
- "low poly cottage"
- "wooden cabin small"
- "farmhouse roblox"

---

## ⭐ Cave Entrance — `Workspace.Map.CaveArea.CaveEntrance`

**ปัจจุบัน:** 3 slate pillars (left + right + lintel) forming a doorframe + transparent glass "CaveDoor" Part that becomes invisible/walkable when player reaches Lv.3

**ทำไมต้องอัพ:** จุด landmark ของพื้นที่ต่อไป — gating mechanism

**Image prompt:**
> mysterious cave entrance carved into a low rocky cliff, irregular dark gray slate rock formation arching around a deep black opening, hanging vines and moss patches, faint blue magical glow emanating from the depths, low-poly stylized 3D model for adventure game, isometric 3/4 view, similar to Don't Starve cave entrance style

**Required to keep:**
- The `CaveDoor` invisibility-toggle Part (gameplay gate) — can wrap the mesh
- The `CaveDoor` CollectionService tag must survive the swap

---

## ⭐ Trees (× 5) — `Workspace.Map.Decor.TreePine_1..5`

**ปัจจุบัน:** Cylinder trunk + Sphere foliage, Wood + Grass materials, brown + green. All identical.

**ทำไมต้องอัพ:** ห้องเล่นรอบนอก — 5 ต้นเดียวกันหมดดูซ้ำซาก

**Image prompt (3 variants):**
> Variant A — Cypress: tall narrow conifer, dark teal-green dense foliage, slim brown trunk, low-poly stylized, isometric view
> Variant B — Oak: wide canopy bushy oak tree, mid-green leaves, sturdy thick brown trunk with visible roots, low-poly stylized
> Variant C — Sakura: small flowering cherry tree with pink-white blossoms, slender brown trunk, low-poly stylized, slightly transparent foliage for soft look

**Acquisition:**
- Best: 3 different mesh variants + scale randomization
- Free: Toolbox "low poly tree pack" search → import 3-5 variants
- Quick: keep code-built; vary trunk color slightly per tree

---

## 🌱 Welcome Sign — `Workspace.Map.Beach.WelcomeSign`

**ปัจจุบัน:** Wood pole + wood board with SurfaceGui text "🌱 Welcome to Sprout Isle"

**Image prompt:**
> rustic wooden signpost partially weathered, hand-carved tilted board with chiseled letters, single rusty nail visible, small flowering vine wrapping around the pole, low-poly stylized 3D model for cozy farming game, isometric front view

---

## 🌱 Rocks (Meadow + Cave) — `Workspace.Map.*.Rock*`

**ปัจจุบัน:** Sphere/block Slate-material parts, gray.

**Image prompt:**
> small mossy boulder cluster, irregular natural rock shapes with patches of green moss growing on top, low-poly stylized, similar to Genshin Impact world props, isometric view, 3-5 stud diameter

---

## 🌱 Ocean Surface — `Workspace.Map.OceanSurface`

**ปัจจุบัน:** Single huge Glass-material Part, transparent blue

**Image prompt (or use Roblox Terrain):**
> stylized cartoon ocean with gentle foam waves, gradient turquoise to deep blue, soft sparkle highlights, slight ripple pattern, low-poly water plane for top-down cozy island game

**Better:** ลบ OceanSurface ไป + ใช้ `mcp__roblox__fill_terrain` ด้วย Material.Water — Roblox Terrain water มี shader พื้นบ้านอยู่แล้ว

---

## ⚙️ Engineering note สำหรับการอัพ asset ใน framework

1. **อย่าลบ CollectionService tags** — ทุก gameplay script ใช้ tags
2. **อย่าลบ Attribute** เช่น `PolishedV1`, `_homeY` ที่ idle-bob script ใช้
3. **ถ้าเปลี่ยน sprout ให้เป็น Model แทน Part:** อัพเดต `SproutQuestSystem` ตรง `.Touched` event ให้ติด Touched กับ PrimaryPart แทน
4. **Pip swap:** keep child Part `PipTalkAnchor` for ProximityPrompt mount — เก็บ tag `Pip_NPC` + `PipTalkAnchor` ไว้

---

## Acquisition log (สำหรับ track ที่ user upload จริง)

| Asset | Status | Path | Source | Date |
|---|---|---|---|---|
| Sprout (green) | code-built v2 (polish) | Map.Meadow.SproutSpawn_*.Sprout | self | 2026-05-28 |
| Sprout (gold) | code-built v2 | Map.CaveArea.SproutSpawn_Gold_*.SproutGold | self | 2026-05-28 |
| Pip NPC | classic R6 avatar | Map.PipsHut.PipNPC | create_humanoid_model userId=1 | 2026-05-28 |
| Pip's Hut | code-built (walls+roof) | Map.PipsHut | self | 2026-05-28 |
| Trees ×5 | code-built (Trunk+Foliage) | Map.Decor.TreePine_* | self | 2026-05-28 |
| Cave entrance | code-built (arch+pillars) | Map.CaveArea.CaveEntrance | self | 2026-05-28 |
| Welcome sign | code-built + SurfaceGui | Map.Beach.WelcomeSign | self | 2026-05-28 |
| Rocks | code-built | Map.* | self | 2026-05-28 |
| Ocean | Glass-material Part | Map.OceanSurface | self | 2026-05-28 |
