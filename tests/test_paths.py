"""Sandbox tests.

This is the security boundary described in spec section 21, so the cases here are
weighted toward escape attempts rather than happy paths.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from aseprite_mcp.bridge.protocol import BridgeError, ErrorCode
from aseprite_mcp.paths import OPEN_SUFFIXES, SAVE_SUFFIXES, resolve_in_sandbox


def resolve(raw, roots, suffixes=OPEN_SUFFIXES, **kwargs):
    return resolve_in_sandbox(raw, tuple(roots), suffixes=suffixes, **kwargs)


def assert_rejected(raw, roots, suffixes=OPEN_SUFFIXES, code=ErrorCode.PATH_NOT_ALLOWED):
    with pytest.raises(BridgeError) as excinfo:
        resolve(raw, roots, suffixes)
    assert excinfo.value.code is code, f"{raw!r} produced {excinfo.value.code}"


class TestAccepts:
    def test_file_inside_root(self, sandbox):
        target = sandbox / "hero.aseprite"
        assert resolve(str(target), [sandbox]) == Path(os.path.realpath(target))

    def test_nested_file(self, sandbox):
        (sandbox / "tamer").mkdir()
        target = sandbox / "tamer" / "attack.aseprite"
        assert resolve(str(target), [sandbox]).name == "attack.aseprite"

    def test_relative_path_resolves_against_first_root(self, sandbox):
        # The spec's own examples use relative paths.
        resolved = resolve("tamer/attack.aseprite", [sandbox])
        assert resolved.parent.name == "tamer"
        assert resolved.is_relative_to(Path(os.path.realpath(sandbox)))

    def test_second_root_is_honoured(self, sandbox, tmp_path):
        other = tmp_path / "other"
        other.mkdir()
        assert resolve(str(other / "a.aseprite"), [sandbox, other]).name == "a.aseprite"

    def test_target_need_not_exist_yet(self, sandbox):
        # Save targets are validated before they are created.
        assert resolve(str(sandbox / "new.aseprite"), [sandbox], SAVE_SUFFIXES)


class TestRejects:
    def test_parent_traversal(self, sandbox):
        assert_rejected(str(sandbox / ".." / "escape.aseprite"), [sandbox])

    def test_deep_parent_traversal(self, sandbox):
        assert_rejected("../../../../Users/someone/secret.aseprite", [sandbox])

    def test_absolute_path_outside(self, sandbox, tmp_path):
        assert_rejected(str(tmp_path / "outside.aseprite"), [sandbox])

    def test_sibling_directory_sharing_a_prefix(self, sandbox):
        # 'sprites-evil' must not match the root 'sprites' by string prefix.
        sibling = sandbox.parent / f"{sandbox.name}-evil"
        sibling.mkdir()
        assert_rejected(str(sibling / "x.aseprite"), [sandbox])

    def test_no_roots_configured(self, sandbox):
        with pytest.raises(BridgeError) as excinfo:
            resolve_in_sandbox("x.aseprite", (), suffixes=OPEN_SUFFIXES)
        assert excinfo.value.code is ErrorCode.PATH_NOT_ALLOWED

    def test_null_byte(self, sandbox):
        assert_rejected(str(sandbox / "a\x00b.aseprite"), [sandbox], code=ErrorCode.INVALID_PARAMS)

    def test_empty_path(self, sandbox):
        assert_rejected("   ", [sandbox], code=ErrorCode.INVALID_PARAMS)

    @pytest.mark.parametrize("name", ["notes.txt", "sprite", "sheet.gif", "archive.aseprite.zip"])
    def test_disallowed_extensions(self, sandbox, name):
        assert_rejected(str(sandbox / name), [sandbox])

    def test_png_can_be_opened_but_not_saved(self, sandbox):
        target = sandbox / "sheet.png"
        assert resolve(str(target), [sandbox], OPEN_SUFFIXES)
        # Refusing to save .png keeps a layered source file from being flattened.
        assert_rejected(str(target), [sandbox], SAVE_SUFFIXES)

    def test_must_exist(self, sandbox):
        with pytest.raises(BridgeError) as excinfo:
            resolve(str(sandbox / "missing.aseprite"), [sandbox], must_exist=True)
        assert excinfo.value.code is ErrorCode.INVALID_PARAMS


@pytest.mark.skipif(os.name != "nt", reason="Windows-specific path semantics")
class TestWindows:
    def test_case_insensitive_match(self, sandbox):
        # Windows paths are case-insensitive; a case-sensitive prefix check would
        # reject a legitimate path here (or, reversed, admit an illegitimate one).
        shouty = str(sandbox).upper() + "\\HERO.ASEPRITE"
        assert resolve(shouty, [sandbox]).name.lower() == "hero.aseprite"

    def test_forward_slashes(self, sandbox):
        assert resolve(str(sandbox).replace("\\", "/") + "/hero.aseprite", [sandbox])

    def test_junction_cannot_escape(self, sandbox, tmp_path):
        """A directory junction inside the sandbox must not lead out of it.

        This is the case plain '..' collapsing misses, and why the sandbox uses
        realpath rather than Path.resolve-free normalisation.
        """
        secret = tmp_path / "secret"
        secret.mkdir()
        (secret / "loot.aseprite").write_bytes(b"")
        link = sandbox / "escape"

        result = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(link), str(secret)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            pytest.skip(f"could not create a junction: {result.stderr.strip()}")

        assert_rejected(str(link / "loot.aseprite"), [sandbox])
