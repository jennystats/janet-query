#==------------------------------------------------------------------------==#
# The fixture sink: writes schema.sql from the rows defined in tables.janet.
# Run from this directory: janet gen.janet. The rows are generated from a
# fixed seed, so a rerun is byte-identical. See README.md.
#==------------------------------------------------------------------------==#

(import ./tables :prefix "")

(def out "schema.sql")

(def timestamp-shape
  "ts-text's exact output shape (YYYY-MM-DD HH:MM:SS): a looser test (a
hyphen and a space) misreads genre names such as \"Protected MPEG-4 video
file\" as timestamps."
  (peg/compile '(* (repeat 4 :d) "-" (repeat 2 :d) "-" (repeat 2 :d) " "
                   (repeat 2 :d) ":" (repeat 2 :d) ":" (repeat 2 :d) -1)))

(defn sql-lit [v]
  (cond
    (nil? v) "NULL"
    (and (string? v) (peg/match timestamp-shape v)) (string "TIMESTAMP '" v "'")
    (string? v) (string "'" (string/replace-all "'" "''" v) "'")
    (string v)))

(def buf @[])
(defn add [& xs] (each x xs (array/push buf (if (string? x) x (string x)))))

(defn emit-per-row [table cols rows]
  (add (string "CREATE TABLE " table " ("
               (string/join (map (fn [c] (string/join c " ")) cols) ", ")
               ");\n")
       (string/join
        (map (fn [r]
               (string "INSERT INTO " table " VALUES ("
                       (string/join (map (fn [v] (string (sql-lit v))) r) ", ")
                       ");\n"))
             rows))))

(defn emit [table cols rows]
  (add (string "CREATE TABLE " table " ("
               (string/join (map (fn [c] (string/join c " ")) cols) ", ")
               ");\n")
       "INSERT INTO " table " VALUES\n"
       (string/join
         (map (fn [r]
                (string "  ("
                        (string/join (map (fn [v] (string (sql-lit v))) r) ", ") ")"))
              rows)
         ",\n")
       ";\n\n"))

(add "-- Chinook data model: schema and the generated sample dataset.\n"
     "-- Derived from the Chinook sample database (Lucas N. Goncalves, MIT\n"
     "-- licence). The CREATE TABLE statements follow the published schema;\n"
     "-- the rows are a deterministic generated sample (the recipe is\n"
     "-- test/fixtures/chinook/tables.janet, seed 20261020). Generated file,\n"
     "-- do not edit by hand.\n\n")

# per-table rows in dependency order: a forward reference inside one multi-row
# INSERT is a load-order error in duckdb, so each table is emitted once with
# its rows in key order (the self-referencing employee rows included)
(emit "artist"
      [["artistid" "INTEGER" "NOT NULL PRIMARY KEY"] ["name" "VARCHAR"]]
      artists)
(emit "album"
      [["albumid" "INTEGER" "NOT NULL PRIMARY KEY"]
       ["title" "VARCHAR" "NOT NULL"]
       ["artistid" "INTEGER" "NOT NULL REFERENCES artist (artistid)"]]
      albums)
(emit "genre"
      [["genreid" "INTEGER" "NOT NULL PRIMARY KEY"] ["name" "VARCHAR"]]
      genres)
(emit "mediatype"
      [["mediatypeid" "INTEGER" "NOT NULL PRIMARY KEY"] ["name" "VARCHAR"]]
      mediatypes)
(emit-per-row "employee"
      [["employeeid" "INTEGER" "NOT NULL PRIMARY KEY"]
       ["lastname" "VARCHAR" "NOT NULL"] ["firstname" "VARCHAR" "NOT NULL"]
       ["title" "VARCHAR"]
       ["reportsto" "INTEGER" "REFERENCES employee (employeeid)"]
       ["birthdate" "TIMESTAMP"] ["hiredate" "TIMESTAMP"]]
      employees)
(emit "customer"
      [["customerid" "INTEGER" "NOT NULL PRIMARY KEY"]
       ["firstname" "VARCHAR" "NOT NULL"] ["lastname" "VARCHAR" "NOT NULL"]
       ["company" "VARCHAR"] ["address" "VARCHAR"] ["city" "VARCHAR"]
       ["state" "VARCHAR"] ["country" "VARCHAR"] ["postalcode" "VARCHAR"]
       ["phone" "VARCHAR"] ["email" "VARCHAR" "NOT NULL"]
       ["supportrepid" "INTEGER" "NOT NULL REFERENCES employee (employeeid)"]]
      customers)
(emit "invoice"
      [["invoiceid" "INTEGER" "NOT NULL PRIMARY KEY"]
       ["customerid" "INTEGER" "NOT NULL REFERENCES customer (customerid)"]
       ["invoicedate" "TIMESTAMP" "NOT NULL"] ["billingaddress" "VARCHAR"]
       ["billingcity" "VARCHAR"] ["billingstate" "VARCHAR"]
       ["billingcountry" "VARCHAR"] ["billingpostalcode" "VARCHAR"]
       ["total" "NUMERIC(10,2)" "NOT NULL"]]
      invoices)
(emit "track"
      [["trackid" "INTEGER" "NOT NULL PRIMARY KEY"] ["name" "VARCHAR" "NOT NULL"]
       ["albumid" "INTEGER" "REFERENCES album (albumid)"]
       ["mediatypeid" "INTEGER" "NOT NULL REFERENCES mediatype (mediatypeid)"]
       ["genreid" "INTEGER" "REFERENCES genre (genreid)"] ["composer" "VARCHAR"]
       ["milliseconds" "INTEGER" "NOT NULL"] ["bytes" "INTEGER"]
       ["unitprice" "NUMERIC(10,2)" "NOT NULL"]]
      tracks)
(emit "playlist"
      [["playlistid" "INTEGER" "NOT NULL PRIMARY KEY"] ["name" "VARCHAR"]]
      playlists)
(emit "playlist_track"
      [["playlistid" "INTEGER" "NOT NULL REFERENCES playlist (playlistid)"]
       ["trackid" "INTEGER" "NOT NULL REFERENCES track (trackid)"]]
      playlist-tracks)

(spit out (string/join buf ""))
(print (string "wrote " out))
