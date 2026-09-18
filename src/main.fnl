(local js (require :js))
(local jsu (require :jsutil))
(local jira (require :jira))
(local render (require :render))
(local fmt (require :format))
(local config (require :config))
(local keymap (require :keymap))

(local blessed (jsrequire "blessed"))

;; ignoreLocked: normally when a textbox (ask() prompts) has focus, blessed
;; sets grabKeys=true and suppresses screen-level quit key events (they only
;; reach the focused widget as characters) — by excepting configured quit
;; keys here, our global handlers below still run while a prompt is open.
(local ignore-locked [])
(each [_ k (ipairs (config.keys-for :quit))]
  (table.insert ignore-locked k))
(each [_ k (ipairs (config.keys-for :forceQuit))]
  (table.insert ignore-locked k))

(local screen (blessed:screen (jsu.to-js {:smartCSR true :title "jira-tui"
                                           :ignoreLocked ignore-locked})))

;; Outer margin around the whole UI (not inside panels).
;; Top/left/right only — flush to the bottom edge.
(local root (blessed:box (jsu.to-js
               {:parent screen
                :top 1 :left 1 :right 1 :bottom 0})))

;; list-tab-bar: same idea as the detail panel tab-bar — shows which view the
;; Issues list is in (normal/Test-UAT) and whether hidden issues are shown, as
;; a visual "tab" strip on top (changes with u and h/Shift-v).
(local list-tab-bar (blessed:box (jsu.to-js
                      {:parent root :top 0 :left 0 :width "38%" :height 1
                       :tags true :content ""})))

(local list-box (blessed:list (jsu.to-js
                  {:parent root :top 1 :left 0 :width "38%" :height "100%-2"
                   :label " Issues " :border {:type "line"} :tags true
                   :keys true :vi true :mouse true
                   :style {:selected {:bg "blue" :fg "white"}
                           :item {:fg "white"} :border {:fg "grey"}}})))

(local tab-bar (blessed:box (jsu.to-js
                 {:parent root :top 0 :left "38%" :right 0 :height 1
                  :tags true :content ""})))

;; scrollbar: show a visible scrollbar when content (e.g. History tab) is
;; longer than the panel — :scrollable/:keys already allowed scrolling with
;; j/k, but there was no visual cue, so it felt like "can't scroll".
(local detail-box (blessed:box (jsu.to-js
                    {:parent root :top 1 :left "38%" :right 0 :height "100%-2"
                     :label " Detail " :border {:type "line"} :tags true
                     :scrollable true :alwaysScroll true
                     :scrollbar {:ch " " :track {:bg "grey"} :style {:inverse true}}
                     :keys true :vi true :mouse true :content ""})))

;; On the Transitions tab we show this instead of detail-box: blessed's list
;; widget already handles j/k/arrow navigation and Enter to select, so the
;; user does not need to type a transition id by hand.
(local transitions-list (blessed:list (jsu.to-js
                          {:parent root :top 1 :left "38%" :right 0 :height "100%-2"
                           :label " Transitions " :border {:type "line"} :tags false
                           :hidden true :keys true :vi true :mouse true
                           :style {:selected {:bg "blue" :fg "white"}
                                   :item {:fg "white"} :border {:fg "grey"}}})))

;; Single footer row: status on the left, "? help" on the right.
(local status-bar (blessed:box (jsu.to-js
                    {:parent root :top "100%-1" :left 0 :right 10
                     :tags true :content "Ready."})))

(local shortcuts-bar (blessed:box (jsu.to-js
                       {:parent root :top "100%-1" :right 0 :width 10
                        :tags true :align "right" :content " ? help "})))

(local help-box (blessed:box (jsu.to-js
                  {:parent screen :top "center" :left "center" :width "60%" :height "60%"
                   :border {:type "line"} :label " Help (press ? or esc to close) "
                   :tags true :hidden true :keys true :content (keymap.help-text)})))

;; -------------------------------------------------------------------------
;; state (tabs / views / keys from ~/.config/jira-tui/config.json)

(local tabs config.cfg.tabs)
(local default-jql (or (config.view-jql :mine)
                       "assignee = currentUser() ORDER BY updated DESC"))
(local uat-jql (or (config.view-jql :uat)
                   "\"Developer\" = currentUser() AND status in (Test, UAT, \"UAT Deployment\") ORDER BY updated DESC"))

(local state {:jql default-jql
              :issues nil
              :issues-all nil
              :current-issue nil
              :list-view :mine
              :tab (or (. tabs 1) "overview")
              :transitions nil
              :help-visible false
              :prompting false
              ;; After a prompt closes, discard key events for a short window.
              ;; Multi-line terminal paste submits the textbox on the first \n;
              ;; the remaining characters would otherwise hit global bindings
              ;; (e → nvim, q → quit, …) and tear down the TUI.
              :ignore-keys-until 0})

;; -------------------------------------------------------------------------
;; helpers

;; ask() builds and destroys a fresh textbox on every call, so the global "q"
;; shortcut (while prompting) needs to know which box to cancel — keep the
;; currently open prompt-box here.
(var active-prompt-box nil)
;; Cache whoami() result so we do not re-fetch for "assign to me".
(var my-username nil)
;; A list refresh (load-issues!/apply-filter!) could start two concurrent
;; get-issue requests for the SAME key — one from the list-box "select item"
;; event, one from our explicit load-issue! call. That let two nested/racing
;; fetch().catch() Lua callbacks re-enter fengari's (single) Lua state and
;; crash on an unrelated line with "attempt to call a string value".
;; With this table we silently skip a second request for a key already loading
;; and eliminate that race at the root.
(local loading-keys {})

;; Hidden issue keys persist in ~/.config/jira-tui/hidden.json so "stalled"
;; issues stay hidden across restarts; switch to Hidden with Shift-v and
;; unhide with "h".
(local hidden-keys {})

