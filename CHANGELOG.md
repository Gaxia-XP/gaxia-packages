# Changelog — GaxiaPackages

All notable changes to the GaxiaPackages in-game framework. Runtime version is
exposed as `Gaxia.VERSION` (shared) and `GaxiaServer.VERSION` (server).

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/);
this framework uses a single rolling version until a public release cut.

## Unreleased

### Fixed — hardening (ui-root)
- **`PlayerGui.Gaxia_UI` is created on demand.** `UIController.GetActiveScreen` / `HUD` /
  `Overlays` now find or create the ScreenGui (ResetOnSpawn off, with the `HUD` and
  `Overlays` folders) in one place, so `NotificationService`, `MenuController`,
  `HUDController`, `HealthBarController`, `InventoryController` and the pet panel draw
  without the game making it first. Before, they waited 5 s and showed nothing. A
  `Gaxia_UI` made in StarterGui is still reused (it waits up to 5 s for Roblox's copy) and
  gets any missing folder. With no character yet (CharacterAutoLoads off, slow spawn) Gaxia
  draws into a stand-in `Gaxia_UI` and, when Roblox's copy arrives, moves its content into
  that copy and removes the stand-in, so PlayerGui never holds two. The pets, ui, show-values-on-screen and troubleshooting
  playbooks no longer create `Gaxia_UI` themselves.
- **`Toast.ShowAction`** (new): a toast with Accept / Decline buttons (`AcceptText`,
  `DeclineText`, `OnAccept`, `OnDecline`, `Duration` default 15 s). At most one callback
  runs; a timeout or `Toast.Clear` declines, unless `DeclineOnTimeout = false` (then the
  toast just goes away and neither callback runs).
- **`UI.InviteToast` works:** friend requests, guild and party invites show an action toast
  whose buttons answer the service. Only a Decline click declines: an ignored toast goes
  away after 30 s without answering, so the invite stays open on the server and
  `/accept`, `/partyjoin`, `/guildjoin` keep working until it expires there. Behaviour change: requiring it no longer blocks up to
  ~60 s waiting for the remotes (each service is wired on its own thread), so
  `Gaxia.UI.InviteToast` now loads through the loader too, also when Friend / Guild /
  Party are not installed.
- **`Components.Slider`** keeps its UserInputService connections in a Trove that is cleaned
  when the slider (or a parent) is destroyed; the handle has a new `Destroy()`.
- **`Responsive`:** `Apply` disconnects its viewport / camera listeners when the gui or its
  UIScale is destroyed, follows a new `CurrentCamera`, and no longer stacks listeners when
  called twice. Behaviour change: on touch screens the scale from `Apply` is at least
  0.75 (was 0.5) so buttons stay tappable; `ComputeScale(viewport, ref?, touch?)` takes
  the new optional `touch` flag and `GetScale()` (new) applies it for this device.
- **`MenuTemplate`** is centred (AnchorPoint 0.5, 0.5 at Position 0.5, 0.5), so
  `MenuController` menus and the pet panel open in the middle instead of the top-left.

### Fixed — hardening (economy-econfig)
- **Behaviour change — Economy rejects instead of clamping.** `Economy.Add`, `Spend` and
  `Transfer` accept only a whole number from 1 to `Economy.MaxTransaction`. A fraction,
  NaN, `math.huge`, 0, a negative amount or an amount above the limit now returns `false`
  and changes nothing (before: fractions were rounded down and big amounts were cut to the
  limit, so `Spend(player, "Coins", 2000000)` took only 1,000,000 and returned `true`).
  `Economy.Set` accepts a whole number from 0 to `Economy.MaxBalance` (before: clamped).
  The balance itself still stops at `MaxBalance` on `Add`.
- Economy no longer fails silently: every refused call warns once per call site and
  reason, with the reason, the expected signature and the calling script line, e.g.
  `Economy.Add(player, 100, "Coins")` → `[Economy] Add refused: currency must be a
  non-empty string, got number 100 (are currency and amount swapped?). Expected
  Economy.Add(player: Player, currency: string, amount: number): boolean`. A
  non-Player `player` is refused the same way.
- Economy refuses (with a warning) a currency whose saved value is not a number
  (`Inventory`, `Pets`, …) instead of overwriting that data with a number; `Get` returns 0.
- A saved balance that is NaN or ±inf (corrupt, e.g. from bad game math through
  `Data.Set`) is not treated as "not a currency": `Economy.Set` overwrites it (the
  `OnTransaction` delta counts it as 0) and warns that it repaired it, so the profile can
  save again. `Get` returns 0 and `Add` / `Spend` refuse it, each with a warning that says
  to repair it with `Economy.Set`.
- Added `Economy.GetMaxTransaction()` and `Economy.GetMaxBalance()`. Idle offline
  earnings and Raid loot are capped at `GetMaxTransaction()` before they are paid, so
  they keep paying the limit (as the old clamp did) instead of being refused.
- Quest and Achievement currency rewards (every currency, with or without the Pet
  package) are rounded down and capped at `GetMaxTransaction()` before they are paid, as
  the old clamp did: a 10.5 reward pays 10 and a 2,000,000 reward pays 1,000,000 instead
  of nothing. `Quest.Register` / `Achievement.Register` warn once when a reward amount is
  not a whole number from 1 to the limit, so the problem shows at boot. A Trade offering more than the limit of one
  currency now fails and rolls back (before: only the limit moved).
- An invalid `Economy.MaxTransaction` / `MaxBalance` (not a finite number above 0) falls
  back to the default instead of making every call error.
- **Behaviour change — `EConfig.Get` type-checks overrides.** An override whose type
  differs from the default's (`"5000000"` or `true` for a number setting) is ignored with a
  warning (once per key and value) and the default is returned. Before, it was returned
  as is (`/flag set Economy.MaxTransaction` with no value made every `Add` / `Spend`
  error). `EConfig.Enabled` therefore uses its default for a non-boolean override. A nil
  default still returns any override.

### Fixed — hardening (net-guard)
- **`Net.OnInvoke` handler errors no longer reach the client.** The handler runs in
  `xpcall`; an error is printed red in the server's Output (the error and its line
  first, then the handler's stack, then `(error in the Net.OnInvoke('X') handler; the
  client got nil)`) and the client's `Net.InvokeServer` returns `nil` instead of raising
  the server's error. Clients already treat `nil` as "rejected".
- **Validators that error reject the request.** A `validators` function that errors on
  what a client sent (for example indexing a number) drops the request and warns
  `[NetService] validator N of remote 'X' errored (request rejected)` (at most once per
  10 s per remote), instead of erroring inside the remote handler. No AntiCheat flag.
- **Added `Net.DeclareEvent(name, opts?)`** (server): creates a RemoteEvent that only the
  server fires, so clients can `Net.OnClient` it at once. Client `FireServer` calls on it
  are drained (rate-limited by `opts`), so they never queue up. A later `Net.OnServer` on
  the same name takes over. Replace `Net.OnServer("X", function() end)` stubs with
  `Net.DeclareEvent("X")` (the playbooks now do).
- **`Net.OnClient` waits for a remote the server has not created yet** instead of
  erroring after 10 s: after 5 s it warns once, `[NetService] Net.OnClient('X') is still
  waiting: … The server must declare it …`, and connects as soon as the server creates
  the remote. (It still yields the calling script until then, as before.)
  `FireServer` / `InvokeServer` keep their 10 s limit.
- **Duplicate registrations warn:** a second `Net.OnServer` (both handlers run) or
  `Net.OnInvoke` (the new one replaces the old) for the same name prints
  `[NetService] Net.OnServer('X') registered twice …`.
- **Behaviour change — `RemoteOpts.validationSeverity`** (`"soft"` | `"hard"`, default
  `"soft"`): the severity of the `RemoteValidation:X` AntiCheat flag when a validator
  rejects. Before, a failed validator was always a **hard** flag (escalation at once);
  now it is soft by default (counted toward the threshold ladder). This also applies to
  the framework's own validated remotes (Pets). Pass `validationSeverity = "hard"` to keep
  the old behaviour.
- **Behaviour change — Guard numeric checks reject NaN and ±inf.** `Guard.number` and
  `Guard.numberRange` (even with `math.huge` bounds) now reject NaN and ±inf, like
  `Guard.integer` already did. Before, `Guard.number` accepted both and `numberRange`
  accepted NaN.

### Fixed — hardening (liveops-quest-inventory)
- **DailyReward:** `Claim` returns `nil, "data not loaded"` while the player's data is not
  loaded (it used to hand out the reward without saving it, so it could be claimed again).
  `CanClaim` is `false` until the data loads.
- **Mail:** `Send` now returns `(string?, string?)`: `nil, "data not loaded"` when the
  recipient's data is not loaded (the mail used to be dropped while `Send` still returned an
  id), and nothing is stored or fired. **Behaviour change:** check the result before
  remembering a gift as sent. When the inbox is over `Mail.MaxMail`, finished mail (claimed,
  expired, or read with no attachments) is trimmed first, then the oldest, so an unclaimed
  gift outlives newer read text-only mail; the new mail is never trimmed (it could be when several
  mails were sent in the same second), so `OnReceive`'s mail is never nil.
- **Inventory:** every per-player call checks the player's data is loaded. `Add` now returns
  `(string?, string?)`: `nil, "data not loaded"` before the data loads (it used to return an
  id, fire `OnAdd` and lose the item). `Equip` returns `false, "data not loaded"`;
  `Remove`/`Unequip` return `false`; reads return nil / empty.
- **Quest:** `Track` iterates a snapshot of the active quests, so an `OnQuestComplete`
  handler that starts, restarts or abandons a quest no longer errors (`invalid key to
  'next'`) or skips/repeats quests; a quest started during a `Track` gets no progress from
  that event. Finished quests are saved in the player's data (`QuestsCompleted`, times
  completed per quest id); new `Quest.GetCompletedCount(player, questId)`.
  **Migration:** `QuestsCompleted` starts empty for every existing save: quests finished
  before this version are not in it, so `IsComplete` is `false` and `GetCompletedCount` is
  `0` for them. A game that kept its own record (the old progression playbook's
  `QuestsDone = { [questId] = true }`) must keep reading it, e.g.
  `Quest.IsComplete(player, id) or QuestsDone[id] == true` (the progression playbook does),
  or a live game restarts finished quests and pays their reward again.
  **Behaviour change:** `Quest.IsComplete` is `true` only for a quest the player finished
  (and that is not active again); it used to be `true` for every inactive quest, also one
  never started. `OnQuestComplete` gets a 4th argument `paid: number`, the currency amount
  actually added (pet bonus and balance cap included; 0 when none); its type is now
  `Signal<Player, string, QuestReward, number>` (3-parameter handlers keep working).
- **Leaderboard:** `Update` stores whole numbers (rounds down; it used to fail on a
  fraction) and returns `false` with a warning for NaN / infinity; `OnUpdate` carries the
  stored value. `GetTop`'s count (and `Leaderboard.DefaultTopN`) is clamped to 1..100 (more
  than 100 used to fail and return an empty list).
- Playbooks `live-ops`, `progression` and `items-and-inventory` updated (the progression
  example uses `Quest.IsComplete` instead of its own `QuestsDone` field).

### Fixed — hardening (data)
- **`Data.SetDefaults(defaults)` (new):** game code lists default values for its own saved
  fields once, at the top of a Script. They are deep-merged into the template and reconciled
  into every profile on load (after `DEFAULT_PROFILE`, before migrations), so `Data.WaitFor`
  and `Data.OnLoaded` already see them; each player gets their own copy of the tables. Values
  must be saveable (string keys only, or a list 1..n; mixed tables are refused); a list
  default is copied only when the field is missing and never merged into a saved list;
  built-in fields (`Coins`, `Level`, `Settings.Music`, …) and `__` names are refused with a
  warning. A call after a profile loaded warns and fills the players already loaded.
  `playbooks/game/player-data.md` uses it instead of the per-player `addMissingFields` helper.
- **`Data.WaitFor(player)` default timeout is now 120 s** (was 30 s;
  `Config.Data.WaitForDefaultTimeout`). Slow DataStore loads no longer return `nil` to game
  code that did not pass a timeout. Pass a timeout to wait less.
- **Neutral kick messages.** A failed data load kicks with `Could not load your data. Please
  rejoin.` (was `[DataManager] Could not load profile (another session active).`) and a
  session taken by another server with `Your data was opened on another server. Please
  rejoin.` (was `[DataManager] Profile released.`). The details go to a server warning. An
  error thrown by `LoadProfileAsync` is now caught and kicks the same way (before, the
  player stayed in the game without data).
- **Migrations are atomic.** `Migration.Migrate` runs the steps on a deep copy and commits
  only when every step succeeds; a step that errors (or a missing step) leaves the data
  exactly as it was and the warning names the failing step (`… failed: <error> (data left at
  v1)`). Behaviour change: before, the steps before the failing one were kept (the save moved
  to an in-between version, and a step that errored halfway left half its changes);
  `Migrate` now returns `false` and `OnMigrated` does not fire in that case. Steps still run
  in version order whatever order they were registered in.

### Fixed — hardening (social)
- **Guilds and friend lists now save with real UserIds.** `GuildData.Members` and
  `profile.Social.Friends` / `Blocks` / `PendingOut` were keyed by number UserId; a
  DataStore rejects such sparse number keys, so with real (large) UserIds
  `Guild.Create` failed with `save failed` and an accepted friend made the whole player
  profile fail to save (ProfileService "critical state"). Guild records are now saved
  with string member keys (in memory and in `Guild.GetGuild` / `GetById`, `Members` is
  still keyed by number UserId). **Changed:** `profile.Social` maps are keyed by
  `tostring(userId)` (`FriendService.SocialProfile` type); number keys from older data
  are converted when the profile is read. `Friend.GetList` / `GetBlocks` still return
  number `userId`s.
- **Party: a player who leaves the game leaves their party** (`PlayerRemoving` →
  `Party.Leave`): the next member becomes leader and an empty party is removed (it now
  also fires `OnPartyChanged`). Games that call `Party.Leave` themselves on
  `PlayerRemoving` keep working (the second call does nothing).
- **Party: `GetMembers` returns `{ Player }`** (was `{ any }`) and `GetLeader` returns
  `Player?`. **Changed:** `GetMembers` returns a new list each call, so changing it no
  longer changes the party.
- **Friend: accepting or declining a request removes it from the queued
  (cross-server) requests**, so it no longer comes back at the player's next join
  (where it could be accepted again after an unfriend). Blocking a user also removes
  their queued request. New `InviteQueue.Remove(kind, toUserId, match, ttlSec?)`.
- **Guild: every change waits for the player's data.** `Create`, `Invite`,
  `AcceptInvite`, `Kick`, `Promote`, `Demote`, `Transfer`, `Leave`, `Disband`,
  `SetDescription`, `VaultDeposit` and `VaultWithdraw` return `false, "data not loaded"`
  until `Data.IsLoaded(player)`. Before, an early `Create` skipped the "already in a
  guild" check and could leave a guild the player's profile did not point to. Friend
  changes (`SendRequest`, `AcceptRequest`, `DeclineRequest`, `Remove`, `Block`,
  `Unblock`, `SetFavorite`) do the same; `GetList` / `GetBlocks` are empty until then.
- **Guild: a stale guild is cleared at join.** The join-time check that clears
  `profile.Social.GuildId` when the guild no longer exists (disbanded or deleted on
  another server) ran before the player's data loaded, so it never did anything and
  the player was stuck (`Create` / `AcceptInvite`: "already in a guild", `Leave`: "not
  in a guild"). It now waits for the data first.
- **Guild: failure reasons no longer carry a script position** (`"guild full"`, not
  `"…GuildService:510: guild full"`).
- **GuildLock: Studio fallback.** When MemoryStore is unavailable in Studio (place not
  published, or Studio API access off) the lock warns once and uses a single-server
  in-memory lock for the session, instead of every guild change failing with
  `lock busy`. Live servers keep failing closed (`lock busy`).
- **Friend / Guild / Party remotes check their arguments and are rate-limited**
  (`Events/Friend/Action`, `Events/Guild/Action`, `Events/Party/InviteAction`), with the
  rules `Net` applies to its own remotes (RemoteOpts `rate` / `burst` / `validators`): a
  per-player token bucket (`Config.Social.<Friend|Guild|Party>.RemoteRate` = 4 per
  second, `RemoteBurst` = 10) and a check of every envelope field. A refused request
  returns `false, "rate limited"` / `false, "bad request"` / `false, "unknown action"`.
  Before, a string userId errored inside the Friend and Party handlers, and NaN or
  fractional vault counts reached `Guild.VaultDeposit` / `VaultWithdraw`. The public
  functions check their arguments too: a userId must be a whole number (`"invalid
  target"`), vault counts a whole number of 1 or more (`"bad count"`).
