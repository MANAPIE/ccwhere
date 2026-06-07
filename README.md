# ccwhere

A tiny terminal monitor that shows where your Claude Code sessions are running right now.

Whether a session lives in a terminal, inside the VSCode extension's GUI chat panel, or in tmux — `ccwhere` lists all active sessions in one view. It works by reading the JSONL session files under `~/.claude/projects/` directly, so it doesn't depend on process tracking or hooks.

## Output

```
  Claude Code Sessions  ·  14:32  ·  last 24h

  PROJECT          STATUS      LAST     MODEL      MSGS   LAST_MSG
  api-server       ● active    3s ago   opus-4     142    Refactor auth middleware to verify session server-side
  web-client       ◐ recent    4m ago   sonnet-4   87     Add pagination to /api/v1/comments endpoint
  billing-service  ○ idle      3h ago   opus-4     23     Fix race condition in WebSocket reconnect logic
  shared-utils     ○ idle      18h ago  sonnet-4   8      Migrate CommonJS modules to ESM

  30x120 · Ctrl+C to quit · 5s refresh
```

## Features

- **File-based** — reads JSONL session logs from `~/.claude/projects/`, which means sessions started from the VSCode extension's GUI chat panel are picked up too.
- **Live** — refreshes every 5 seconds with double buffering, so the screen does not flicker while data is being gathered.
- **Adaptive layout** — column widths and the number of rows adjust to your terminal size; CJK display widths are taken into account when truncating.
- **Minimal dependencies** — only `jq` is required.

## Requirements

- macOS (uses BSD `stat`/`find`)
- `jq` — `brew install jq`

## Installation

```bash
git clone https://github.com/MANAPIE/ccwhere.git
cd ccwhere
chmod +x ccwhere.sh

# Option 1: run in place
./ccwhere.sh

# Option 2: install on PATH (without the .sh extension)
install -m 755 ccwhere.sh ~/bin/ccwhere
# or
sudo install -m 755 ccwhere.sh /usr/local/bin/ccwhere
```

## Usage

```bash
ccwhere
```

Press `Ctrl+C` to quit.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `CUTOFF_MIN` | `1440` | Display window in minutes (default 24 hours) |
| `ACTIVE_SEC` | `60` | Threshold for the `active` state, in seconds |
| `RECENT_SEC` | `600` | Threshold for the `recent` state, in seconds (default 10 minutes) |
| `REFRESH_SEC` | `5` | Refresh interval in seconds |
| `TAIL_LINES` | `300` | Number of trailing lines read from each session file |
| `MSG_MAX` | auto | Maximum width of the `LAST_MSG` column. `0` means auto (computed from terminal width) |
| `DEBUG` | `0` | When `1`, jq errors are written to stderr instead of being suppressed |

Examples:

```bash
# 12-hour window, recent threshold 5 minutes, refresh every 1 second
CUTOFF_MIN=720 RECENT_SEC=300 REFRESH_SEC=1 ccwhere

# Fix LAST_MSG width at 120 columns
MSG_MAX=120 ccwhere

# Debug mode
DEBUG=1 ccwhere
```

## How it works

Claude Code writes every session log to `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` regardless of where the session was started — terminal, VSCode extension, tmux, anywhere. `ccwhere` periodically scans this directory:

1. `find -mmin -$CUTOFF_MIN` selects sessions modified within the window.
2. `stat -f %m` reads each file's mtime and classifies it as `active` / `recent` / `idle`.
3. `jq` extracts the most recent model name and the last user message from each file's trailing lines.
4. `column -t` aligns the rows, and ANSI sequences add color.

The goal is intentionally narrow: not to stream the contents of each session live, but to tell you at a glance "what's running where" in a single screen.

## Known limitations

- **macOS only.** Linux users will need to swap `stat -f %m` for `stat -c %Y`. PRs welcome.
- Claude Code encodes the project path by replacing both `/` and `-` with `-`, so directory names that contain `-` cannot be perfectly recovered. `ccwhere` sidesteps this by showing only the basename.
- CJK display widths are estimated by treating any codepoint above 255 as 2 columns wide. This isn't a complete East Asian Width implementation, but it handles the common Korean / Chinese / Japanese / emoji cases well enough.

## License

MIT