# packs/player-data

The player data pack: ProfileStore 1.0.3 wrapped by DataManager, as one folder that needs nothing else from the
library. Gaxia Crew's `library_add` tool puts it in a place at `ServerStorage.GaxiaPackages.PlayerData`; it also
works dropped in by hand.

| Module | What it is |
|---|---|
| `DataManager` | The library's DataManager, standalone edition: requires only this folder, template from DataConfig |
| `DataConfig` | The game's own settings: store name, key prefix, tunables, `Template` (the one file a game edits) |
| `DataMigration` | The library's DataMigration, requiring the pack's Signal |
| `ProfileStore` | `lm-loleris/profilestore@1.0.3`, unchanged (Apache-2.0) |
| `Signal` | `sleitnick/signal@2.0.3`, unchanged (MIT) |
| `NOTICE` | The licenses; nothing requires it |

Use from a server Script:

```lua
local ServerStorage = game:GetService("ServerStorage")
local DataManager = require(ServerStorage.GaxiaPackages.PlayerData.DataManager)

DataManager.OnLoaded:Connect(function(player, data)
	print(player.Name, data.Coins)
end)
-- DataManager.Get(player, "Coins"), DataManager.Set(player, "Coins", 10), DataManager.WaitFor(player)
```

Files are LF. `manifest.json` pins each file's sha256.

- To rebuild after a library change: `python scripts/build-player-data-pack.py` (needs `wally install`).
- To check: `python scripts/test-player-data-pack.py --luau <luau> --luau-compile <luau-compile>`.
  It checks the build and the hashes, the words the Creator Store's scan flags, a compile, and a run of DataManager
  in the standalone Luau CLI against a fake place, with the default and a custom template.

Then copy the folder to Gaxia Crew's `server/library/player_data/`.
