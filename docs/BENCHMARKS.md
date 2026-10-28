# Measuring token cost

Every claim that a change saves tokens should come with numbers from this page.
Progress is tracked in GitHub issue #10.

There are three levels of measurement, from cheapest to most realistic.

## 1. Size budgets (offline, in CI)

```sh
uv run pytest -s tests/test_token_budget.py
```

This guards the size of the tool list, keeps replies compact (no indentation, no
`null`, no `structuredContent` duplicate), and checks that `draw_rows` stays at
least 10× cheaper than `draw_pixels` for the same art. It prints the numbers.
Sizes are in bytes.

## 2. Exact token counts (needs an API key)

```sh
ANTHROPIC_API_KEY=... uv run --with anthropic python scripts/measure_tokens.py
```

Uses the API's free token-counting endpoint for the tool definitions and the
draw payloads. Without a key it prints byte sizes only.

## 3. A real session

Set `ASEPRITE_MCP_USAGE_LOG` in the MCP server's environment:

```sh
claude mcp add aseprite -e ASEPRITE_MCP_USAGE_LOG=/tmp/aseprite-usage.jsonl \
  -- uv run --directory /path/to/AsepriteMCP aseprite-mcp
```

Each tool call appends one line:

```json
{"t":1761650000.1,"tool":"draw_rows","argBytes":1209,"textBytes":96,"ms":38}
{"t":1761650001.4,"tool":"get_canvas_preview","argBytes":2,"textBytes":61,"images":[[256,256]],"imageTokens":88,"ms":51}
```

- `argBytes` is what the model had to write, so it tracks output tokens.
- `textBytes` and `imageTokens` are what it then had to read.
- Count the lines to get calls per asset.

Also note the session total from `/cost` in Claude Code.

## Benchmark set

Run each prompt in a fresh Claude Code session. Start each one on a blank sprite
of the given size, made with `new_sprite`. Use the same model for every run, and
record `/cost` plus the usage-log totals, before and after the change.

| # | Canvas | Prompt |
|---|---|---|
| 1 | 16×16 | "Draw a potion bottle icon: outline, glass, liquid, one highlight." |
| 2 | 32×32 | "Draw a front-facing knight character with a 4–6 colour palette." |
| 3 | 32×32 | "Turn the current sprite into a 4-frame idle bob animation, 1 px up and down, and tag it idle." |
| 4 | any | "Recolor the existing sprite's armour from blue to red across every frame." |
| 5 | any | "The arm on layer Arm in frame 3 is 1 px too long; fix only that." |

Judge the result by eye too: a cheaper run that produces worse art is not a saving.
