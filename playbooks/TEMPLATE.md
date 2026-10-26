# <Task, in the words a user would use>

> One sentence: what the game has when you finish.

**Use this when** the user asks for: "<phrase>", "<phrase>" (ไทย: "<คำที่ผู้ใช้พิมพ์>").
**Packages:** `PackageA`, `PackageB` (the script below stops with a clear message if one is missing).
**You will create:** a Script `ServerScriptService/<Name>` and a LocalScript `StarterPlayer/StarterPlayerScripts/<Name>`.

## Step 1 — <verb phrase>

Create a **Script** in **ServerScriptService** named **<Name>**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/<Name>
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("PackageA"), "<Name> needs the PackageA package: install it (playbooks/start/01-install-packages.md)")

-- complete, working code; every name comes from playbooks/api
print("[<Name>] ready")
```

What it does: <one or two short lines>.

## Step 2 — <verb phrase>

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **<Name>**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/<Name>
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
```

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[<Name>] ready` and no red errors.
3. <a second thing the user can see or print>.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `<wrong code>` | `<right code>` | <reason> |

## Change it

- To <variation>: change `<line>` to `<line>`.

## See also

- [API: PackageA](../api/PackageA.md)