;; Keys opened via "o" (checkout) are pinned into the Issues list and persist
;; in ~/.config/jira-tui/pinned.json; "D" (Shift-d) removes them.
(local pinned-keys {})

(fn config-dir []
  (config.config-dir))

(fn hidden-path [] (.. (config-dir) "/hidden.json"))
(fn pinned-path [] (.. (config-dir) "/pinned.json"))

(fn load-key-set! [path into]
  (let [fs (jsrequire "fs")
        (ok text) (pcall (fn [] (fs:readFileSync path "utf8")))]
    (when ok
      (let [parsed (js.global.JSON:parse text)
            n (or parsed.length 0)]
        (for [i 0 (- n 1)]
          (tset into (. parsed i) true))))))

(fn save-key-set! [path from]
  (let [fs (jsrequire "fs")
        arr (js.new js.global.Array)]
    (each [k _ (pairs from)] (arr:push k))
    (pcall (fn []
             (fs:mkdirSync (config-dir) (jsu.to-js {:recursive true}))
             (fs:writeFileSync path (js.global.JSON:stringify arr) "utf8")))))

(fn load-hidden! [] (load-key-set! (hidden-path) hidden-keys))
(fn save-hidden! [] (save-key-set! (hidden-path) hidden-keys))
(fn load-pinned! [] (load-key-set! (pinned-path) pinned-keys))
(fn save-pinned! [] (save-key-set! (pinned-path) pinned-keys))

;; Issues view JQL: assigned to me, plus any keys opened with "o".
(fn build-mine-jql []
  (var keys [])
  (each [k _ (pairs pinned-keys)] (table.insert keys k))
  (if (= (length keys) 0)
      default-jql
      (.. "(assignee = currentUser() OR key in ("
          (table.concat keys ", ")
          ")) ORDER BY updated DESC")))

(fn set-status! [msg]
  (status-bar:setContent msg)
  (screen:render))

(fn ready-status []
  (if (jira.is-cached) "Ready. (offline - from cache)" "Ready."))

(local base-shortcuts-text " ? help ")

(fn render-shortcuts! []
  (shortcuts-bar:setContent base-shortcuts-text)
  (screen:render))

(fn current-issue-key []
  (and state.current-issue (render.field state.current-issue [:key] nil)))

(fn render-tab-bar! []
  (var parts [])
  (each [_ tab-id (ipairs tabs)]
    (let [label (config.tab-label tab-id)]
      (table.insert parts (if (= tab-id state.tab)
                               (.. "{inverse} " label " {/inverse}")
                               (.. " " label " ")))))
  (tab-bar:setContent (table.concat parts " ")))

;; state.list-view (:mine/:uat/:hidden) — exactly one of the three is active;
;; highlight the current one like a real tab bar.
(fn render-list-tab-bar! []
  (let [chip (fn [view label]
               (if (= state.list-view view)
                   (.. "{inverse} " label " {/inverse}")
                   (.. " " label " ")))]
    (list-tab-bar:setContent (.. (chip :mine (config.view-label :mine))
                                 (chip :uat (config.view-label :uat))
                                 (chip :hidden (config.view-label :hidden))))))

(fn detail-widget []
  (if (= state.tab :transitions) transitions-list detail-box))

(fn render-detail! []
  (render-tab-bar!)
  (if (= state.tab :transitions)
      (do
        (detail-box:hide)
        (transitions-list:show)
        (let [lines (render.transitions-lines state.transitions)]
          (transitions-list:setLabel (.. " Transitions (" (length lines) ") - Enter to apply "))
          (transitions-list:setItems (jsu.to-js lines))))
      (do
        (transitions-list:hide)
        (detail-box:show)
        (if (not state.current-issue)
            (detail-box:setContent "select an issue on the left...")
            (let [issue state.current-issue]
              (detail-box:setContent
               (match state.tab
                 :overview (render.overview-text issue)
                 :comments (render.comments-text issue)
                 :worklog (render.worklog-text issue)
                 :history (render.history-text issue)
                 _ ""))))
        (detail-box:setScroll 0)))
  (screen:render))

;; When ?reset-tab? is true, reset to Overview - used when opening via "o" or
;; refreshing the list. While navigating with j/k, pass false so the current
;; tab (e.g. Worklog) is kept. state.transitions is ALWAYS cleared (regardless
;; of reset-tab) and re-fetched if we are on the Transitions tab.
(fn refetch-transitions-for-current-tab! [key]
  (set-status! "Loading transitions...")
  (jira.get-transitions
   key
   (fn [terr tresult]
     (if terr
         (set-status! (.. "ERROR: " terr))
         (do
           (tset state :transitions tresult.transitions)
           (render-detail!)
           (set-status! (ready-status)))))))

(fn load-issue! [key ?reset-tab?]
  (when (and key (not (. loading-keys key)))
    (tset loading-keys key true)
    (set-status! (.. "Loading " key "..."))
    (jira.get-issue
     key
     (fn [err issue]
       (tset loading-keys key nil)
       (if err
           (set-status! (.. "ERROR: " err))
           (do
             (tset state :current-issue issue)
             (tset state :transitions nil)
             (when ?reset-tab? (tset state :tab :overview))
             (render-detail!)
             (if (= state.tab :transitions)
                 (refetch-transitions-for-current-tab! key)
                 (set-status! (ready-status)))))))))

;; Sync state.issues (what is currently shown in the list) with the list-box
;; widget; used after a fresh server search and after a local filter (/).
(fn show-issue-list! []
  (let [n (or state.issues.length 0)]
    (render-list-tab-bar!)
    (list-box:setLabel (.. " Issues (" n ") "))
    (list-box:setItems (jsu.to-js (render.issue-list-lines state.issues)))
    (screen:render)
    (if (> n 0)
        (do (list-box:select 0)
            (load-issue! (render.field (. state.issues 0) [:key] nil) true))
        (do (tset state :current-issue nil) (render-detail!)))))

