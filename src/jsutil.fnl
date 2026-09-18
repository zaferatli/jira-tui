;; When fengari-interop passes a Lua table to JS it does not make a real JS
;; Object/Array; it produces an opaque "function"-typed proxy with only methods
;; like .get/.set/.has (see fengari-interop/src/js.js wrap()). So any API that
;; does plain JS property reads such as `options.someKey` (blessed constructors,
;; fetch's `headers`/`body` reads, etc.) silently ignores such a table.
;; Fix: before handing tables to JS, convert them to real JS Object/Arrays by
;; walking with pairs/ipairs on the Lua side and building via Reflect.set /
;; Array.push by hand.

(local js (require :js))

(fn is-array? [t]
  (let [n (length t)]
    (var count 0)
    (each [_ (pairs t)] (set count (+ count 1)))
    (= count n)))

(fn to-js [v]
  (if (= (type v) "table")
      (if (is-array? v)
          (let [arr (js.new js.global.Array)]
            (each [_ item (ipairs v)] (arr:push (to-js item)))
            arr)
          (let [obj (js.new js.global.Object)]
            (each [k val (pairs v)]
              (js.global.Reflect:set obj (tostring k) (to-js val)))
            obj))
      v))

(fn js-filter [arr pred]
  "Filter a 0-based JS array (or `.length`) with a Lua predicate and return a
new JS array."
  (let [out (js.new js.global.Array)
        n (or arr.length 0)]
    (for [i 0 (- n 1)]
      (let [item (. arr i)
            matched (pred item)]
        (when matched (out:push item))))
    out))

{: to-js : is-array? : js-filter}
