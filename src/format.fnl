;; JSON.stringify cannot serialize Lua tables (fengari-interop carries a Lua
;; table into JS as an opaque "function"-typed proxy; JSON.stringify skips it
;; and returns `undefined`) — so we build outgoing request bodies by hand with
;; a small JSON string encoder.

(fn escape-json [s]
  (let [s (or s "")]
    (var r s)
    (set r (r:gsub "\\" "\\\\"))
    (set r (r:gsub "\"" "\\\""))
    (set r (r:gsub "\n" "\\n"))
    (set r (r:gsub "\r" "\\r"))
    (set r (r:gsub "\t" "\\t"))
    r))

(fn json-string [s]
  (.. "\"" (escape-json s) "\""))

;; date: "2026-08-25T09:12:33.000+0300" -> "2026-08-25 09:12"
(fn short-date [iso]
  (if (not iso) ""
      (let [(y m d hh mm) (iso:match "(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)")]
        (if y (.. y "-" m "-" d " " hh ":" mm) iso))))

(fn truncate [s width]
  (let [s (or s "")]
    (if (<= (length s) width) s
        (.. (s:sub 1 (- width 1)) "…"))))

(fn pad-right [s width]
  (let [s (or s "")
        len (length s)]
    (if (>= len width) s (.. s (string.rep " " (- width len))))))

;; nvim (like most editors) appends a trailing newline when saving; so when
;; comparing/writing back against the original Jira description we ignore a
;; single trailing "\n" (we do not touch whitespace the user intentionally
;; wrote — only the one newline the editor added).
(fn rstrip-newline [s]
  (let [s (or s "")
        stripped (s:gsub "\n$" "")]
    stripped))

{: json-string : escape-json : short-date : truncate : pad-right : rstrip-newline}
