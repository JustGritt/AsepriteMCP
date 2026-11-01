"""Run the docs/BENCHMARKS.md prompts, each in its own fresh Claude Code session.

Every prompt starts a headless `claude -p` session outside the repo, with only
the aseprite MCP server and no built-in tools, on a fresh copy of the same
fixture (tests/lua/make_bench_fixtures.lua). The session's result line gives the
cost and token usage; the event stream gives the tool calls.

    uv run python scripts/run_benchmarks.py --label current
    uv run python scripts/run_benchmarks.py --label baseline --server-dir <old checkout>
    uv run python scripts/run_benchmarks.py --compare baseline current

Only one server can hold the bridge port, so disable the aseprite server in any
other Claude Code session first (/mcp), and have the Aseprite extension
installed from the same checkout as --server-dir. Results and transcripts go to
sprites/bench/<label>/, which is gitignored.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests.test_lua_integration import find_aseprite  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
BENCH = REPO / "sprites" / "bench"
MODEL = "claude-opus-5-5"
PORT = int(os.environ.get("ASEPRITE_MCP_PORT", "32145"))
ATTEMPTS = 3

PROMPTS = {
    1: ("1-potion.aseprite", "Draw a potion bottle icon: outline, glass, liquid, one highlight."),
    # ASCII only: prompts pass through claude.cmd and a possibly non-UTF-8 console.
    2: ("2-knight.aseprite", "Draw a front-facing knight character with a 4-6 colour palette."),
    3: (
        "3-idle.aseprite",
        "Turn the current sprite into a 4-frame idle bob animation, 1 px up and down, "
        "and tag it idle.",
    ),
    4: ("4-armour.aseprite", "Recolor the existing sprite's armour from blue to red across every frame."),
    5: ("5-arm.aseprite", "The arm on layer Arm in frame 3 is 1 px too long; fix only that."),
}
TEMPLATE = "Open the sprite {path} in Aseprite. {task} Save it when you are done."


def make_fixtures(out: Path) -> None:
    exe = find_aseprite()
    if not exe:
        sys.exit("Aseprite not found. Set ASEPRITE_PATH.")
    out.mkdir(parents=True, exist_ok=True)
    # Another port, so this headless Aseprite cannot take the bridge from the GUI one.
    env = {**os.environ, "ASEPRITE_MCP_PORT": "32199"}
    script = REPO / "tests" / "lua" / "make_bench_fixtures.lua"
    result = subprocess.run(
        [exe, "-b", "--script-param", f"out={out}", "--script", str(script)],
        env=env, capture_output=True, text=True, timeout=120,
    )
    if "FIXTURES_DONE" not in result.stdout:
        sys.exit(f"Fixture script failed:\n{result.stdout}\n{result.stderr}")


def port_free() -> bool:
    with socket.socket() as s:
        try:
            s.bind(("127.0.0.1", PORT))
        except OSError:
            return False
    return True


def wait_for_port(seconds: float = 15) -> None:
    """The previous session's server has to let go of the port first."""
    deadline = time.monotonic() + seconds
    while not port_free():
        if time.monotonic() > deadline:
            sys.exit(
                f"Port {PORT} is held by another aseprite MCP server. Disable it in any "
                "other Claude Code session (/mcp), then rerun."
            )
        time.sleep(0.5)


def run_one(n: int, work: Path, config: Path, model: str, cwd: str) -> dict:
    name, task = PROMPTS[n]
    sprite = work / name
    prompt = TEMPLATE.format(path=sprite.as_posix(), task=task)
    # npm's global bin is often on the shell's PATH but not the Windows one.
    claude = (
        shutil.which("claude")
        or shutil.which("claude", path=str(Path(os.environ.get("APPDATA", "")) / "npm"))
        or sys.exit("claude not found on PATH.")
    )
    command = [
        claude, "-p", prompt,
        "--output-format", "stream-json", "--verbose",
        "--model", model,
        "--strict-mcp-config", "--mcp-config", str(config),
        "--tools", "",
        "--allowedTools", "mcp__aseprite",
        "--no-session-persistence",
    ]
    for attempt in range(1, ATTEMPTS + 1):
        shutil.copy(BENCH / "fixtures" / name, sprite)
        wait_for_port()
        proc = subprocess.run(
            command, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True,
            text=True, encoding="utf-8", timeout=1800,
        )
        (work / f"{n}.jsonl").write_text(proc.stdout, encoding="utf-8")
        calls, result, not_connected = Counter(), None, False
        for line in proc.stdout.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get("type")
            if kind == "assistant":
                for block in event["message"].get("content", []):
                    if block.get("type") == "tool_use":
                        calls[block["name"].removeprefix("mcp__aseprite__")] += 1
            elif kind == "user" and "ASEPRITE_NOT_CONNECTED" in line:
                not_connected = True
            elif kind == "result":
                result = event
        # A run that started before Aseprite reconnected measures the race, not the tools.
        if result and not not_connected:
            break
        print(f"  #{n} attempt {attempt}: {'not connected' if result else proc.stderr[-300:]}")
        time.sleep(5)
    else:
        return {"n": n, "failed": True}

    usage = result.get("usage", {})
    return {
        "n": n,
        "cost_usd": round(result.get("total_cost_usd", 0), 4),
        "tool_calls": sum(calls.values()),
        "tools": dict(calls),
        "turns": result.get("num_turns"),
        "input": usage.get("input_tokens", 0),
        "cache_write": usage.get("cache_creation_input_tokens", 0),
        "cache_read": usage.get("cache_read_input_tokens", 0),
        "output": usage.get("output_tokens", 0),
        "seconds": round(result.get("duration_ms", 0) / 1000),
        "models": sorted(result.get("modelUsage", {})),
        "is_error": result.get("is_error", False),
        "attempts": attempt,
    }


