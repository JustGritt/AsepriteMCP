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
    "~/Library/Application Support/Steam/steamapps/common/Aseprite/Aseprite.app/Contents/MacOS/aseprite",
)


def find_aseprite() -> str | None:
    override = os.environ.get("ASEPRITE_PATH")
    if override:
        return override if Path(override).is_file() else None
    for candidate in CANDIDATES:
        path = Path(candidate).expanduser()
        if path.is_file():
            return str(path)
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


def test_lua_and_python_fingerprint_the_extension_alike(aseprite_exe: str, tmp_path: Path):
    """The extension's own fingerprint (sent in its hello) must equal the server's
    of the same files, or every window would look outdated (#16)."""
    import json

    from aseprite_mcp.extension_check import ExtensionCopy

    extension = REPO_ROOT / "extension" / "aseprite-mcp"
    out = tmp_path / "fingerprint.json"
    script = tmp_path / "fingerprint.lua"
    script.write_text(
        "local fsio = dofile(app.params.ext .. '/fsio.lua')\n"
        "local files, why = fsio.fingerprint(app.params.ext)\n"
        "local f = io.open(app.params.out, 'w')\n"
        "f:write(json.encode(files or { error = why }))\n"
        "f:close()\n"
    )
    subprocess.run(
        [aseprite_exe, "-b", "--script-param", f"ext={extension}",
         "--script-param", f"out={out}", "--script", str(script)],
        capture_output=True, text=True, timeout=60, check=True,
    )
    from_lua = json.loads(out.read_text())
    assert "error" not in from_lua, from_lua
    assert from_lua == ExtensionCopy(extension).fingerprint()
