# kmsg Usage

This guide covers installation, first-run setup, every public CLI command,
configuration, output formats, MCP operation, troubleshooting, and release
maintenance.

## Installation

### Requirements

- macOS 13 or later
- KakaoTalk for macOS
- Accessibility permission for the installed `kmsg` binary

### Homebrew

```bash
brew install channprj/tap/kmsg
```

The tap publishes `kmsg` for the latest release and retains exact-version
formulae for the ten most recent published releases.

Update an existing installation with:

```bash
kmsg update
```

`kmsg update` installs Homebrew when it is missing, installs or upgrades the
formula, and links a directly installed binary to the Homebrew-managed command.
The plain Homebrew equivalent is `brew update` followed by `brew upgrade kmsg`.

### Direct download

The release workflow publishes a universal macOS binary named
`kmsg-macos-universal`.

```bash
mkdir -p ~/.local/bin
curl -fL \
  https://github.com/channprj/kmsg/releases/latest/download/kmsg-macos-universal \
  -o ~/.local/bin/kmsg
chmod +x ~/.local/bin/kmsg
```

Ensure `~/.local/bin` is in `PATH`, then verify the binary:

```bash
kmsg --version
```

Run `kmsg update` later to move this binary onto the Homebrew-managed release.

### Build from source

Source builds require Swift 6.

```bash
git clone https://github.com/channprj/kmsg.git
cd kmsg
swift build -c release
install -m 755 .build/release/kmsg ~/.local/bin/kmsg
```

## Quick start

Run the environment check first:

```bash
kmsg status
```

macOS may open the Accessibility settings pane. Enable the binary you actually
run, then retry `kmsg status`.

List chats and read recent messages:

```bash
kmsg chats
kmsg read "Chat name" --limit 20
```

Preview a send without changing KakaoTalk:

```bash
kmsg send "Chat name" "Hello" --dry-run
```

After verifying the target and message, omit `--dry-run` to send.

## Authentication

Commands that require interactive KakaoTalk access automatically check the
login state. If saved credentials are unavailable, `kmsg` prompts in the
terminal and stores them locally.

Enter fresh credentials explicitly:

```bash
kmsg auth login
```

Reuse stored credentials when available:

```bash
kmsg auth login --auto
```

Add `--trace-ax` to print Accessibility traversal and retry diagnostics.

The password is encrypted with AES-GCM. The credential document and encryption
key are stored separately with owner-only filesystem permissions:

```text
~/.config/kmsg/credentials.json
~/.config/kmsg/credentials/primary.key
```

### Lock mode

When KakaoTalk's lock screen is showing, commands unlock it before continuing,
then carry on with the original request.

The passcode comes from what is already stored: the passcode remembered from an
earlier unlock, otherwise the account password saved by `kmsg auth login`. `kmsg`
prompts only when neither is available, and remembers whatever worked.

Only one unlock attempt is made per command, because KakaoTalk signs the account
out after repeated wrong passcodes. A saved account password the lock screen
refuses is not tried again — run `kmsg auth login` to save the current one.

Callers without a terminal — `kmsg mcp-server`, `kmsg watch`, cron jobs — cannot
prompt, so they depend on those stored credentials.

## Command reference

### Global behavior

```bash
kmsg
kmsg --help
kmsg --version
kmsg -v
```

Running `kmsg` without a subcommand runs `status`.

### `status`

```bash
kmsg status [--verbose]
```

Checks Accessibility permission, launches KakaoTalk if needed, verifies
authentication, and prints readiness information.

| Option | Description |
|---|---|
| `--verbose` | Include window titles, indexes, positions, and sizes. |

### `auth login`

```bash
kmsg auth login [--auto] [--trace-ax]
```

| Option | Description |
|---|---|
| `--auto` | Use stored credentials when available; otherwise prompt and save. |
| `--trace-ax` | Print AX traversal and retry details to `stderr`. |

Without `--auto`, the command prompts for fresh credentials and replaces the
stored values.

### `chats`

```bash
kmsg chats [options]
```

