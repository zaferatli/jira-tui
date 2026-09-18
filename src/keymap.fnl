;; lazygit-style keybinding list - used by the ? help screen (and README).
;; Key chords come from ~/.config/jira-tui/config.json (via config.fnl).

(local config (require :config))

(local help-entries
       [["j/k, ↑/↓" "Navigate focused panel (list or detail scroll)"]
        [:focusToggle "Toggle focus between List <-> Detail"]
        [:prevTab "Previous detail tab"]
        [:nextTab "Next detail tab"]
        [:tabOverview "Jump to Overview tab"]
        [:tabComments "Jump to Comments tab"]
        [:tabWorklog "Jump to Worklog tab"]
        [:tabHistory "Jump to History tab"]
        [:tabTransitions "Jump to Transitions tab"]
        [:comment "Add a comment (multiline: C-s submit; optional clipboard image)"]
        [:browser "Open the selected issue in the default browser"]
        [:worklog "Log work on the selected issue (time + optional multiline comment)"]
        [:assign "Assign the selected issue (empty = unassign; optional multiline comment)"]
        [:assignSelf "Assign the selected issue to yourself"]
        [:edit (.. "Edit description in " (config.editor-label)
                   " - save & close writes to Jira if changed")]
        [:hide "Hide the selected issue (unhide when in Hidden view)"]
        [:hideAll "Hide all visible issues (unhide all when in Hidden view)"]
        [:copyKey "Copy the selected issue key (e.g. PROJ-123) to clipboard"]
        [:copyDescription "Copy the selected issue description to clipboard"]
        [:removeFromList "Remove the selected issue from the list (unpins if added via o)"]
        [:attachments "Download and open attachments in the default viewer"]
        [:downloadAttachments "Download attachments only (no open) - for offline later"]
        [:links "Open a link from the issue description/comments (pick by number if several)"]
        [:cycleListView "Cycle Issues <-> custom view <-> Hidden views"]
        [:jumpHidden "Jump to Hidden view (press again to return to Issues)"]
        [:openIssue "Open issue key/URL (empty Enter = clipboard); multi-key text also works"]
        [:bulkOpen "Bulk-add all issue keys from the clipboard (copy list first — do not paste into the TUI)"]
        [:search "Full-text search on the server (title/description/comments)"]
        [:filter "Locally filter the on-screen list by key/title/status (empty=clear)"]
        [:refresh "Refresh the issue list and the selected issue"]
        [:help "Toggle this help window"]
        [:quit "Close help/prompt if open, otherwise quit"]
        [:forceQuit "Quit immediately"]])

(fn help-text []
  (var out ["{bold}jira-tui - keybindings{/bold}\n"])
  (each [_ entry (ipairs help-entries)]
    (let [keys-or-label (. entry 1)
          desc (. entry 2)
          ;; Fennel keywords are plain strings, so detect actions by looking
          ;; them up in the loaded key map rather than by type.
          label (if (. config.cfg.keys keys-or-label)
                    (config.format-keys keys-or-label)
                    keys-or-label)]
      (when (and label (not= label ""))
        (table.insert out (.. "  " label "  -  " desc)))))
  (table.concat out "\n"))

{: help-text : help-entries}
