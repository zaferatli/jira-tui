;; User config: ~/.config/jira-tui/config.json
;; Missing file / missing fields fall back to built-in defaults.

(local js (require :js))

(local default-tabs ["overview" "comments" "worklog" "history" "transitions"])

(local default-tab-labels
       {:overview "Overview"
        :comments "Comments"
        :worklog "Worklog"
        :history "History"
        :transitions "Transitions"})

(local default-keys
       {:comment ["c"]
        :browser ["w"]
        :worklog ["S-w"]
        :assign ["a"]
        :assignSelf ["S-a"]
        :edit ["e"]
        :hide ["h"]
        :hideAll ["S-h"]
        :copyKey ["y"]
        :copyDescription ["d"]
        :removeFromList ["S-d"]
        :attachments ["i"]
        :downloadAttachments ["S-i"]
        :links ["l"]
        :cycleListView ["u" "tab"]
        :jumpHidden ["S-v"]
        :openIssue ["o"]
        :bulkOpen ["S-o"]
        :search ["s"]
        :filter ["/"]
        :refresh ["r"]
        :help ["?"]
        :quit ["q"]
        :forceQuit ["C-c"]
        :focusToggle ["S-tab"]
        :prevTab ["[" "left"]
        :nextTab ["]" "right"]
        :tabOverview ["1"]
        :tabComments ["2"]
        :tabWorklog ["3"]
        :tabHistory ["4"]
        :tabTransitions ["5" "t"]})

(local default-views
       {:mine {:label "Issues"
               :jql "assignee = currentUser() ORDER BY updated DESC"}
        :uat {:label "Test/UAT"
              :jql "\"Developer\" = currentUser() AND status in (Test, UAT, \"UAT Deployment\") ORDER BY updated DESC"}
        :hidden {:label "Hidden"}})

(fn config-dir []
  (let [os-mod (jsrequire "os")]
    (.. (os-mod:homedir) "/.config/jira-tui")))

(fn config-path []
  (.. (config-dir) "/config.json"))

(fn action-name [action]
  (tostring action))

;; Convert a JSON.parse result (JS object/array/primitive) into a Lua table.
(fn js->lua [v]
  (if (or (= v nil) (= v js.null) (= (js.typeof v) "undefined"))
      nil
      (= (js.typeof v) "object")
      (if (not= (js.typeof v.length) "undefined")
          (let [out []
                n (or v.length 0)]
            (for [i 0 (- n 1)]
              (table.insert out (js->lua (. v i))))
            out)
          (let [out {}
                keys (js.global.Object:keys v)
                n (or keys.length 0)]
            (for [i 0 (- n 1)]
              (let [k (. keys i)]
                (tset out k (js->lua (. v k)))))
            out))
      v))

(fn copy-table [t]
  (if (= (type t) "table")
      (let [out {}]
        (each [k v (pairs t)]
          (tset out k (copy-table v)))
        out)
      t))

(fn is-array? [t]
  (and (= (type t) "table")
       (> (length t) 0)
       (= (. t 0) nil)))

(fn merge-maps [base override]
  "Merge two map-like tables. Array values from override replace; nested maps merge."
  (var out (copy-table base))
  (when (= (type override) "table")
    (each [k v (pairs override)]
      (if (and (= (type v) "table") (is-array? v))
          (tset out k (copy-table v))
          (and (= (type v) "table") (= (type (. out k)) "table") (not (is-array? (. out k))))
          (tset out k (merge-maps (. out k) v))
          (tset out k (copy-table v)))))
  out)

(fn normalize-key-list [v]
  (if (= (type v) "string") [v]
      (and (= (type v) "table") (is-array? v)) v
      []))

(fn normalize-keys [keys-map]
  (var out {})
  (each [k v (pairs keys-map)]
    (tset out k (normalize-key-list v)))
  out)

(fn known-tab? [id]
  (or (= id "overview") (= id "comments") (= id "worklog")
      (= id "history") (= id "transitions")))

(fn normalize-tabs [tabs]
  (if (or (not (= (type tabs) "table")) (= (length tabs) 0))
      (copy-table default-tabs)
      (do
        (var out [])
        (var seen {})
        (each [_ id (ipairs tabs)]
          (let [s (tostring id)]
            (when (and (known-tab? s) (not (. seen s)))
              (tset seen s true)
              (table.insert out s))))
        (if (= (length out) 0) (copy-table default-tabs) out))))

(fn load-raw []
  (let [fs (jsrequire "fs")
        path (config-path)
        (ok text) (pcall (fn [] (fs:readFileSync path "utf8")))]
    (if (not ok)
        nil
        (let [(pok parsed) (pcall (fn [] (js.global.JSON:parse text)))]
          (if pok (js->lua parsed) nil)))))

(fn build-config [raw]
  (let [raw (or raw {})
        keys (normalize-keys (merge-maps default-keys (or raw.keys {})))
        tabs (normalize-tabs (or raw.tabs default-tabs))
        tab-labels (merge-maps default-tab-labels (or raw.tabLabels raw.tab_labels {}))
        views (merge-maps default-views (or raw.views {}))]
    {:keys keys :tabs tabs :tab-labels tab-labels :views views}))

(local cfg (build-config (load-raw)))

(fn keys-for [action]
  (or (. cfg.keys (action-name action)) []))

(fn format-keys [action]
  "Human-readable key list for help, e.g. \"u, Tab\"."
  (let [ks (keys-for action)
        pretty (fn [k]
                 (if (= k "S-tab") "Shift-Tab"
                     (= k "S-w") "Shift-w"
                     (= k "S-a") "Shift-a"
                     (= k "S-h") "Shift-h"
                     (= k "S-d") "Shift-d"
                     (= k "S-i") "Shift-i"
                     (= k "S-o") "Shift-o"
                     (= k "S-v") "Shift-v"
                     (= k "C-c") "Ctrl-c"
                     (= k "tab") "Tab"
                     (= k "left") "←"
                     (= k "right") "→"
                     k))
        parts []]
    (each [_ k (ipairs ks)]
      (table.insert parts (pretty k)))
    (table.concat parts ", ")))

(fn view-label [view]
  (let [v (. cfg.views (action-name view))]
    (or (and v v.label) (action-name view))))

(fn view-jql [view]
  (let [v (. cfg.views (action-name view))]
    (and v v.jql)))

(fn tab-label [tab-id]
  (or (. cfg.tab-labels (action-name tab-id)) (action-name tab-id)))

{: cfg : keys-for : format-keys : view-label : view-jql : tab-label
 : config-dir : config-path : default-keys : default-tabs}
