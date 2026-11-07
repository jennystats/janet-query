#==------------------------------------------------------------------------==#
# The fixture rows: the single source of the deterministic Chinook-shaped
# data (seed keyed; a rerun gives the same corpus). Two sinks read it:
# gen.janet writes schema.sql, and the query suite builds its backend-bound
# datasets from the same defines. No sink writes here. See README.md.
#==------------------------------------------------------------------------==#

(def seed 20261020)
(def customer-n 60)
(def per-album 12)
(def invoices-per-customer 33)

(def rng-state @{:v seed})
(defn rnd []
  (def v (mod (+ (* 1664525 (get rng-state :v)) 1013904223) 4294967296))
  (put rng-state :v v)
  v)
(defn between [lo hi] (+ lo (mod (rnd) (- (inc hi) lo))))
(defn pick [arr] (arr (mod (rnd) (length arr))))

(defn pad2 [n] (if (< n 10) (string "0" n) (string n)))

(defn ts-text
  "The timestamps stay calendar text here: the schema sink needs SQL
TIMESTAMP literals, and the suite converts through duckdb's epoch() when it
binds them. One representation, two readers."
  [y mo d h mi s]
  (string y "-" (pad2 mo) "-" (pad2 d) " " (pad2 h) ":" (pad2 mi) ":" (pad2 s)))

(def artists
  [[1 "AC/DC"] [2 "Accept"] [3 "Aerosmith"] [4 "Alanis Morissette"]
   [5 "Alice In Chains"] [6 "Antonio Carlos Jobim"] [7 "Apocalyptica"]
   [8 "Audioslave"] [9 "BackBeat"] [10 "Billy Cobham"]
   [11 "Black Label Society"] [12 "Black Sabbath"]])

(def albums
  [[1 "For Those About To Rock We Salute You" 1]
   [2 "Balls to the Wall" 2] [3 "Restless and Wild" 2]
   [4 "Let There Be Rock" 1] [5 "Big Ones" 3] [6 "Jagged Little Pill" 4]
   [7 "Facelift" 5] [8 "Warner 25 Anos" 6] [9 "Plays Metallica By Four Cellos" 7]
   [10 "Audioslave" 8] [11 "Out Of Exile" 8] [12 "BackBeat Soundtrack" 9]
   [13 "The Best Of Billy Cobham" 10] [14 "Alcohol Fueled Brewtality Live" 11]
   [15 "[1997] Black Light Syndrome" 1] [16 "Live After Death" 1]
   [17 "A Matter of Life and Death" 1] [18 "A Twist of Motown" 1]
   [19 "Acoustic" 5] [20 "Ai no Corrida" 5] [21 "Alive 2007" 9]
   [22 "Alice In Chains" 5]])

(def genre-names
  ["Rock" "Jazz" "Metal" "Alternative & Punk" "Rock And Roll" "Blues"
   "Latin" "Reggae" "Pop" "Soundtrack" "Bossa Nova" "Easy Listening"])
(def genres (seq [i :range [0 (length genre-names)]] [(inc i) (genre-names i)]))

(def mediatypes
  [[1 "MPEG audio file"] [2 "Protected AAC audio file"]
   [3 "Protected MPEG-4 video file"] [4 "Purchased AAC audio file"]
   [5 "AAC audio file"]])

(def employee-title
  [nil "Sales Manager" "Sales Support Agent" "Sales Support Agent"
   "Sales Support Agent" "IT Manager" "IT Staff" "IT Staff"])
(def employee-mgr [nil 1 2 2 2 1 6 6])
(def employee-birth [[1962 2 18] [1958 12 8] [1973 8 29] [1947 9 19]
                     [1965 3 3] [1973 7 1] [1970 5 29] [1968 1 9]])
(def employee-hire [[2002 8 14] [2002 5 1] [2002 4 1] [2003 5 3]
                    [2004 3 2] [2001 3 3] [2010 1 1] [2010 1 1]])
(def employee-last ["Adams" "Edwards" "Peacock" "Park" "Johnson" "Mitchell" "King" "Callahan"])
(def employee-first ["Andrew" "Nancy" "Jane" "Margaret" "Steve" "Michael" "Robert" "Laura"])