(fn issue-key [issue] (render.field issue [:key] nil))

(fn issue-in-list? [arr key]
  (let [n (or (and arr arr.length) 0)]
    (var found false)
    (for [i 0 (- n 1)]
      (when (= (issue-key (. arr i)) key) (set found true)))
    found))

;; Prepend an issue into the on-screen list (and issues-all) if missing, then
;; select it. Used after opening with "o" so the issue appears in Issues.
(fn ensure-issue-in-list! [issue]
  (when issue
    (let [key (issue-key issue)]
      (when (not state.issues-all)
        (tset state :issues-all (js.new js.global.Array)))
      (when (not state.issues)
        (tset state :issues (js.new js.global.Array)))
      (when (not (issue-in-list? state.issues-all key))
        (state.issues-all:unshift issue))
      (when (not (issue-in-list? state.issues key))
        (state.issues:unshift issue))
      (let [n (or state.issues.length 0)]
        (render-list-tab-bar!)
        (list-box:setLabel (.. " Issues (" n ") "))
        (list-box:setItems (jsu.to-js (render.issue-list-lines state.issues)))
        (var idx 0)
        (for [i 0 (- n 1)]
          (when (= (issue-key (. state.issues i)) key) (set idx i)))
        (list-box:select idx)
        (screen:render)))))

(fn remove-issue-from-arrays! [key]
  (when state.issues-all
    (tset state :issues-all
          (jsu.js-filter state.issues-all (fn [i] (not= (issue-key i) key)))))
  (when state.issues
    (tset state :issues
          (jsu.js-filter state.issues (fn [i] (not= (issue-key i) key))))))

;; state.issues-all filtered by hidden/visible: normally non-hidden; in the
;; Hidden view only hidden ones. "/" filter applies on top of this.
(fn visible-base []
  (jsu.js-filter state.issues-all
                 (fn [issue]
                   (let [hidden? (. hidden-keys (issue-key issue))]
                     (if (= state.list-view :hidden) hidden? (not hidden?))))))

(fn load-issues! []
  (set-status! "Loading issues...")
  (jira.search-issues
   state.jql
   (fn [err result]
     (if err
         (set-status! (.. "ERROR: " err))
         (do
           (tset state :issues-all result.issues)
           (tset state :issues (visible-base))
           (show-issue-list!)
           (set-status! (if (jira.is-cached)
                             "Ready. (offline - from cache)"
                             "Ready.")))))))

(fn issue-matches? [issue needle-lower]
  (let [rendered (render.issue-line issue)
        line (rendered:lower)
        found (line:find needle-lower 1 true)]
    found))

(fn apply-filter! [q]
  (if (= q "")
      (do (tset state :issues (visible-base))
          (show-issue-list!)
          (set-status! "filter cleared."))
      (let [needle (q:lower)
            filtered (jsu.js-filter (visible-base)
                                    (fn [issue] (issue-matches? issue needle)))]
        (tset state :issues filtered)
        (show-issue-list!)
        (set-status! (.. "filter: \"" q "\" (" filtered.length " results)")))))

(fn toggle-hide-selected! []
  (let [idx list-box.selected
        issue (. state.issues idx)]
    (if (not issue)
        (set-status! "no issue selected")
        (let [key (issue-key issue)]
          (if (= state.list-view :hidden)
              (do (tset hidden-keys key nil)
                  (set-status! (.. key " unhidden.")))
              (do (tset hidden-keys key true)
                  (set-status! (.. key " hidden."))))
          (save-hidden!)
          (tset state :issues (visible-base))
          (show-issue-list!)))))

;; Hide (or unhide, in Hidden view) every issue currently shown in the list.
(fn hide-all-visible! []
  (let [n (or (and state.issues state.issues.length) 0)]
    (if (= n 0)
        (set-status! "no issues to hide")
        (let [unhide? (= state.list-view :hidden)]
          (for [i 0 (- n 1)]
            (let [key (issue-key (. state.issues i))]
              (when key
                (if unhide?
                    (tset hidden-keys key nil)
                    (tset hidden-keys key true)))))
          (save-hidden!)
          (tset state :issues (visible-base))
          (show-issue-list!)
          (set-status! (if unhide?
                            (.. n " issues unhidden.")
                            (.. n " issues hidden.")))))))

;; Remove the selected issue from the list. If it was pinned via "o", unpin it
;; so it stays gone on refresh (unless it still matches the assignee JQL).
(fn remove-selected-from-list! []
  (let [idx list-box.selected
        issue (. state.issues idx)]
    (if (not issue)
        (set-status! "no issue selected")
        (let [key (issue-key issue)
              was-pinned (. pinned-keys key)]
          (when was-pinned
            (tset pinned-keys key nil)
            (save-pinned!)
            (when (= state.list-view :mine)
              (tset state :jql (build-mine-jql))))
          (remove-issue-from-arrays! key)
          (tset state :issues (visible-base))
          (show-issue-list!)
          (set-status! (if was-pinned
                            (.. key " removed from list.")
                            (.. key " removed from list (will return on refresh if still assigned).")))))))

(fn goto-list-view! [view]
  (tset state :list-view view)
  (tset state :jql (if (= view :uat) uat-jql (build-mine-jql)))
  (load-issues!))

(local list-view-order [:mine :uat :hidden])

(fn cycle-list-view! [dir]
  (var idx 1)
  (each [i v (ipairs list-view-order)] (when (= v state.list-view) (set idx i)))
  (let [n (length list-view-order)
        zero-based (% (+ (- idx 1) dir n) n)]
    (goto-list-view! (. list-view-order (+ zero-based 1)))))

(fn jump-to-hidden-view! []
  (goto-list-view! (if (= state.list-view :hidden) :mine :hidden)))

