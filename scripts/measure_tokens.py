"""Exact token counts for the tool list and the draw_pixels / draw_rows payloads.

tests/test_token_budget.py guards sizes in bytes offline. This asks the API's
token-counting endpoint for the real numbers, which is what to quote when a
change claims a saving:

    ANTHROPIC_API_KEY=... uv run --with anthropic python scripts/measure_tokens.py

Counting tokens is free but needs a key; without one this prints byte sizes only.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from aseprite_mcp.server import build_server  # noqa: E402
from tests.test_token_budget import LEGEND, blob_sprite  # noqa: E402

MODEL = "claude-opus-5-5"


def compact(value) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


async def tool_definitions() -> list[dict]:
    mcp, _ = build_server()
    return [
        {"name": t.name, "description": t.description or "", "input_schema": t.input_schema}
        for t in await mcp.list_tools()
    ]


def samples() -> dict[str, str]:
    rows = blob_sprite()
    pixels = [
        {"x": x, "y": y, "color": LEGEND[c]}
        for y, row in enumerate(rows)
        for x, c in enumerate(row)
        if c != "."
    ]
    return {
        "draw_pixels args (32x32)": compact({"pixels": pixels}),
        "draw_rows args (32x32)": compact({"x": 0, "y": 0, "rows": rows, "legend": LEGEND}),
    }


def main() -> None:
    tools = asyncio.run(tool_definitions())
    texts = samples()
    print(f"tool definitions: {len(tools)} tools, {len(compact(tools))} bytes")
    for name, text in texts.items():
        print(f"{name}: {len(text)} bytes")

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("\nSet ANTHROPIC_API_KEY for exact token counts.")
        return

    import anthropic

    client = anthropic.Anthropic()

    def count(content: str, with_tools: bool = False) -> int:
        kwargs = {"tools": tools} if with_tools else {}
        return client.messages.count_tokens(
            model=MODEL, messages=[{"role": "user", "content": content}], **kwargs
        ).input_tokens

    baseline = count("x")
    print(f"\nExact counts on {MODEL}:")
    print(f"tool definitions: {count('x', with_tools=True) - baseline} tokens")
    for name, text in texts.items():
        print(f"{name}: {count(text) - baseline} tokens")


if __name__ == "__main__":
    main()