def run(args: argparse.Namespace) -> None:
    server_dir = Path(args.server_dir).resolve()
    # `uv run` sets UV to its own path, which works even when uv is not on PATH.
    uv = args.uv or os.environ.get("UV") or shutil.which("uv") or sys.exit("uv not found; pass --uv.")
    work = BENCH / args.label
    work.mkdir(parents=True, exist_ok=True)
    make_fixtures(BENCH / "fixtures")

    config = work / "mcp.json"
    config.write_text(json.dumps({"mcpServers": {"aseprite": {
        "command": uv,
        "args": ["run", "--directory", str(server_dir), "aseprite-mcp"],
        "env": {
            "ASEPRITE_MCP_ALLOWED_DIRS": str(work),
            "ASEPRITE_MCP_USAGE_LOG": str(work / "usage.jsonl"),
        },
    }}}, indent=2), encoding="utf-8")

    # Outside the repo, so no project CLAUDE.md or memory reaches the session.
    cwd = tempfile.mkdtemp(prefix="aseprite-bench-")
    # --only reruns some prompts and keeps the rest of an earlier run.
    results = load(args.label) if args.only and (work / "results.json").exists() else []
    for n in args.only or sorted(PROMPTS):
        print(f"#{n} {PROMPTS[n][1]}")
        record = run_one(n, work, config, args.model, cwd)
        print(f"  {json.dumps(record)}")
        results = sorted([r for r in results if r["n"] != n] + [record], key=lambda r: r["n"])
        (work / "results.json").write_text(
            json.dumps({"server_dir": str(server_dir), "model": args.model, "results": results}, indent=2),
            encoding="utf-8",
        )
    print_table({args.label: results})


def load(label: str) -> list[dict]:
    return json.loads((BENCH / label / "results.json").read_text(encoding="utf-8"))["results"]


def print_table(runs: dict[str, list[dict]]) -> None:
    labels = list(runs)
    by_n = {label: {r["n"]: r for r in rows if not r.get("failed")} for label, rows in runs.items()}
    head = ["#"] + [f"{label} {col}" for label in labels for col in ("$", "calls", "output tok")]
    print("\n| " + " | ".join(head) + " |\n|" + "---|" * len(head))
    totals = {label: Counter() for label in labels}
    for n in sorted(PROMPTS):
        cells = [str(n)]
        for label in labels:
            r = by_n[label].get(n)
            if r is None:
                cells += ["-"] * 3
                continue
            totals[label].update(cost=r["cost_usd"], calls=r["tool_calls"], output=r["output"])
            cells += [f"{r['cost_usd']:.2f}", str(r["tool_calls"]), f"{r['output']:,}"]
        print("| " + " | ".join(cells) + " |")
    cells = ["**total**"]
    for label in labels:
        t = totals[label]
        cells += [f"**{t['cost']:.2f}**", f"**{t['calls']}**", f"**{t['output']:,}**"]
    print("| " + " | ".join(cells) + " |")
    if len(labels) == 2 and totals[labels[1]]["cost"]:
        ratio = totals[labels[0]]["cost"] / totals[labels[1]]["cost"]
        print(f"\n{labels[0]} costs {ratio:.1f}x {labels[1]}")


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--label", help="name for this run, e.g. baseline or current")
    parser.add_argument("--server-dir", default=str(REPO), help="checkout whose server to run")
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--uv", help="path to uv, if Claude Code cannot find it on PATH")
    parser.add_argument("--only", type=int, nargs="+", choices=sorted(PROMPTS))
    parser.add_argument("--compare", nargs=2, metavar=("A", "B"), help="compare two labels")
    args = parser.parse_args()
    if args.compare:
        print_table({label: load(label) for label in args.compare})
    elif args.label:
        run(args)
    else:
        parser.error("pass --label to run, or --compare A B")


if __name__ == "__main__":
    main()