(fn switch-tab! [tab-id]
  (tset state :tab tab-id)
  (if (and (= tab-id :transitions) (not state.transitions) (current-issue-key))
      (do
        (set-status! "Loading transitions...")
        (jira.get-transitions
         (current-issue-key)
         (fn [err result]
           (if err
               (set-status! (.. "ERROR: " err))
               (do (tset state :transitions result.transitions)
                   (render-detail!)
                   (when (= state.tab :transitions) (transitions-list:focus))
                   (set-status! (if (jira.is-cached)
                                     "Ready. (offline - from cache)"
                                     "Ready.")))))))
      (do (render-detail!)
          (when (= tab-id :transitions) (transitions-list:focus)))))

(fn cycle-tab! [dir]
  (var idx 1)
  (each [i t (ipairs tabs)] (when (= t state.tab) (set idx i)))
  (let [n (length tabs)
        zero-based (% (+ (- idx 1) dir n) n)]
    (switch-tab! (. tabs (+ zero-based 1)))))

;; On every `ask()` we create a textbox FROM SCRATCH and destroy it after use.
;; Reusing the same textbox instance with readInput caused DOUBLE keystrokes
;; from the second call onward under this fengari/blessed combo (blessed's own
;; internal keypress listener cleanup does not work properly with Lua-wrapped
;; callbacks); a fresh widget each time removes the problem entirely.
;; state.prompting exists so letters in typed text (e.g. w/t/r in "worklog")
;; do not also fire global shortcuts.
(fn now-ms []
  (js.global.Date:now))

(fn swallow-paste-tail! []
  ;; ~400ms covers a typical bracketed/multi-line paste burst after the
  ;; textbox already submitted on the first newline.
  (tset state :ignore-keys-until (+ (now-ms) 400)))

(fn keys-allowed? []
  (if state.prompting
      false
      (< (now-ms) (or state.ignore-keys-until 0))
      false
      true))

;; ?multiline?: use textarea for multi-line input like comments.
;; textbox submits on the first \n (a paste of "Android 568\n\niOS ..." only
;; keeps the first line); in textarea Enter=newline, C-s=submit, Esc=cancel.
(fn ask [label on-submit ?multiline?]
  (tset state :prompting true)
  (let [full-label (if ?multiline?
                        (.. label " — C-s submit, Esc cancel")
                        label)
        prompt-box (if ?multiline?
                       (blessed:textarea (jsu.to-js
                         {:parent screen :bottom 1 :left 0 :width "100%" :height 8
                          :border {:type "line"} :label (.. " " full-label " ")
                          :keys true :inputOnFocus true :style {:fg "white"}}))
                       (blessed:textbox (jsu.to-js
                         {:parent screen :bottom 1 :left 0 :width "100%" :height 3
                          :border {:type "line"} :label (.. " " full-label " ")
                          :inputOnFocus true :style {:fg "white"}})))]
    (set active-prompt-box prompt-box)
    (when ?multiline?
      ;; blessed textarea.submit() actually cancels; use C-s for _done(null, value).
      ;; fengari-interop: calling a JS function from Lua swallows the first arg
      ;; as `this` — so pass prompt-box first, then err/value.
      (prompt-box:key
       "C-s"
       (fn []
         (let [done prompt-box._done
               value (or (prompt-box:getValue) "")]
           (when (and done (not= done js.null)
                      (not= (js.typeof done) "undefined"))
             (done prompt-box js.null value))))))
    (screen:render)
    (prompt-box:readInput
     (fn [_this err value]
       ;; On success blessed sends JS `null` for err; in js.js interop that is
       ;; NOT Lua nil but a special userdata — treat both nil and js.null as
       ;; "no error".
       (tset state :prompting false)
       ;; Set BEFORE processing any further key events from the same paste.
       (swallow-paste-tail!)
       (set active-prompt-box nil)
       (prompt-box:destroy)
       (screen:render)
       ;; On Escape cancel, blessed calls callback(null, null): JS `null`
       ;; arrives as js.null, which is NOT Lua `nil` — so a bare truthy check
       ;; on `value` is NOT enough (js.null is truthy in Lua, which caused
       ;; on-submit to be CALLED on cancel with a "null" value — e.g.
       ;; comment/assign/filter — and crash with nil:gsub / nil:lower).
       ;; Explicitly reject both nil and js.null.
       (when (and (or (= err nil) (= err js.null))
                  (not= value nil) (not= value js.null))
         (on-submit value))))))

(fn bind-keys! [keys handler]
  (when (and keys (= (type keys) "table"))
    (each [_ k (ipairs keys)]
      (when (and k (not= k ""))
        (screen:key k (fn [_this] (when (keys-allowed?) (handler _this))))))))

;; -------------------------------------------------------------------------
;; event bindings

;; blessed's list widget fires "select item" while navigating with j/k/arrows
;; (on every highlight change, without waiting for Enter), and also "select"
;; on Enter/click. We bind both to the same (guarded) function so the detail
;; panel updates live while navigating; the guard prevents load-issues!'s
;; `list-box:select 0` from fetching the same issue twice via this event.
;; false: while moving in the list with j/k the tab does NOT change (e.g. if
;; you are on Worklog you stay on Worklog when moving to the next issue) —
;; load-issue! already always clears state.transitions and re-fetches if needed.
(fn load-selected-issue-at! [idx]
  (let [issue (. state.issues idx)]
    (when issue
      (let [key (render.field issue [:key] nil)]
        (when (not= key (current-issue-key))
          (load-issue! key false))))))

(list-box:on "select item" (fn [_this _item idx] (load-selected-issue-at! idx)))
(list-box:on "select" (fn [_this _item idx] (load-selected-issue-at! idx)))

