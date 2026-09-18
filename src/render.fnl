;; Pure functions that turn Jira JSON objects (JS objects, read with `.`) into
;; plain text for blessed panels.

(local js (require :js))
(local fmt (require :format))

(fn present? [v]
  "Reject Lua nil, JS undefined AND JS null at once (js.null is not real nil;
indexing it throws a real JS TypeError)."
  (and v (not= v js.null) (not= (js.typeof v) "undefined")))

(fn field [obj path default]
  "Safely read dotted paths like obj.fields.assignee.displayName."
  (var cur obj)
  (each [_ key (ipairs path)]
    (if (present? cur) (set cur (. cur key)) (set cur nil)))
  (if (present? cur) cur default))

;; Jira's ISO 8601 dates are fixed-width, so comparing them as text gives the
;; correct chronological order. Sort a 0-based JS array by the `created` field
;; (oldest first) and return a 1-based Lua array — so comments/worklogs are
;; always shown in guaranteed date order, not whatever raw order Jira returned.
(fn sorted-by-created [items]
  (let [n (or items.length 0)]
    (var lua-arr [])
    (for [i 0 (- n 1)]
      (table.insert lua-arr (. items i)))
    (table.sort lua-arr
                (fn [a b]
                  (< (field a [:created] "") (field b [:created] ""))))
    lua-arr))

;; For history (changelog): sort DESC (newest first) so the latest date is on top.
(fn sorted-by-created-desc [items]
  (let [n (or items.length 0)]
    (var lua-arr [])
    (for [i 0 (- n 1)]
      (table.insert lua-arr (. items i)))
    (table.sort lua-arr
                (fn [a b]
                  (> (field a [:created] "") (field b [:created] ""))))
    lua-arr))

;; Pick a rough color from status/priority text (covers common Turkish/English
;; Jira workflow names); unknown values fall back to a neutral color and never
;; throw.
(fn status-color [status]
  (let [s (status:lower)]
    (if (or (s:find "done" 1 true) (s:find "kapa" 1 true) (s:find "tamam" 1 true)
            (s:find "closed" 1 true) (s:find "resolved" 1 true) (s:find "cozul" 1 true))
        "green"
        (or (s:find "progress" 1 true) (s:find "surumde" 1 true) (s:find "development" 1 true)
            (s:find "review" 1 true) (s:find "incele" 1 true))
        "yellow"
        (or (s:find "block" 1 true) (s:find "iptal" 1 true) (s:find "reject" 1 true) (s:find "red" 1 true))
        "red"
        "cyan")))

(fn priority-color [priority]
  (let [p (priority:lower)]
    (if (or (p:find "highest" 1 true) (p:find "high" 1 true) (p:find "acil" 1 true)
            (p:find "kritik" 1 true) (p:find "yuksek" 1 true))
        "red"
        (or (p:find "medium" 1 true) (p:find "orta" 1 true))
        "yellow"
        (or (p:find "low" 1 true) (p:find "dusuk" 1 true))
        "green"
        "white")))

;; blessed's tag parser treats "{" / "}" as color/style tags; in free-text
;; fields (title/comment/worklog comment) we rewrite real curly braces the user
;; typed into harmless plain parentheses so they do not break rendering.
(fn escape-tags [s]
  (let [safe (or s "")
        a (safe:gsub "{" "(")
        b (a:gsub "}" ")")]
    b))

(fn issue-line [issue]
  (let [key (field issue [:key] "?")
        status (field issue [:fields :status :name] "?")
        summary (escape-tags (field issue [:fields :summary] ""))
        scolor (status-color status)]
    (.. (fmt.pad-right key 12) " "
        "{" scolor "-fg}" (fmt.pad-right (fmt.truncate status 14) 15) "{/" scolor "-fg} "
        summary)))

(fn issue-list-lines [issues]
  (let [n (or issues.length 0)]
    (var lines [])
    (for [i 0 (- n 1)]
      (table.insert lines (issue-line (. issues i))))
    lines))

