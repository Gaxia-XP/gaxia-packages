"""Builds packs/player-data from the library, and checks it (scripts/test-player-data-pack.py).

Usage: python scripts/build-player-data-pack.py [--wally <dir with Packages/ and ServerPackages/>]

The pack is what Gaxia Crew adds to a place with library_add: ServerStorage.GaxiaPackages.PlayerData.
- DataManager and DataMigration are the library's own files with the few changes listed in EDITS below, so the
  standalone edition needs nothing outside its folder. Every other line stays as the library has it.
- ProfileStore and Signal are the Wally packages' text, unchanged.
- DataConfig and NOTICE are written by hand (DataConfig is the game's own file).
Every file is LF: Gaxia Crew's allowlist refuses a carriage return in a script's text.
manifest.json pins each file's sha256.
"""

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "packs/player-data"
LIB = "src/ServerStorage/Gaxia_Packages_Server/Lib"

UPSTREAM = {
    "ProfileStore": ("ServerPackages/_Index/lm-loleris_profilestore@1.0.3/profilestore/ProfileStore.luau",
                     "lm-loleris/profilestore@1.0.3", "Apache-2.0"),
    "Signal": ("Packages/_Index/sleitnick_signal@2.0.3/signal/init.luau", "sleitnick/signal@2.0.3", "MIT"),
}

# (old, new): each old text occurs exactly once in the library file.
EDITS = {
    "DataManager": (f"{LIB}/DataManager/init.lua", [
        ("\tModule : DataManager\n\tLocation: ServerStorage.Gaxia_Packages_Server.Lib.DataManager\n",
         "\tModule : DataManager (standalone edition, GaxiaPackages packs/player-data)\n"
         "\tLocation: ServerStorage.GaxiaPackages.PlayerData.DataManager\n"
         "\t          It requires only its own folder: Signal, DataConfig, DataMigration and ProfileStore. The save\n"
         "\t          template is DataConfig.Template. Built from the library's DataManager by\n"
         "\t          scripts/build-player-data-pack.py; every other line is the library's.\n"),
        ("local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")\n", ""),
        ("-- ── Shared utilities ──\n"
         "local SharedPkg = require(ReplicatedStorage:WaitForChild(\"Gaxia_Packages\")) :: any\n"
         "local Signal = SharedPkg.Signal\n"
         "local Util   = SharedPkg.Util\n",
         "-- ── Shared utilities (the pack's own copy of sleitnick/signal 2.0.3) ──\n"
         "local Signal = require(script.Parent.Signal) :: any\n"),
        ("-- ── Config (server-side, see ServerStorage/Gaxia_Packages_Server/Config) ──\n"
         "-- FindFirstChild (not WaitForChild) + Config's body has no yields, so requiring it\n"
         "-- here is safe under the loader's no-yield metamethod. Config is the single place\n"
         "-- DataStore names + resilience tunables are set — nothing below is hardcoded.\n"
         "local Config = require(script.Parent.Parent:FindFirstChild(\"Config\") :: ModuleScript) :: any\n",
         "-- ── Config (the game's DataConfig, next to this module) ──\n"
         "-- DataConfig is the single place DataStore names, resilience tunables and the save\n"
         "-- template are set — nothing below is hardcoded.\n"
         "local Config = { Data = require(script.Parent.DataConfig) :: any }\n"),
        ("-- ── Types ──\nexport type PlayerData = {\n",
         "-- ── Types ──\n"
         "-- The library's default shape. A game that changes DataConfig.Template has its own fields;\n"
         "-- DataManager itself reads only LastLogin and __version.\n"
         "export type PlayerData = {\n"),
        ("-- Default profile schema: anything missing in saved data is filled via Reconcile.\n"
         "DataManager.DEFAULT_PROFILE = {\n"
         "\tCoins      = 0,\n"
         "\tGems       = 0,\n"
         "\tLevel      = 1,\n"
         "\tExperience = 0,\n"
         "\tInventory  = {} :: { [string]: number },\n"
         "\tSettings   = { Music = true, SFX = true },\n"
         "\tPlayTime   = 0,\n"
         "\tLastLogin  = 0,\n"
         "\t-- Schema baseline (see PlayerData.__version). currentVersion in DataMigration\n"
         "\t-- also defaults to 1, so Migrate is a clean no-op until a game bumps it.\n"
         "\t__version  = 1,\n"
         "} :: PlayerData\n",
         "-- Default profile schema: anything missing in saved data is filled via Reconcile.\n"
         "-- It is DataConfig.Template (the library's default shape unless the game changed it).\n"
         "DataManager.DEFAULT_PROFILE = Config.Data.Template :: PlayerData\n"
         "-- Schema baseline (see PlayerData.__version). currentVersion in DataMigration\n"
         "-- also defaults to 1, so Migrate is a clean no-op until a game bumps it. A template\n"
         "-- without __version gets 1, so a new save never walks a migration chain from 0.\n"
         "if (DataManager.DEFAULT_PROFILE :: any).__version == nil then\n"
         "\t(DataManager.DEFAULT_PROFILE :: any).__version = 1\n"
         "end\n"),
        ("\tlocal serverPackages = script.Parent.Parent:WaitForChild(\"ServerPackages\")\n"
         "\tlocal ProfileStore = require(serverPackages:WaitForChild(\"ProfileStore\")) :: any\n",
         "\tlocal ProfileStore = require(script.Parent.ProfileStore) :: any\n"),
        ("-- Test-only seed: install a synthetic profile",
         "-- Fills target's missing fields from template, copying tables (the library's\n"
         "-- Util.Table has no Reconcile; this is the same fill ProfileStore's Reconcile does).\n"
         "local function reconcile(target: { [string]: any }, template: { [string]: any }): { [string]: any }\n"
         "\tlocal function copy(t: { [any]: any }): { [any]: any }\n"
         "\t\tlocal out = {}\n"
         "\t\tfor k, v in t do\n"
         "\t\t\tout[k] = if typeof(v) == \"table\" then copy(v) else v\n"
         "\t\tend\n"
         "\t\treturn out\n"
         "\tend\n"
         "\tfor k, v in template do\n"
         "\t\tif target[k] == nil then\n"
         "\t\t\ttarget[k] = if typeof(v) == \"table\" then copy(v) else v\n"
         "\t\tend\n"
         "\tend\n"
         "\treturn target\n"
         "end\n\n"
         "-- Test-only seed: install a synthetic profile"),
        ("\t\tData = (Util :: any).Table.Reconcile(data or {}, DataManager.DEFAULT_PROFILE),\n",
         "\t\tData = reconcile(data or {}, DataManager.DEFAULT_PROFILE),\n"),
    ]),
    "DataMigration": (f"{LIB}/DataMigration.lua", [
        ("-- Location: ServerStorage/Gaxia_Packages_Server/Lib/DataMigration\n",
         "-- Location: ServerStorage/GaxiaPackages/PlayerData/DataMigration (GaxiaPackages packs/player-data)\n"),
        ("local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")\n"
         "local SharedPkg = require(ReplicatedStorage:WaitForChild(\"Gaxia_Packages\")) :: any\n"
         "local Signal = SharedPkg.Signal\n",
         "local Signal = require(script.Parent.Signal) :: any\n"),
    ]),
}