;; NOTE: instead of chaining a method on `(detail-widget):focus` (direct method
;; on a function-call result), store the result in a local first — see the note
;; above issue-matches?; the same Fennel/fengari compile issue applied here.
(bind-keys! (config.keys-for :focusToggle)
            (fn [_this]
              (if (= screen.focused list-box)
                  (let [w (detail-widget)] (w:focus))
                  (list-box:focus))))

(fn apply-transition! [tid ?comment? ?assignee?]
  (set-status! "applying transition...")
  (jira.do-transition
   (current-issue-key) tid ?comment? ?assignee?
   (fn [err _res]
     (if err
         (set-status! (.. "ERROR: " err))
         (do (tset state :transitions nil)
             (load-issue! (current-issue-key))
             ;; Return focus to the issue list so j/k navigation continues
             ;; there (switch-tab! would re-focus the transitions panel).
             (list-box:focus)
             (set-status! "transition applied."))))))

(transitions-list:on
 "select"
 (fn [_this _item idx]
   (let [tid (render.transition-id-at state.transitions idx)]
     (when tid
       (ask "Comment (optional)"
            (fn [tcomment]
              (ask "Assignee username (optional, empty = keep)"
                   (fn [tassignee]
                     (apply-transition! tid tcomment tassignee))))
            true)))))

(bind-keys! (config.keys-for :prevTab) (fn [_this] (cycle-tab! -1)))
(bind-keys! (config.keys-for :nextTab) (fn [_this] (cycle-tab! 1)))
(bind-keys! (config.keys-for :tabOverview) (fn [_this] (switch-tab! "overview")))
(bind-keys! (config.keys-for :tabComments) (fn [_this] (switch-tab! "comments")))
(bind-keys! (config.keys-for :tabWorklog) (fn [_this] (switch-tab! "worklog")))
(bind-keys! (config.keys-for :tabHistory) (fn [_this] (switch-tab! "history")))
(bind-keys! (config.keys-for :tabTransitions) (fn [_this] (switch-tab! "transitions")))

;; AppleScript string literal (path quoting).
(fn applescript-string [s]
  (var r (or s ""))
  (set r (r:gsub "\\" "\\\\"))
  (set r (r:gsub "\"" "\\\""))
  (.. "\"" r "\""))

;; Save a PNG (or TIFF→PNG) from the macOS clipboard.
;; Returns: {:path :filename} or nil (no image on clipboard / error).
(fn save-clipboard-image! []
  (let [os-mod (jsrequire "os")
        fs (jsrequire "fs")
        cp (jsrequire "child_process")
        ts (tostring (js.global.Date:now))
        filename (.. "jira-tui-" ts ".png")
        dest (.. (os-mod:tmpdir) "/" filename)
        tiff-path (.. dest ".tiff")
        script (.. "set outPath to " (applescript-string dest) "\n"
                   "set tiffPath to " (applescript-string tiff-path) "\n"
                   "try\n"
                   "  set pngData to the clipboard as «class PNGf»\n"
                   "  set f to open for access (POSIX file outPath) with write permission\n"
                   "  set eof of f to 0\n"
                   "  write pngData to f\n"
                   "  close access f\n"
                   "  return \"png\"\n"
                   "on error\n"
                   "  try\n"
                   "    set tiffData to the clipboard as TIFF picture\n"
                   "    set f to open for access (POSIX file tiffPath) with write permission\n"
                   "    set eof of f to 0\n"
                   "    write tiffData to f\n"
                   "    close access f\n"
                   "    return \"tiff\"\n"
                   "  on error\n"
                   "    return \"\"\n"
                   "  end try\n"
                   "end try\n")
        (ok kind) (pcall (fn []
                           (let [raw (tostring (cp:execSync "osascript"
                                                            (jsu.to-js {:input script
                                                                        :encoding "utf8"})))]
                             (raw:gsub "%s+$" ""))))]
    (if (not ok)
        nil
        (= kind "png")
        (if (fs:existsSync dest) {:path dest :filename filename} nil)
        (= kind "tiff")
        (let [(ok2 _) (pcall (fn []
                               (cp:execFileSync "sips"
                                                (jsu.to-js ["-s" "format" "png" tiff-path
                                                            "--out" dest]))))]
          (pcall (fn [] (fs:unlinkSync tiff-path)))
          (if (and ok2 (fs:existsSync dest))
              {:path dest :filename filename}
              nil))
        nil)))

(fn yes-answer? [s]
  (let [t (: (or s "") :gsub "%s+" "")]
    (let [t (t:lower)]
      (or (= t "y") (= t "yes") (= t "e") (= t "evet")))))

;; Comment text + optional clipboard image. Empty text is only accepted when
;; an image will be attached. Jira wiki: !filename.png!
(fn post-comment! [text]
  (ask "Attach clipboard image? (y/N)"
       (fn [ans]
         (let [want-img? (yes-answer? ans)
               key (current-issue-key)]
           (if (and (= text "") (not want-img?))
               (set-status! "empty comment, cancelled")
               (not want-img?)
               (do
                 (set-status! "posting comment...")
                 (jira.add-comment
                  key text
                  (fn [err _res]
                    (if err
                        (set-status! (.. "ERROR: " err))
                        (do (switch-tab! :comments)
                            (load-issue! key)
                            (set-status! "comment added."))))))
               (do
                 (set-status! "reading clipboard image...")
                 (let [saved (save-clipboard-image!)]
                   (if (not saved)
                       (set-status! "ERROR: no image on clipboard (copy a screenshot first)")
                       (do
                         (set-status! "uploading image...")
                         (jira.upload-attachment
                          key saved.path saved.filename
                          (fn [err res]
                            (pcall (fn []
                                     (let [fs (jsrequire "fs")]
                                       (fs:unlinkSync saved.path))))
                            (if err
                                (set-status! (.. "ERROR uploading image: " err))
                                (let [fname (or (render.field (. res 0) [:filename] nil)
                                                saved.filename)
                                      body (if (= text "")
                                               (.. "!" fname "!")
                                               (.. text "\n\n!" fname "!"))]
                                  (set-status! "posting comment...")
                                  (jira.add-comment
                                   key body
                                   (fn [cerr _cres]
                                     (if cerr
                                         (set-status! (.. "image uploaded, comment ERROR: " cerr))
                                         (do (switch-tab! :comments)
                                             (load-issue! key)
                                             (set-status! "comment + image added."))))))))))))))))))

