;;; Code for modelling perceptual inference using IDyOM

(cl:in-package #:inference)

(defparameter *verbose* nil)

; Directory for caching counts
(defparameter *counts-dir* 
  (ensure-directories-exist
   (merge-pathnames "data/counts/" (utils:ensure-directory utils:*root-dir*))))

(defgeneric infer-category (training-set target-viewpoints source-viewpoints test-sequence
			&key &allow-other-keys))

(defmethod infer-category ((training-set md:music-dataset) target-viewpoints source-viewpoints test-sequence
			   &rest kwargs &key &allow-other-keys)
    (apply #'infer-category (append (list (coerce training-set 'list) target-viewpoints 
					 source-viewpoints test-sequence)
				    kwargs)))

(defmethod infer-category ((training-set list) target-viewpoints source-viewpoints test-sequence
			&rest kwargs &key &allow-other-keys)
  (let ((training-set-promise 
	 (promises:make-promise :function training-set 
				:id (composition-list-signature training-set))))
    (apply #'infer-category (append (list training-set-promise target-viewpoints 
					 source-viewpoints test-sequence)
				    kwargs))))

(defmethod infer-category ((training-set promises:promise) 
			target-viewpoints source-viewpoints test-sequence
			   &key (voices nil) (texture :melody)
			     (prior :empirical)
			     custom-prior
			     resampling-fold resampling-count
			     (resolution 16) (use-cache? t) &allow-other-keys)
  "Train models for each of the <source-viewpoints> using <training-set>. Predict the <target-viewpoints> in <test-sequence>. The type of prior to use can be specified with <prior>. Options are :empirical and :flat. <resampling-fold> and <resampling-count> are used to load or store the right cached models."
  (let* ((sources (viewpoints:get-viewpoints source-viewpoints))
	 (targets (viewpoints:get-basic-viewpoints target-viewpoints training-set texture))
	 ;; Obtain event counts per category
	 (category-counts (count-categories training-set texture resolution :use-cache? nil))
	 ;; Extract a list of metrical interpretations
	 (categories (mapcar #'(lambda (category-count) 
				 (md:category-string->metrical-interpretation 
				  (car category-count)))
			     category-counts))
	 (models (make-category-models training-set (promises:get-identifier training-set)
				       categories targets sources
				       resampling-fold resampling-count
				       :voices voices :texture texture
				       :resolution resolution :use-cache? use-cache?))
	 ;; Generate a Nparams x Ntarget-viewpoints x Nevents matrix for event-likelihoods
	 (likelihoods 
	  (generate-category-predictions categories models test-sequence
					 :resolution resolution :texture texture))
	 ;; Initialize the prior distribution
	 (prior-distribution (cond ((eq prior :empirical)
				     (initialise-prior-distribution category-counts resolution))
				   ((eq prior :flat)
				    (flat-prior-distribution categories resolution))
				   ((eq prior :custom)
				    (initialise-prior-distribution custom-prior
								   resolution))
				   (t nil)))
	 ;; Convert to a Nparams x Nevents data structure where each column is 
	 ;; a probability distribution over params
	 (posteriors (generate-category-posteriors prior-distribution likelihoods 
						   (length test-sequence)))
	 (information-contents 	
	  (loop for p below (length test-sequence) collecting
	       (- (log (event-likelihood p likelihoods posteriors)
		       2)))))
    (values prior-distribution likelihoods posteriors information-contents)))

(defun event-likelihood (position likelihoods posteriors)
  "Return the predictive likelihood of an event at position <position>"
  (let ((interpretations (prediction-sets:distribution-symbols posteriors)))
    (apply '+ (mapcar #'(lambda (i) 
			  (* (nth position (lookup-key i likelihoods))
			     (nth position (lookup-key i posteriors))))
		      interpretations))))

