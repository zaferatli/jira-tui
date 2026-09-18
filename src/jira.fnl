;; Jira Server/Data Center REST v2 client.
;; Credentials match rapor/.env (same as fetch/config.py):
;;   JIRA_BASE_URL, JIRA_AUTH_MODE (bearer|basic), JIRA_PAT, JIRA_USERNAME, JIRA_PASSWORD

(local js (require :js))
(local fmt (require :format))
(local jsu (require :jsutil))

(fn env [name]
  (let [v (. js.global.process.env name)]
    (if (= (js.typeof v) "undefined") "" v)))

;; -------------------------------------------------------------------------
;; local cache: when offline / no VPN (real network failure — not HTTP errors
;; like 401/404), read the last successful response from disk and show it.
;; Written under ~/.config/jira-tui/cache/<key>.json.

(local fs (jsrequire "fs"))
(local os-mod (jsrequire "os"))

(var last-from-cache? false)
(fn is-cached [] last-from-cache?)

(fn cache-dir []
  (.. (os-mod:homedir) "/.config/jira-tui/cache"))

(fn cache-path [cache-key]
  (.. (cache-dir) "/" cache-key ".json"))

(fn cache-write! [cache-key text]
  (when cache-key
    (pcall (fn []
             (fs:mkdirSync (cache-dir) (jsu.to-js {:recursive true}))
             (fs:writeFileSync (cache-path cache-key) text "utf8")))))

(fn cache-read [cache-key]
  (when cache-key
    (let [(ok text) (pcall (fn [] (fs:readFileSync (cache-path cache-key) "utf8")))]
      (if ok text nil))))

(fn base-url []
  (var u (env "JIRA_BASE_URL"))
  (when (u:match "/$") (set u (u:sub 1 -2)))
  u)

;; For low-level, reliable field writes onto a JS object from Lua under
;; fengari-interop, we use a real js `new Headers()` + `:set` / `:append`
;; instead of a plain table (fetch's Headers spec can misbehave when
;; enumerating a "record" via the Lua-table wrapper; `:set` is a direct method
;; call and is reliable).
(fn build-headers []
  (let [h (js.new js.global.Headers)
        mode (env "JIRA_AUTH_MODE")]
    (h:set "Accept" "application/json")
    (h:set "Content-Type" "application/json")
    (if (= mode "basic")
        (let [user (env "JIRA_USERNAME")
              pass (env "JIRA_PASSWORD")
              buf (js.global.Buffer:from (.. user ":" pass) "utf8")]
          (h:set "Authorization" (.. "Basic " (buf:toString "base64"))))
        (h:set "Authorization" (.. "Bearer " (env "JIRA_PAT"))))
    h))

;; method: "GET" | "POST" | "PUT"
;; path: "/rest/api/2/..."
;; body-str: nil or a ready JSON string
;; on-done: (fn [err result]) - result = {:status :ok :text}
;; NOTE: fengari-interop ALWAYS passes the JS `this` value as the first Lua
;; parameter to a Lua function called from JS; real call arguments start at
;; the 2nd parameter. So in all Promise callbacks below the first parameter
;; is an unused `_this`.
(fn request [method path body-str on-done]
  (let [url (.. (base-url) path)
        opts {:method method :headers (build-headers)}]
    (when body-str (tset opts :body body-str))
    (-> (js.global:fetch url (jsu.to-js opts))
        (: :then (fn [_this resp]
                    (-> (resp:text)
                        (: :then (fn [_this2 text]
                                    (on-done nil {:status resp.status
                                                  :ok resp.ok
                                                  :text text}))))))
        (: :catch (fn [_this err] (on-done (js.global:String err) nil))))))

(fn parse-json [text]
  (js.global.JSON:parse text))

