# Writing a playbook

Playbooks are read by AI agents, including small and weak ones. A weak agent copies
code exactly, follows steps literally, and cannot fill gaps. Write for that reader.

## Shape

Start from [TEMPLATE.md](TEMPLATE.md). Keep these sections, in this order:
title, one-line result, *Use this when*, *Packages*, *You will create*, numbered steps,
*Check that it works*, *Common mistakes*, *Change it*, *See also*.

## Rules for the text

- Short sentences (under 20 words). Imperative: "Create a Script", not "You might want to".
- One way to do each thing. Put alternatives in *Change it*, never inside a step.
- Every step says **where** (service, folder, script type, script name), then gives the code.
- Name things the same way every time (a script called `CoinShop` stays `CoinShop`).
- *Use this when* lists the phrases users type, in English and Thai.
- Explain *why* in one line after the code, not in long paragraphs before it.
- Under 220 lines (a full example game may be longer).

## Rules for the code

- Every ```lua block starts with its location line:
  `-- Script: ServerScriptService/Name`, `-- LocalScript: StarterPlayer/StarterPlayerScripts/Name`,
  `-- ModuleScript: ServerStorage/Folder/Name`, or `-- fragment` (a few lines shown on their own).
- Blocks are **complete**: an agent pastes the block into an empty script and it works.
  Use `-- fragment` only for one- to five-line illustrations.
- Each script path appears once per playbook. A later step that changes a script shows a
  new script with its own name, or a `-- fragment` with the exact lines to add.
- Require lines exactly as in AGENTS.md rule 1 and 2. Never `:: any`, never `.init`.
- Only names from [api/INDEX.md](api/INDEX.md). The checker rejects anything else.
- Server scripts first check their packages with `assert(GaxiaServer.IsInstalled("X"), "…")`.
- Never read player data before it is loaded (`Data.WaitFor` or `Data.OnLoaded`).
- The server validates everything that comes from a client.
- Print one `[ScriptName] ready` line (and one line per important event) so the agent can see
  in Output that it works.
- Clean up per-player connections when the player leaves.

## Check before you commit

```sh
node tools/gen-api.mjs                      # regenerate playbooks/api from the source
node tools/check-playbooks.mjs --v2         # every block type-checks, names and links exist
```

`check-playbooks` needs `rojo`, `luau-lsp` and the Roblox definitions file (see the header
of `tools/check-playbooks.mjs`).