| Option | Description |
|---|---|
| `-v`, `--verbose` | Include the last visible message preview. |
| `-l N`, `--limit N` | Return at most `N` chats. Default: `20`. |
| `--trace-ax` | Print AX traversal and retry details. |
| `--json` | Return one structured JSON document. |
| `-k`, `--keep-window` | Keep a chat-list window that the command opened. |

Each result includes a local synthetic `chat_id`. The registry is refreshed by
running `kmsg chats` and stored at `~/.kmsg/chat-registry.json`.

Each result also includes the chat list's unread badge as `unread_count`
(`null` when the row shows no badge). A capped badge such as `999+` becomes
`unread_count: 999` with `unread_count_capped: true`. Text output appends the
count after the title, for example `[1] 홍길동 (3)`. The count is read from the
chat list before any chat is opened, so a later `read` does not change it.

### `read`

```bash
kmsg read <chat> [options]
kmsg read --chat-id <chat-id> [options]
```

A chat name and `--chat-id` are mutually exclusive.

| Option | Description |
|---|---|
| `--chat-id ID` | Resolve a synthetic ID produced by `kmsg chats`. |
| `-l N`, `--limit N` | Maximum messages to return. Default: `20`. With `--since`, a safety cap. Default: `2000`. |
| `--since TIME` | Return every message at or after `TIME` instead of the latest `N`. Accepts ISO 8601 (`2026-11-18T07:00:00+09:00`; local time when no offset is given) or a relative span (`90m`, `24h`, `2d`). |
| `--max-pages N` | With `--since`, load at most `N` pages (about 50 rows each) of older history. The same cap applies separately to newer pages loaded while scrolling to the newest end. Default: `40`. |
| `--timeout-sec N` | Overall time budget in seconds. With `--since`, when it runs out, the newest messages read so far are returned with `truncated: true`; default `180`. Without `--since`, when it runs out, the messages read so far are returned with `newest_reached: false`; default `6`. |
| `--debug` | Show compact raw parsing information in text output. |
| `--trace-ax` | Print AX traversal and retry details. |
| `-k`, `--keep-window` | Keep a chat window opened by the command. |
| `--background-safe` | Read only an already exposed matching window without launching, activating, logging in, searching, opening, resizing, or closing UI. |
| `--deep-recovery` | Enable deeper window recovery after the fast path fails. |
| `--layout MODE` | Use `preserve`, `left`, `right`, `split-left`, `split-right`, or `offscreen`. Default: `preserve`. |
| `--json` | Return one structured JSON document. |

The name form supports partial matching. For repeated automation, use a
`chat_id` after refreshing the registry with `kmsg chats`.

`--background-safe` is suitable for automation that must not disturb foreground
work, but it fails unless the matching chat window is already exposed.

`--layout offscreen` keeps KakaoTalk out of your way. The chat window keeps its
size but is moved past the bottom-right corner of the rightmost display as soon
as it opens, and the main window goes there too while kmsg searches for the
chat. macOS clamps the position and leaves a small corner piece visible.
KakaoTalk is not brought to the front: the search result is opened with
arrow-down and Enter posted to KakaoTalk's process only, and Enter is sent only
while the selected row matches the chat name. If another KakaoTalk window holds
the focus, the window kmsg works in is raised (after it left the displays) so
it takes the keys; that can lift it above other apps' inactive windows. Reading
does not depend on the window being visible. Every moved window is put back
where it was, also when kmsg is stopped with SIGTERM or SIGINT; a window kmsg
opened is put back just before it is closed (KakaoTalk reopens a chat where it
was last closed), and a window that was already open (or kept with
`--keep-window`) stays at its original position. A window a killed run left off
the displays returns to the main display on the next run. If KakaoTalk has no
window at all, kmsg has to bring it to the front once to get one and then hands
the front back to the app that had it. With `--background-safe` nothing is
moved.

When kmsg has to type the chat name into the main window's search field to
open a chat, it puts the field back afterwards (also on errors): it clears the
name it typed, or restores the text that was there before. If the field holds
some other text by then, kmsg leaves it alone.

