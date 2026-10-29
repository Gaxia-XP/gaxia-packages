#!/usr/bin/env bash
# Installs the pinned tools the framework checks need (Linux x86_64) into one folder:
#   <dest>/bin/{rojo,lune,luau-lsp,luau-ast}   <dest>/defs/globalTypes.d.luau
# Used by .github/workflows/checks.yml; works the same on a dev machine:
#   bash tools/ci/install-tools.sh /tmp/gaxia-tools
#   export PATH=/tmp/gaxia-tools/bin:$PATH ROBLOX_DEFS=/tmp/gaxia-tools/defs/globalTypes.d.luau
# Every download is checked against a pinned sha256. Bump a version = change its
# version AND its hash below (sha256sum the new asset). Downloads are kept in
# <dest>/dl, so a second run (or a CI cache hit) downloads nothing.
# On GitHub Actions it also adds <dest>/bin to PATH and sets LUAU_AST / ROBLOX_DEFS.
set -euo pipefail

DEST="${1:?usage: install-tools.sh <dest-dir>}"
mkdir -p "$DEST/bin" "$DEST/defs" "$DEST/dl"
DEST="$(cd "$DEST" && pwd)"

ROJO_VERSION=7.4.4         # needs only `rojo sourcemap`; rokit.toml pins 7.7.0-rc.1 for Studio sync
LUNE_VERSION=0.10.4        # = rokit.toml
LUAU_LSP_VERSION=1.70.0    # the version the type checks were last verified with
LUAU_VERSION=0.744         # luau-ubuntu.zip ships luau-ast (check-architecture.mjs)

# name|url|sha256
ASSETS=(
  "rojo.zip|https://github.com/rojo-rbx/rojo/releases/download/v${ROJO_VERSION}/rojo-${ROJO_VERSION}-linux-x86_64.zip|784e2cd42af3d565826c4910df94f45080fc7ed6206eb6808dbc79b516323652"
  "lune.zip|https://github.com/lune-org/lune/releases/download/v${LUNE_VERSION}/lune-${LUNE_VERSION}-linux-x86_64.zip|ffba0bd404ae078c9543ef5ac12479938a741aab255768a11a08517ae963b288"
  "luau-lsp.zip|https://github.com/JohnnyMorganz/luau-lsp/releases/download/${LUAU_LSP_VERSION}/luau-lsp-linux-x86_64.zip|4ff08890ea0d4b6d9de25fdff1a4c87e0dc9f2e45d782c894e83475e51d55813"
  "luau.zip|https://github.com/luau-lang/luau/releases/download/${LUAU_VERSION}/luau-ubuntu.zip|6506f0852c623aaffcb28494aac16c26dc04a269ea0e16cc0aafc8c8ac79f3ec"
  # Roblox type definitions from the luau-lsp tag that matches LUAU_LSP_VERSION.
  "globalTypes.d.luau|https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/${LUAU_LSP_VERSION}/scripts/globalTypes.d.luau|2b0df788dc3fd1b572e71ee7fe9e1c55cc23882afbd5024aecdec30d9bd7520f"
)

fetch() { # name url sha
  local file="$DEST/dl/$1"
  if [ -f "$file" ] && echo "$3  $file" | sha256sum -c --status; then
    echo "cached  $1"
    return
  fi
  local i
  for i in 1 2 3 4; do
    if curl -fsSL --retry 3 -o "$file.part" "$2"; then break; fi
    echo "download failed ($i/4): $2" >&2
    [ "$i" = 4 ] && exit 1
    sleep $((2 ** i))
  done
  if ! echo "$3  $file.part" | sha256sum -c --status; then
    echo "sha256 mismatch for $2 (got $(sha256sum "$file.part" | cut -c1-64))" >&2
    exit 1
  fi
  mv "$file.part" "$file"
  echo "fetched $1"
}

for a in "${ASSETS[@]}"; do
  IFS='|' read -r name url sha <<<"$a"
  fetch "$name" "$url" "$sha"
done

unzip -oq "$DEST/dl/rojo.zip" rojo -d "$DEST/bin"
unzip -oq "$DEST/dl/lune.zip" lune -d "$DEST/bin"
unzip -oq "$DEST/dl/luau-lsp.zip" luau-lsp -d "$DEST/bin"
unzip -oq "$DEST/dl/luau.zip" luau-ast -d "$DEST/bin"
chmod +x "$DEST/bin/"*
cp "$DEST/dl/globalTypes.d.luau" "$DEST/defs/globalTypes.d.luau"

"$DEST/bin/rojo" --version
"$DEST/bin/lune" --version
"$DEST/bin/luau-lsp" --version
"$DEST/bin/luau-ast" 2>&1 | head -1 || true

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$DEST/bin" >>"$GITHUB_PATH"
  {
    echo "LUAU_AST=$DEST/bin/luau-ast"
    echo "ROBLOX_DEFS=$DEST/defs/globalTypes.d.luau"
  } >>"$GITHUB_ENV"
fi
