;; f is the nickname for the features package
(f:featurelet
    ;; Define a 'normal' (not recursive) feature with no horizontal and no
    ;; vertical arguments.
    ((f (normal () ()
		;; Below is the feature's function, which returms the list of
		;; "possible values" the feature can assume given its horizontal
		;; and vertical arguments. Since this feature takes no arguments
		;; it simply returns a list.
		'(a b))))
  ;; Add a sequential (ppm) model to f
  (f:add-model f #'models:make-ppm)
  ;; Construct a 'feature-graph' containing just f.
  (let ((graph (gm:make-feature-graph f)))
    (multiple-value-bind (hidden-states locations evidence)
	;; Model '(- - -) with graph.
	;; No features are observed, so the contents of the events are irrelevant.
	(gm:model-sequence graph '(- - -))
      ;; Report evidence
      ;; Probabilities may be logarithmic, depending on whether probabilities:*log-space*
      ;; is true. probabilities:out converts them to normal probabilities.
      (format t "~A~%" (probabilities:out evidence))
      ;; Iterate over hidden states remaining after observing events
      (dolist (state hidden-states)
	;; Trace back reconstructs the values of 'f in the parameter
	;; joint distribution parameter that a hidden-state corresponds to.
	(format t "~A~%" (gm:trace-back state locations 'f))))))

;; Now make f observable in an event by #'identity
(f:featurelet
    ((f (normal () () '(a b))))
  (f:add-model f #'models:make-ppm)
  (f:make-observable f #'identity)
  (let ((graph (gm:make-feature-graph f)))
    (multiple-value-bind (hidden-states locations evidence)
	(gm:model-sequence graph '(a b b))
      (format t "~A~%" (probabilities:out evidence))
      (dolist (state hidden-states)
	(format t "~A~%" (gm:trace-back state locations 'f))))))
;; Only one plausible hidden state remains. Notice the evidence.

;; Let's add another feature.
(f:featurelet 
    ((f (normal () () '(a b)))
     ;; f-eq has one *horizontal* argument f, refered to by 'previous-f' in its function
     ;; and one *vertical* argument, f.
     (f-eq (normal (f) (f) (if (eq previous-f f)
			       (list 'same)
			       (list 'diff)))))
  (f:add-model f #'models:make-ppm) (f:add-model f-eq #'models:make-ppm)
  (let ((graph (gm:make-feature-graph f f-eq)))
    (multiple-value-bind (hidden-states locations)
	(gm:model-sequence graph '(0 1 2))
      (dolist (state hidden-states)
	;; Now trace back the values of f and f-eq
	(format t "~A~%" (gm:trace-back state locations 'f 'f-eq))))))
;; Notice that f-eq is undefined in the first event.

;; Let's introduce a recursive feature
;; (This example is somewhat confusing: the first f-eq is ignored)
(f:featurelet 
    ((f (recursive () (f-eq) 
		   (case f-eq 
		     (yes (list previous-f))
		     (no (case previous-f (a '(b)) (b '(a)))) 
		     (maybe '(a b)))
		   () () '(a b)))
     (f-eq (normal () () '(yes no maybe))))
  (f:make-observable f-eq) (f:add-model f #'models:make-ppm)
  (let ((graph (gm:make-feature-graph f f-eq)))
    (multiple-value-bind (hidden-states locations)
	(gm:model-sequence graph '(yes maybe no))
      (dolist (state hidden-states)
	(format t "~A~%" (gm:trace-back state locations 'f 'f-eq))))))

;; Perhaps better (but without a recursive feature):
(f:featurelet 
    ((f (normal () () '(a b))) 
     (same? (normal (f) (f) (list 'maybe (if (eq previous-f f) 'yes 'no)))))
  (f:add-model f #'models:make-ppm) (f:add-model same? #'models:make-ppm)
  (f:make-observable same? #'identity)
  (let ((graph (gm:make-feature-graph f same?)))
    (multiple-value-bind (hidden-states locations)
	(gm:model-sequence graph '(nil yes maybe no))
      (dolist (state hidden-states)
	(format t "~A~%" (gm:trace-back state locations 'f 'same?))))))


;; Let's introduce a recursive feature
(f:featurelet
    ;; F is defined with zero horizontal and zero vertical arguments
    ;; however, it receives an implicit 
    ((f (recursive () ()
		   (list (1+ previous-f))
		   ;; The above part is the same as a normal feature's definition.
		   ;; The part below defines the function that calculates the
		   ;; first value, the initialisation function.
		   ;; No horizontal and vertical arguments
		   () ()
		   ;; Return a singleton containing zero.
		   '(0))))
  (f:add-model f #'models:make-ppm)
  (let ((graph (gm:make-feature-graph f)))
    (multiple-value-bind (hidden-states locations)
	(gm:model-sequence graph '(- - -))
      (dolist (state hidden-states)
	(format t "~A~%" (gm:trace-back state locations 'f))))))

;; Easy enough? Now a more complicated example.
(f:featurelet 
    ((f (recursive () (f-eq) 
		   (case f-eq 
		     (yes (list previous-f))
		     (no (case previous-f (a '(b)) (b '(a)))) 
		     (maybe '(a b)))
		   () () '(a b)))
     (f-eq (normal (f) () '(yes no maybe))))
  (f:make-observable f-eq) (f:add-model f #'models:make-ppm)
  (let ((graph (gm:make-feature-graph f f-eq)))
    (multiple-value-bind (hidden-states locations)
	(gm:model-sequence graph '(nil yes maybe no))
      (dolist (state hidden-states locations)
	(format t "~A~%" (gm:trace-back state locations 'f 'f-eq))))))
;; Experiment with difference sequences of yes, no, maybe to get a feel for what this does.

;; An example of a feature that implements a delta feature (could be used for
;; cpint
;; And let's just generate all possible sequences of three events that can be generated
;; by this model.
(let ((f-alphabet '(0 1 2)))
  (f:featurelet 
      ((df (normal (f) ()
		   (loop for next in f-alphabet
		      collect (- next previous-f))))
       (f (recursive () (df)
		     (list (+ previous-f df))
		     nil nil
		     f-alphabet)))
    (f:add-model df #'models:make-ppm) (f:add-model f #'models:make-ppm)
    (let ((graph (gm:make-feature-graph f df)))
      (multiple-value-bind (hidden-states locations)
	  (gm:model-sequence graph '(- - -))
	(dolist (state hidden-states)
	  (format t "~A~%" (gm:trace-back state locations 'f 'df)))))))

;; This specifies the delta feature generatively, which seems a bit counter-intuitive.
;; The following much more readable system is equivalent, but breaks with the idea of
;; generating observations from latent features.
(f:featurelet
    ((df (normal (f) (f) (list (- previous-f f))))
     (f (normal () () basic-alphabet)))
  ...)


;; Integration with music data can be achieved by using music-data accessors as
;; observation functions.

(defun key-model (dataset)
  (let* ((octave 12)
	 (modes '(0 9))
	 (scale-degrees (loop for sd below octave collect sd))
	 (keysigs (loop for ks below octave collect (- ks 5)))
	 (pitches (viewpoints::unique-elements
		   (viewpoints:get-viewpoint 'cpitch) dataset)))
    (f:featurelet
	((mode (recursive () () (list previous-mode)
			  () () modes))
	 (keysig (recursive () () (list previous-keysig)
			    () () keysigs))
	 (tonic (normal () (keysig mode)
			(list (if (> keysig 0)
				  (mod (+ (* keysig 7) mode) octave)
				  (mod (+ (* (- keysig) 5) mode) octave)))))
	 (scale-degree (normal () (mode)
			       (mapcar (lambda (sd) (cons sd mode)) scale-degrees)))
	 (pitch (normal () (tonic scale-degree)
			(loop for pitch in pitches
			   if (eq (car scale-degree)
				      (mod (- pitch tonic)
					   octave))
			   collect pitch))))
      (values mode keysig tonic scale-degree pitch))))


(defun trained-key-model (dataset-id)
  (let ((dataset (md:get-event-sequences (list dataset-id))))
    (multiple-value-bind (mode keysig tonic scale-degree pitch)
	(key-model dataset)
      (let ((graph (gm:make-feature-graph mode keysig tonic scale-degree pitch)))
	(f:make-observable keysig #'md:key-signature)
	(f:make-observable mode #'md:mode)
	(f:make-observable pitch #'md:chromatic-pitch)
	(f:add-model mode #'models:make-zeroth-order-once)
	(f:add-model scale-degree #'models:make-ppm)
	(gm:model-dataset graph dataset :construct? t)
	(f:hide keysig mode)
	(f:make-observable pitch #'identity)
	(gm:flush-cache graph)
	(multiple-value-bind (states evidence)
	    (gm:model-sequence graph '(60 62 64 67) :predict? t)
	  (dolist (state (sort states #'> :key #'fourth))
	    (let ((state (first (gm:trace-back state 'keysig 'mode)))
		  (p (fourth state)))
	      (format t "P~A: ~A~%" state
		      (probabilities:out (probabilities:div p evidence))))))))))

;; Training takes a while because all mechanisms involved in prediction are also active
;; during training.


(defun temperley ()
  ;; BS (beat salience) klopt nog niet.
  ;;
  (f:featurelet
      ((ut (recursive () () (list previous-ut)
		      () () '(2 3)))
       (lt (recursive () () (list previous-lt)
		      () () '(2 3)))
       (uph (recursive () () (list previous-uph)
		       () (ut) 
		       (case ut 
			 (2 '(1 2))
			 (3 '(1 2 3)))))
       (ti (normal () () '(6)))
       (pip (recursive () () (list (1+ previous-pip))
		       () () (list 0)))
       (a (normal () (bs) (list (if (eq bs 2) 'yes 'no))))
       (bs (normal () (ut lt uph pip ti)
		   (multiple-value-bind (b p)
		       (truncate pip ti)
		     (list (if (eq ti 0)
			       (if (eq (mod (- b uph) ut) 0)
				   3 2)
			       (if (eq (mod p (/ ti lt)) 0) 
				   1 0))))))
       (n (normal () (bs a) (list (cons bs 'yes) (cons bs 'no)))))
    (list pip ut lt uph ti a bs n)))




