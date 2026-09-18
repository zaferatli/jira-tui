# jira-tui — agent brief

You are helping with Jira via **jira-tui**: a keyboard-first terminal UI
(lazygit-style). Prefer driving jira-tui (or reading its on-disk state) over
opening the Jira web UI unless the user asks otherwise.

Paste this file (or `@AGENTS.md`) into a chat so an AI agent can start using
jira-tui without guessing.

## Run

```sh
jira-tui
```

Needs Node.js and credentials (see below). Interactive TUI — send keys to the
terminal session; do not paste multi-line text into prompts (it breaks input).
Press `?` for live keybindings (user may have remapped keys in config).

## Local data (`~/.config/jira-tui/`)

| Path | What it is |
|------|------------|
| `.env` | Credentials (`JIRA_BASE_URL`, `JIRA_AUTH_MODE`, `JIRA_PAT` or user/password). **Secrets — never commit or print.** |
| `config.json` | Optional overrides: `editor`, `keys`, `tabs`, `views` (JQL). Restart after edits. |
| `hidden.json` | Issue keys the user **hid** with `h` / `Shift-h`. Still in Jira; only hidden from normal list views. |
| `pinned.json` | Issue keys **pinned** into the Issues list via `o` / `Shift-o` (survive refresh/restart until `Shift-d`). |
| `cache/` | Last successful search/issue/transitions JSON (offline / VPN-down fallback). |
| `attachments/<ISSUE-KEY>/` | Downloaded attachment files (images/screenshots/etc.). Prefer these paths over re-downloading when present. |

Also check cwd `.env` (jira-tui picks the first usable `.env` it finds).

## List views (cycle with `u` / `Tab`)

1. **Issues (`mine`)** — default JQL: assigned to current user (+ pinned keys).
2. **Custom (`uat`)** — configurable JQL (default: Test/UAT-style).
3. **Hidden** — only keys in `hidden.json`. `Shift-v` jumps here; `h` unhides.

Hidden ≠ deleted. `Shift-d` only removes from the local list / unpins; it does
not delete the Jira issue. If an issue “vanished”, check Hidden and `hidden.json`
before assuming it is gone from Jira.

## Useful defaults (unless remapped in config)

| Key | Action |
|-----|--------|
| `j`/`k` | Move in focused panel |
| `Shift-Tab` | Focus List ↔ Detail |
| `1`–`5` / `[` `]` | Detail tabs (overview, comments, worklog, history, transitions) |
| `o` | Open/pin issue key(s) or URL (empty Enter = clipboard) |
| `Shift-o` | Bulk-pin keys from clipboard (`pbpaste`) — copy first, then key |
| `/` | Local filter (no network) |
| `s` | Server full-text search |
| `r` | Refresh |
| `c` | Comment (`Ctrl-s` submit) |
| `e` | Edit description in external editor (`config.editor` / `$EDITOR`) |
| `t` | Transitions |
| `a` / `Shift-a` | Assign / assign to me |
| `Shift-w` | Worklog |
| `i` / `Shift-i` | Open / download-only attachments → `attachments/<KEY>/` |
| `h` / `Shift-h` | Hide one / hide all visible |
| `y` / `d` | Copy key / description |
| `w` | Open in browser |
| `q` | Dismiss help/prompt or quit |

## How to help the user

1. Launch or reuse `jira-tui` when they want interactive Jira work.
2. For context without the TUI: read `cache/`, `hidden.json`, `pinned.json`, and
   `attachments/<KEY>/` (screenshots and files already downloaded).
3. Respect hidden issues — don’t re-surface them unless asked.
4. Never expose or commit `.env` / PAT contents.
5. Jira Server/Data Center REST v2 only (not Cloud OAuth).
