"""Offline hardening checks; never launches/connects to Studio or cloud services.

Usage: python scripts/test-hardening-local.py --luau /path/to/luau[.exe]
Requires the standalone official Luau CLI, not Roblox Studio. No installs/builds
or repo writes. Temporary generated chunks are removed even on failure.
"""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "ReplicatedStorage.Gaxia_Packages.Shared.NetService":
        "src/ReplicatedStorage/Gaxia_Packages/Shared/NetService.lua",
    "ReplicatedStorage.Gaxia_Packages.Shared.RemoteObfuscator":
        "src/ReplicatedStorage/Gaxia_Packages/Shared/RemoteObfuscator.lua",
    "ServerStorage.Gaxia_Packages_Server.AntiCheat":
        "src/ServerStorage/Gaxia_Packages_Server/AntiCheat/init.lua",
    "ServerStorage.Gaxia_Packages_Server.Lib.GuildService":
        "src/ServerStorage/Gaxia_Packages_Server/Lib/GuildService.lua",
}


def quote(value):
    """A Lua long string preserving arbitrary production source verbatim."""
    equals = "="
    while "]" + equals + "]" in value:
        equals += "="
    # A leading newline is discarded by Lua; insert one so user data is intact.
    return "[" + equals + "[\n" + value + "]" + equals + "]"


def fixture(verifier, variant):
    # Deliberately tiny read-only source-tree fixture, NOT a Roblox simulation.
    # Forbidden mutations/APIs fail rather than pretending to implement them.
    setup = r'''
local warn = print -- standalone Luau has no Roblox warn global
local function node(className, source, children, denied)
    return setmetatable({}, {
        __index = function(_, key)
            if key == "FindFirstChild" then
                return function(_, name)
                    assert(type(name) == "string", "FindFirstChild requires string")
                    return children[name]
                end
            elseif key == "IsA" then
                return function(_, expected) return className == expected end
            elseif key == "Source" then
                assert(not denied, "source permission denied")
                return source
            end
            error("unsupported read-only fixture API: " .. tostring(key))
        end,
        __newindex = function() error("source fixture is read-only") end,
    })
end
local rootChildren = {}
local game = node("DataModel", nil, rootChildren, false)
'''
    tree = {}
    for path, relative in SOURCES.items():
        parts = path.split(".")
        if variant == "missing-node" and parts[-1] == "NetService":
            continue
        current = tree
        for part in parts[:-1]:
            current = current.setdefault(part, {})
        source = (ROOT / relative).read_text(encoding="utf-8")
        if variant == "missing-marker" and parts[-1] == "NetService":
            source = source.replace("player.Parent ~= Players", "REMOVED_FOR_NEGATIVE_TEST")
        current[parts[-1]] = source

    serial = 0

    def emit(children, expression):
        nonlocal serial
        lines = []
        for name, item in children.items():
            slot = expression + "[ " + quote(name) + " ]"
            if isinstance(item, dict):
                serial += 1
                variable = f"children_{serial}"
                lines.append(f"do local {variable} = {{}}")
                lines.append(slot + f' = node("Folder", nil, {variable}, false)')
                lines.extend(emit(item, variable))
                lines.append("end")
            else:
                wrong = variant == "wrong-class" and name == "NetService"
                denied = variant == "source-denied" and name == "NetService"
                lines.append(slot + " = node(" + quote("Folder" if wrong else "ModuleScript")
                             + ", " + quote(item) + ", {}, " + str(denied).lower() + ")")
        return lines

    return setup + "\n".join(emit(tree, "rootChildren")) + "\n" + verifier


def run(cli, directory, name, source, marker, success=True):
    chunk = directory / (name + ".luau")
    chunk.write_text(source, encoding="utf-8")
    result = subprocess.run([cli, str(chunk)], capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    expected_exit = result.returncode == 0 if success else result.returncode != 0
    if not expected_exit or marker not in output:
        raise RuntimeError(f"{name}: unexpected exit {result.returncode}\n{output}")
    if not success and "[SOURCE_SYNC] PASS" in output:
        raise RuntimeError(f"{name}: failure emitted a PASS marker\n{output}")
    print(f"[LOCAL] {name}: PASS (Luau exit {result.returncode})")
    if success:
        print(output.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luau", default=shutil.which("luau"), help="Standalone Luau executable")
    args = parser.parse_args()
    if not args.luau:
        parser.error("Luau not on PATH; supply --luau. Studio will NOT be used as a fallback.")
    cli = str(Path(args.luau).resolve())
    verifier = (ROOT / "tests/hardening_verify.luau").read_text(encoding="utf-8")
    encoder = (ROOT / SOURCES["ReplicatedStorage.Gaxia_Packages.Shared.RemoteObfuscator"]).read_text(
        encoding="utf-8"
    )
    suite = (ROOT / "tests/remote_obfuscator.unit.luau").read_text(encoding="utf-8")
    # The sole engine dependency is Random.new at module load. Explicit nonces
    # bypass randomness. Accidental RNG use fails; this does not validate Roblox
    # RNG, native values, network serialization, or any NetService handler.
    encoder_chunk = '''
local Random = { new = function()
    return { NextInteger = function() error("unit suite must supply explicit nonce") end }
end }
local encoder = (function()
''' + encoder + "\nend)()\nlocal suite = (function()\n" + suite + "\nend)()\nsuite(encoder)\n"
    with tempfile.TemporaryDirectory(prefix="gaxia-hardening-local-") as temp:
        directory = Path(temp)
        run(cli, directory, "encoder-unit", encoder_chunk, "[ENCODER_UNIT] PASS")
        run(cli, directory, "source-fixture", fixture(verifier, "normal"), "[SOURCE_SYNC] PASS")
        for variant, message in {
            "missing-node": "missing source path:",
            "wrong-class": "not a ModuleScript:",
            "source-denied": "cannot read Source:",
            "missing-marker": "source contains player.Parent ~= Players",
        }.items():
            run(cli, directory, variant, fixture(verifier, variant), message, success=False)
    print("[LOCAL] PASS: encoder units + source-tree fixture/negative controls; NOT Roblox integration")


if __name__ == "__main__":
    main()
