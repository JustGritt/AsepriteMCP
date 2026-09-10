"""Runs the Lua handler suite against a real Aseprite in batch mode.

Marked ``lua`` so it can be deselected with ``-m "not lua"`` on a machine without
Aseprite. Batch mode is used here only to exercise Lua logic against the real
engine -- it is not an editing fallback, which spec section 2.1 rules out.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.lua

REPO_ROOT = Path(__file__).resolve().parents[1]

# Checked in order; ASEPRITE_PATH always wins.
CANDIDATES = (
    r"C:\Program Files\Aseprite\Aseprite.exe",
    r"C:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe",
    r"Z:\Program Files (x86)\Steam\steamapps\common\Aseprite\Aseprite.exe",
    "/Applications/Aseprite.app/Contents/MacOS/aseprite",
)


def find_aseprite() -> str | None:
    override = os.environ.get("ASEPRITE_PATH")
    if override:
        return override if Path(override).is_file() else None
    for candidate in CANDIDATES:
        if Path(candidate).is_file():
            return candidate
    return shutil.which("aseprite")


@pytest.fixture(scope="module")
def aseprite_exe() -> str:
    exe = find_aseprite()
    if not exe:
        pytest.skip(
            "Aseprite not found. Set ASEPRITE_PATH to the executable to run the Lua tests."
        )
    return exe


def test_lua_handler_suite(aseprite_exe: str):
    script = REPO_ROOT / "tests" / "lua" / "run_tests.lua"
    result = subprocess.run(
        [aseprite_exe, "-b", "--script", str(script)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=180,
    )
    output = result.stdout + result.stderr
    print(output)

    assert "LUA_TESTS_PASSED" in output, (
        "Lua handler tests failed or did not run to completion.\n" + output
    )