(defun generate-category-posteriors (prior-distribution likelihoods n)
  "Perform iterative Bayesian inference using the prior distribution and list
of event likelihoods per interpretation. 
Return an ALIST of posterior probabilities per interpretation per point in time. 
The posterior probabilities at time zero correspond to the prior distribution."
  (when *verbose* (format t "Performing Bayesian inference using predictions and the prior~%"))
  (let* ((interpretations (prediction-sets:distribution-symbols prior-distribution))
	 ;; Initialise results with the prior
	 (results (mapcar #'(lambda (interpretation) 
			      (cons interpretation
				    (copy-list 
				     (lookup-key interpretation prior-distribution))))
			  interpretations)))
    ;; Iterate over positions in the test sequence to infer interpretation
    (dotimes (position n)
      (let ((evidence (apply #'+ 
			     (mapcar #'(lambda (m) 
					 (* (get-event-likelihood m position likelihoods)
					    (first (lookup-key m results))))
				     interpretations))))
	(dolist (interpretation interpretations)
	  (let* ((posteriors (lookup-key interpretation results))
		 (likelihood (get-event-likelihood interpretation position likelihoods))
		 (prior (first posteriors))
		 (posterior (/ (* likelihood prior) evidence)))
	    ; Store the result
	    (push posterior (cdr (assoc interpretation results :test #'string-equal)))))))
    ;; Reverse the list of probabilities for each interpretation
    (dolist (interpretation interpretations)
      (let ((result (assoc interpretation results :test #'string-equal)))
	(rplacd result (nreverse (cdr result)))))
    results))

(defun make-category-models (training-set dataset-id categories
			     targets sources resampling-fold resampling-count
			     &key voices texture resolution use-cache?)
  "Return a LIST of with one mvs for each category in CATEGORIES."
  (mapcar #'(lambda (category) (make-category-mvs training-set dataset-id
						  category targets sources
						  resampling-fold resampling-count
						  :voices voices :texture texture
						  :resolution resolution
						  :use-cache? use-cache?))
	  categories))

(defun make-category-mvs (training-set dataset-id category
			  targets sources resampling-fold resampling-count
			  &key voices texture resolution use-cache?)
  (let ((training-set (get-category-training-set training-set category)))
    (let ((ltms (resampling:get-long-term-models sources training-set
						 nil dataset-id
						 resampling-fold resampling-count
						 :voices voices :texture texture
						 :interpretation category
						 :resolution resolution
						 :use-cache? use-cache?)))
      (mvs:make-mvs targets sources ltms))))

(defgeneric get-category-training-set (training-set category))

(defmethod get-category-training-set ((training-set promises:promise)
				      (category md::time-signature))
  (get-category-training-set (promises:retrieve training-set) category))
  
(defmethod get-category-training-set ((training-set list)
				      (category md:metrical-interpretation))
  "Loop over all events in the training set. Collect all subsequences of 
consequent events that have the same category as <category>."
  (let ((category-training-set)
	(subsequence))
    (dolist (composition training-set)
      (dolist (event (coerce composition 'list))
	(if (md:same-time-signature? event category)
	    (push event subsequence)
	    (when (not (eql subsequence nil))
	      (push (reverse subsequence) category-training-set)
	      (setf subsequence nil))))
      (unless (eql subsequence nil)
	(push (reverse subsequence) category-training-set)
	(setf subsequence nil)))
    category-training-set))

(defun generate-category-predictions (categories models test-sequence
				   &key (resolution 16) texture (keep-prediction-sets nil))
  "Return an ALIST containing event likelihoods under each possible interpretation of
each category, indexed by (a string representation of the) interpretation."
  (when *verbose* 
    (format t "Generating predictions for the test sequence in all interpretations~%"))
  (flet ((model-sequence (model interpretation)
	   (mvs:model-sequence model (coerce test-sequence 'list) texture :construct? t 
			       :predict? t :interpretation interpretation)))		
    ;; Create a list of interpretations per category
    (let ((interpretations-per-category
	   (mapcar #'(lambda (c) (md:create-interpretations c resolution)) categories)))
      ;; Aggregate results into a flat ALIST 
      (apply #'append
	     ;; Cycle over the models and associated interpretations
	     (mapcar 
	      #'(lambda (model interpretations)
		  ;; Obtain likelihoods of TEST-SEQUENCE for each interpretation
		  (mapcar 
		   #'(lambda (interpretation)
		       (let ((prediction-sets (model-sequence model interpretation)))
			 (cons (md:metre-string interpretation)
			       ;; FIXME: Only the predictions of the
			       ;; *first* target viewpoint are taken
			       ;; into account here!
			       ;; They should be combined.
			       (first (if keep-prediction-sets
					  prediction-sets
					  (prediction-sets->likelihoods prediction-sets))))))
		   interpretations))
	      models interpretations-per-category)))))
;; More readable implementation (write tests first before refactoring things that work)
;;     (let ((predictions))
;;      (loop for category in categories for model in models collecting
;;	   (let ((interpretations (md:create-interpretations category resolution)))
;;	     (loop for interpretation in interpretations collecting
;;		  (let ((prediction-sets (model-sequence model interpretation)))
;;		    (push (cons (md:metre-string interpretation)
;;				(first (if keep-prediction-sets
;;					   prediction-sets
;;					   (prediction-sets->likelihoods prediction-sets))))
;;			  predictions))))))))


(defun prediction-sets->likelihoods (prediction-sets)
  (mapcar #'(lambda (prediction-set)
	      (prediction-sets:distribution-probabilities
	       (prediction-sets:event-predictions prediction-set)))
	  prediction-sets))

(defgeneric count-categories (training-set texture resolution 
			  &key &allow-other-keys))

(defmethod count-categories ((training-set promises:promise) texture resolution
			 &key (use-cache? t) (per-composition? nil))
  (let ((filename (format nil "~A~A-~A" *counts-dir* 
			  (promises:get-identifier training-set) resolution)))
    (unless (and (utils:file-exists filename) use-cache?)
      (let ((training-set (promises:retrieve training-set)))
	(utils:write-object-to-file (count-categories training-set texture resolution    
						  :per-composition? per-composition?)
				    filename))
      (when *verbose* (format t "Written category counts to ~A.~%" filename)))
    (utils:read-object-from-file filename)))

(defmethod count-categories ((training-set list) texture resolution
			 &key (per-composition? nil))
  "Find every occurring category in a list of composition and count the number of bars in 
each category (unless <per-composition?> is true and the texture is not :grid, in that case
the number of compositions per category are counted and compositions are assumed not to 
contain metrical changes). Return an ALIST with counts indexed by category-strings."
  (let ((category-counts))
    (dolist (composition training-set category-counts)
      (cond ((eq texture :grid)
	     (sequence:dosequence (event composition)
	       (if (not (or (null (md:barlength event)) (null (md:pulses event))))
		   (let* ((category-string (md:category-string event (md:timebase event)))
			  (count (lookup-key category-string category-counts))
			  (increment (/ 1 (md:barlength event))))
		     (if count ; use count as a check whether the key already exists
			 (rplacd (assoc category-string category-counts :test #'string-equal)
				 (+ count increment))
			 (setf category-counts
			       (acons category-string increment category-counts))))
		   (warn "Unannotated event encountered while counting categories"))))
	    ((member texture (list :melody :harmony))
	     (let ((last-event (utils:last-element composition)))
	       (if (not (or (null (md:barlength last-event)) (null (md:pulses last-event))))
		   (let ((duration (+ (md:onset last-event) ; Calculate composition duration
				      (md:duration last-event)))
			 (category-string (md:category-string last-event
							      (md:timebase last-event))))
		     (let* ((count (lookup-key category-string category-counts))
			    (increment (if per-composition? 
					   1
					   (/ duration (md:barlength last-event)))))
		       (if count ; use count as a check whether the key already exists
			   (rplacd (assoc category-string category-counts :test #'string-equal)
				   (+ count increment))
			   (setf category-counts
				 (acons category-string increment category-counts)))))
		   (warn "Unannotated event encountered while counting categories"))))))))

(defun initialise-prior-distribution (category-counts resolution)
  "Initialise a prior distribution over categories based on <category-counts>.
Rescale the distribution so the sum of prior category likelihoods in each possible
phase equals one. Return the rescaled distribution."
  (when *verbose* (format t "Generating prior distribution~%"))
  (let ((counts (mapcar #'cdr category-counts))
	(categories (mapcar #'(lambda (category-count) 
				(md:metre-string->metrical-interpretation
				 (car category-count)))
			    category-counts)))
    (let ((observation-count (apply '+ counts)))
      (let ((category-prior (mapcar #'(lambda (count) (/ count observation-count)) counts))
	    (interpretations-per-category
	     (mapcar (lambda (c) (md:create-interpretations c resolution))
				     categories)))
	(let ((interpretation-prior 
	       (apply #'append
		      (mapcar #'(lambda (interpretations p) 
				  (mapcar #'(lambda (interpretation) 
					      (list (md:metre-string interpretation) p))
					  interpretations))
		       interpretations-per-category category-prior))))
	  ;; Flatten and re-normalise the distribution
	  (prediction-sets:normalise-distribution interpretation-prior))))))

(defun flat-prior-distribution (categories resolution)
    "Initialise a prior distribution over categories based on <category-counts>.
Rescale the distribution so the sum of prior category likelihoods in each possible
phase equals one. Return the rescaled distribution."
    (when *verbose* (format t "Generating a flat  distribution~%"))
    (let* ((categories (mapcar #'md:metre-string->metrical-interpretation categories))
	   (interpretations
	    (apply #'append
		  (mapcar (lambda (c) (md:create-interpretations c resolution))
			  categories)))
	   (parameters (length interpretations)))
      (mapcar (lambda (interpretation) (list (md:metre-string interpretation)
					     (/ 1 parameters)))
	      interpretations)))

(defun composition-list-signature (composition-list)
  "Return the hexdigest of the MD5SUM of the list of all composition indices in the list."
  (let* ((identifiers (mapcar #'md:get-identifier composition-list))
	 (composition-indices (mapcar #'md:get-composition-index identifiers)))
    (utils:md5-sum-of-list composition-indices)))

(defun sum-over-time (distributions)
  "Take an alist where each key is a distribution parameter and the
corresponding value is a list of probabilities at a specific time. Sum 
the probabilities over time and divide by the list length."
  (let ((categories (prediction-sets:distribution-symbols distributions)))
    (loop for category in categories collecting
      (let* ((probabilities (lookup-key category distributions)))
	(list category (apply #'utils:average probabilities))))))

(defun get-posterior (distributions n)
  "Obtain the posterior distribution at a specific point in time"
  (let ((params (prediction-sets:distribution-symbols distributions)))
    (mapcar (lambda (param) (list param
				  (elt (lookup-key param distributions) n)))
	    params)))

(defun interpretations->categories (distribution)
  "Convert a distribution over metre and phase to a distribution
over metre by averaging over phases for each metre."
  (let* ((interpretations (mapcar #'md:metre-string->metrical-interpretation
				  (prediction-sets:distribution-symbols distribution)))
	 (categories (remove-duplicates (mapcar #'md:category-string
						interpretations
						(mapcar #'md:timebase interpretations)) 
					:test #'equal))
	 (interpretations-per-category
	  (loop for category in categories collect 
	       (cons category (loop for interpretation in interpretations 
				 when (equal (md:category-string interpretation
								 (md:timebase interpretation))
					     category)
				 collect interpretation)))))
    (let ((category-distribution
	   (loop for category-interpretations in interpretations-per-category collect
		(let ((category (car category-interpretations))
		      (interpretations (cdr category-interpretations)))
		  (let ((probabilities (loop for interpretation in interpretations collect 
					    (car (lookup-key (md:metre-string interpretation)
							     distribution)))))
		    (list category (apply #'utils:average probabilities)))))))
      (prediction-sets:normalise-distribution category-distribution))))

(defun lookup-key (key alist)
  (cdr (assoc key alist :test #'string-equal)))

(defun get-sequence-likelihoods (category-likelihoods category)
  (first (lookup-key category category-likelihoods)))

(defun get-event-likelihood (category position likelihoods)
  (nth position (lookup-key category likelihoods)))

(defun get-prior-likelihood (category likelihoods)
  (lookup-key category likelihoods))

(defun category->time-signature (interpretation)
  (let ((phase (md:interpretation-phase interpretation))
	(pulses (md:pulses interpretation))
	(beat-division (md:beat-division interpretation)))
    (values pulses beat-division phase)))