;; When cache-key is given: successful GETs write the response to disk; if
;; `request` reports a real network error (DNS/connection — not HTTP status
;; codes like 401/404, those are handled separately below) and a previously
;; written response exists, return that and is-cached() becomes true.
;; ?fallback-cache-key?: second key to try when the primary has nothing (e.g.
;; this exact JQL has never succeeded online). Before "u" (Test/UAT) was added,
;; search results were always written to a single fixed "search-last" file;
;; this exists so we can still read that old file (and not lose the user's
;; existing offline cache).
(fn get [path cache-key on-done ?fallback-cache-key?]
  (request "GET" path nil
           (fn [err res]
             (if err
                 (let [cached (or (cache-read cache-key)
                                  (and ?fallback-cache-key? (cache-read ?fallback-cache-key?)))]
                   (if cached
                       (do (set last-from-cache? true) (on-done nil (parse-json cached)))
                       (do (set last-from-cache? false) (on-done err nil))))
                 (not res.ok)
                 (do (set last-from-cache? false)
                     (on-done (.. "HTTP " res.status ": " res.text) nil))
                 (do (cache-write! cache-key res.text)
                     (set last-from-cache? false)
                     (on-done nil (parse-json res.text)))))))

(fn post [path body-str on-done]
  (request "POST" path body-str
           (fn [err res]
             (if err (on-done err nil)
                 (not res.ok) (on-done (.. "HTTP " res.status ": " res.text) nil)
                 (on-done nil (if (and res.text (> (length res.text) 0))
                                  (parse-json res.text)
                                  {}))))))

(fn put [path body-str on-done]
  (request "PUT" path body-str
           (fn [err res]
             (if err (on-done err nil)
                 (not res.ok) (on-done (.. "HTTP " res.status ": " res.text) nil)
                 (on-done nil (if (and res.text (> (length res.text) 0))
                                  (parse-json res.text)
                                  {}))))))

;; Previously there was a SINGLE "search-last" cache file — whatever JQL was
;; asked, offline always showed the SAME (last successful) result; that caused
;; switching to Test/UAT with "u" to accidentally show the default view's cache
;; offline (or vice versa). Now each JQL writes to its own file, so each view
;; (Issues / Test-UAT / free-text search) gets its OWN last successful result
;; back correctly when offline.
(fn sanitize-cache-key [s]
  (let [safe (or s "")
        cleaned (safe:gsub "[^%w]" "_")
        truncated (if (> (length cleaned) 100) (cleaned:sub 1 100) cleaned)]
    (.. "search-" truncated)))

(fn search-issues [jql on-done]
  (let [q (.. "?jql=" (js.global:encodeURIComponent jql)
              "&maxResults=50"
              "&fields=" (js.global:encodeURIComponent
                          "summary,status,assignee,priority,issuetype,updated"))
        cache-key (sanitize-cache-key jql)]
    (get (.. "/rest/api/2/search" q) cache-key on-done "search-last")))

(fn get-issue [key on-done]
  (get (.. "/rest/api/2/issue/" key "?expand=changelog") (.. "issue-" key) on-done))

(fn whoami [on-done]
  (get "/rest/api/2/myself" nil on-done))

(fn add-comment [key text on-done]
  (let [body (.. "{\"body\":" (fmt.json-string text) "}")]
    (post (.. "/rest/api/2/issue/" key "/comment") body on-done)))

(fn add-worklog [key time-spent worklog-comment on-done]
  (let [body (.. "{\"timeSpent\":" (fmt.json-string time-spent)
                 ",\"comment\":" (fmt.json-string (or worklog-comment "")) "}")]
    (post (.. "/rest/api/2/issue/" key "/worklog") body on-done)))

;; On Jira Server/Data Center, assignment uses username (not Cloud's
;; accountId): PUT /issue/{key}/assignee body {"name": "username"}
;; Empty username unassigns (Jira API does this with "name": null — not "").
(fn assign-issue [key username on-done]
  (let [body (.. "{\"name\":" (if (= username "") "null" (fmt.json-string username)) "}")]
    (put (.. "/rest/api/2/issue/" key "/assignee") body on-done)))

;; Save description after editing in nvim:
;; PUT /issue/{key} body {"fields":{"description":"..."}}
(fn update-description [key description on-done]
  (let [body (.. "{\"fields\":{\"description\":" (fmt.json-string description) "}}")]
    (put (.. "/rest/api/2/issue/" key) body on-done)))