;; Turn Jira's issue attachment list into "filename (size)"-style lines; each
;; line is kept together with the attachment object itself (the `content` URL
;; is needed to download/open).
(fn attachments [issue]
  (or (field issue [:fields :attachment] nil) []))

(fn attachment-lines [issue]
  (let [atts (attachments issue)
        n (or atts.length 0)]
    (var out [])
    (for [i 0 (- n 1)]
      (let [a (. atts i)
            fname (field a [:filename] "?")]
        (table.insert out (.. "  - " fname))))
    out))

;; Pull http(s) URLs out of free text (description / comments). Handles plain
;; URLs and Jira wiki [label|url] forms; strips common trailing punctuation.
(fn extract-urls-from-text [text]
  (var out [])
  (var seen {})
  (when (and text (not= text js.null))
    (let [s (tostring text)]
      (each [raw (s:gmatch "https?://%S+")]
        (var url (raw:gsub "[%]%.,;:!%>\"']+$" ""))
        (set url (url:gsub "%)+$" ""))
        (when (and (> (length url) 7) (not (. seen url)))
          (tset seen url true)
          (table.insert out url)))))
  out)

(fn issue-links [issue]
  (var texts [])
  (table.insert texts (or (field issue [:fields :description] "") ""))
  (let [comments (field issue [:fields :comment :comments] nil)
        n (if comments (or comments.length 0) 0)]
    (for [i 0 (- n 1)]
      (table.insert texts (or (field (. comments i) [:body] "") ""))))
  (var out [])
  (var seen {})
  (each [_ t (ipairs texts)]
    (each [_ url (ipairs (extract-urls-from-text t))]
      (when (not (. seen url))
        (tset seen url true)
        (table.insert out url))))
  out)

(fn link-lines [issue]
  (var out [])
  (each [i url (ipairs (issue-links issue))]
    (table.insert out (.. "  - " url)))
  out)

(fn overview-text [issue]
  (let [key (field issue [:key] "?")
        summary (escape-tags (field issue [:fields :summary] ""))
        status (field issue [:fields :status :name] "?")
        itype (field issue [:fields :issuetype :name] "?")
        priority (field issue [:fields :priority :name] "-")
        assignee (field issue [:fields :assignee :displayName] "Unassigned")
        reporter (field issue [:fields :reporter :displayName] "-")
        updated (fmt.short-date (field issue [:fields :updated] nil))
        created (fmt.short-date (field issue [:fields :created] nil))
        description (escape-tags (field issue [:fields :description] "(no description)"))
        scolor (status-color status)
        pcolor (priority-color priority)
        att-lines (attachment-lines issue)
        lnk-lines (link-lines issue)
        att-block (if (= (length att-lines) 0)
                      ""
                      (.. "\n\n{yellow-fg}{bold}Attachments ("
                          (length att-lines)
                          ") - press i to open{/bold}{/yellow-fg}\n"
                          (table.concat att-lines "\n")))
        lnk-block (if (= (length lnk-lines) 0)
                      ""
                      (.. "\n\n{yellow-fg}{bold}Links ("
                          (length lnk-lines)
                          ") - press l to open{/bold}{/yellow-fg}\n"
                          (table.concat lnk-lines "\n")))]
    (.. "{cyan-fg}{bold}" key "{/bold}{/cyan-fg} - {bold}" summary "{/bold}\n\n"
        "{yellow-fg}Status:     {/yellow-fg}{" scolor "-fg}" status "{/" scolor "-fg}\n"
        "{yellow-fg}Type:       {/yellow-fg}" itype "\n"
        "{yellow-fg}Priority:   {/yellow-fg}{" pcolor "-fg}" priority "{/" pcolor "-fg}\n"
        "{yellow-fg}Assignee:   {/yellow-fg}{magenta-fg}" assignee "{/magenta-fg}\n"
        "{yellow-fg}Reporter:   {/yellow-fg}{magenta-fg}" reporter "{/magenta-fg}\n"
        "{yellow-fg}Created:    {/yellow-fg}{grey-fg}" created "{/grey-fg}\n"
        "{yellow-fg}Updated:    {/yellow-fg}{grey-fg}" updated "{/grey-fg}"
        att-block
        lnk-block
        "\n\n{yellow-fg}{bold}Description:{/bold}{/yellow-fg}\n" description)))

