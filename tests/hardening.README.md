# Safe hardening verification

## Offline checks (no Studio or cloud services)

```text
python scripts/test-hardening-local.py --luau /path/to/standalone/luau.exe
stylua --check tests/hardening_verify.luau tests/remote_obfuscator.unit.luau
selene tests/hardening_verify.luau tests/remote_obfuscator.unit.luau
```

`test-hardening-local.py` uses Python's standard library and the standalone Luau
CLI. It reads the current checkout, creates temporary chunks outside the repo,
and removes them in a `finally`-managed temporary directory. It never installs
packages, builds a place, connects to Studio, launches Studio, or stops processes.
Each Luau invocation has a 30-second timeout; missing tools and failed assertions
produce nonzero exits. Use a trusted standalone Luau executable.

- **Encoder units:** executes the actual `RemoteObfuscator.lua` source in a local
  closure and passes its export to `remote_obfuscator.unit.luau`. All calls use
  explicit nonces. A minimal `Random.new` shim errors if `NextInteger` is called;
  no RNG or native Roblox serialization coverage is claimed. Checks include
  packed nils, nested tables, binary strings, booleans, numbers, function/thread
  rejection (root, nested value, table key), cycles, depth/node limits, malformed
  envelopes/nodes/nonces, decode string/node budgets, and recovery after failure.
- **Source-tree fixture:** runs `hardening_verify.luau` against read-only lookup
  proxies containing checkout source. The fixture enforces string child names
  and refuses unsupported APIs/writes. Negative controls remove a module, change
  its class, deny Source access, and remove a required marker. Each must fail
  with the expected diagnostic and without a PASS marker. This tests the
  verifier, **not Roblox source synchronization or production behavior**.

## Optional source-readable Roblox context

`tests/hardening_verify.luau` itself only reads ModuleScript sources using bounded
`FindFirstChild` lookups. It never requires production modules, clones/replaces
modules, registers/deletes remotes, or changes anti-cheat flags/configuration.
Missing modules and inaccessible Source are explicit failures, not hangs or skips.
It raises an error if any check fails, and emits `[SOURCE_SYNC] PASS` only when
all checks pass. Source markers check selected text presence, **not complete
source equality, runtime behavior, or integration**. No claim is made that the
open Studio's code matches the checkout until this is run there by an authorized
operator; the offline fixture does not establish that.

## Coverage gaps and why the existing CLI smoke was not used

The existing `scripts/test-oss-dependencies.ps1` refuses to start with Studio
already running and uses `--quitAfterExecution`; it must not be bypassed or used
to close someone's work. Its synchronous RunScript task also cannot exercise
real client-to-server RPCs. Do not run the old destructive verifier or attempt
module-cache healing/remotes cleanup in a live place.

These checks do **not** verify NetService handler execution/INTERNAL fallback,
player departure or destroy-during-yield races, async detector execution,
enforcement decisions, `/ac reset`, Guild persistence/concurrency, or native
Roblox transport serialization. In particular, a mock caller rejected at the
player-liveness guard never reaches an erroring/unencodable handler and cannot
prove either boundary. Those require a separate disposable Roblox server/client
integration place with real joined Players, handler-entry assertions, and no
production cloud resources. No such integration result is claimed here.
