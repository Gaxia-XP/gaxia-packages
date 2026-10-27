"""Offline checks of packs/player-data; never launches Studio or touches a DataStore.

Usage: python scripts/test-player-data-pack.py --luau <luau.exe> --luau-compile <luau-compile.exe>

1. The pack is what scripts/build-player-data-pack.py makes from the library (no drift), and every file's sha256
   matches manifest.json.
2. No pack file holds a word the Creator Store's scan or Gaxia Crew's script check refuses.
3. Every pack file compiles (luau-compile --null).
4. DataManager runs in the standalone Luau CLI against a fake place, with the default and a custom template
   (tests/player_data_pack.runtime.luau).
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "packs/player-data"
sys.path.insert(0, str(ROOT / "scripts"))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("build_pack", ROOT / "scripts/build-player-data-pack.py")
build_pack = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build_pack)

# The words the Creator Store's automated scan is known to flag, and what Gaxia Crew's allowlist denies.
BANNED = ["loadstring", "loadmodule", "getfenv", "setfenv", "GetObjects", "LoadAsset", "loadAsset", "LinkedSource",
          "HttpEnabled", "LoadStringEnabled", "InsertService", "PostAsync", "RequestAsync", "HttpGet"]
REQUIRE_NUMBER = re.compile(r"require\s*\(?\s*[0-9]")


def quote(value):
    equals = "="
    while "]" + equals + "]" in value:
        equals += "="
    return "[" + equals + "[\n" + value + "]" + equals + "]"


def check_build():
    problems = build_pack.check()
    if problems:
        raise RuntimeError("pack drift:\n" + "\n".join(problems))
    print("[PACK] build and manifest: PASS")


def check_words():
    for path in sorted(PACK.glob("*.luau")):
        text = path.read_text(encoding="utf-8")
        for word in BANNED:
            if word in text:
                raise RuntimeError(f"{path.name} holds {word!r}")
        if REQUIRE_NUMBER.search(text):
            raise RuntimeError(f"{path.name} requires a number")
        if "\r" in text:
            raise RuntimeError(f"{path.name} has a carriage return (the pack is LF)")
    print("[PACK] words and line endings: PASS")


def check_compile(compiler):
    files = sorted(str(p) for p in PACK.glob("*.luau"))
    result = subprocess.run([compiler, "--null", *files], capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError("luau-compile failed:\n" + result.stdout + result.stderr)
    print(f"[PACK] luau-compile of {len(files)} files: PASS")


def check_runtime(cli):
    harness = (ROOT / "tests/player_data_pack.runtime.luau").read_text(encoding="utf-8")
    sources = {name: (PACK / f"{name}.luau").read_text(encoding="utf-8")
               for name in ["DataManager", "DataConfig", "DataMigration", "Signal"]}
    table = "local SOURCES = {\n" + "".join(f"\t{name} = {quote(text)},\n" for name, text in sources.items()) + "}\n"
    with tempfile.TemporaryDirectory(prefix="gaxia-player-data-") as temp:
        for variant in ["default", "custom"]:
            chunk = Path(temp) / f"runtime-{variant}.luau"
            chunk.write_text(table + f'local VARIANT = "{variant}"\n' + harness, encoding="utf-8")
            result = subprocess.run([cli, str(chunk)], capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            marker = f"[PLAYER_DATA_PACK] {variant}: PASS"
            if result.returncode != 0 or marker not in output:
                raise RuntimeError(f"runtime {variant}: exit {result.returncode}\n{output}")
            print(marker)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luau", required=True, help="Standalone Luau executable")
    parser.add_argument("--luau-compile", required=True, help="luau-compile executable")
    args = parser.parse_args()
    check_build()
    check_words()
    check_compile(args.luau_compile)
    check_runtime(args.luau)
    print("[PACK] all checks: PASS")


if __name__ == "__main__":
    main()