(fn comments-text [issue]
  (let [comments (field issue [:fields :comment :comments] nil)
        n (if comments (or comments.length 0) 0)]
    (if (= n 0) "(no comments)"
        (do
          (var out [])
          (each [_ c (ipairs (sorted-by-created comments))]
            (let [author (field c [:author :displayName] "?")
                  created (fmt.short-date (field c [:created] nil))
                  body (escape-tags (field c [:body] ""))]
              (table.insert out (.. "{cyan-fg}{bold}" author "{/bold}{/cyan-fg}  {grey-fg}" created "{/grey-fg}\n" body))))
          (table.concat out "\n\n" )))))

(fn worklog-text [issue]
  (let [worklogs (field issue [:fields :worklog :worklogs] nil)
        n (if worklogs (or worklogs.length 0) 0)]
    (if (= n 0) "(no worklogs)"
        (do
          (var out [])
          (for [i 0 (- n 1)]
            (let [w (. worklogs i)
                  author (field w [:author :displayName] "?")
                  spent (field w [:timeSpent] "?")
                  started (fmt.short-date (field w [:started] nil))
                  wcomment (escape-tags (field w [:comment] ""))]
              (table.insert out (.. "{cyan-fg}{bold}" author "{/bold}{/cyan-fg}  {grey-fg}" started "{/grey-fg}  {yellow-fg}(" spent "){/yellow-fg}\n" wcomment))))
          (table.concat out "\n\n")))))

(fn history-text [issue]
  (let [histories (field issue [:changelog :histories] nil)
        n (if histories (or histories.length 0) 0)]
    (if (= n 0) "(no history)"
        (do
          (var out [])
          (each [_ h (ipairs (sorted-by-created-desc histories))]
            (let [author (field h [:author :displayName] "?")
                  created (fmt.short-date (field h [:created] nil))
                  items (field h [:items] nil)
                  in (if items (or items.length 0) 0)]
              (var changes [])
              (for [j 0 (- in 1)]
                (let [it (. items j)]
                  (table.insert changes (.. "{yellow-fg}" (field it [:field] "?") "{/yellow-fg}: "
                                             "{grey-fg}" (or (field it [:fromString] "-") "-") "{/grey-fg} -> "
                                             "{green-fg}" (or (field it [:toString] "-") "-") "{/green-fg}"))))
              (table.insert out (.. "{cyan-fg}{bold}" author "{/bold}{/cyan-fg}  {grey-fg}" created "{/grey-fg}\n"
                                     (table.concat changes "\n")))))
          (table.concat out "\n\n")))))

;; Produce plain text for each row of a blessed list widget; the selection
;; highlight (high-contrast row) is handled by the widget itself — here we only
;; format "Name -> Target status".
(fn transitions-lines [transitions]
  (let [n (if transitions (or transitions.length 0) 0)]
    (var out [])
    (for [i 0 (- n 1)]
      (let [tr (. transitions i)
            name (field tr [:name] "?")
            to (field tr [:to :name] "?")]
        (table.insert out (.. name " -> " to))))
    out))

;; blessed list select event returns an index; use it to get the real id of
;; the transition at that index.
(fn transition-id-at [transitions idx]
  (field (. transitions idx) [:id] nil))

{: issue-line : issue-list-lines : overview-text : comments-text
 : worklog-text : history-text : transitions-lines : transition-id-at : field
 : attachments : issue-links}
