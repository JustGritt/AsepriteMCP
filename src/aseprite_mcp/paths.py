"""Filesystem sandboxing for open_sprite / save_sprite.

This is the security-critical module (docs/ASEPRITE_MCP.md section 21). Every
path that reaches Aseprite from the agent goes through resolve_in_sandbox.

Validation order matters:

1. expand a leading ~
2. make relative paths relative to the first allowed root (the spec's examples
   use relative paths like Assets/Sprites/Tamer/attack.aseprite)
3. os.path.realpath -- collapses ".." and resolves symlinks and Windows
   directory junctions, so neither can be used to step outside a root
4. os.path.normcase -- Windows paths are case-insensitive, so a prefix
   comparison without this is trivially bypassable
5. prefix-match against each allowed root on path components rather than raw
   strings, so "sprites-evil" does not match the root "sprites"
6. extension allowlist

Note that realpath is applied to a path that need not exist yet (save targets),
which still normalises the path and resolves any symlinked parent directories.
"""

from __future__ import annotations

import os
from pathlib import Path

from .bridge.protocol import BridgeError, ErrorCode

# Formats Aseprite can open as a document.
OPEN_SUFFIXES = frozenset({".aseprite", ".ase", ".png"})

# Formats we allow writing. Deliberately narrower than OPEN_SUFFIXES: the point
# of the project is to deliver an editable .aseprite asset, and refusing to
# write .png keeps the agent from flattening someone's layered source file.
SAVE_SUFFIXES = frozenset({".aseprite", ".ase"})


def canonical(path):
    """Fully resolve a path for comparison purposes."""
    return Path(os.path.normcase(os.path.realpath(os.path.expanduser(str(path)))))


def _is_within(candidate: Path, root: Path) -> bool:
    """True if candidate is root or lives underneath it.

    Compares parts rather than string prefixes so that /a/sprites-evil is not
    treated as living inside /a/sprites.
    """
    c_parts = candidate.parts
    r_parts = root.parts
    return len(c_parts) >= len(r_parts) and c_parts[: len(r_parts)] == r_parts


def resolve_in_sandbox(
    raw_path: str,
    allowed_dirs,
    *,
    suffixes,
    must_exist: bool = False,
) -> Path:
    """Return the real, absolute path raw_path refers to, or raise.

    Raises BridgeError with PATH_NOT_ALLOWED for anything outside the allowlist,
    and INVALID_PARAMS for structurally bad input.
    """
    if not isinstance(raw_path, str) or not raw_path.strip():
        raise BridgeError(ErrorCode.INVALID_PARAMS, "A non-empty 'path' is required.")
    if "\x00" in raw_path:
        raise BridgeError(ErrorCode.INVALID_PARAMS, "Path contains a null byte.")

    if not allowed_dirs:
        raise BridgeError(
            ErrorCode.PATH_NOT_ALLOWED,
            "No sandbox roots are configured. Set ASEPRITE_MCP_ALLOWED_DIRS to a "
            "directory the server may read and write.",
        )

    expanded = Path(os.path.expanduser(raw_path.strip()))
    if not expanded.is_absolute():
        # Relative paths are interpreted against the primary sandbox root, never
        # against the server's cwd, which the agent cannot see.
        expanded = Path(allowed_dirs[0]) / expanded

    resolved = Path(os.path.realpath(expanded))
    normalised = Path(os.path.normcase(resolved))

    if not any(_is_within(normalised, canonical(root)) for root in allowed_dirs):
        roots = ", ".join(str(d) for d in allowed_dirs)
        raise BridgeError(
            ErrorCode.PATH_NOT_ALLOWED,
            f"{raw_path!r} resolves to {str(resolved)!r}, which is outside the "
            f"allowed directories: {roots}",
        )

    suffix = resolved.suffix.lower()
    if suffix not in suffixes:
        allowed = ", ".join(sorted(suffixes))
        raise BridgeError(
            ErrorCode.PATH_NOT_ALLOWED,
            f"{resolved.name!r} has extension {suffix or '(none)'!r}; "
            f"allowed here: {allowed}",
        )

    if must_exist and not resolved.is_file():
        raise BridgeError(ErrorCode.INVALID_PARAMS, f"No such file: {resolved}")

    return resolved