- Harness: `--memorystore fail` (every MemoryStore call errors) and
  `harness.join(name, userId)` in scenarios.

### Fixed — hardening (monetization-shop)
- **`Monetization.OwnsGamePass`** no longer caches a failed Roblox check: when
  `UserOwnsGamePassAsync` errors it returns `false` and asks Roblox again on the next
  call (it used to answer `false` until the player rejoined). A real "not owned" is still
  cached for the session. The doc comment now says so.
- **Game passes bought in this server count at once.** Monetization listens to
  `MarketplaceService.PromptGamePassPurchaseFinished`; when `wasPurchased` is true it marks
  the pass as owned (`OwnsGamePass` returns `true`) and fires the new signal
  **`Monetization.OnGamePassPurchased(player, gamePassId)`**. A `Shop` item with
  `gamePassReq` can be bought right after the pass. playbooks/game/robux-purchases.md uses
  the signal instead of connecting `PromptGamePassPurchaseFinished` itself.
- **`ProcessedReceipts` is bounded.** Each player keeps the last 100 granted PurchaseIds
  (oldest dropped first) instead of every purchase forever. Behaviour change: the values are
  now an order number (`1, 2, 3 …`) instead of `true`; old `true` records still block a
  re-grant and are the first to be dropped. A receipt older than the last 100 grants is
  no longer recognised (Roblox only re-sends receipts that were never acknowledged).