KakaoTalk can keep showing that search's results after the field is emptied,
and a list left like that makes the next search for the same chat fail. kmsg
checks the list after restoring the field, and again when a query it typed
does not change the list, and closes the search with the main window's search
button so the full chat list comes back.

#### Reading the newest end

KakaoTalk opens a chat with many unread messages at the "read up to here"
marker (여기까지 읽었습니다) and loads only about 50 rows around it; newer rows
load only as the transcript is scrolled to the bottom. Before reading, kmsg
therefore sets the transcript's scroll position to the bottom (from just above
it when it is already there), waits up to 3 seconds for the row count or the
newest time label to change, and repeats until nothing changes. It also stops at
the time budget, after `--max-pages` loads, or when the scroll position cannot
be set; these newer loads are not counted in `pages_loaded`.

The JSON output reports the result as `newest_reached`:

- `true`: the last step loaded nothing, the transcript sits at the bottom, and
  the newest time-labelled row seen then is the newest time-labelled row the
  read analyzed. A transcript without a vertical scroll bar (the whole
  conversation fits) is `true` too.
- `false`: loading stopped at the time budget, `--max-pages`, or a scroll
  failure, or the newest row seen at the bottom is not among the analyzed rows.
- `null`: not checked, because of `--background-safe` or because the transcript
  table, its row count, or its scroll position could not be read.

`--since` reads always run this step first, within half of the paging share of
`--timeout-sec` (at least one full 3-second wait when the share allows it), so
paging older history keeps the rest. Reads of the latest `N` run it only when the
opened transcript is not at the bottom; otherwise they report `true` without
scrolling, or `false` when one of the analyzed rows is the read marker.

#### Reading since a time

`--since` scrolls the chat transcript to the top repeatedly so KakaoTalk loads
older messages (about 50 rows per page), until the oldest loaded message is
older than `TIME`, the conversation start is reached, `--max-pages` is hit, or
the paging share (half of `--timeout-sec`, after the newest-end step) is used. It then scrolls back to the bottom and reads
from the newest message backwards, stopping once two consecutive time-labelled
messages are older than `TIME`. Only a message's own time label (the time text
whose tooltip carries the date) decides this, so quoted or forwarded content
with older dates does not end the range. In `--since` results, each message's
`date` and `time_raw` come from its own time label or, for bubbles without one,
from the nearest newer label in the same range; messages that still resolve to
before `TIME` are dropped. Message times have minute precision, so `TIME` is compared at the start
of its minute. Combined with `--background-safe`, `--since` does not scroll and
reads only the rows already loaded in the window.

#### Reading the latest messages

Without `--since`, `kmsg read` takes the rows straight from the chat's transcript
table, newest first, and stops once `--limit` messages and the author of the oldest
one are in hand. `date` and `time_raw` follow the `--since` rule above: a message's
own time label, or the nearest newer label for a bubble without one. A message
therefore carries the same time in both reads. A window without a transcript table,
or one that yields too few messages this way, is read by searching for its rows as
before. Both paths read the rows after the newest-end step above, and the whole read
stops at `--timeout-sec` (default 6 seconds).

#### If `--background-safe` is missing

The CLI flag is available in kmsg `v1.260618.0` and later, and belongs only to
the `kmsg read` command. Check the binary that your shell actually resolves:

```bash
kmsg --version
kmsg read --help
```

If the help output does not list the flag, update the Homebrew installation and
check again:

```bash
brew update
brew upgrade kmsg
kmsg read --help
```

MCP clients use the JSON argument `background_safe: true` instead of the CLI
spelling `--background-safe`.

Messages whose author cannot be resolved are represented as `"(me)"`.

### `watch`

```bash
kmsg watch <chat> [options]
```

| Option | Description |
|---|---|
| `--poll-interval S` | Poll interval in seconds. Default: `0.2`; values are clamped to `0.2...10.0`. |
| `--trace-ax` | Print AX traversal and recovery details. |
| `-k`, `--keep-window` | Keep a chat window opened by the command. |
| `--deep-recovery` | Enable deeper recovery when fast window detection fails. |
| `--json` | Emit each event as a separate pretty-printed JSON object. |
| `--include-system` | Include system rows such as date separators. |