(bind-keys!
 (config.keys-for :comment)
 (fn [_this]
   (if (not (current-issue-key))
       (set-status! "select an issue first")
       (ask "Comment"
            (fn [text] (post-comment! text))
            true))))

(bind-keys!
 (config.keys-for :worklog)
 (fn [_this]
   (if (not (current-issue-key))
       (set-status! "select an issue first")
       (ask "Time spent (e.g. 1h 30m)"
            (fn [time-spent]
              (if (= time-spent "")
                  (set-status! "empty time, cancelled")
                  (ask "Worklog comment (optional)"
                       (fn [wcomment]
                         (set-status! "posting worklog...")
                         (jira.add-worklog
                          (current-issue-key) time-spent wcomment
                          (fn [err _res]
                            (if err
                                (set-status! (.. "ERROR: " err))
                                (do (switch-tab! "worklog")
                                    (load-issue! (current-issue-key))
                                    (set-status! "worklog added."))))))
                       true)))))))

(bind-keys!
 (config.keys-for :browser)
 (fn [_this]
   (if (not (current-issue-key))
       (set-status! "select an issue first")
       (let [key (current-issue-key)
             url (.. (jira.base-url) "/browse/" key)
             cp (jsrequire "child_process")]
         (cp:spawn "open" (jsu.to-js [url]))
         (set-status! (.. "opening " key " in browser..."))))))

(fn do-assign! [username ?comment?]
  (set-status! "updating assignee...")
  (jira.assign-issue
   (current-issue-key) username
   (fn [err _res]
     (if err
         (set-status! (.. "ERROR: " err))
         (if (and ?comment? (not= ?comment? ""))
             (do
               (set-status! "posting comment...")
               (jira.add-comment
                (current-issue-key) ?comment?
                (fn [cerr _cres]
                  (if cerr
                      (set-status! (.. "assignee updated, comment ERROR: " cerr))
                      (do (load-issue! (current-issue-key))
                          (set-status! "assignee updated + comment added."))))))
             (do (load-issue! (current-issue-key))
                 (set-status! "assignee updated.")))))))

(bind-keys!
 (config.keys-for :assign)
 (fn [_this]
   (if (not (current-issue-key))
       (set-status! "select an issue first")
       (ask "Assignee username (empty = unassign)"
            (fn [username]
              (ask "Comment (optional)"
                   (fn [acomment] (do-assign! username acomment))
                   true))))))

(bind-keys!
 (config.keys-for :assignSelf)
 (fn [_this]
   (if (not (current-issue-key))
       (set-status! "select an issue first")
       (if my-username
           (do-assign! my-username)
           (do
             (set-status! "fetching current user...")
             (jira.whoami
              (fn [err me]
                (if err
                    (set-status! (.. "ERROR: " err))
                    (let [username (render.field me [:name] nil)]
                      (if (not username)
                          (set-status! "ERROR: could not get username")
                          (do (set my-username username)
                              (do-assign! username))))))))))))

(bind-keys!
 (config.keys-for :filter)
 (fn [_this]
   (ask "Filter (key/title/status - empty=clear)"
        (fn [q] (apply-filter! q)))))

;; Extract all PROJECT-N style keys from free text (notes, pasted lists,
;; browse URLs). Returns unique keys in first-seen order, uppercased.
(fn extract-issue-keys [input]
  (var out [])
  (var seen {})
  (when (and input (not= input js.null) (not= (js.typeof input) "undefined"))
    (let [s (tostring input)]
      (each [k (s:gmatch "([A-Za-z][A-Za-z0-9_]+%-%d+)")]
        (let [up (k:upper)]
          (when (not (. seen up))
            (tset seen up true)
            (table.insert out up))))))
  out)