- **`Shop.RegisterItem(id, def)`** takes a `Shop.ShopItemDef`: `def.id` is optional (the
  `id` argument is always used), and `def.grant` is optional for a `devProductId` item
  (Monetization's `RegisterProduct` grants it). A coin item without `grant` still errors.
  `Shop.Get` / `GetCatalog` still return a `ShopItem` with `id` and `grant` set.
- **`Shop.Purchase`** returns `false, "not_loaded"` (new `PurchaseFailure` value) while the
  buyer's data is not loaded, and checks or spends nothing. Behaviour change: it used to
  answer `insufficient_funds` (or `level_too_low`) for a player whose data was loading;
  a Robux item (`devProductId`) also no longer opens the purchase prompt, and a free item
  (cost 0 / nil) no longer runs its `grant`, until the buyer's data is loaded.
  playbooks/game/shop.md maps the new reason to a message.
### Fixed — hardening (infra-misc)
- **Teleport:** a teleport that `TeleportAsync` accepted but that then fails
  (`TeleportInitFailed`) is retried with the same backoff when the result is `Flooded` or
  `Failure` (up to `MaxAttempts` in all) when it was for one player or a reserved server
  (`ToPrivate` / `ReservedAccessCode`). A group teleport to a public server is not retried
  for one player alone (that player would land in a different server than the group). Any
  other result, a failed public group teleport, or the last retry, fires
  `OnTeleportFailed({ player }, placeId, "<TeleportResult>: <message>")`. New pure helper
  `Teleport.IsRetryable(result)`.
- **Teleport.GetPlaceInstance (behaviour change):** returns `(placeId, jobId, err)` of the
  server the user is in (it returned the raw, mislabelled `(isThisServer, errorMessage)` and
  ignored `placeId`). Pass the expected place or `0` for any place; not online / another
  place / an error return `(nil, nil, reason)`.
- **Trade:** a player who leaves cancels their open trade (`OnComplete(tradeId, false)`), so
  the partner can trade again; before, both stayed "already trading" until the server
  restarted. **Behaviour change:** `Trade.Cancel(player, tradeId)` returns `false` unless
  `player` is one of the two players in the trade (anyone could cancel any trade).
  `OnComplete` was already fired after the items and currency moved; its doc now says so.
- **Memory:** after the real MemoryStore fails (Studio without API access, an outage, one
  failed call), calls use the local fallback for 60 s and then try the real store again;
  before, one failure kept the server on the single-server fallback until it restarted.
  A queue `readId` from a fallback read is still removed locally. Entries written to the
  fallback are never copied to the real store (other servers never see them), but this
  server keeps reading them until their TTL ends: `MapGet` returns the local value when the
  real store has none, `MapRange` merges local entries with the real range, and
  `QueueRead` returns local items before reading the real queue. `MapSet` / `MapRemove` on
  a key after recovery replace or delete its local copy.
- **Messages.Subscribe (behaviour change):** returns `(nil, reason)` (and fires `OnError`)
  when `SubscribeAsync` fails, instead of erroring. Its type is now
  `(RBXScriptConnection?, string?)`; code that wrapped it in `pcall` must check the first
  result (playbook multi-server updated).
- **Interaction:** a prompt with a `Cooldown` forgets a player's last use when they leave
  (the table kept every player who ever used it); `Destroy()` releases it too.
- **SFX:** a sound is cleaned up after its own length (`TimeLength / PlaybackSpeed`, read once
  it has loaded: `TimeLength` is 0 before) when `Ended` does not fire, or after 10 s when it
  never loads. Before, every sound was destroyed after 10 s, cutting off longer sounds.
- **Motion3D (behaviour change):** `Spin` and `Float` on the same part compose (Float moved
  the part to an absolute CFrame every frame, undoing Spin and any other move). Float's
  `stop()` now removes only its own offset instead of snapping the part back to the CFrame
  it had when Float started. Float still assumes it is the only code moving the part: stop
  it before moving the part with `To` or a script (a move while it floats can shift the
  rest height by up to the amplitude).
- **VFX.PlayAt:** the `EmitCount` burst is emitted on the next frame, after the holder is
  parented and replicated (an `Emit` in the same frame as the parenting can be lost on
  clients), and is skipped when the effect already ended.
- **Player.SetLeaderstat (behaviour change):** creates a missing `leaderstats` folder or stat
  (like `SetupLeaderstats`) instead of doing nothing; a `nil` value or a value the stat's class
  cannot hold warns `[PlayerService] SetLeaderstat(...)` instead of erroring or doing nothing.
- **Cooldown:** doc comments for every function, including that per-player cooldowns are
  in memory and cleared when the player leaves (the header example no longer suggests
  `ConsumePlayer` for a daily reward).
- **State (ReplicatedState):** `Destroy()` drops the object from the cache, so `State.Get`
  returns `nil` and `State.Create` makes a fresh state after it (both returned the destroyed
  object). A cached object whose folder is gone (destroyed by the server) is dropped on
  the client too.
- **Flags (client):** when the server has no flag state yet, only the first `Get` /
  `IsEnabled` / `OnChanged` waits (up to ~10 s); later calls return the default at once
  until the server creates it (each call waited again).
- **Sound (client):** `PlayOnce` releases a sound that never loads, or whose `Ended` never
  fires, after its own length (or 10 s when not loaded); before, it stayed active in the
  pool forever. Releasing an already released sound does nothing (StopAll then a music
  fade-out pooled it twice).
- **Effects (client):** `EmitParticle` turns the clone's `Enabled` off, so it is one burst
  even when the template is Enabled. New `Effects.EmitBurst(template, cframe, count?)` bursts
  every ParticleEmitter of a template (Attachment / Part / Model / Folder), honouring
  `EmitCount` / `EmitDelay` attributes. Expired effects are removed from the cleanup Trove
  (it kept every effect until `ClearAll`).
- **Camera:** `Shake`'s `intensity` is documented as degrees of camera turn (it said studs).

### Added — pick the packages a game installs
The framework is split into ~100 packages (`Gaxia_Packages_Server/Packages.lua`). Pick
the ones a game uses and only those, the packages they need, and Core are installed;
nothing else is in the place or replicated to clients. A Data-only install loads 37
server modules at boot instead of 80.
- **Companion → Install** lists the packages by category, with presets (`Default` = what
  the framework booted before, `All`, `None`). Packages added because a picked one needs
  them are marked `[+]`. The picker starts from the place's current pick.
- **Rojo:** `node tools/packages.mjs build --select Data,Pet --out <dir>` writes the
  picked tree and a `default.project.json` for `rojo serve` / `rojo build`. Also `list`,
  `resolve`, `check`, `fix`.
- **Installed = enabled.** The pick is recorded on both package roots (attribute
  `GaxiaPackages`). At boot the server starts every picked service, plus every installed
  package with `Boot = true` (player hooks, remotes, loops, ProcessReceipt), including
  ones installed only because a picked package Requires them (picking Idle boots Data).
  Other services installed as dependencies start on first use. The `Default` preset
  boots the same services as before, plus Cooldown (Friend and Guild need it).
- Companion: a place installed before this release opens with everything ticked, and
  an install that would remove packages the place has asks for a second click (the
  status line lists them). Ticking everything is a full install with no pick recorded. `ServerStorage.GaxiaFeatures` still overrides. A
  full install without a pick keeps using `Config/Features`.
- The loaders' types list only installed modules, so autocomplete shows what is there.
  The Companion needs script-edit permission to trim them.
- `GaxiaServer.IsInstalled(name)` / `Gaxia.IsInstalled(key)`. The client bootstrap skips
  pre-warm entries whose package is not installed.
- `Lifecycle.Find(name)` (soft dependency): the service if its package is installed, else
  nil. Quest/Idle (Pet coin multiplier), Player/Admin (AntiCheat whitelist), Admin
  `/give` (Item, ItemDef), Ban (AntiCheat escalation), Webhook (Ban/AntiCheat/Guild
  reports), Analytics (Economy/Level/Quest funnel) and AntiCheatAdmin (Analytics audit)
  now use it, so picking Quest no longer installs Pet and its UI. Behaviour is the same
  when those packages are installed.
- Every package's `Requires` is generated from the source (`packages.mjs fix`);
  `packages.mjs check` and `check-architecture` (R12) fail when the catalogue is stale or a
  module belongs to no package.

### Changed — services start only when the game uses them (Features + typed lifecycle)
The server no longer loads everything at boot. Each service registers its setup with
`ServiceLifecycle.Define(module, { Name, Needs, Init, Start })`, and its module body does
nothing when required. A service starts when the first of these happens: it is listed in
`Config/Features` (started at Boot, dependencies first), game code first touches
`GaxiaServer.<Name>`, or one of its functions is first called. Services nobody uses are
never loaded.
- `Config/Features.lua`: the boot list, typed as `Types.ServiceName` so names autocomplete
  and typos are flagged. Default = exactly what the bootstrap force-loaded before. To
  customise it, games create `ServerStorage.GaxiaFeatures` (and optionally
  `ReplicatedStorage.GaxiaClientFeatures`). Companion's Install/Update replaces the whole
  package, Config included, and these files live outside it.
- `Gaxia_ServerBootstrap` just calls `GaxiaServer.Boot()`. The hand-kept 19-service list
  and its ordering comments are gone; order comes from `Needs`. This also fixes the
  violated "Ban before Admin" rule.
- Boot also runs on the first service access, and `ReplicatedStorage.Events/Net` exist as
  soon as the loader is required. Game Scripts no longer depend on Roblox's Script run order.
- A module whose body errors, or whose Init fails, affects only that service (warned once;
  `GaxiaServer.<Name>` returns nil).
- `GaxiaServer.IsEnabled(name)`. The server publishes its started services to clients,
  and the client bootstrap skips client modules whose server side is not running.
- Cycle-free typed dependencies: modules require each other directly (no `server()` /
  `SharedPkg :: any`). The two-way couplings became hooks: `Net.SetViolationHandler`,
  `Ban.SetRoleResolver`, `Chat.SetRoleResolver`.
- `GaxiaServer.Lifecycle`'s documented `Register/Start/OnStarted` API keeps its old
  synchronous semantics for game code.
- `tools/check-architecture.mjs` enforces the module rules (needs `luau-ast`).

### Improved — types / autocomplete
Signals declare their payloads, so `:Connect(function(player, ...)` callbacks are typed
(e.g. `Economy.OnTransaction` → `kind: "add" | "spend" | "set" | "transfer"`). Public
functions are annotated, and the stub-returning UI modules are typed.
- Config sections carry types (`AdminConfig`, `AntiCheatConfig`, `WebhookConfig`,
  `PlayerConfig`), so `Config.AntiCheat.BanPolicy.` autocompletes and a mistyped
  `Severity` is flagged.
- The AntiCheat detector contract (`AntiCheatSnapshot`, `AntiCheatFlag`, `DetectorHost`)
  is defined once in `Types.lua` instead of copied into each detector.
- New `Config/Player.lua` (`MaxWalkSpeed`, default 500 as before): the clamp in
  `Player.SetWalkSpeed` can now be configured.
- Stricter on purpose (no runtime change): `Random.Choice/Weighted/Shuffle` are generic,
  so `Random.Choice(spawnPoints)` returns a `BasePart?`; a literal mixing types
  (`Random.Choice({ "Sword", 100 })`) is now a type error — annotate it
  (`local pool: { any } = { "Sword", 100 }`). `Scheduler.Debounce/Throttle` return a
  function with `fn`'s parameters, so calling it with extra arguments is flagged.

### Fixed — AntiCheat detectors never loaded (now in observe mode)
Since e3b2e06 (2026-07-17) the orchestrator scanned the wrong parent, so none of the 15
detectors registered. They load again, but in OBSERVE mode by default
(`Config.AntiCheat.Enforce = false`): flags are recorded and warned, and would-be hard
actions are published as `OnAction(..., "observe")`, so nobody is kicked or banned. Three
false-positive causes found in simulation are fixed too:
- StarterPack/StarterGear tools are now legitimate for BackpackGuard.
- PlayerService's leaderstat writes announce the expected value to StatGuard.
- BanService escalates at most once per player per session. Before, simultaneous flags
  walked kick → temp ban → perm ban inside one frame.

Play-test with a non-creator account before setting `Enforce = true` (MANUAL §9.0).

### Changed — AntiCheat sampling is spread over frames
Each 0.5 s pass used to sample every player in one frame. It now spreads the players
over the pass (within 80% of the interval); each player is still sampled every 0.5 s,
and a player who left mid-pass is skipped. MicroProfiler labels `AntiCheat.Sampler`
and `AntiCheat.<Detector>` show the cost in a live server.

### Fixed
- Runtime flags with dotted names (all of them: `AntiCheat.Enforce`,
  `AntiCheat.Detector.Speed.Enabled`, …) threw "Attribute name is not valid", so
  `EConfig.Set`, `/flag`, `/ac` and `AntiCheat.SetEnabled/SetDetectorEnabled` failed.
  Flags now stores each name under a valid attribute name; callers keep the dotted names.
- `Gaxia.State` (ReplicatedState) waited for `GaxiaState` while being required, which
  fails inside the client loader when the folder has not replicated yet. The client now
  waits in `State.Get` (documented to yield) instead.
- DataManager kicked every player on a normal leave ("Profile released.").
- Chat command replies were dropped when no command had run in the server's first 30 s:
  the reply remote was created lazily and the client stopped waiting for it.
- The loaders' auto-tagger tagged all of ReplicatedStorage/ServerStorage instead of just
  the package.
- MANUAL told games to `require(... .init)`, which errors under Rojo. Require the package
  ModuleScript itself.

### Fixed — hardening (anticheat-admin)
- **A disabled detector no longer flags.** The `host` a detector's `Init` receives now has
  its own `Flag`, which does nothing while that detector is off
  (`AntiCheat.SetDetectorEnabled`, `/ac off <Detector>`, `Config.AntiCheat.<Name>.Enabled`).
  Before, only `Sample` was skipped, so the event-driven detectors (`Stat`, `Backpack`,
  `ToolDupe`, `Combat`, `Animation`, `RemoteRate`, `ExploitSig`) could not be turned off.
  **Behaviour change:** `/ac off Stat` now really stops `StatTamper` flags. `AntiCheat.Flag`
  from game code is unchanged (never tied to a detector).
- **Teleport and Speed skip seated players and allow for falls.** Seated means
  `Humanoid.SeatPart` is set (now or on the previous sample): the server makes the seat
  weld, so a client cannot fake it. The `Seated` state and `Humanoid.Sit` are NOT trusted
  (the owning client sets them; an exploiter could switch to `Seated` and teleport).
  While falling (`Freefall`), `Teleport` ignores only the downward part of the move (a long
  drop is fine; a 50+ stud sideways or upward jump is still a hard flag), and `Speed`
  keeps checking with its limit multiplied by the new optional
  `Config.AntiCheat.Speed.FreefallMultiplier` (default 2): the client also sets
  `Freefall`, so skipping it would let an airborne speed hacker go any speed. Trade-off: a
  sideways launch faster than 2x the limit for 2+ samples is a soft `Speed` flag; raise
  `FreefallMultiplier` for games with big launchers. Vehicles, moving seats and long
  drops no longer need `Whitelist` calls.
- **Admin no longer fails to start when `GetDataStore` errors** (Studio in an unpublished
  place). The roles store is opened in a `pcall`; without it roles live in memory for the
  session (one warning), and `SetRole` / the join-time role load skip the store.
- **`/acban` takes a multi-word reason:** `/acban Bob speed hacking 3600` bans for
  "speed hacking", 3600 s. With 3+ arguments a number at the end is the seconds; the words
  between the player and it are the reason (quotes still work). **Parsing change:** a last
  argument with a unit is now a duration: `30m`, `1h`, `2d`, `90s`, `1w`
  (`/acban Bob cheating 1h` = 1 hour). Before, `1h` was refused ("seconds must be a
  positive number"). An unknown unit (`5x`) is refused; a duration-shaped word is never
  folded into the reason (that made a permanent ban).
- **Ban strikes last for the server's lifetime.** They were reset on leave, so with the
  default `BanPolicy` (KickAt 1, TempBanAt 2, PermBanAt 3) a cheater was kicked, rejoined
  and was kicked again, forever. **Behaviour change:** a second hard action after a rejoin
  to the same server is now a 1-hour ban, a third a permanent ban. A moderator resets them:
  `Ban.Unban` / `/acunban` and `/acclear` forget the player's strikes (new additive
  `Ban.ResetStrikes(userId)`), so an unbanned false positive starts again at a kick. A temp
  ban that simply expires keeps the strikes.
- **Journal is quiet by default.** The default sink no longer `warn`s every flag (Output
  spam). `Journal.WarnSink` (new) restores it: `Journal.SetSink(Journal.WarnSink)`. The
  per-player history keeps each player's last 100 entries and is freed 30 s after they
  leave (it grew without limit).
- **`Journal` and `AntiCheatAdmin` boot by default** (`Config/Features` and the `Default`
  preset), so flags are journaled from boot and `/acflags` `/acban` `/ac` … work without
  game code touching them.
- Harness: `harness.join(name, userId)` joins with a given UserId (a rejoin), for probes.

### Removed / deprecated
- `Shared/Comm` removed. It required a non-existent `Option` module and nothing used it.
- `Janitor` and `ComponentLegacy` are deprecated (they warn on first use) in favour of
  `Trove` / `Component`.
- Test and config files (`*.test.luau`, `jest.config.luau`, `wally.toml`) no longer end up
  in the built place.

### Changed — framework cleanup uses Trove; Maid is deprecated
One cleanup library instead of three. Every framework module that used `Maid`
now uses `Trove` (the one `Component` already depends on): the five AntiCheat
guards (Animation / Backpack / Combat / HumanoidState / Stat), `ZoneService`,
`TooltipSystem`, `DialogSystem`, `CutsceneSystem` and `EffectsController`.
- Mapping: `Maid.new` → `Trove.new`, `:GiveTask` → `:Add`, `:DoCleaning` → `:Clean`,
  `:Destroy` → `:Destroy`.
- **Fixed as a side effect** — `CutsceneSystem.Stop()` (and cancelling the
  `Play` promise) destroyed the cutscene's Maid, then the play thread destroyed
  it a second time. `Maid:Destroy()` clears the metatable, so that second call
  errored in the play thread; after `Stop()` this meant the `Play` promise
  never settled. `Trove:Destroy()` is safe to call twice.
- `Maid` stays in `Shared/` for existing game code but warns on first require;
  MANUAL §5.2 has the Maid → Trove mapping. It will be removed in a later version.
- Behaviour differences to know when migrating your own code: `Trove:Clean()`
  order is not guaranteed (Maid was LIFO), `:Add()` during `:Clean()` errors,
  and function tasks run via `task.spawn`. None of the migrated call sites
  depend on these.

### Added — Pet Coins multiplier wired into the Idle & Quest faucets
`PetService.GetCoinMultiplier` (built in the Pet MVP) was previously **dead** — no
faucet consumed it, so equipped pets had no in-game effect. The two **generated**
coin faucets now apply it:
- **`IdleService.Collect`** — coin idle income × multiplier, re-clamped to the
  configured `cap` (**ceiling** policy; `cap` is `math.huge` when unset → plain
  multiply). Pets reach the offline cap faster but don't exceed it.
- **`QuestSystem.grantReward`** — coin reward × multiplier (floored).
- Both gate on the coin currency (`"Coins"`), so Gems / other rewards aren't touched.
- **`RaidService` is intentionally excluded** — raid loot is a zero-sum transfer;
  multiplying it would mint currency.
- Lookup is best-effort (`pcall` + NaN guard → `1.0`), so a missing Pet service
  never breaks a grant.

### Fixed — high roles can no longer be auto-banned or auto-kicked (escalation banned the owner)
The AntiCheat auto-escalation had no role awareness: dev-tool teleports
hard-flagged the **place creator**, who got temp-banned ("Auto: Teleport x2")
and then kicked at join by the ban gate — locked out of their own game.
- **Escalation exemption** — `escalate()` skips the place creator (sync
  `CreatorId` check, no role-load race) and anyone at/above
  `Config.AntiCheat.BanPolicy.ExemptRole` (default `"admin"` — deliberately
  NOT `"moderator"`, so the lowest staff tier keeps the automated cheating
  deterrent; `false` narrows to creator-only). Exempt detections warn instead
  of kick/ban. Role lookup via new userId-keyed
  `AdminCommands.GetRoleForUserId` / `IsUserIdAtLeast` (in-memory registry
  only; lazy pcall require — BanService still works without AdminCommands,
  falling back to creator-only). Known limit: DataStore-granted roles load
  async at join, so a hard-flag burst in the first seconds can still strike a
  non-Bootstrap admin.
- **Bootstrap kick exemption** — `AntiCheat.OnAction` has TWO enforcing
  consumers; the default hard-action handler in `Gaxia_ServerBootstrap` used
  to kick unconditionally, so the creator was still kicked even with the ban
  exemption. It now consults the new public `Ban.IsEscalationExempt(userId)`.
- **Join-gate self-heal** — a stale ban record on the place creator is
  dropped with a warn instead of kicking (creator only: lower staff can be
  legitimately banned, so their records must still enforce).
- **/acban guard hole** — AntiCheatAdmin's `/acban` called `Ban.Ban` directly,
  bypassing the self/creator/rank guard `/ban` has — a delegated admin could
  ban the owner. Now applies the same guard via the new public
  `AdminCommands.ProtectTarget` and REFUSES if the guard is missing
  (fail closed, mixed-version Lib folders).
- **AntiCheatAdmin hardening (same review)** — its private player resolver
  had the audit-outlawed footguns: blank query matched the FIRST player in
  the server (`/acban "" reason` banned someone arbitrary), ambiguity
  resolved by join order, and an earlier-joined prefix match shadowed an
  exact name ("/acban Bob" banned Bobby). Now blank/ambiguous are rejected
  with the reason and exact beats prefix. `/acban` validates `[seconds]`
  (NaN/inf/negative → rejected; NaN expiresAt made a "temp" ban permanent),
  `/acban`+`/acunban` surface the persisted-write WARNING like `/ban`, and
  all rejection paths in the pack (`/ac`, `/flag` usage errors included)
  carry the `(message, failed=true)` contract so they render as rejections.
- Clicking `/unban` in the panel now opens a list of **active bans** —
  `Name (userId) — reason · permanent/Xh left` with a per-row Unban button
  (auto-refreshes after each unban) plus a manual userId fallback box. Backed
  by the new `BanService.ListBans(maxCount?)` (session cache merged with
  DataStore `ListKeysAsync`, expired records filtered, pcall-guarded) and a
  new admin-gated `bans` envelope on `Events/Admin/Action` with cached
  username resolution. Cap via `Config.Admin.BanListLimit` (default 50).

### Fixed — Admin command audit (31 findings, 9 fix batches)
Full report: `docs/superpowers/specs/2026-06-12-admin-command-audit.md`
(multi-agent audit of every built-in command against the service APIs it
calls; 24 findings adversarially verified + 7 critic leads, 0 refuted).

- **Targeting safety** — `findPlayerByPartialName` no longer guesses: a blank
  target used to resolve to the FIRST player in the server (a bare `/kick`
  kicked someone arbitrary), ambiguous prefixes silently picked join order,
  and the DisplayName fallback matched substrings anywhere. Blank/ambiguous
  queries are now rejected with the reason ("Ambiguous target … matches N
  players"); DisplayName matching is prefix-anchored. Same guards in
  `ChatCommandSystem.parsePlayer`.
- **NaN inventory poisoning** — `/give X item nan` wrote NaN into the
  persisted profile inventory (NaN passes one-sided clamps; DataStore then
  rejects every later save of that profile). `ItemService.clampCount` and
  `VaultService.Deposit/Withdraw` now NaN-guard; `/give` validates count as a
  finite positive integer, rejects unknown itemIds when an
  ItemDefinitionService catalog is registered, and reports the DELIVERED
  amount (Give returns the delta) instead of echoing the request.
- **/role moderation guard** — `/role` now runs `protectTarget` like
  `/ban`/`/kick` (a bare "/role me" typo used to silently self-demote with a
  persisted row = permanent lockout for non-creator owners), requires an
  explicit role argument, refuses granting a role at/above the caller's own
  tier (no peer minting), and refuses demotions below a Bootstrap floor
  instead of reporting a change that reverts on next join.
- **Cross-server cache staleness** — `roleByUserId` and the BanService session
  cache are evicted on PlayerRemoving, so demotions/bans/unbans issued on
  another server now apply on rejoin (both were warm-cache-forever; the
  upgrade-only role load made demotions unapplyable). BanService no longer
  negative-caches a GetAsync ERROR as "not banned" for the server lifetime;
  `Ban`/`Unban` warn + return a `persisted` boolean and `/ban`/`/unban`
  append an explicit WARNING when the DataStore write failed. Persisted roles
  also load for players already in-game at module init (catch-up loop).
- **Anti-cheat whitelist sync** — the orchestrator's whitelist/ClearFlags are
  family-aware (entry "HumanoidState" covers "HumanoidState:Climbing" etc. —
  the entry was dead under exact matching); missing "Heuristic" and
  "WorldBounds" (hard severity!) added; "ClientReport" documented as
  deliberately excluded. A bad runtime `/flag` override of
  `Admin.ActionWhitelistSeconds` can no longer error before the handler pcall
  and lock out every admin command incl. the recovery `/flag clear` (tonumber
  coercion + fail-closed Whitelist + pcall'd pre-handler block).
- **/speed, /heal, character resolution** — `Util.Player.GetCharacter`
  honors its documented timeout (was an unbounded `CharacterAdded:Wait()`
  that hung `/speed` and the panel invoke forever on character-less targets);
  `PlayerService.SetWalkSpeed` clamps to `[0, Player.MaxWalkSpeed]` (negative
  WalkSpeed got the target anti-cheat-kicked ~30s later — detector baseline
  floors at 8) and returns the applied value; `/speed` validates input;
  `/heal` errors on no-character/dead targets ("X is dead — use /respawn")
  instead of claiming success.
- **Chat feedback actually delivered** — `ChatCommandSystem.reply` used a
  client-only API from the server (every reply silently dropped, incl.
  "Permission denied." and `/help`); replies now go through a new
  `Events/Chat/SystemMessage` RemoteEvent rendered locally by the new
  `Gaxia.ChatFeedback` client module (TCS system line, legacy SetCore
  fallback). The admin chat bridge forwards Run's real outcome message;
  `Config.Admin.Aliases` now work from chat (each alias registered with
  ChatCommandSystem); ALL TextChannels are hooked (commands in team/whisper
  chat used to leak the raw command line to teammates); `/kick`/`/ban`
  reasons greedy-join the remaining words ("/ban Bob exploiting speed hacks"
  used to persist reason "exploiting").
- **Admin Panel truthfulness + usability** — handlers mark rejections via a
  `fail()` second return, so guard-blocked/not-found commands now toast as
  "Blocked" (red) and show ✗ in the Audit feed instead of green successes;
  the audit broadcast carries the outcome message and renders it; the audit
  buffer fills via an always-on subscription (the tab used to open empty —
  it only buffered while focused); dropdown option menus raise their root
  ZIndex while open (later siblings used to paint over and click-shadow the
  menu — a misclick could fire Run at a default target); trailing blank form
  fields are stripped server-side (bans used to persist with reason "");
  `schema`/`players` envelope endpoints now require moderator+ (any client
  could enumerate the live staff roster with roles).
- **`Config.Admin.Enabled` is wired** — the kill switch existed in Config but
  was never read. `false` now disables registration, `Run`, the Events/Admin
  remote surface, role hooks, and creator auto-grant.

### Added — Phase 27 · Admin UX
- **Admin Panel** (`Gaxia.UI.AdminPanel`) — a role-gated in-game GUI over the
  existing `AdminCommands` registry (no command-surface fork). Three tabs:
  Players (per-target actions filtered to the caller's role), Commands
  (role-filtered list + auto-rendered arg form: `player`→searchable dropdown,
  `number`/`string`→text field), and Audit (live moderator+ feed of the last
  50 command results). Opens via a 🛡 toolbar button (moderator+ only) or the
  F2 hotkey; the client bootstrap pre-warms it so the toolbar + hotkey +
  role-hint subscription wire up at spawn.
- **AdminCommands** server surface — `Events/Admin/Action` RemoteFunction
  (`schema` / `players` / `run` / `role`) + `Events/Admin/Inbound` RemoteEvent
  (audit broadcast to moderator+ only, plus a role hint at join). Server-
  authoritative: every `run` delegates to `AdminCommands.Run`'s existing role
  check; `schema` is role-filtered server-side so a client never learns of
  commands it can't run. The `commands` registry, every `Register` call site,
  `Run`, `GetRole`, and `IsAtLeast` are unchanged.

### Added — Admin moderation guard
- **`/ban` and `/kick` now refuse self / owner / equal-or-higher-rank targets.**
  A single `protectTarget(caller, target)` guard (shared by chat + the Admin
  Panel, since the panel re-enters the same handlers) blocks the classic
  "I banned myself and got locked out" footgun, protects the place creator
  from a delegated admin, and stops a compromised admin from banning peers or
  superiors. The Players-tab Ban/Kick buttons therefore fail safely with a
  clear toast instead of locking you out.
- **`AdminCommands.Run` now returns `(ok, message?)`** — the handler's
  descriptive result string ("Banned X", "You can't target yourself", "You
  don't have permission to run /role", …). The Admin Panel surfaces this in
  its result toast so a guard-blocked action shows the real reason instead of
  a misleading "Done". Existing callers that read only the boolean are
  unaffected (extra return value is ignored).

### Fixed — Plugin double-boot
- **The Companion plugin's bundled bootstraps no longer boot a second framework
  during play test.** The plugin's `Payload` carries the real
  `Gaxia_ServerBootstrap` (Script) and `Gaxia_ClientBootstrap` (LocalScript) so
  the 1-click Installer can clone runnable copies into a place. The plugin
  *entry* is guarded (`if plugin == nil then return`), but those Payload
  bootstraps were not — so when the plugin tree is dev-mounted into the
  DataModel, the Payload's `Gaxia_ServerBootstrap` ran and stood up a SECOND
  AntiCheat + DataManager alongside the place's own (double event handlers,
  concurrent ProfileService loads). Both bootstraps now self-guard on their
  runtime location: the server bootstrap boots only as a **direct child of
  ServerScriptService** (`script.Parent == ServerScriptService` — strict `==`,
  because the Payload copy is a *descendant* of SSS but not a direct child), and
  the client bootstrap boots only when a **descendant of `Players`** (its
  PlayerScripts clone). The place's own bootstraps and the Installer-cloned
  copies are unaffected; the Payload copies stay inert. Verified live: cloning
  the server bootstrap under a Folder-in-ServerScriptService produced no second
  boot, while the real one (direct SSS child) still came up normally.

### Fixed — Admin
- **`/ban` / `/unban`** now delegate to `BanService` (`Gaxia.Ban`) instead of a
  parallel ban store. Previously AdminCommands wrote a raw-string ban record to
  the same DataStore key BanService read as a table, so `Gaxia.Ban.IsBanned`
  returned false for chat-banned players, `Gaxia.Ban.Unban` was a no-op against
  AdminCommands' separate in-memory set, chat bans never fired `OnBan` (Webhook
  "BanReports" missed them), and temp bans were enforced as permanent. One ban
  code path now: `BanService` owns the record shape, session cache, expiresAt-
  aware `IsBanned`, and `OnBan`/`OnUnban` signals. `Gaxia_ServerBootstrap`
  eager-loads `Ban` before `Admin` and `Webhook`.

### Added — Phase 26 · Social
- **Friend** (`Gaxia.Friend`) — game-internal buddies + blocks list persisted
  under `profile.Social`; two-tier online status (same-server free, cross-server
  cached `Player:GetPresenceAsync`); cross-server invite delivery via the new
  `InviteQueue` helper (MemoryStoreSortedMap per kind). Block is bidirectional
  + unilateral (blocked users can't send invites, can't see online status,
  can't be Party/Guild-invited).
- **Guild** (`Gaxia.Guild`) — persistent guilds (per-guild DataStore key
  `guild:<guildId>`) with three roles (Owner / Officer / Member), invite +
  accept + kick + promote + demote + transfer + disband flows, plus a shared
  per-guild vault (own DataStore key `vault:<guildId>`). Every mutation
  serialises across servers through the new `GuildLock` MemoryStore mutex.
  Officer cap configurable (default 5). Webhook auto-reports create/disband/
  transfer to the `"GuildEvents"` channel if configured.
- **Party** invite extensions — `Invite` / `AcceptInvite` / `DeclineInvite`
  / `CancelInvite` / `GetPendingInvites` on the existing PartyService;
  ephemeral RAM-only with TTL from `Config.Social.Party.InviteTTL` (default
  60s).
- **WebhookService** auto-report extended to the new `"GuildEvents"` channel
  for guild create / disband / ownership transfer (no-op if not configured).
- **Config** new top-level `Social = { Friend, Guild, Party }` block; all
  numeric caps overrideable live via `/flag set Social.<…>`.
- **DataManager**: added test-only `_SeedForTest(player, data)` helper for
  MockPlayer-based unit tests; gated so it cannot clobber a real loaded profile.
- **Client UI**: minimal `FriendListPanel`, `GuildPanel`, `InviteToast`
  modules in `Gaxia_Packages/Client/UI/` — open via `:Open()` from a
  LocalScript. Real UX is a starter skeleton; consumers will theme/extend.
- **RemoteFunction surface**: `ReplicatedStorage/Events/Friend/Action`,
  `Events/Guild/Action`, `Events/Party/InviteAction` — single envelope-shaped
  `{type=..., ...}` API per service, server-authoritative validation.

## [1.0.0] — Framework roadmap Phases 17–25 complete

The framework reached feature-complete across all nine roadmap phases. Every
increment below was verified in Studio (server fresh-VM `run_script_in_play_mode`,
client `run_luau`, or Play-mode screenshots) before commit.

### Docs
- **MANUAL.md** — full sweep to match the runtime: documented all 34 previously-missing
  Lib services (Ban, Analytics, Journal, AntiCheatAdmin, Protection, Lifecycle, Vault,
  Shop, Monetization, Trade, Inventory, Loot, ItemDef, Idle, DailyReward, Mail, Raid,
  Party, Event, Visit, Codex, Refine, Placement, Teleport, Cooldown, Interaction,
  Settings, Memory, AI, VFX, SFX, Anim, Motion3D, Ragdoll) as §8.16–§8.49 in the
  existing per-service code-first format. Added a new "Config / EConfig / Flags" sub-
  section at the top of §8 covering the two-layer config (server-private Config defaults
  ← runtime Flags overlay via EConfig.Get/Enabled/Set/Clear), the `/flag` and `/ac`
  admin commands, and the shared `Gaxia.Flags` client read path. TOC regrouped by
  category (Core / Moderation / Economy / Live-ops / Engines / Utility+Juice).

### Added — WebhookService (Discord / outbound webhooks)
- **Webhook** (`Gaxia.Webhook`) — server-side outbound webhook sender. Per-channel
  queue with HTTP 429 retry (honours `Retry-After`), a Discord embed builder
  (`Discord` / `Embed`), raw `Send` / `SendUrl`, and `IsConfigured`. Webhook URLs
  are server-private secrets in `Config.Webhook.Channels` (never replicated, never
  client-callable). Zero-wiring auto-reports for player bans (`Ban.OnBan` /
  `OnUnban`) and AntiCheat hard actions when a channel is configured; the service
  is eager-loaded at boot so those reports wire up automatically. Swappable
  transport (`SetTransport`) for tests. See MANUAL §8.15.

### Added — Phase 22 · UI breadth
- **Theme** — single design-token source (color/font/spacing/radius) + live `SetTheme`/`OnThemeChanged`.
- **Responsive** — viewport-fitted `UIScale`, device class, safe-area insets.
- **Router** — screen stack with unified DisplayOrder (no z-fighting).
- **Localization** — i18n seam: catalogs, `{token}` interpolation, locale fallback.
- **Components** — Button/Toggle/Slider/TextInput/Dropdown/Tabs/Modal + virtualized ScrollList.
- **GamepadNav** — auto `NextSelection*` wiring from on-screen geometry.
- **RebindMenu** — key-capture + action↔key UI over InputManager.
- **Accessibility** — colorblind/high-contrast (reversible) + text-scale + reduced-motion.
- **Toast** — FIFO notification queue (overflow queues, never drops).
- **Haptics** — gamepad rumble + named patterns.

### Added — Phase 23 · Genre engine pack
- **Codex** (collection/dex + sets), **Refine** (atomic craft + timed Begin/Claim),
  **Vault** (capacity storage + GetValue), **Placement** (grid build + overlap +
  rebuild), **Idle** (offline accrual + clamp/cap), **Loot** (weighted + persisted
  pity + drop transparency → Codex), **AI** (PathfindingService mover/roam/follow),
  **Protection** + **Raid** (state machine + atomic loot move).

### Added — Phase 24 · Retention / social / live-ops
- **DailyReward** (streak ladder), **Mail** (persistent inbox + claimable attachments),
  **Trade** (two-party both-confirm **atomic** swap), **Inventory** (unique instances +
  stacks + equip slots), **Event** + **Visit** (live-ops windows + read-only visiting),
  **Teleport** (retry + reserved server), **Memory** (MemoryStore sorted-map + queue +
  fallback), **Party** (grouping + matchmaking).

### Added — Phase 25 · Juice & motion
- **VFX** (pooled effect registry), **SFX** (3D bank + category volume + ducking),
  **Anim** (named clips + priority/blend + markers), **Motion** (UI tween presets +
  sequence + stagger), **Motion3D** (CFrame tween + waypoint path + spin/float),
  **Ragdoll** (Motor6D↔BallSocket toggle).

### Notes
- Phases 17–21 (hardening, foundation, net/state, monetization, anti-cheat durability)
  predate this changelog; see the git history.
- All hardcoded operational values moved to `Gaxia.Config` (server-side config surface).
- Tooling track (Rojo migration, CI, scaffolding CLI, Companion Plugin) is tracked
  separately in `ROADMAP.md` as the MCP/tooling/DX layer.