At startup, `watch` stabilizes a transcript baseline for up to two seconds and
does not replay the existing history. Rows that cannot be assigned a safe
timestamp may be suppressed during startup.

Stop the process with Ctrl-C or `SIGTERM`.

### `send`

```bash
kmsg send <recipient> <message> [options]
kmsg send --chat-id <chat-id> <message> [options]
```

| Option | Description |
|---|---|
| `--chat-id ID` | Resolve a synthetic ID produced by `kmsg chats`. |
| `--dry-run` | Print the target and message without accessing or changing KakaoTalk. |
| `--trace-ax` | Print AX traversal and retry details. |
| `--no-cache` | Disable AX path cache use for this invocation. |
| `--refresh-cache` | Remove relevant cached paths before sending. |
| `-k`, `--keep-window` | Keep chat and list windows opened by the command. |
| `--deep-recovery` | Enable deeper recovery after the fast path fails. |
| `--layout MODE` | Same modes as `kmsg read`. `offscreen` sends with the KakaoTalk windows off all displays and without bringing KakaoTalk to the front: the text is set in the input and the chat window's own send button is pressed, so no key is typed. It leaves the chat list window open, never falls back to blind typing, and sends nothing (`SEND_BUTTON_MISSING`) when the button is not found. The send counts as done once the input empties; if it does not (`SEND_UNCONFIRMED`), read the chat before sending again. Default: `preserve`. |

Without `--keep-window`, windows opened transiently by the command are closed
after the send attempt.

### `send-image`

```bash
kmsg send-image <recipient> <image-path> [options]
```

| Option | Description |
|---|---|
| `--trace-ax` | Print AX traversal and retry details. |
| `--no-cache` | Disable AX path cache use for this invocation. |
| `-k`, `--keep-window` | Keep chat and list windows opened by the command. |
| `--deep-recovery` | Enable deeper recovery after the fast path fails. |

The path must point to a readable image. `kmsg` loads the image into the macOS
pasteboard and completes KakaoTalk's image-send UI.

### `inspect`

```bash
kmsg inspect [options]
```

| Option | Description |
|---|---|
| `-d N`, `--depth N` | Maximum hierarchy depth. Default: `4`. |
| `-w N`, `--window N` | Inspect a window by zero-based index. |
| `--show-attributes` | Print available AX attributes. |
| `--show-path` | Print the hierarchy path. |
| `--show-frame` | Print element frames. |
| `--show-index` | Print sibling indexes. |
| `--show-flags` | Print enabled, focused, selected, and editable state. |
| `--show-actions` | Print supported AX actions. |
| `--debug-layout` | Enable path, frame, index, and state output together. |
| `--row-summary` | Print message-row parsing diagnostics. |
| `--row-range A:B` | Limit row summaries to an inclusive zero-based range. |

`--row-range` applies only with `--row-summary`.

### `cache`

```bash
kmsg cache
kmsg cache status
kmsg cache clear
kmsg cache export <output-path>
kmsg cache import <input-path>
kmsg cache warmup [options]
```

Running `kmsg cache` without a subcommand runs `cache status`.

| Subcommand | Description |
|---|---|
| `status` | Show path, schema, KakaoTalk fingerprint, entry count, and update time. |
| `clear` | Delete the local AX path cache. |
| `export PATH` | Export the current cache document as JSON. |
| `import PATH` | Import JSON after schema and KakaoTalk fingerprint validation. |
| `warmup` | Discover and store common chat-list, search, and input paths. |

`cache warmup` accepts:

| Option | Description |
|---|---|
| `--recipient NAME` | Also warm the chat-open and message-input path for a recipient. |
| `--trace-ax` | Print AX traversal and retry details. |
| `-k`, `--keep-window` | Keep a chat window opened by warmup. |

### `mcp-server`

```bash
kmsg mcp-server
```