(def companies ["Witches Brew" "Voodoo Lounge" "Smelly Cat Inc" "In the Shadows"
                "Black Mesa" "Riot Records" "Paddy's Pub" "Stark Industries"
                "Wayne Enterprises" "Cyberdyne Systems" "Umbrella Corp" "Tyrell Corp"])
(def cities ["London" "Paris" "Berlin" "Madrid" "Rome" "Dublin" "Prague" "Oslo"
             "Lisbon" "Vienna" "Warsaw" "Athens"])
(def countries ["United Kingdom" "France" "Germany" "Spain" "Italy" "Ireland"
                "Czech Republic" "Norway" "Portugal" "Austria" "Poland" "Brazil"])
(def first-names ["Luis" "Leonie" "Francois" "Bjorn" "Eduardo" "Hugh" "Pedro"])
(def last-names ["Goncalves" "Kohler" "Tremblay" "Hansen" "Silva" "O'Reilly" "Rodrigues"])
(def support-rep [3 5 3 4 4 5 5 4 4 4 3 4 4 5 4 5 4 5 3 5 4 5 5 4 3 3 4 5 4 4])

(def employees
  (seq [i :range [0 8]]
    (def b (employee-birth i))
    (def h (employee-hire i))
    [(inc i) (employee-last i) (employee-first i) (employee-title i)
     (employee-mgr i) (ts-text (b 0) (b 1) (b 2) 0 0 0)
     (ts-text (h 0) (h 1) (h 2) 0 0 0)]))

(def customers
  (seq [i :range [0 customer-n]]
    [(inc i) (first-names (mod i (length first-names))) (last-names (mod (* 5 i) (length last-names)))
     (companies (mod i (length companies)))
     (string (inc (* 17 i)) " Main Street")
     (cities (mod (* 7 i) (length cities)))
     nil
     (countries (mod (* 11 i) (length countries)))
     (string (+ 10000 (* 233 i)))
     (string "+" (inc i) " 555 " (pad2 (mod (* 37 i) 100)))
     (string "customer" (inc i) "@example.com")
     (support-rep (mod (* 13 i) (length support-rep)))]))

(def invoices
  (seq [inv :range [0 (* customer-n invoices-per-customer)]
        :let [i inv
              year (+ 2021 (mod i 3))
              month (inc (mod (div i 7) 12))
              day (inc (mod (* 13 i) 28))
              c (between 1 400)
              cents (+ 99 (* 100 c))]]
    [(inc i)
     (inc (mod (* 7 i) customer-n))
     (ts-text year month day (mod (* 5 i) 24) (mod (* 17 i) 60) (mod (* 31 i) 60))
     (string (inc (* 17 i)) " Billing Road")
     (cities (mod (* 7 i) (length cities)))
     nil
     (countries (mod (* 11 i) (length countries)))
     (string (+ 20000 (* 311 i)))
     (string (div cents 100) "." (pad2 (mod cents 100)))]))

(def tracks
  (apply array
         (mapcat
          (fn [al]
            (def alid (al 0))
            (seq [k :range [0 per-album]
                  :let [tid (inc (+ (* (dec alid) per-album) k))
                        ms (+ 62384 (* 13711 k) (* 9773 alid))]]
              [tid (string (al 1) " " (inc k)) alid
               (inc (mod (+ k alid) 4))
               (inc (mod (+ (* 5 k) (* 3 alid)) (length genre-names)))
               (if (zero? (mod k 5)) nil (string "Composer " (inc (mod (+ k alid) 9))))
               ms
               (+ (* 1327 ms) (* 431 k) (* 1009 alid))
               (pick ["0.99" "1.99"])]))
          albums)))

(def playlists (seq [i :range [0 18]] [(inc i) (string "Playlist " (inc i))]))

(def playlist-tracks
  (apply array
         (mapcat (fn [r]
                   (seq [t :range [0 (+ 8 (* 2 r))]]
                     [(inc r) (inc (mod (+ (* 7 t) (* 29 r)) (length tracks)))]))
                 (range 18))))
