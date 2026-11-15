;; Clojure: reader macros, destructuring, metadata, syntax quote. Ünïcode ✓
(ns demo.sample
  (:require [clojure.string :as str]
            [clojure.set :refer [union]]))

(def ^:private ^{:doc "a map"} config {:name "démo" :sizes #{1 2 3} :ratio 3/4})

(defn- area
  "Area of a shape."
  [{:keys [kind radius side] :or {side 1}}]
  (case kind
    :circle (* Math/PI radius radius)
    :square (* side side)
    0))

(defmacro unless [test & body]
  `(if (not ~test) (do ~@body) nil))

(defrecord Point [x y])

(defn walk [tree]
  (lazy-seq
    (when-let [[head & tail] (seq tree)]
      (cons head (walk tail)))))

(let [p (->Point 1 2)
      f #(+ % %2)
      re #"[a-z]+\d*"
      ch \a
      v @(atom [1 2 3])]
  #_(ignored form)
  (unless false
    (println (area {:kind :circle :radius 1.5}) (f 1 2) (re-find re "abc12") ch v
             (str/upper-case (:name config)) (union #{1} #{2}) #?(:clj 1 :cljs 2))))
