# project.janet - jpm package manifest for janet-query.
(declare-project
  :name "janet-query"
  :description "Engine-agnostic compositional query trees for Janet over duckdb and rayforce - inert trees, verified refusals, one backend per execution"
  :license "AGPL-3.0"
  :version "0.1.0"
  :dependencies ["https://github.com/jennystats/janet-duckdb"
                 "https://github.com/jennystats/janet-rayforce"])

(declare-source
  :source ["jennystats"])
