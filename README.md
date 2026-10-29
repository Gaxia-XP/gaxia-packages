# Gaxia Packages

A Roblox (Luau) game framework split into ~100 packages: player data, currencies, shops,
Robux purchases, quests, UI, admin commands, anti-cheat and more. Install only the
packages a game uses; each one starts only when the game needs it.

เฟรมเวิร์กเกม Roblox แบ่งเป็น ~100 package เลือกติดตั้งเฉพาะที่เกมใช้ และแต่ละตัวเริ่มทำงานเมื่อเกมต้องใช้เท่านั้น

| Read | For |
|---|---|
| [MANUAL.md](MANUAL.md) | คู่มือฉบับเต็ม (ภาษาไทย) — every package explained |
| [AGENTS.md](AGENTS.md) | AI coding agents: the rules and the task → playbook table |
| [playbooks/](playbooks/README.md) | Step-by-step recipes with complete, checked code (for agents and people) |
| [playbooks/api/](playbooks/api/README.md) | Generated API reference: every function, signal and type |
| [ROJO.md](ROJO.md) | Rojo workflow, and building a game with only some packages |
| [CHANGELOG.md](CHANGELOG.md) | What changed |

## Install

- **Roblox Studio:** the *Gaxia Companion* plugin → **Install** tab → tick the packages → **Install**.
- **Rojo:** `node tools/packages.mjs build --select Data,Economy,Shop --out ../MyGame/gaxia`, then
  `rojo serve ../MyGame/gaxia/default.project.json`.

Details: [playbooks/start/01-install-packages.md](playbooks/start/01-install-packages.md).

## Working on the framework

```sh
node tools/packages.mjs check                     # package catalogue matches the source
node tools/gen-api.mjs                            # regenerate playbooks/api
LUAU_AST=/path/to/luau-ast node tools/check-architecture.mjs --complete
node tools/check-playbooks.mjs --v2 --run         # every playbook code block type-checks, then runs headless
node tools/run-game.mjs --self-test               # the headless harness still catches the bugs it should
node tools/run-game.mjs --quiet --players 3       # boot the whole framework headless: no errors, no hangs
node scaffold.mjs new:service <Name>              # add a service, fully wired
```

CI (`.github/workflows/checks.yml`) runs these checks on every push and pull request, with the pinned tools from
`bash tools/ci/install-tools.sh <dir>` (use the same script to get them locally).

See [playbooks/framework/change-the-framework.md](playbooks/framework/change-the-framework.md). The headless harness (`run-game.mjs`: boot the framework and a game's scripts with no Studio) is described in [tools/harness/README.md](tools/harness/README.md).
