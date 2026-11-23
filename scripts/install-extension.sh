#!/usr/bin/env sh
# Install the aseprite-mcp bridge extension for development (macOS and Linux).
# The Windows equivalent is install-extension.ps1.
#
#   scripts/install-extension.sh            copy extension/aseprite-mcp into Aseprite
#   scripts/install-extension.sh --link     symlink it instead, so edits to the repo
#                                           take effect on the next Aseprite restart
#   scripts/install-extension.sh --uninstall
#
# Aseprite loads extensions at startup, so restart it afterwards. Set
# ASEPRITE_EXTENSIONS_DIR to install somewhere other than the default folder.
set -eu

mode=copy
case "${1:-}" in
  "") ;;
  --link) mode=link ;;
  --uninstall) mode=uninstall ;;
  *) echo "usage: $0 [--link | --uninstall]" >&2; exit 2 ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd)
source_dir="$repo/extension/aseprite-mcp"
if [ -n "${ASEPRITE_EXTENSIONS_DIR:-}" ]; then
  extensions_dir=$ASEPRITE_EXTENSIONS_DIR
elif [ "$(uname)" = "Darwin" ]; then
  extensions_dir="$HOME/Library/Application Support/Aseprite/extensions"
else
  extensions_dir="${XDG_CONFIG_HOME:-$HOME/.config}/aseprite/extensions"
fi
target="$extensions_dir/aseprite-mcp"

[ -d "$source_dir" ] || { echo "Extension source not found at $source_dir" >&2; exit 1; }

if [ -L "$target" ]; then
  echo "Removing existing link at $target"
  rm "$target"
elif [ -e "$target" ]; then
  echo "Removing existing install at $target"
  rm -rf "$target"
fi

if [ "$mode" = uninstall ]; then
  echo "Uninstalled. Restart Aseprite to unload it."
  exit 0
fi

mkdir -p "$extensions_dir"
if [ "$mode" = link ]; then
  ln -s "$source_dir" "$target"
  echo "Linked $target -> $source_dir"
else
  cp -R "$source_dir" "$target"
  echo "Copied to $target"
fi

cat <<'EOF'

Next steps:
  1. Restart Aseprite.
  2. If Aseprite asks whether the script may access files, allow it and tick
     "Give full trust to this script". Previews are PNGs written to disk, so
     rendering fails without it. See docs/SETUP.md.
  3. Check File > MCP Bridge... -- it opens the connect dialog, which reports
     status live and is where the host and port are set.
EOF