(fn get-transitions [key on-done]
  (get (.. "/rest/api/2/issue/" key "/transitions") (.. "transitions-" key) on-done))

;; When ?comment? is given (non-empty), it is sent as update.comment[].add.body
;; — matching the "add comment" field on Jira's transition screen. When
;; ?assignee? is given, assignment is done in the same request via
;; fields.assignee.name (empty = leave current assignee unchanged).
(fn do-transition [key transition-id ?comment? ?assignee? on-done]
  (let [comment-part (if (and ?comment? (not= ?comment? ""))
                          (.. ",\"update\":{\"comment\":[{\"add\":{\"body\":"
                              (fmt.json-string ?comment?) "}}]}")
                          "")
        assignee-part (if (and ?assignee? (not= ?assignee? ""))
                           (.. ",\"fields\":{\"assignee\":{\"name\":"
                               (fmt.json-string ?assignee?) "}}")
                           "")
        body (.. "{\"transition\":{\"id\":" (fmt.json-string transition-id) "}"
                  comment-part assignee-part "}")]
    (post (.. "/rest/api/2/issue/" key "/transitions") body on-done)))

;; Attachment upload: multipart/form-data, field name "file".
;; Content-Type is intentionally NOT set — fetch adds the boundary from FormData.
;; Jira Server/DC: X-Atlassian-Token: no-check is required.
(fn upload-attachment [key file-path filename on-done]
  (let [h (js.new js.global.Headers)
        mode (env "JIRA_AUTH_MODE")
        buf (fs:readFileSync file-path)
        parts (js.new js.global.Array)
        form (js.new js.global.FormData)
        url (.. (base-url) "/rest/api/2/issue/" key "/attachments")]
    (parts:push buf)
    (let [file (js.new js.global.File parts filename (jsu.to-js {:type "image/png"}))]
      (form:append "file" file))
    (h:set "Accept" "application/json")
    (h:set "X-Atlassian-Token" "no-check")
    (if (= mode "basic")
        (let [user (env "JIRA_USERNAME")
              pass (env "JIRA_PASSWORD")
              auth (js.global.Buffer:from (.. user ":" pass) "utf8")]
          (h:set "Authorization" (.. "Basic " (auth:toString "base64"))))
        (h:set "Authorization" (.. "Bearer " (env "JIRA_PAT"))))
    (-> (js.global:fetch url (jsu.to-js {:method "POST" :headers h :body form}))
        (: :then (fn [_this resp]
                    (-> (resp:text)
                        (: :then (fn [_this2 text]
                                    (if (not resp.ok)
                                        (on-done (.. "HTTP " resp.status ": " text) nil)
                                        (on-done nil (if (and text (> (length text) 0))
                                                         (parse-json text)
                                                         {}))))))))
        (: :catch (fn [_this err] (on-done (js.global:String err) nil))))))

;; Attachment content (images etc.) is binary, so we do NOT use `request`'s
;; text-reading fetch path — we take raw bytes via resp:arrayBuffer(), convert
;; to a Node Buffer, and write to disk. `url` already arrives as a FULL
;; (absolute) URL in the attachment.content field of the issue GET response;
;; no need to join with base-url.
(fn download-attachment [url dest-path on-done]
  (-> (js.global:fetch url (jsu.to-js {:method "GET" :headers (build-headers)}))
      (: :then (fn [_this resp]
                  (if (not resp.ok)
                      (on-done (.. "HTTP " resp.status) nil)
                      (-> (resp:arrayBuffer)
                          (: :then (fn [_this2 buf]
                                      (let [nodebuf (js.global.Buffer:from buf)]
                                        (fs:writeFileSync dest-path nodebuf)
                                        (on-done nil dest-path))))))))
      (: :catch (fn [_this err] (on-done (js.global:String err) nil)))))

{: whoami : search-issues : get-issue : add-comment : add-worklog
 : get-transitions : do-transition : assign-issue : base-url : is-cached
 : update-description : download-attachment : upload-attachment}