;; Accept a bare key (PROJ-123), optional trailing/leading whitespace, or a
;; browse URL (https://jira.example.com/browse/PROJ-123). Uses the last
;; PROJECT-N match in the string (single-key "o" behaviour).
(fn parse-issue-key [input]
  (let [keys (extract-issue-keys input)]
    (and (> (length keys) 0) (. keys (length keys)))))

(fn read-clipboard []
  (let [(ok result) (pcall (fn []
                             (let [cp (jsrequire "child_process")]
                               (tostring (cp:execSync "pbpaste"
                                                      (jsu.to-js {:encoding "utf8"}))))))]
    (if ok result nil)))

;; "o": open a known issue key (or browse URL) and pin it into the Issues list
;; (persisted so it survives refresh / restart).
(fn pin-and-open! [key]
  (tset pinned-keys key true)
  (save-pinned!)
  (when (= state.list-view :mine)
    (tset state :jql (build-mine-jql)))
  (when (and key (not (. loading-keys key)))
    (tset loading-keys key true)
    (set-status! (.. "Loading " key "..."))
    (jira.get-issue
     key
     (fn [err issue]
       (tset loading-keys key nil)
       (if err
           (do
             (tset pinned-keys key nil)
             (save-pinned!)
             (when (= state.list-view :mine)
               (tset state :jql (build-mine-jql)))
             (set-status! (.. "ERROR: " err)))
           (do
             (tset state :current-issue issue)
             (tset state :transitions nil)
             (tset state :tab :overview)
             (ensure-issue-in-list! issue)
             (render-detail!)
             (set-status! (.. key " opened and added to Issues."))))))))

;; Pin many keys at once (from a pasted list / clipboard), then refresh Issues
;; so JQL `key in (...)` picks them all up.
(fn pin-many! [keys]
  (var fresh 0)
  (each [_ key (ipairs keys)]
    (when (not (. pinned-keys key))
      (tset pinned-keys key true)
      (set fresh (+ fresh 1))))
  (save-pinned!)
  (tset state :jql (build-mine-jql))
  (tset state :list-view :mine)
  (load-issues!)
  (set-status! (.. "added " (length keys) " issue(s) (" fresh " new) to Issues.")))

(fn open-from-text! [raw]
  ;; Textbox submits on the first newline of a multi-line paste, so `raw` may
  ;; only be "Bug" / the first line. The full list is still on the clipboard —
  ;; fall back to pbpaste when the typed/pasted fragment has no keys.
  (var keys (extract-issue-keys raw))
  (when (= (length keys) 0)
    (set keys (extract-issue-keys (or (read-clipboard) ""))))
  (if (= (length keys) 0)
      (when (and raw (not= raw "") (not= raw js.null))
        (set-status! "no issue keys found (copy a list, then Shift-o — or type PROJ-123)"))
      (= (length keys) 1)
      (pin-and-open! (. keys 1))
      (pin-many! keys)))

(bind-keys!
 (config.keys-for :openIssue)
 (fn [_this]
   (ask "Open key/URL (empty Enter = clipboard)"
        (fn [raw]
          (if (or (= raw "") (= raw js.null))
              (let [keys (extract-issue-keys (or (read-clipboard) ""))]
                (if (= (length keys) 0)
                    (set-status! "clipboard has no issue keys — copy a list first")
                    (= (length keys) 1)
                    (pin-and-open! (. keys 1))
                    (pin-many! keys)))
              (open-from-text! raw))))))

;; Bulk-add from clipboard only (never paste into the TUI — multi-line
;; paste into a textbox submits on first \n and the rest hits keybindings).
(bind-keys!
 (config.keys-for :bulkOpen)
 (fn [_this]
   (let [keys (extract-issue-keys (or (read-clipboard) ""))]
     (if (= (length keys) 0)
         (set-status! "clipboard empty — copy the list, then press Shift-o")
         (= (length keys) 1)
         (pin-and-open! (. keys 1))
         (pin-many! keys)))))

(bind-keys!
 (config.keys-for :search)
 (fn [_this]
   (ask "Search (text in title/description/comments)"
        (fn [q]
          (when (not= q "")
            (let [escaped (q:gsub "\"" "\\\"")]
              (tset state :jql (.. "text ~ \"" escaped "\" ORDER BY updated DESC"))
              (load-issues!)))))))

(bind-keys!
 (config.keys-for :refresh)
 (fn [_this]
   (when (= state.list-view :mine) (tset state :jql (build-mine-jql)))
   (load-issues!)
   (when (current-issue-key) (load-issue! (current-issue-key)))))

(bind-keys! (config.keys-for :hide) (fn [_this] (toggle-hide-selected!)))
(bind-keys! (config.keys-for :hideAll) (fn [_this] (hide-all-visible!)))
(bind-keys! (config.keys-for :jumpHidden) (fn [_this] (jump-to-hidden-view!)))
(bind-keys! (config.keys-for :cycleListView) (fn [_this] (cycle-list-view! 1)))

(bind-keys!
 (config.keys-for :copyKey)
 (fn [_this]
   (if (not (current-issue-key))
       (set-status! "select an issue first")
       (let [key (current-issue-key)
             cp (jsrequire "child_process")
             proc (cp:spawn "pbcopy" (jsu.to-js []))]
         (proc.stdin:write key)
         (proc.stdin:end)
         (set-status! (.. key " copied to clipboard."))))))

;; copyDescription vs removeFromList (defaults: d / Shift-d).
(bind-keys!
 (config.keys-for :copyDescription)
 (fn [_this]
   (if (not state.current-issue)
       (set-status! "select an issue first")
       (let [description (render.field state.current-issue [:fields :description] "")
             cp (jsrequire "child_process")
             proc (cp:spawn "pbcopy" (jsu.to-js []))]
         (proc.stdin:write description)
         (proc.stdin:end)
         (set-status! "description copied to clipboard.")))))

(bind-keys! (config.keys-for :removeFromList) (fn [_this] (remove-selected-from-list!)))

;; Attachments are downloaded PERMANENTLY under
;; ~/.config/jira-tui/attachments/<ISSUE-KEY>/<filename> (not temporary) — so
;; an image downloaded once (while on VPN) can later be opened with "i"
;; without internet/VPN.
(fn attachment-local-path [key fname]
  (let [os-mod (jsrequire "os")]
    (.. (os-mod:homedir) "/.config/jira-tui/attachments/" key "/" fname)))

(fn ensure-attachment-dir! [key]
  (let [fs (jsrequire "fs")
        os-mod (jsrequire "os")]
    (pcall (fn []
             (fs:mkdirSync (.. (os-mod:homedir) "/.config/jira-tui/attachments/" key)
                           (jsu.to-js {:recursive true}))))))

(fn file-exists? [path]
  (let [fs (jsrequire "fs")]
    (fs:existsSync path)))

(fn open-local-file! [path]
  (let [cp (jsrequire "child_process")]
    (cp:spawn "open" (jsu.to-js [path]))))

;; ?open?: if true, open the downloaded (or already local) file immediately
;; ("i"); if false, download only, do not open ("Shift-I" — preload on VPN
;; for offline later).
;; Downloads a single attachment (att) — skips re-download if already local —
;; and if ?open? is true, opens it after download/find.
(fn handle-one-attachment! [key att ?open?]
  (let [fname (render.field att [:filename] "file")
        url (render.field att [:content] nil)
        local-path (attachment-local-path key fname)]
    (if (file-exists? local-path)
        (do
          (when ?open? (open-local-file! local-path))
          (set-status! (.. fname " already local" (if ?open? " - opening." "."))))
        (when url
          (jira.download-attachment
           url local-path
           (fn [err path]
             (if err
                 (set-status! (.. "ERROR (could not download attachment, maybe offline): " err))
                 (do
                   (when ?open? (open-local-file! path))
                   (set-status! (.. fname " downloaded" (if ?open? " - opening." ".")))))))))))

(fn handle-attachments! [?open?]
  (if (not state.current-issue)
      (set-status! "select an issue first")
      (let [key (current-issue-key)
            atts (render.attachments state.current-issue)
            n (or atts.length 0)]
        (if (= n 0)
            (set-status! "no attachments on this issue.")
            (do
              (ensure-attachment-dir! key)
              (set-status! (.. n " attachment(s) " (if ?open? "opening..." "downloading...")))
              (for [idx 0 (- n 1)]
                (handle-one-attachment! key (. atts idx) ?open?)))))))

(bind-keys!
 (config.keys-for :attachments)
 (fn [_this]
   (if (not state.current-issue)
       (set-status! "select an issue first")
       (let [key (current-issue-key)
             atts (render.attachments state.current-issue)
             n (or atts.length 0)]
         (if (= n 0)
             (set-status! "no attachments on this issue.")
             (if (= n 1)
                 (do (ensure-attachment-dir! key)
                     (handle-one-attachment! key (. atts 0) true))
                 (let [names []]
                   (for [idx 0 (- n 1)]
                     (table.insert names
                                    (.. (+ idx 1) ") " (render.field (. atts idx) [:filename] "file"))))
                   (ensure-attachment-dir! key)
                   (set-status! (.. n " attachments: " (table.concat names "  ")))
                   (ask (.. n " attachments - number (empty=all)")
                        (fn [answer]
                          (let [picked (tonumber answer)]
                            (if (and picked (>= picked 1) (<= picked n))
                                (handle-one-attachment! key (. atts (- picked 1)) true)
                                (for [idx 0 (- n 1)]
                                  (handle-one-attachment! key (. atts idx) true)))))))))))))

(bind-keys! (config.keys-for :downloadAttachments) (fn [_this] (handle-attachments! false)))

(fn open-url! [url]
  (let [cp (jsrequire "child_process")]
    (cp:spawn "open" (jsu.to-js [url]))))

;; Open http(s) links found in the issue description/comments (same
;; pick-by-number UX as attachments).
(bind-keys!
 (config.keys-for :links)
 (fn [_this]
   (if (not state.current-issue)
       (set-status! "select an issue first")
       (let [links (render.issue-links state.current-issue)
             n (length links)]
         (if (= n 0)
             (set-status! "no links found in description/comments.")
             (if (= n 1)
                 (do (open-url! (. links 1))
                     (set-status! (.. "opening " (. links 1) "...")))
                 (let [names []]
                   (for [i 1 n]
                     (table.insert names
                                    (.. i ") " (fmt.truncate (. links i) 56))))
                   (set-status! (.. n " links: " (table.concat names "  ")))
                   (ask (.. n " links - number")
                        (fn [answer]
                          (let [picked (tonumber answer)]
                            (if (and picked (>= picked 1) (<= picked n))
                                (do (open-url! (. links picked))
                                    (set-status! (.. "opening " (. links picked) "...")))
                                (set-status! "cancelled."))))))))))))

(bind-keys!
 (config.keys-for :edit)
 (fn [_this]
   (if (not (current-issue-key))
       (set-status! "select an issue first")
       (let [key (current-issue-key)
             original (render.field state.current-issue [:fields :description] "")]
         (set-status! "opening nvim...")
         (screen:readEditor
          (jsu.to-js {:editor "nvim" :name (.. "jira-" key ".md") :value original})
          (fn [_this err data]
            (if (and (not= err nil) (not= err js.null))
                (set-status! (.. "ERROR: " (js.global:String err)))
                (let [changed (fmt.rstrip-newline data)]
                  (if (= changed original)
                      (set-status! "no changes.")
                      (do
                        (set-status! (.. "saving description for " key "..."))
                        (jira.update-description
                         key changed
                         (fn [uerr _res]
                           (if uerr
                               (set-status! (.. "ERROR: " uerr))
                               (do
                                 (when (= key (current-issue-key)) (load-issue! key))
                                 (set-status! "description updated.")))))))))))))))

(bind-keys!
 (config.keys-for :help)
 (fn [_this]
   (if state.help-visible
       (do (help-box:hide) (tset state :help-visible false))
       (do (help-box:show) (help-box:setFront) (tset state :help-visible true)))
   (screen:render)))

(bind-keys!
 ["escape"]
 (fn [_this]
   (when state.help-visible
     (help-box:hide)
     (tset state :help-visible false)
     (screen:render))))

(fn quit-or-dismiss! []
  (if state.help-visible
      (do (help-box:hide) (tset state :help-visible false) (screen:render))
      state.prompting
      (when active-prompt-box (active-prompt-box:cancel))
      ;; Swallow leftover paste characters so a stray quit key does not exit.
      (< (now-ms) (or state.ignore-keys-until 0))
      nil
      (do (screen:destroy) (js.global.process:exit 0))))

(each [_ k (ipairs (config.keys-for :quit))]
  (screen:key k (fn [_this] (quit-or-dismiss!))))

(each [_ k (ipairs (config.keys-for :forceQuit))]
  (screen:key k (fn [_this] (screen:destroy) (js.global.process:exit 0))))

;; -------------------------------------------------------------------------
;; startup

(load-hidden!)
(load-pinned!)
(tset state :jql (build-mine-jql))
(render-detail!)
(render-list-tab-bar!)
(render-shortcuts!)
(list-box:focus)
(screen:render)
(load-issues!)
