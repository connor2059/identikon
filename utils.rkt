#lang racket

(require 2htdp/image
         openssl/sha1
         css-tools/colors
         sugar)

; A grab-bag of helper futions for identikon
(provide (all-defined-out))

; Default Constants
(define DEFAULT-MAX-USER-LENGTH 18)
(define DEFAULT-SATURATION "60%")
(define DEFAULT-LIGHTNESS "50%")
(define DEFAULT-BORDER-MAX 10)

; Data structs
(struct point (x y) #:transparent)
(struct dim (w h) #:transparent)
(struct canvas (outside inside border) #:transparent)

; Use the first and last numbers in user to generate a 6x6 grid of color values
; from min to max in 36 steps
(define (build-color-range user)
  (define s (remove-duplicates user))
  (define color-a (min (first s) (last s)))
  (define color-b (max (first s) (last s)))
  (slice-at (range color-a color-b
                   (/ (- color-b color-a) 36))
            6))

; Turn a hue into an RGB color object
(define (make-rgb hue [sat DEFAULT-SATURATION] [lig DEFAULT-LIGHTNESS])
  (define rgb (map (λ (x) (->int (* 255 x)))
                   (hsl->rgb (list (number->string (* 1.411 hue)) sat lig))))
  (make-color (first rgb) (second rgb) (third rgb)))

; Is a number a double? ex: 33, 66
(define (double? x)
  (let ([nums (string->list (number->string x))])
    (cond
      [(not (even? (length nums))) #f]
      [(eq? (length nums) 2) (eq? (first nums) (last nums))]
      [else (let-values ([(front back) (split-at nums (quotient (length nums) 2))])
              (string=? (list->string front) (list->string back)))])))

; Drop images in a list next to one another
(define (row->image row)
  (cond
    [(empty? row) empty-image]
    [else         (beside (first row)
                          (row->image (rest row)))]))

; Convert a string into a list of string pairs
; (string-pairs "Apple") returns ("Ap" "pl" "e")
(define (string-pairs s)
  (define (loop p l)
    (cond
      [(empty? l) (reverse p)]
      [(eq? (length l) 1) (reverse (cons (list->string l) p))]
      [else (loop (cons (list->string (take l 2)) p) (drop l 2))]))
  (loop '() (string->list (string-join (string-split s) ""))))

; Partition list into lists of n elements
; example: (chunk-mirror 3 '(1 2 3 4 5 6)) returns
; '((1 2 3 3 2 1) (4 5 6 6 5 4))
(define (chunk-mirror xs n)
  (let ([chunked (slice-at xs n)])
    (map (λ (x)
           (flatten (cons x (reverse x)))) chunked)))

; Partition list into lists of n elements
; example: (chunk-mirror 3 '(1 2 3 4 5 6)) returns
; '((1 2 3 1 2 3) (4 5 6 4 5 6))
(define (chunk-dupe xs n)
  (let ([chunked (slice-at xs n)])
    (map (λ (x)
           (flatten (cons x x))) chunked)))

; Calculate the position of a position in a space within a new space
; example: where x = 155 in a 255px wide space return x in 300px space
(define (relative-position pos current-max target-max)
  (* (/ pos current-max) target-max))

; Take the dimensions and calculate a border 10% of dim and the internal draw space
(define (make-canvas width height [max DEFAULT-BORDER-MAX])
  (let* ([border (min (* width .1) max)]
         [iw (->int (- width (* border 2)))]
         [ih (->int (- height (* border 2)))]
         [outside (dim width height)]
         [inside (dim iw ih)])
    (canvas outside inside border)))

;; ///////////////////////
;; // SHA1 Operations
;; //////////////////////

;; Convert contents of port into a list of 20 base-10 numbers from a SHA1 hash
(define (process-input-port pt)
  (let* ([pairs (map (λ (x) (string->number x 16))
                     (string-pairs (sha1 pt)))])
    (when (input-port? pt)
      (close-input-port pt))
    pairs))

;; Convert a string into a byte port
(define (string->numberlist str)
  (process-input-port (open-input-bytes (string->bytes/utf-8 (->string str)))))

;; Convert a file into a byte portb
(define (file->numberlist filename)
  (define fpath (->string filename))
  (if (and (> (string-length fpath) 0) (file-exists? (string->path fpath)))
      (process-input-port (open-input-file fpath #:mode 'binary))
      (raise-argument-error 'file->numberlist "file-exists?" filename)))

; Pad a list with its last value to size
(define (pad-list l size)
  (cond
    [(empty? l) (build-list size values)]
    [(< (length l) size) (pad-list (append l (list (last l))) size)]
    [else l]))

; Fold over a list of lists and gather values from pos in each list into a new list
(define (gather-values pos l)
  (cond
    [(empty? l) '()]
    [else (foldl (λ (x y) (cons (if (empty? x)
                                    '()
                                    (pos x)) y)) '() l)]))

; Build up a list of 12 triplets '(1 2 3) to use as color information
(define (make-triplets user [max DEFAULT-MAX-USER-LENGTH])
  (let* ([initial (cond
                    [(empty? user) (range max)] ; fail safe for empty list
                    [(> (modulo (length user) max) 0) (pad-list user max)]
                    [else user])]
         [triples (filter (λ (x) (> (length x) 0)) (slice-at (take initial max) 3))]
         [firsts (slice-at (pad-list (gather-values first triples) 3) 3)]
         [seconds (slice-at (pad-list (gather-values second triples) 3) 3)]
         [thirds (slice-at (pad-list (gather-values third triples) 3) 3)])
    (append triples firsts seconds thirds)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Tests

(module+ test
  (require rackunit
           sugar)

  (test-case
      "file->numberlist returns a list of 20 values"
    (check-true (= 20 (length (file->numberlist "utils.rkt")))))

  (test-case
      "file->numberlist throws exn if no file exists"
    (check-exn
     exn:fail?
     (λ () (file->numberlist "wutang.rkt")))
    (check-exn
     exn:fail?
     (λ () (file->numberlist "utils"))))

  (test-case
      "file->numberlist throws exn if filename empty"
    (check-exn
     exn:fail?
     (λ () (file->numberlist "")))))

(module+ test
  (require quickcheck
           sugar)

  ; TEST: Make canvas should calculate a border and internal area and create data structures
  (define make-canvas-structs-agree
    (property ([w arbitrary-natural]
               [h arbitrary-natural])
              (let* ([c (make-canvas w h)]
                     [outside (canvas-outside c)]
                     [inside (canvas-inside c)]
                     [border (min (* w .1) DEFAULT-BORDER-MAX)])
                (and (canvas? c)
                     (dim? outside)
                     (dim? inside)
                     (= (dim-w outside) w)
                     (= (dim-h outside) h)
                     (= (canvas-border c) border)
                     (= (->int (- (dim-w outside) (* border 2))) (dim-w inside))
                     (= (->int (- (dim-h outside) (* border 2))) (dim-h inside))))))

  (quickcheck make-canvas-structs-agree)

  ;; Ensure we get a list of 20 values
  (define process-user-lengths-agree
    (property ([val (choose-mixed (list
                                   (choose-integer 1 (random 10000))
                                   (choose-string choose-printable-ascii-char
                                                  (random 100))))])
              (= 20 (length (string->numberlist val)))))

  (quickcheck process-user-lengths-agree)

  ; string-pairs length is equal to original string without spaces
  (define string-pairs-length-agree
    (property ([str arbitrary-printable-ascii-string])
              (= (string-length (string-trim (string-replace str " " "")))
                 (string-length (string-join (string-pairs str) "")))))

  (quickcheck string-pairs-length-agree)

  ; string-pairs list contains items of length 2 or less
  (define string-pairs-lengths-are-two
    (property ([str arbitrary-printable-ascii-string])
              (not (false? (foldl (λ (x y) (<= (string-length x) 2)) #t (string-pairs str))))))

  (quickcheck string-pairs-lengths-are-two)

  ; chunk mirror returns lists with twice the length of the original
  (define chunk-mirrors-length-doubled
    (property ([lst (arbitrary-list arbitrary-natural)]
               [num arbitrary-natural])
              (= (* 2 (length lst)) (length (flatten (chunk-mirror lst (+ 1 num)))))))

  (quickcheck chunk-mirrors-length-doubled)

  ; chunk mirror returns list items that are mirrors, so if we split the item list
  ; in half both pieces should be equal when the 2nd half is reversed
  (define chunk-mirrors-items-mirrored
    (property ([lst (arbitrary-list arbitrary-natural)]
               [num arbitrary-natural])
              (let* ([cm (chunk-mirror lst (+ 1 num))]
                     [results (map (λ (x)
                                     (let-values ([(f b) (split-at x (quotient (length x) 2))])
                                       (equal? f (reverse b))))
                                   cm)])
                (empty? (filter false? results)))))

  (quickcheck chunk-mirrors-items-mirrored)

  ; chunk mirror returns lists with lengths equal slice-at lst num + 1
  (define chunk-mirrors-length-is-round
    (property ([lst (arbitrary-list arbitrary-natural)]
               [num arbitrary-natural])
              (let ([cm (chunk-mirror lst (+ 1 num))])
                (= (length cm) (length (slice-at lst (+ 1 num)))))))

  (quickcheck chunk-mirrors-length-is-round)

  ; chunk dupe returns list items that dupes, so if we split the item list
  ; in half both pieces should be equal
  (define chunk-dupe-items-mirrored
    (property ([lst (arbitrary-list arbitrary-natural)]
               [num arbitrary-natural])
              (let* ([cm (chunk-dupe lst (+ 1 num))]
                     [results (map (λ (x)
                                     (let-values ([(f b) (split-at x (quotient (length x) 2))])
                                       (equal? f b)))
                                   cm)])
                (empty? (filter false? results)))))

  (quickcheck chunk-dupe-items-mirrored)

  ; Relative position should be reversible to original position
  (define relative-position-values-agree
    (property ([pos (choose-integer 0 200)]
               [current (choose-integer 0 300)]
               [target (choose-integer 0 500)])
              (let* ([new (relative-position pos current target)])
                (= (* (/ new target) current)
                   pos))))

  (quickcheck relative-position-values-agree)

  ; pad-list should increase the list to size
  (define pad-list-lengths-agree
    (property ([lst (arbitrary-list arbitrary-natural)]
               [size arbitrary-natural])
              (>= (length (pad-list lst size)) size)))
  (quickcheck pad-list-lengths-agree)

  ; gather values will builds up lists made from pos values in lst
  (define gather-values-lengths-agree
    (property ([lst (arbitrary-list (arbitrary-list arbitrary-natural))])
              (let ([len (length lst)])
                (= (length (gather-values first lst)) len))))
  (quickcheck gather-values-lengths-agree)

  ; make-triplets should always return a list of 12 items
  (define make-triplets-lengths-agree
    (property ([lst (arbitrary-list arbitrary-natural)])
              (= (length (make-triplets lst)) 12)))
  (quickcheck make-triplets-lengths-agree)

  ; make-triplets should always return a list of 12 lists of 3 items
  (define make-triplets-items-agree
    (property ([lst (arbitrary-list arbitrary-natural)])
              (let ([t (make-triplets lst)])
                (empty? (filter false? (map (λ (x) (and (list? x)
                                                        (= (length x) 3))) t))))))
  (quickcheck make-triplets-items-agree)

  ; Test build-color-range
  (define make-color-ranges-lengths-agree
    (property ([user (choose-list (choose-integer 0 255) 20)])
              (= 6 (length (build-color-range user)))))

  (quickcheck make-color-ranges-lengths-agree))
