;;;; ======================================================================
;;;; File:       basic-viewpoints.lisp
;;;; Author:     Marcus  Pearce <marcus.pearce@qmul.ac.uk>
;;;; Created:    <2014-09-25 19:09:17 marcusp>                           
;;;; Time-stamp: <2022-06-16 13:41:48 marcusp>                           
;;;; ======================================================================

(cl:in-package #:viewpoints)

;;;; Basic viewpoints

;; From melody, we also have:
;; 
;; * onset
;; * dur
;; * keysig
;; * mode
;; * pulses
;; * barlength
;; * tempo

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let ((slice (make-instance 'md:music-slice))
        (types '(onset dur keysig mode pulses barlength tempo)))
    (mapcar #'(lambda (x) (viewpoints:register-basic-attribute x slice)) types)))

(define-basic-viewpoint h-cpitch ((events md:harmonic-sequence md:music-slice))
  (sort (mapcar #'md:chromatic-pitch (coerce (car (last events)) 'list)) #'<))