Starts the native stdio MCP server. It accepts both `Content-Length` framing and
one JSON-RPC request per line, and responds using the request's transport style.

The server exposes:

| Tool | Purpose |
|---|---|
| `kmsg_chats` | List chats (read-only) with `title`, `chat_id`, `last_message`, `unread_count`, and `unread_count_capped`; optional `limit` (`1..200`, default `20`), `keep_window`, and `trace_ax`. |
| `kmsg_read` | Read by `chat` or `chat_id`, with limit, `since`, `timeout_sec`, layout, recovery, background-safe, window, and trace controls. |
| `kmsg_send` | Send a text message by chat name. |
| `kmsg_send_image` | Send a local image by chat name. |

`kmsg_read` limits: without `since`, `limit` is clamped to `1..100` (default
`20`) and the read process times out after 8 seconds (15 with deep recovery);
the read itself gets `--timeout-sec 6` (`13` with deep recovery) so it returns what
it read before that.
A process that runs over its time limit gets a stop signal and up to 2 seconds to
put a moved window back and close the chat window it opened, before it is killed.
With `since`, `limit` is a safety cap clamped to `1..2000` (default `2000`), and
`timeout_sec` (default `180`, range `10..600`) sets the process time limit. The
result `meta` then also carries `since`, `oldest_reached`, `truncated`,
`pages_loaded`, and `stop_reason`. In both modes `meta.newest_reached` carries the
read's `newest_reached` (`null` when it was not checked).

`kmsg_chats` runs `kmsg chats --json` with a 20 second process time limit and
returns `{ok, count, chats, meta: {latency_ms}}`. Each chat carries `title`,
`chat_id`, `last_message`, `unread_count` (`null` when there is no badge), and
`unread_count_capped`.

For send tools, `confirm=false` or an omitted `confirm` sends immediately.
`confirm=true` does not send; it returns `CONFIRMATION_REQUIRED` so a supervisor
can request approval and call again.

See [docs/openclaw.md](docs/openclaw.md) for complete integration examples.

### `update`

```bash
kmsg update
```

Moves the current installation onto the Homebrew-managed release:

1. Finds `brew` on `PATH`, at `/opt/homebrew/bin/brew`, or at
   `/usr/local/bin/brew`, and runs Homebrew's official installer when none of
   them exists.
2. Runs `brew install` or `brew upgrade` for `channprj/tap/kmsg`.
3. Verifies the resulting binary by running it with `--version`.
4. Replaces a directly installed `kmsg` with a link to the verified binary, so
   the path the shell already resolved keeps working. A build product under
   `.build` is never replaced.

Progress goes to `stderr` and the final summary to `stdout`. Homebrew or `sudo`
may ask for confirmation. The command needs no Accessibility permission and
never edits shell startup files.

## JSON output

### Chats

```bash
kmsg chats --json
```

```json
{
  "count": 1,
  "chats": [
    {
      "title": "홍길동",
      "chat_id": "chat_7f42c5e1d9ab",
      "last_message": "곧 도착해요",
      "unread_count": 3,
      "unread_count_capped": false
    }
  ]
}
```

### Read

```bash
kmsg read "홍길동" --limit 20 --json
```

```json
{
  "chat": "홍길동",
  "fetched_at": "2026-02-26T01:23:45.678Z",
  "count": 1,
  "newest_reached": true,
  "messages": [
    {
      "author": "홍길동",
      "time_raw": "00:27",
      "date": "2026-02-26",
      "body": "밤이 깊었네",
      "has_image": false,
      "image_count": 0,
      "link_count": 0,
      "has_attachment": false,
      "attachment_count": 0
    }
  ]
}
```

`date` and `time_raw` may be absent when KakaoTalk does not expose the
corresponding metadata. `newest_reached` (`true`, `false`, or `null`) tells whether
the newest messages were confirmed loaded; see "Reading the newest end".

`image_count` counts the images shown with a message's text. It is the same
wherever the transcript is scrolled, and a text message's bubble background is
not counted. A message with no text
at all, such as a photo on its own, is not listed.

With `--since`, the document adds four fields:

```bash
kmsg read --chat-id "chat_7f42c5e1d9ab" --since 2026-11-18T07:00:00+09:00 --json
```

```json
{
  "chat": "홍길동",
  "fetched_at": "2026-11-19T01:23:45.678Z",
  "count": 42,
  "messages": ["..."],
  "newest_reached": true,
  "since": "2026-11-18T07:00:00+09:00",
  "oldest_reached": false,
  "truncated": false,
  "pages_loaded": 1,
  "stop_reason": "complete"
}
```

`oldest_reached` is `true` when paging reached the start of the conversation.
`truncated` is `true` when the read stopped at `--max-pages`, `--timeout-sec`,
or `--limit` before covering `since`, or when `--background-safe` prevented
loading older history; the returned messages are then the newest part of the
range. It is also `true` whenever `newest_reached` is not `true` (`false` or
`null`), so a `--background-safe` `--since` read is always truncated. An empty
range returns `count: 0`.

`stop_reason` says why the read ended: `complete` (the range back to `since` is
covered), `page_cap` (`--max-pages`), `deadline` (`--timeout-sec`), `limit`
(`--limit` dropped older messages), `newest_unreached` (the range back to `since`
is covered but `newest_reached` is not `true`), `scroll_failed` (the transcript
could not be scrolled up), `rows_unreadable` (rows reaching back to `since` were loaded but
KakaoTalk exposed no content for them, even after one re-read; retrying usually
helps), or `paging_unavailable` (`--background-safe`, or no scrollable
transcript). When several apply, the reasons for an uncovered range (`deadline`,
`page_cap`, `scroll_failed`, `rows_unreadable`, `paging_unavailable`) come first,
then `newest_unreached`, then `limit`. It is `complete` exactly when `truncated`
is `false`.

### Watch

```bash
kmsg watch "홍길동" --json
```

```json
{
  "chat": "홍길동",
  "detected_at": "2026-03-25T10:20:30.123Z",
  "event": "message",
  "message": {
    "author": "홍길동",
    "time_raw": "10:20",
    "body": "새 메시지",
    "has_image": false,
    "image_count": 0,
    "link_count": 0,
    "has_attachment": false,
    "attachment_count": 0
  }
}
```

With `--include-system`, `event` may be `"system"`.

JSON payloads are written to `stdout`. `--trace-ax` diagnostics remain on
`stderr`.

## Configuration

### Environment variables

| Variable | Default | Behavior |
|---|---:|---|
| `KMSG_AX_TIMEOUT` | `0.25` | AX messaging timeout in seconds. Accepted range: `0.05...5.0`; invalid values fall back to the default. |
| `KMSG_DEFAULT_DEEP_RECOVERY` | `false` | Default `deep_recovery` value for MCP tools. |
| `KMSG_DEFAULT_BACKGROUND_SAFE` | `false` | Default `background_safe` value for `kmsg_read`. |
| `KMSG_TRACE_DEFAULT` | `false` | Default `trace_ax` value for MCP tools. |
| `KMSG_DEFAULT_READ_LAYOUT` | `preserve` | Default MCP read layout: `preserve`, `left`, `right`, `split-left`, `split-right`, or `offscreen`. |
| `KMSG_DEFAULT_LAYOUT` | `preserve` | Same as `KMSG_DEFAULT_READ_LAYOUT`, used when that one is unset or invalid. Invalid values are ignored. MCP `kmsg_send` takes its layout from this variable alone. |
| `KMSG_MCP_STARTUP_STATUS_CHECK` | `false` | When `true`, MCP initialization also runs `kmsg status`; otherwise it checks only the binary version. |
| `KMSG_MCP_VERSION` | build version | Overrides MCP server version metadata. |

Example:

```bash
KMSG_DEFAULT_BACKGROUND_SAFE=true \
KMSG_DEFAULT_READ_LAYOUT=split-right \
kmsg mcp-server
```

### Local state

