"""Is the extension Aseprite is running the one this server was written against?

A stale extension used to fail obscurely: a copy that predated a change answered
`UNKNOWN_COMMAND: sprite.new`, and an Aseprite that had not really restarted (on
macOS, closing the window leaves it running) returned subtly wrong replies
(#16). So the extension fingerprints its own files at load and sends them in its
hello, and the server compares them with its own copy of the extension.

The fingerprint is a content hash per file, the same FNV-1a as
`fsio.contentHash` on the Lua side, with carriage returns skipped so a checkout
with Windows line endings matches one without.
"""

from __future__ import annotations

from pathlib import Path

FNV_OFFSET, FNV_PRIME = 2166136261, 16777619

# How many differing files an error names before it summarises the rest.
MAX_NAMED = 6


def content_hash(data: bytes) -> int:
    h = FNV_OFFSET
    for byte in data:
        if byte != 13:
            h = ((h ^ byte) * FNV_PRIME) & 0xFFFFFFFF
    return h


def _counted(path: Path) -> bool:
    return not path.name.startswith("__") and (path.suffix == ".lua" or path.name == "package.json")


class ExtensionCopy:
    """The server's copy of the extension, fingerprinted on demand.

    Hashes are cached per file by size and modification time, so asking on every
    call costs a directory listing, and an edit to the copy mid-session (the
    usual way to make a running Aseprite stale while developing) is seen at once.
    """

    def __init__(self, directory: Path):
        self.directory = directory
        self._cache: dict[str, tuple[int, int, int]] = {}

    def fingerprint(self) -> dict[str, int]:
        files: dict[str, int] = {}
        for path in sorted(self.directory.rglob("*")):
            if not path.is_file() or not _counted(path):
                continue
            rel = path.relative_to(self.directory).as_posix()
            stat = path.stat()
            cached = self._cache.get(rel)
            if cached and cached[0] == stat.st_size and cached[1] == stat.st_mtime_ns:
                files[rel] = cached[2]
                continue
            digest = content_hash(path.read_bytes())
            self._cache[rel] = (stat.st_size, stat.st_mtime_ns, digest)
            files[rel] = digest
        return files

    def differences(self, running: dict[str, int]) -> list[str]:
        """Files that differ between the running extension and this copy, sorted."""
        expected = self.fingerprint()
        names = set(expected) | set(running)
        return sorted(n for n in names if expected.get(n) != running.get(n))


def describe(files: list[str]) -> str:
    shown = ", ".join(files[:MAX_NAMED])
    more = len(files) - MAX_NAMED
    return shown + (f" and {more} more" if more > 0 else "")