HAND = ["DataConfig", "NOTICE"]
CLASS = "ModuleScript"
EDITABLE = {"DataConfig"}


def lf(text):
    return text.replace("\r\n", "\n")


def edited(name):
    path, edits = EDITS[name]
    text = lf((ROOT / path).read_text(encoding="utf-8"))
    for old, new in edits:
        count = text.count(old)
        if count != 1:
            raise RuntimeError(f"{name}: an edit's old text occurs {count} times: {old[:60]!r}")
        text = text.replace(old, new)
    return text


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def manifest(texts, wally_found):
    modules = []
    for name in ["DataManager", "DataConfig", "DataMigration", "ProfileStore", "Signal", "NOTICE"]:
        entry = {"name": name, "class": CLASS, "file": f"{name}.luau", "sha256": sha(texts[name]),
                 "editable": name in EDITABLE}
        if name in UPSTREAM:
            entry["upstream"] = {"wally": UPSTREAM[name][1], "path": UPSTREAM[name][0], "license": UPSTREAM[name][2]}
        elif name in EDITS:
            entry["from"] = EDITS[name][0]
        modules.append(entry)
    return {
        "pack": "player_data",
        "place": ["ServerStorage", "GaxiaPackages", "PlayerData"],
        "require": "require(game:GetService(\"ServerStorage\").GaxiaPackages.PlayerData.DataManager)",
        "modules": modules,
    }


def texts_for(wally):
    texts = {name: edited(name) for name in EDITS}
    for name in HAND:
        texts[name] = (PACK / f"{name}.luau").read_text(encoding="utf-8")
    found = True
    for name, (path, _, _) in UPSTREAM.items():
        source = wally / path
        if source.exists():
            texts[name] = lf(source.read_text(encoding="utf-8"))
        else:
            found = False
            texts[name] = (PACK / f"{name}.luau").read_text(encoding="utf-8")
    return texts, found


def default_wally():
    # Packages/ and ServerPackages/ are made by `wally install` and not tracked.
    for candidate in [ROOT, ROOT.parent / "repo"]:
        if (candidate / UPSTREAM["ProfileStore"][0]).exists():
            return candidate
    return ROOT


def check(wally=None):
    wally = wally or default_wally()
    texts, found = texts_for(wally)
    problems = []
    for name, text in texts.items():
        path = PACK / f"{name}.luau"
        if not path.exists() or path.read_bytes() != text.encode("utf-8"):
            problems.append(f"{path.name} differs from the build")
    want = json.dumps(manifest(texts, found), indent=2) + "\n"
    have = (PACK / "manifest.json").read_text(encoding="utf-8") if (PACK / "manifest.json").exists() else ""
    if have != want:
        problems.append("manifest.json differs from the build")
    if not found:
        print("[PACK] note: no Wally packages found; ProfileStore and Signal were checked by hash only")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wally", type=Path, default=None)
    args = parser.parse_args()
    texts, found = texts_for(args.wally or default_wally())
    if not found:
        raise SystemExit("ProfileStore/Signal not found: run wally install or pass --wally")
    PACK.mkdir(parents=True, exist_ok=True)
    for name, text in texts.items():
        (PACK / f"{name}.luau").write_bytes(text.encode("utf-8"))
    (PACK / "manifest.json").write_bytes((json.dumps(manifest(texts, found), indent=2) + "\n").encode("utf-8"))
    print(f"[PACK] wrote {len(texts)} modules and manifest.json")


if __name__ == "__main__":
    main()