| Path | Contents |
|---|---|
| `~/.config/kmsg/credentials.json` | Encrypted credential document. |
| `~/.config/kmsg/credentials/primary.key` | Local AES-GCM key. |
| `~/.kmsg/chat-registry.json` | Synthetic chat identities. |
| `~/.kmsg/ax-cache.json` | Self-healing AX paths. |

Do not publish these files or include their contents in issue reports.

## Examples

Read without disturbing foreground windows:

```bash
kmsg read "홍길동" --json --background-safe
```

Read by synthetic ID and arrange the window on the right:

```bash
kmsg chats --json
kmsg read --chat-id "chat_7f42c5e1d9ab" \
  --layout split-right \
  --limit 50 \
  --json
```

Watch for new messages:

```bash
kmsg watch "홍길동" --json --poll-interval 0.5
```

Preview and then send:

```bash
kmsg send "홍길동" "안녕하세요" --dry-run
kmsg send "홍길동" "안녕하세요"
```

Warm and inspect the AX cache:

```bash
kmsg cache warmup --recipient "홍길동" --trace-ax
kmsg cache status
```

Collect parsing diagnostics:

```bash
kmsg inspect --window 0 --depth 20 --debug-layout
kmsg inspect --window 0 --depth 20 --row-summary --row-range 10:30
kmsg read "홍길동" --limit 20 --trace-ax
```

## Troubleshooting

### Accessibility permission is not granted

1. Run `kmsg status`.
2. Open **System Settings → Privacy & Security → Accessibility**.
3. Add or enable the exact `kmsg` binary you run.
4. Retry `kmsg status`.

A rebuilt or moved binary may need to be added again.

### KakaoTalk cannot be launched or has no usable window

Open KakaoTalk manually, complete login if necessary, and run:

```bash
kmsg status --verbose
```

Use `--deep-recovery` only when the normal fast path cannot recover a window.

### A chat name or `chat_id` is not found

Refresh local identities:

```bash
kmsg chats --json
```

A renamed room receives a new local identity. If duplicate rooms have the same
name, prefer the `chat_id` values produced from the current chat list.

### Background-safe read fails

`--background-safe` never opens or searches for a chat. Expose the target chat
window first, or omit the flag when foreground automation is acceptable.

### Messages cannot be parsed

Collect both hierarchy and trace evidence:

```bash
kmsg inspect --window 0 --depth 20 --row-summary
kmsg read "Chat name" --trace-ax
```

Attach the relevant output to an issue after removing private message content.

### Cached paths appear stale

```bash
kmsg cache status
kmsg cache clear
```

Verify target and message parsing without touching KakaoTalk:

```bash
kmsg send "Chat name" "Test" --dry-run
```

`--dry-run` exits before KakaoTalk access. If a real test send is acceptable,
retry that send with `--no-cache` to compare the uncached UI path:

```bash
kmsg send "Chat name" "Test" --no-cache
```

### MCP initialization fails

Verify the binary directly:

```bash
kmsg --version
kmsg status
kmsg mcp-server
```

The MCP server skips the interactive status check by default. Set
`KMSG_MCP_STARTUP_STATUS_CHECK=true` only when startup should validate full
KakaoTalk readiness.

## Development and releases

Build debug and release variants:

```bash
swift build
swift build -c release
.build/debug/kmsg --version
```

Useful manual checks:

```bash
.build/debug/kmsg status --verbose
.build/debug/kmsg inspect --depth 5
.build/debug/kmsg chats --verbose --limit 20
.build/debug/kmsg send "Name" "Message" --dry-run
.build/debug/kmsg read "Chat" --limit 50
```

The root `VERSION` file is managed through Headatever-backed make targets:

```bash
make version
make release
make release-major
make release-push
```

Do not hand-edit `VERSION`. See [VERSIONING.md](VERSIONING.md) for the
`MAJOR.YYMMDD.PATCH_COUNT` rules.

Pushing a matching `v*` tag triggers the release workflow, which:

1. Builds arm64 and x86_64 release binaries.
2. combines them as `kmsg-macos-universal`;
3. verifies the embedded version against the tag;
4. creates or updates the GitHub Release; and
5. synchronizes the required Homebrew tap metadata.
