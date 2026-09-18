# jira-tui

A [lazygit](https://github.com/jesseduffield/lazygit)-style, panel-based terminal
UI for browsing and managing Jira issues: issue list, multi-tab detail panel
(overview / comments / worklog / history / transitions), commenting, worklogs,
status transitions, assignment, description editing, and more — all from the
keyboard.

![jira-tui](https://img.shields.io/badge/terminal-blessed-blue) ![lang](https://img.shields.io/badge/lang-Fennel-8a2be2)

## Highlights

- **Keyboard-first, lazygit feel** — panel layout, single-key actions, `?` for
  an always-available help overlay.
- **Multiple list views** — `u`/`Tab` cycles assigned-to-me issues, a custom
  JQL view (default: Test/UAT), and permanently hidden issues.
- **Open any issue into the list** — `o` opens a known key (or pasted text
  with many keys) and pins them into Issues; `Shift-o` bulk-adds from the
  clipboard; `Shift-d` removes; `Shift-h` hides everything currently visible.
- **Local filter + server search** — `/` narrows the on-screen list instantly
  (no network); `s` runs full-text search across Jira.
- **nvim integration** — `e` edits the description in nvim; `:wq` saves to
  Jira automatically when changed.
- **Attachments** — download and open images/files; preload with `Shift-i`
  while on VPN, view offline later with `i`.
- **Offline cache** — when the network/VPN is down, the last successful
  responses are shown from disk; each view/search keeps its own cache.
- **Clipboard & browser** — copy the issue key (`y`) or description (`d`);
  open in the browser with `w`.

## How it works

Application logic is written in **[Fennel](https://fennel-lang.org)** (a Lisp
that compiles to Lua). It runs on **[Fengari](https://github.com/fengari-lua/fengari)**
(a Lua VM in JavaScript) with
[fengari-interop](https://github.com/fengari-lua/fengari-interop) bridging to
real Node.js APIs (`fs`, `child_process`, `fetch`, …). The terminal UI uses
[blessed](https://github.com/chjj/blessed). Because npm has no official Fennel
compiler package, the compiler itself (`vendor/fennel.lua`) is vendored;
`bin/jira-tui.js` bootstraps by reading, compiling, and running the `.fnl`
sources.

```
src/
  main.fnl     UI state, keybindings, panel/event wiring
  config.fnl   Loads ~/.config/jira-tui/config.json (keys, tabs, views)
  jira.fnl     Jira REST v2 client (search, issue, comment, worklog, transition,
               attachment download) + offline cache
  render.fnl   Pure functions: Jira JSON → (colored) panel text
  jsutil.fnl   Lua ↔ JS data conversion helpers
  format.fnl   String/date formatting helpers
  keymap.fnl   Keybinding help text (from config)
```

## Install

Requirements: Node.js; `nvim` for `e`; `open` / `pbcopy` on macOS for browser
and clipboard shortcuts.

```sh
npm install jira-tui -g
```
```sh
yarn global add jira-tui
```


### Credentials

The app looks for a `.env` in this order and uses the first it finds:

1. `.env` in the current working directory
2. `~/.config/jira-tui/.env` (recommended for a global install)
3. `.env` one/two levels above the package

See [`.env.example`](.env.example) for a ready-to-copy template:

```
JIRA_BASE_URL=https://jira.example.com
JIRA_AUTH_MODE=bearer        # "bearer" (PAT) or "basic" (user/password)
JIRA_PAT=...
JIRA_USERNAME=...
JIRA_PASSWORD=...
```

`.env` holds secrets — it is in `.gitignore`; never commit it.

## Run

```sh
jira-tui          # after global install, from any directory
```

## Keybindings

Defaults are listed below. Remap them (and detail tabs / list views) in
`~/.config/jira-tui/config.json` — see [Configuration](#configuration).
Press `?` in the app for the live list (reflects your config).

| Key | Action |
|---|---|
| `j`/`k` | Navigate the focused panel (list or detail scroll) — current detail tab is kept while moving in the list |
| `Shift-Tab` | Toggle focus List ↔ Detail |
| `[` / `]`, `←`/`→` | Previous/next detail tab |
| `1`–`5` | Jump to a detail tab |
| `c` | Add a comment (multiline: **C-s** submit; then optional clipboard image with `y`) |
| `w` | Open issue in the default browser |
| `Shift-w` | Log work (time + optional multiline comment) |
| `t` | Transitions tab — j/k to pick, Enter to apply (optional multiline comment + assignee) |
| `a` | Assign (empty = unassign; optional multiline comment) |
| `Shift-a` | Assign to yourself |
| `e` | Edit description in nvim — `:wq` saves to Jira if changed |
| `h` | Hide selected issue (unhide in Hidden view) — stored in `~/.config/jira-tui/hidden.json` |
| `Shift-h` | Hide **all** currently visible issues (unhide all when in Hidden view) |
| `y` | Copy issue key (e.g. `PROJ-123`) to clipboard |
| `d` | Copy description to clipboard |
| `Shift-d` | Remove selected issue from the list (unpins if added via `o`) |
| `i` | Open attachments — prompts for a number if there are several; works offline if pre-downloaded with `Shift-i` |
| `Shift-i` | Download attachments only (do not open) |
| `l` | Open a link from description/comments — prompts for a number if there are several |
| `u`, `Tab` | Cycle Issues ↔ custom view ↔ Hidden (see [Configuration](#configuration)) |
| `Shift-v` | Jump to Hidden (press again to return to Issues) |
| `o` | Open a known issue key **or browse URL**. Empty Enter = read clipboard. If the input (or clipboard) has many `PROJECT-N` keys, all are pinned |
| `Shift-o` | Bulk-add from clipboard (`pbpaste`) — **copy the list first, then press Shift-o** (do not paste into the terminal; multi-line paste breaks textbox input) |
| `s` | Full-text search on the server |
| `/` | Locally filter the on-screen list by key/title/status (empty clears) |
| `r` | Refresh list and selected issue |
| `?` | Toggle help |
| `q` | Close help/prompt if open; otherwise quit |
| `Ctrl-c` | Quit immediately |

Default JQL: `assignee = currentUser() ORDER BY updated DESC`.

Issues opened with `o` are OR'd into that query (`key in (...)`) so they stay
in the Issues list across refresh and restart until you remove them with
`Shift-d`.

## Configuration

Optional file: `~/.config/jira-tui/config.json`. Copy
[`config.example.json`](config.example.json) and edit what you need; omitted
fields keep the built-in defaults. Restart the app after changes.

```sh
mkdir -p ~/.config/jira-tui
cp config.example.json ~/.config/jira-tui/config.json
```

| Field | Purpose |
|---|---|
| `keys` | Remap actions to blessed key names (`"c"`, `"S-w"`, `"C-c"`, `"tab"`, …). Each value is a string or array of keys. |
| `tabs` | Detail-tab order (subset/reorder of `overview`, `comments`, `worklog`, `history`, `transitions`). Jump keys still target fixed tab ids. |
| `tabLabels` | Display labels for detail tabs. |
| `views` | List-tab labels and JQL for `mine` / `uat` (and label for `hidden`). |

Example — custom Test/UAT JQL and comment key:

```json
{
  "keys": { "comment": ["C"] },
  "views": {
    "uat": {
      "label": "QA",
      "jql": "status in (QA, Test) ORDER BY updated DESC"
    }
  }
}
```

## Offline cache

Successful search/issue/transitions responses are written under
`~/.config/jira-tui/cache/`. When Jira is unreachable at the network level
(VPN off, DNS failure, etc. — not HTTP 401/404), the app serves the last
cached data and shows `(offline - from cache)` in the status bar. Writes
(comment / worklog / transition) still need the live server. Downloaded
attachments live under `~/.config/jira-tui/attachments/`.

## Known limits

- Comment/worklog lists are limited to the first page of the issue GET
  response.
- Description is shown as Jira wiki markup (REST v2 / Data Center) with no
  rich rendering layer yet.
- Only Jira Server/Data Center REST v2 (bearer/basic auth) is supported; Jira
  Cloud (OAuth, different endpoints) is not.

## License

MIT Licence
