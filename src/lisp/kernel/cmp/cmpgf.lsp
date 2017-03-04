(in-package :cmp)

;;#+(or)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (pushnew :debug-cmpgf *features*))

#+debug-cmpgf
(progn
  (defun insert-message ()
    (irc-create-call "cc_dispatch_debug" (list (jit-constant-i32 0) (jit-constant-i64 (incf *message-counter*)))))
  (defun debug-argument (arg arg-tag)
    (insert-message)
    (irc-create-call "cc_dispatch_debug" (list (jit-constant-i32 1) arg))
    (irc-create-call "cc_dispatch_debug" (list (jit-constant-i32 2) arg-tag)))
  (defun debug-pointer (ptr)
    (insert-message)
    (irc-create-call "cc_dispatch_debug" (list (jit-constant-i32 4) ptr)))
  (defun debug-arglist (ptr)
    (insert-message)
    (irc-create-call "cc_dispatch_debug" (list (jit-constant-i32 3) ptr)))
  (defun debug-call (fn args)
    (irc-create-call fn args)))

#+debug-cmpgf
(progn
  (defmacro gf-log (fmt &rest fmt-args) `(format t ,fmt ,@fmt-args))
  (defmacro gf-do (&body code) `(progn ,@code)))

#-debug-cmpgf
(progn
  (defun insert-message())
  (defun debug-call (fn args))
  (defmacro gf-log (fmt &rest fmt-args) nil)
  (defmacro gf-do (&body code) nil))

(unless (boundp '+header-size+)
  (defparameter +header-size+ 8))

(defstruct (outcome (:type vector) :named)  outcome)

(defstruct (match (:type vector) :named) outcome)
(defstruct (single (:include match) (:type vector) :named) stamp class-name)
(defstruct (range (:include match) (:type vector) :named) first-stamp last-stamp reversed-class-names)
(defstruct (node (:type vector) :named) (eql-specializers (make-hash-table :test #'eql) :type hash-table) (class-specializers nil :type list))

(defstruct (dtree (:type vector) :named) root)

(defstruct (spec-vec-iterator (:type vector))
  index vector)

(defun spec-vec-iterator-value (spec-vec)
  (svref (spec-vec-iterator-vector spec-vec) (spec-vec-iterator-index spec-vec)))

(defun spec-vec-iterator-advance (spec-vec)
  (incf (spec-vec-iterator-index spec-vec)))

(defun parse-call-history-entry (entry)
  (values (butlast entry) (car (last entry))))
    
(defun dtree-add-call-history (dtree specializers)
  "Add specializers for one method to the dtree"
  (dolist (one specializers)
    (let ((signature (car one))
	  (outcome (cdr one)))
      (parse-call-history-entry one)
      (when (null (dtree-root dtree))
	(setf (dtree-root dtree) (make-node)))
      (node-add (dtree-root dtree) (svref signature 0) 1 signature outcome)))
  (optimize-nodes (dtree-root dtree)))

(defun eql-specializer-p (spec)
  "Return t if the spec is an eql specializer - they are represented as CONS cells
   with the value in the CAR  - the 'EQL symbol has been removed"
  (consp spec))

(defun node-add (node spec sidx rest-specs goal)
  (if (eql-specializer-p spec)
      (node-eql-add node spec sidx rest-specs goal)
      (node-class-add node spec sidx rest-specs goal)))

(defun insert-sorted (item lst &optional (test #'<) (key #'single-stamp))
  (if (null lst)
      (list item)
      (if (funcall test (funcall key item) (funcall key (car lst)))
          (cons item lst) 
          (cons (car lst) (insert-sorted item (cdr lst) test key)))))

(defun node-class-add (node spec sidx rest-specs goal)
  (let* ((stamp (core:get-instance-stamp (if (clos:classp spec) spec (find-class spec))))
	 (match (find stamp (node-class-specializers node) :test #'eql :key #'single-stamp)))
    (if match
	(node-add (match-outcome match) (svref rest-specs sidx) (1+ sidx) rest-specs goal)
	(setf (node-class-specializers node)
	      (insert-sorted (make-single :stamp stamp
                                          :class-name spec
                                          :outcome (ensure-outcome sidx rest-specs goal))
			     (node-class-specializers node))))))

(defun node-eql-add (node spec sidx rest-specs goal)
  (let* ((eql-value (cadr spec)) ; (eval (cadr spec)))
	 (eql-ht (node-eql-specializers node)))
    (let ((outcome (ensure-outcome sidx rest-specs goal)))
      (setf (gethash eql-value eql-ht) outcome))))

(defun extends-range-p (prev-last-stamp prev-outcome next)
  (and (= (1+ prev-last-stamp) (single-stamp next))
       (equalp prev-outcome (single-outcome next))))

(defun optimize-node (node)
  "Create a list from the argument list and merge matches
   that can be considered adjacent into a range object."
  (let ((class-specializers (node-class-specializers node))
	(merged-specializers nil)
	merged)
    (dolist (head class-specializers)
      (let ((prev (car merged-specializers)))
	(cond
	  ((null prev)
	   ;; There is no prev head or range
	   (push head merged-specializers))
	  ((and (range-p prev)
		(extends-range-p (range-last-stamp prev)
				 (range-outcome prev)
				 head))
	   ;; The new head extends the previous range
	   (incf (range-last-stamp prev))
	   (push (single-class-name head) (range-reversed-class-names prev))
	   (setf merged t))
	  ((range-p prev)
	   ;; The new head doesn't extend the prev range
	   (push head merged-specializers))
	  ((extends-range-p (single-stamp prev)
			    (single-outcome prev)
			    head)
	   ;; prev was a single match but with the new head
	   ;; they make a range.  Pop prev from merged-specializers
	   ;; and push a range-match
	   (pop merged-specializers)
	   (push (make-range :first-stamp (single-stamp prev)
			     :last-stamp (single-stamp head)
			     :reversed-class-names (list (single-class-name head)
							 (single-class-name prev))
			     :outcome (single-outcome head))
		 merged-specializers)
	   (setf merged t))
	  (t (push head merged-specializers)))))
    (when merged
      (setf (node-class-specializers node) (nreverse merged-specializers)))))

(defun optimize-nodes (node-or-outcome)
  (when (node-p node-or-outcome)
    (dolist (spec (node-class-specializers node-or-outcome))
      (let ((child-node-or-outcome (match-outcome spec)))
	(optimize-nodes child-node-or-outcome)))
    (optimize-node node-or-outcome)))
	    

(defun ensure-outcome (sidx specs goal)
  (if (>= sidx (length specs))
      (make-outcome :outcome goal)
      (let ((node (make-node)))
	(node-add node (svref specs sidx) (1+ sidx) specs goal)
	node)))


(defmacro with-graph ((name fout &rest open-args) &body body)
  `(with-open-file (,fout ,@open-args)
     (format ,fout "digraph ~a {~%" ,name)
     ,@body
     (format ,fout "}~%")))



(defun compile-remaining-eql-tests (eql-tests arg args orig-args)
  (if (null eql-tests)
      nil
      (let ((eql-test (car eql-tests))
	    (eql-rest (cdr eql-tests)))
	`(if (eql ,arg ',(car eql-test))
	     ,(compile-node-or-outcome (second eql-test) args orig-args)
	     ,(if eql-rest
		  (compile-remaining-eql-tests eql-rest arg args orig-args))))))

(defun compile-eql-specializers (node arg args orig-args)
  (let ((eql-tests (let (values)
		     (maphash (lambda (key value)
				(push (list key value) values))
			      (node-eql-specializers node))
		     values)))
    (let ((result (compile-remaining-eql-tests eql-tests arg args orig-args)))
      (if result
	  (list result)
	  nil))))


(defun compile-class-binary-search (matches stamp-var args orig-args)
  (cond
    ((null matches)
     `(no-applicable-method orig-args))
    ((= (length matches) 1)
     (let ((match (car matches)))
       (if (single-p match)
	   `(if (= ,stamp-var ,(single-stamp match))
		,(compile-node-or-outcome (single-outcome match) args orig-args)
		(go miss))
	   `(if (and (>= ,stamp-var ,(range-first-stamp match)) (<= ,stamp-var ,(range-last-stamp match)))
		,(compile-node-or-outcome (match-outcome match) args orig-args)
		(go miss)))))
    (t
     (let* ((len-div-2 (floor (length matches) 2))
	    (left-matches (subseq matches 0 len-div-2))
	    (right-matches (subseq matches len-div-2))
	    (right-head (car right-matches))
	    (right-stamp (if (single-p right-head)
			     (single-stamp right-head)
			     (range-first-stamp right-head))))
       `(if (< ,stamp-var ,right-stamp)
	    ,(compile-class-binary-search left-matches stamp-var args orig-args)
	    ,(compile-class-binary-search right-matches stamp-var args orig-args))))))

(defun compile-class-specializers (node arg args orig-args)
  (let ((stamp-var (gensym "STAMP")))
    `(let ((,stamp-var (core:get-instance-stamp (class-of ,arg))))
       ,(compile-class-binary-search (node-class-specializers node) stamp-var args orig-args))))

(defun gather-outcomes (outcome)
  (let ((tag (intern (format nil "T~a" (hash-table-count *map-tag-outcomes*)))))
    (setf (gethash tag *map-tag-outcomes*) outcome)
    tag))

(defun compile-outcome (node args orig-args)
  `(go ,(gather-outcomes (outcome-outcome node))))

(defun compile-node (node args orig-args)
  (let ((arg (gensym "ARG")))
    `(let ((,arg (va-arg ,args)))
       ,@(compile-eql-specializers node arg args orig-args)
       ,(compile-class-specializers node arg args orig-args))))

(defun compile-node-or-outcome (node-or-outcome args orig-args)
  (if (outcome-p node-or-outcome)
      (compile-outcome node-or-outcome args orig-args)
      (compile-node node-or-outcome args orig-args)))

(defvar *map-tag-outcomes* (make-hash-table))
(defun compiled-dtree-form (dtree)
  (let ((vargs (gensym "VARGS"))
	(orig-vargs (gensym "ORIG-VARGS"))
	(*map-tag-outcomes* (make-hash-table)))
    `(lambda (,orig-vargs &aux (,vargs (copy-vargs ,orig-vargs)))
       (tagbody
	  ,(compile-node-or-outcome (dtree-root dtree) vargs `(copy-vargs ,vargs))
	  ,@(loop for key being the hash-keys of *map-tag-outcomes*
	       using (hash-value value)
	       append (list key value))
	miss
	  (no-applicable-methods ,vargs)))))

(defun draw-node (fout node)
  (cond
    ((null node)
     #+(or)(let ((nodeid (gensym)))
	     (format fout "~a [shape = circle];~%" nodeid)
	     (format fout "~a [label = \"nil\"];~%" nodeid)
	     nodeid)
     nil)
    ((outcome-p node)
     (let ((nodeid (gensym)))
       (format fout "~a [shape=ellipse,label=\"~a\"];~%" nodeid (outcome-outcome node))
       nodeid))
    ((node-p node)
     (let* ((nodeid (gensym))
	    (idx 0)
	    (eql-entries (loop for key being the hash-keys of (node-eql-specializers node)
			    using (hash-value value)
			    collect (list (prog1 idx (incf idx))
					  (format nil "eql ~a" key)
					  (draw-node fout value))))
	    (class-entries (loop for x in (node-class-specializers node)
			      collect (list (prog1 idx (incf idx))
					    (if (single-p x)
						(format nil "~a;~a" (single-stamp x) (class-name (single-class-name x)))
						(format nil "~a-~a;~a" (range-first-stamp x) (range-last-stamp x) (mapcar #'class-name (reverse (range-reversed-class-names x)))))
					    (draw-node fout (match-outcome x)))))
	    (entries (append eql-entries class-entries)))
       (format fout "~a [shape = record, label = \"~{ <f~a> ~a ~^|~}\" ];~%" nodeid (loop for x in entries
											 append (list (first x) (second x))))
       (loop for x in entries
	  do (format fout "~a:<f~a> -> ~a;~%" nodeid (first x) (third x)))
       nodeid))
    (t (error "Handle draw-node for ~a" node )
       #+(or)(let ((id (gensym)))
	       (format fout "~a [ label = \"~a\"];~%" id node)
	       id))))

(defun draw-graph (pathname dtree)
  (with-graph ("G" fout pathname :direction :output)
    (format fout "graph [ rankdir = \"LR\"];~%")
    (let ((startid (gensym)))
      (format fout "~a [ label = \"Start\", shape = diamond ];~%" startid)
      (format fout "~a -> ~a;~%" startid (draw-node fout (dtree-root dtree))))))



;;; ------------------------------------------------------------
;;;
;;; Compile the dispatcher to llvm-ir
;;
;;

;;; Define the va_list structure

(defvar *accumulated-values* nil
  "Accumulate values that the dispatch function needs")
(defvar *outcomes* nil
  "Map effective methods and symbols to basic-blocks")
(defvar *message-counter* nil)
(defvar *gf-data-id* nil)
(defvar *gf-data* nil
  "Store the global variable that will store effective methods")
(defvar *bad-tag-bb*)
(defvar *eql-selectors*)
(defun compiled-dtree-form (dtree)
  (let ((vargs (gensym "VARGS"))
	(orig-vargs (gensym "ORIG-VARGS"))
	(*map-tag-outcomes* (make-hash-table)))
    `(lambda (,orig-vargs &aux (,vargs (copy-vargs ,orig-vargs)))
       (tagbody
	  ,(codegen-node-or-outcome (dtree-root dtree) vargs `(copy-vargs ,vargs))
	  ,@(loop for key being the hash-keys of *map-tag-outcomes*
	       using (hash-value value)
	       append (list key value))
	miss
	  (no-applicable-methods ,vargs)))))




(defun lookup-eql-selector (eql-test)
  (let ((tagged-immediate (core:create-tagged-immediate-value-or-nil eql-test)))
    (if tagged-immediate
	(irc-int-to-ptr (jit-constant-i64 tagged-immediate) +t*+)
	(let ((eql-selector-id (gethash eql-test *eql-selectors*)))
	  (unless eql-selector-id
	    (setf eql-selector-id (prog1 *gf-data-id* (incf *gf-data-id*)))
	    (setf (gethash eql-test *eql-selectors*) eql-selector-id))
	  (let* ((eql-selector (irc-smart-ptr-extract
				(irc-load (irc-gep *gf-data*
						   (list (jit-constant-size_t 0)
							 (jit-constant-size_t eql-selector-id))) "load") "extract-sp")))
	    eql-selector)))))
	

(defun codegen-remaining-eql-tests (eql-tests eql-fail-branch arg args gf gf-args)
  (if (null eql-tests)
      (irc-br eql-fail-branch)
      (let* ((eql-test (car eql-tests))
	     (eql-rest (cdr eql-tests))
	     (eql-spec (first eql-test))
	     (eql-outcome (second eql-test))
	     (eql-selector (lookup-eql-selector eql-spec))
	     (eq-cmp (irc-icmp-eq arg eql-selector))
	     (eql-branch (irc-basic-block-create "eql-branch"))
	     (else-eql-test (irc-basic-block-create "else-eql-test")))
	(irc-cond-br eq-cmp eql-branch else-eql-test)
	(irc-begin-block else-eql-test)
	(let* ((eql-i32 (irc-create-call "cc_eql" (list arg eql-selector)))
	       (eql-cmp (irc-icmp-eq eql-i32 (jit-constant-i32 1)))
	       (next-eql-test (irc-basic-block-create "next-eql-test")))
	  (irc-cond-br eql-cmp eql-branch next-eql-test)
	  (irc-begin-block next-eql-test)
	  (codegen-remaining-eql-tests eql-rest eql-fail-branch arg args gf gf-args))
	(irc-begin-block eql-branch)
	(codegen-node-or-outcome eql-outcome args gf gf-args))))

(defun codegen-eql-specializers (node arg args gf gf-args)
  (let ((eql-tests (loop for key being the hash-keys of (node-eql-specializers node)
		      using (hash-value value)
		      collect (list key value)))
	(on-to-class-specializers (irc-basic-block-create "on-to-class-specializers")))
    (codegen-remaining-eql-tests eql-tests on-to-class-specializers arg args gf gf-args)
    (irc-begin-block on-to-class-specializers)))



(defun gather-outcomes (outcome)
  (let ((tag (intern (format nil "T~a" (hash-table-count *map-tag-outcomes*)))))
    (setf (gethash tag *map-tag-outcomes*) outcome)
    tag))

(defun codegen-outcome (node args gf gf-args)
  (let* ((outcome (outcome-outcome node))
	 (effective-method-block (gethash outcome *outcomes*)))
    (if effective-method-block
	(irc-br effective-method-block)
	(let* ((effective-method-block (irc-basic-block-create "effective-method"))
	       (gf-data-id (prog1 *gf-data-id* (incf *gf-data-id*))))
	  (setf (gethash outcome *outcomes*) gf-data-id)
	  (irc-branch-to-and-begin-block effective-method-block)
	  (let ((effective-method (irc-smart-ptr-extract
				   (irc-load (irc-gep *gf-data*
						      (list (jit-constant-size_t 0)
							    (jit-constant-size_t gf-data-id))) "load") "extract-sp")))
            (debug-pointer (irc-ptr-to-int
                            (irc-gep *gf-data*
                                     (list (jit-constant-size_t 0)
                                           (jit-constant-size_t gf-data-id))) +uintptr_t+))
            (debug-call "debugPointer" (list (irc-bit-cast effective-method +i8*+)))
	    (irc-create-call "llvm.va_end" (list (irc-pointer-cast args +i8*+ "local-arglist-i8*")))
	    (irc-ret (irc-create-call "cc_dispatch_effective_method" (list effective-method gf gf-args) "ret")))))))

(defun codegen-class-binary-search (matches stamp-var args gf gf-args)
  (insert-message)
  (cond
    ((null matches)
     (irc-br (gethash :miss *outcomes*)))
    ((= (length matches) 1)
     (let ((match (car matches)))
       (if (single-p match)
	   (let ((cmpeq (irc-icmp-eq stamp-var (jit-constant-i64 (single-stamp match)) "eq"))
		 (true-branch (irc-basic-block-create "match"))
		 (false-branch (irc-basic-block-create "cont")))
	     (irc-cond-br cmpeq true-branch false-branch)
	     (irc-begin-block true-branch)
	     (codegen-node-or-outcome (single-outcome match) args gf gf-args)
	     (irc-begin-block false-branch)
	     (irc-br (gethash :miss *outcomes*)))
	   (let ((ge-first-branch (irc-basic-block-create "gefirst"))
		 (le-last-branch (irc-basic-block-create "lelast"))
		 (miss-branch (gethash :miss *outcomes*))
		 (cmpge (irc-icmp-sge stamp-var (jit-constant-i64 (range-first-stamp match)) "ge")))
	     (irc-cond-br cmpge ge-first-branch miss-branch)
	     (irc-begin-block ge-first-branch)
	     (let ((cmple (irc-icmp-sle stamp-var (jit-constant-i64 (range-last-stamp match)) "le")))
	       (irc-cond-br cmple le-last-branch miss-branch)
	       (irc-begin-block le-last-branch)
	       (codegen-node-or-outcome (match-outcome match) args gf gf-args))))))
    (t
     (let* ((len-div-2 (floor (length matches) 2))
	    (left-matches (subseq matches 0 len-div-2))
	    (right-matches (subseq matches len-div-2))
	    (right-head (car right-matches))
	    (right-stamp (if (single-p right-head)
			     (single-stamp right-head)
			     (range-first-stamp right-head))))
       (let ((lt-branch (irc-basic-block-create "lt-branch"))
	     (gt-branch (irc-basic-block-create "gt-branch"))
	     (cmplt (irc-icmp-slt stamp-var (jit-constant-i64 right-stamp) "lt")))
	 (irc-cond-br cmplt lt-branch gt-branch)
	 (irc-begin-block lt-branch)
	 (codegen-class-binary-search left-matches stamp-var args gf gf-args)
	 (irc-begin-block gt-branch)
	 (codegen-class-binary-search right-matches stamp-var args gf gf-args)))))
  #+(or)(cond
	  ((null matches)
	   `(no-applicable-method orig-args))
	  ((= (length matches) 1)
	   (let ((match (car matches)))
	     (if (single-p match)
		 `(if (= ,stamp-var ,(single-stamp match))
		      ,(codegen-node-or-outcome (single-outcome match) args orig-args)
		      (go miss))
		 `(if (>= ,stamp-var ,(range-first-stamp match))
		      (if (<= ,stamp-var ,(range-last-stamp match))
			  ,(codegen-node-or-outcome (match-outcome match) args orig-args)
			  (go miss))))))
	  (t
	   (let* ((len-div-2 (floor (length matches) 2))
		  (left-matches (subseq matches 0 len-div-2))
		  (right-matches (subseq matches len-div-2))
		  (right-head (car right-matches))
		  (right-stamp (if (single-p right-head)
				   (single-stamp right-head)
				   (range-first-stamp right-head))))
	     `(if (< ,stamp-var ,right-stamp)
		  ,(codegen-class-binary-search left-matches stamp-var args orig-args)
		  ,(codegen-class-binary-search right-matches stamp-var args orig-args))))))


(defun codegen-arg-stamp (arg gf gf-args)
  "Return a uintptr_t llvm::Value that contains the stamp for this object"
  ;; First check the tag
  (let* ((tagged-ptr (irc-ptr-to-int arg +uintptr_t+))
         (tag (irc-and tagged-ptr (jit-constant-uintptr_t +tag-mask+))))
    (insert-message)
    (debug-argument tagged-ptr tag)
    (let ((fixnum-bb (irc-basic-block-create "fixnum-bb"))
          (cons-bb (irc-basic-block-create "cons-bb"))
          (general-bb (irc-basic-block-create "general-bb"))
          (single-float-bb (irc-basic-block-create "single-float-bb"))
          (character-bb (irc-basic-block-create "character-bb"))
          (valist_s-bb (irc-basic-block-create "valists-bb"))
          (general-or-instance-bb (irc-basic-block-create "general-or-instance-bb"))
          (instance-bb (irc-basic-block-create "instance-bb"))
          (done-bb (irc-basic-block-create "done-bb")))
      (let ((tag-switch (irc-switch tag *bad-tag-bb* 7)))
        (mapc (lambda (tag-bb)
                (let ((tag (car tag-bb))
                      (bb (cadr tag-bb)))
                  (irc-add-case tag-switch (jit-constant-uintptr_t tag) bb)))
              (list (list +fixnum-tag+ fixnum-bb)
                    (list +fixnum1-tag+ fixnum-bb)
                    (list +cons-tag+ cons-bb)
                    (list +single-float-tag+ single-float-bb)
                    (list +character-tag+ character-bb)
                    (list +valist_s-tag+ valist_s-bb)
                    (list +general-tag+ general-or-instance-bb)))
        (let (fixnum-stamp fixnum1-stamp cons-stamp general-stamp instance-stamp single-float-stamp character-stamp valist_s-stamp)
          (irc-begin-block fixnum-bb)
          (setf fixnum-stamp (jit-constant-i64 +fixnum-stamp+))
          (insert-message)
          (irc-br done-bb)
          (irc-begin-block cons-bb)
          (setf cons-stamp (jit-constant-i64 +cons-stamp+))
          (insert-message)
          (irc-br done-bb)
          (irc-begin-block single-float-bb)
          (setf single-float-stamp (jit-constant-i64 +single-float-stamp+))
          (insert-message)
          (irc-br done-bb)
          (irc-begin-block character-bb)
          (setf character-stamp (jit-constant-i64 +character-stamp+))
          (insert-message)
          (irc-br done-bb)
          (irc-begin-block valist_s-bb)
          (setf valist_s-stamp (jit-constant-i64 +valist_s-stamp+))
          (insert-message)
          (irc-br done-bb)
          (irc-begin-block general-or-instance-bb)
          (let* ((header-ptr (irc-int-to-ptr (irc-sub (irc-ptr-to-int arg +uintptr_t+) (jit-constant-uintptr_t (+ +general-tag+ +header-size+)) "sub") +uintptr_t*+ "header-ptr"))
                 (header-val (irc-load header-ptr "header-val")))
            (insert-message)
            (debug-call "debugPrint_size_t" (list header-val))
            (setf general-stamp (llvm-sys:create-lshr-value-uint64 *irbuilder* header-val +kind-shift+ "gstamp" nil))
            (let ((instance-cmp (irc-icmp-eq general-stamp (jit-constant-uintptr_t +instance-kind+))))
              (irc-cond-br instance-cmp instance-bb general-bb))
            (irc-begin-block instance-bb)
            (insert-message)
            (let* ((rack-ptr-addr-int (irc-add (irc-ptr-to-int arg +uintptr_t+)
                                               (jit-constant-uintptr_t (- +instance-rack-offset+
                                                                          +general-tag+))))
                   (rack-ptr-addr (irc-int-to-ptr rack-ptr-addr-int +uintptr_t*+))
                   (rack-tagged (irc-load rack-ptr-addr))
                   (stamp-ptr (irc-int-to-ptr (irc-add rack-tagged (jit-constant-uintptr_t (- +instance-rack-stamp-offset+ +general-tag+))) +uintptr_t*+))
                   (stamp-fixnum (irc-load stamp-ptr))
                   (stamp (llvm-sys:create-lshr-value-uint64 *irbuilder* stamp-fixnum +fixnum-shift+ "stamp" nil)))
              (debug-call "debugPrint_size_t" (list stamp))
              (setf instance-stamp stamp)
              (irc-br done-bb)))
          (irc-begin-block general-bb)
          (debug-call "debugPrint_size_t" (list general-stamp))
          (irc-br done-bb)
          (irc-begin-block done-bb)
          (let* ((phi-bbs (list (list fixnum-stamp fixnum-bb)
                                (list cons-stamp cons-bb)
                                (list single-float-stamp single-float-bb)
                                (list character-stamp character-bb)
                                (list valist_s-stamp valist_s-bb)
                                (list general-stamp general-bb)
                                (list instance-stamp instance-bb)))
                 (stamp-phi (irc-phi +i64+ (length phi-bbs) "stamp")))
            (mapc (lambda (val-bb)
                    (let ((val (first val-bb))
                          (bb (second val-bb)))
                      (irc-phi-add-incoming stamp-phi val bb)))
                  phi-bbs)
            stamp-phi))))))

(defun codegen-class-specializers (node arg args gf gf-args)
  (let ((arg-stamp (codegen-arg-stamp arg gf gf-args)))
    (codegen-class-binary-search (node-class-specializers node) arg-stamp args gf gf-args)))


(defun codegen-node (node args gf gf-args)
  (let ((arg (irc-va_arg args +t*+)))
    (debug-call "debugPointer" (list (irc-bit-cast arg +i8*+)))
    (insert-message)
    (codegen-eql-specializers node arg args gf gf-args)
    (codegen-class-specializers node arg args gf gf-args)))



(defun codegen-node-or-outcome (node-or-outcome args gf gf-args)
  (insert-message)
  (if (outcome-p node-or-outcome)
      (codegen-outcome node-or-outcome args gf gf-args)
      (codegen-node node-or-outcome args gf gf-args)))

(defparameter *dispatcher-count* 0)
(defun codegen-dispatcher (dtree)
  (let ((*the-module* (create-run-time-module-for-compile)))
    (define-primitives-in-module *the-module*)
    (with-module (:module *the-module*
                          :optimize nil
			  :source-namestring "dispatcher"
			  :source-file-info-handle 0)
      (let ((disp-fn (irc-simple-function-create "gf-dispatcher"
						 +fn-gf+
						 'llvm-sys::External-linkage
						 *the-module*
						 :argument-names +fn-gf-arguments+ )))
	;;(1) Create a function with a gf-function signature
	;;(2) Allocate space for a va_list and copy the va_list passed into it.
	;;(3) compile the dispatch function to llvm-ir refering to the eql specializers and stamps and
	;;      the va_list passed.
	;;(4) Reach an outcome and either call the effective method with the saved va_list
	;;      or call the miss function with the saved va_list
	(let* ((irbuilder-alloca (llvm-sys:make-irbuilder *llvm-context*))
	       (irbuilder-body (llvm-sys:make-irbuilder *llvm-context*))
	       (*irbuilder-function-alloca* irbuilder-alloca)
	       (*irbuilder-function-body* irbuilder-body)
	       (*current-function* disp-fn)
               (*gf-data* 
		(llvm-sys:make-global-variable *the-module*
					       cmp:+tsp[DUMMY]+ ; type
					       nil ; isConstant
					       'llvm-sys:internal-linkage
					       (llvm-sys:undef-value-get cmp:+tsp[DUMMY]+)
					       ;; nil ; initializer
					       (next-value-table-holder-name "dummy")))
               (*gcroots-in-module* 
		(llvm-sys:make-global-variable *the-module*
					       cmp:+gcroots-in-module+ ; type
					       nil ; isConstant
					       'llvm-sys:internal-linkage
					       (llvm-sys:undef-value-get cmp:+gcroots-in-module+)
					       ;; nil ; initializer
					       "GCRootsHolder"))
	       (*gf-data-id* 0)
	       (*message-counter* 0)
	       (*eql-selectors* (make-hash-table :test #'eql))
	       (*outcomes* (make-hash-table))
	       (entry-bb (irc-basic-block-create "entry" disp-fn))
	       (*bad-tag-bb* (irc-basic-block-create "bad-tag" disp-fn))
	       (arguments (llvm-sys:get-argument-list disp-fn))
	       (gf (first arguments))
	       (gf-args (second arguments)))
	  (llvm-sys:set-insert-point-basic-block irbuilder-alloca entry-bb)
	  (let ((body-bb (irc-basic-block-create "body" disp-fn))
		(miss-bb (irc-basic-block-create "miss" disp-fn)))
	    (setf (gethash :miss *outcomes*) miss-bb)
	    (llvm-sys:set-insert-point-basic-block irbuilder-body body-bb)
	    ;; Setup exception handling and cleanup landing pad
	    (with-irbuilder (irbuilder-alloca)
	      (let* ((local-arglist (irc-alloca-va_list :label "local-arglist"))
		     (arglist-passed-untagged (irc-int-to-ptr (irc-sub (irc-ptr-to-int gf-args +uintptr_t+ "iargs") (jit-constant-uintptr_t +Valist_S-tag+) "sub") +Valist_S*+ "arglist-passed-untagged"))
		     (va_list-passed (irc-in-bounds-gep-type +VaList_S+ arglist-passed-untagged (list (jit-constant-i32 0) (jit-constant-i32 1)) "va_list-passed")))
		(insert-message)
                (debug-arglist (irc-ptr-to-int va_list-passed +uintptr_t+))
		(irc-create-call "llvm.va_copy" (list (irc-pointer-cast local-arglist +i8*+ "local-arglist-i8*") (irc-pointer-cast va_list-passed +i8*+ "va_list-passed-i8*")))
		(insert-message)
                (debug-arglist (irc-ptr-to-int local-arglist +uintptr_t+))
		(irc-br body-bb)
		(with-irbuilder (irbuilder-body)
		  (codegen-node-or-outcome (dtree-root dtree) local-arglist gf gf-args))
		(irc-begin-block *bad-tag-bb*)
		(irc-create-call "llvm.va_end" (list (irc-pointer-cast local-arglist +i8*+ "local-arglist-i8*")))
		(irc-create-call "cc_bad_tag" (list gf gf-args))
		(irc-unreachable)
		(irc-begin-block miss-bb)
		(irc-create-call "llvm.va_end" (list (irc-pointer-cast local-arglist +i8*+ "local-arglist-i8*")))
		(irc-ret (irc-create-call "cc_dispatch_miss" (list gf gf-args) "ret")))))
          (let* ((array-type (llvm-sys:array-type-get cmp:+tsp+ *gf-data-id*))
		 (correct-size-holder (llvm-sys:make-global-variable *the-module*
								     array-type
								     nil ; isConstant
								     'llvm-sys:internal-linkage
								     (llvm-sys:undef-value-get array-type)
								     (bformat nil "CONSTANTS-%d" (incf *dispatcher-count*))))
		 (bitcast-correct-size-holder (irc-bit-cast correct-size-holder +tsp[DUMMY]*+ "bitcast-table")))
            (multiple-value-bind (startup-fn shutdown-fn)
                (codegen-startup-shutdown *gcroots-in-module* correct-size-holder *gf-data-id*)
              (llvm-sys:replace-all-uses-with *gf-data* bitcast-correct-size-holder)
              (llvm-sys:erase-from-parent *gf-data*)
              #+debug-cmpgf(llvm-sys:dump *the-module*)
              (let ((sorted-roots (let ((values nil))
                                    (maphash (lambda (k v)
                                               (push (cons v k) values))
                                             *eql-selectors*)
                                    (maphash (lambda (k v)
                                               (unless (eq k :miss)
                                                 (push (cons v k) values)))
                                             *outcomes*)
                                    (let ((sorted (sort values #'< :key #'car)))
                                      (mapcar #'cdr sorted)))))
                (let* ((compiled-dispatcher (jit-add-module-return-dispatch-function *the-module* disp-fn startup-fn shutdown-fn sorted-roots)))
                  (gf-log "Compiled dispatcher -> ~a~%" compiled-dispatcher)
                  (gf-log "Dumping module\n")
                  (gf-do (cmp-log-dump *the-module*))
                  compiled-dispatcher)))))))))

(export '(make-dtree
	  dtree-add-call-history
	  draw-graph
	  codegen-dispatcher))

(in-package :clos)

(defun specializers-as-list (arguments)
  (loop for arg in arguments
     for specializer = (if (consp arg) (cadr arg) 'T)
     collect specializer))

(defun maybe-update-instances (arguments)
  (let ((invalid-instance nil))
    (dolist (x arguments)
      (when (core:cxx-instance-p x)
        (let* ((i x)
               (s (si::instance-sig i)))
          (declare (:read-only i s))
          (clos::with-early-accessors (clos::+standard-class-slots+)
            (when (si::sl-boundp s)
              (unless (and (eq s (clos::class-slots (core:instance-class i)))
                           (= (core:header-stamp i) (core:get-instance-stamp (core:instance-class i))))
                (setf invalid-instance t)
                (when *monitor-dispatch*
                  (push (list :update-obsolete-argument (core:header-stamp i) (core:get-instance-stamp (core:instance-class i))) *dispatch-log*))
                (clos::update-instance i)
                (core:header-stamp-set i (core:get-instance-stamp (si:instance-class i)))))))))
    invalid-instance))


(defparameter *trap* nil)
(defparameter *monitor-dispatch* nil)
(defparameter *dispatch-log* nil)

(defmacro with-gf-debug (exp)
  `(let ((*monitor-dispatch* t)
         (*dispatch-log* nil))
     (multiple-value-prog1
         ,exp
       (format t "Log -> ~s~%" (nreverse *dispatch-log*)))))

(defmacro when-monitor-dispatch ((log) &body body)
    `(when *monitor-dispatch*
       (symbol-macrolet ((,log *dispatch-log*))
         ,@body)))

(defun do-dispatch-miss (generic-function valist-args arguments)
  (when *monitor-dispatch*
    (push (list :dispatch-miss generic-function arguments (mapcar (lambda (x) (cons (core:header-stamp x) (core:get-instance-stamp (core:instance-class x)))) arguments)) *dispatch-log*))
  (multiple-value-bind (method-list ok)
      (clos::compute-applicable-methods-using-classes
       generic-function
       (mapcar #'class-of arguments))
    ;; If ok is NIL then what do we use as the key
    (unless ok
      (setf method-list
            (clos::compute-applicable-methods generic-function arguments))
      (unless method-list
        (clos::no-applicable-methods generic-function arguments)))
    (when method-list
      (let ((memoize-key (clos:memoization-key generic-function valist-args)))
        (let ((effective-method-function (clos::compute-effective-method-function
                                          generic-function
                                          (clos::generic-function-method-combination generic-function)
                                          method-list)))
          (cmp::gf-log "Memoizing key -> ~a ~%" memoize-key)
          (core:generic-function-call-history-push-new generic-function memoize-key effective-method-function)
          (cmp::gf-log "Invalidating dispatch function~%")
          (safe-set-funcallable-instance-function generic-function (calculate-strandh-dispatch-function generic-function)) ;;'clos::invalidated-dispatch-function)
          (funcall effective-method-function arguments nil))))))


(defun clos::dispatch-miss (generic-function valist-args)
  (format t "Missed~%")
  (core:stack-monitor (lambda () (format t "In clos::dispatch-miss with generic function ~a~%" (clos::generic-function-name generic-function))))
  ;; update instances
  (cmp::gf-log "In clos::dispatch-miss~%")
  ;; Update any invalid instances
  (let* ((arguments (core:list-from-va-list valist-args))
         (invalid-instance (maybe-update-instances arguments)))
    (if invalid-instance
        (progn
          (when *monitor-dispatch*
            (push (list :restarting-gf-dispatch generic-function (core:list-from-va-list valist-args)) *dispatch-log*))
          (funcall generic-function valist-args))
        (progn
          (do-dispatch-miss generic-function valist-args arguments)))))


(defun safe-set-funcallable-instance-function (gf func)
  ;; FIXME: Not thread safe
  (let ((previous-dispatcher (clos::generic-function-compiled-dispatch-function gf)))
    (cmp::gf-log "Here we must clean up the old compiled-dispatch-function: ~a~%" (instance-ref gf 0))
    (when previous-dispatcher
      (core:shutdown previous-dispatcher)
      (when *monitor-dispatch*
        (push :shutting-down-previous-dispatcher *dispatch-log*))
      (let ((removed (cmp:jit-remove-module (core:llvm-module previous-dispatcher))))
        (setf (clos::generic-function-compiled-dispatch-function gf) nil)
        (unless removed
          (format t "Could not remove previous dispatcher~%")))))
  (clos:set-funcallable-instance-function gf func))

;;; change-class requires removing call-history entries involving the class
;;; and invalidating the generic functions


(defun calculate-strandh-dispatch-function (generic-function)
  (let* ((call-history (clos::generic-function-call-history generic-function)))
    (if call-history
        (let ((dispatch-tree (cmp::make-dtree)))
          (cmp::dtree-add-call-history dispatch-tree call-history)
          (cmp::codegen-dispatcher dispatch-tree))
        'clos::invalidated-dispatch-function)))

(defun graph-strandh-dispatch-function (generic-function)
  (let* ((call-history (clos::generic-function-call-history generic-function)))
    (if call-history
        (let ((dispatch-tree (cmp::make-dtree)))
          (cmp::dtree-add-call-history dispatch-tree call-history)
          (cmp::draw-graph "/tmp/dispatch.dot" dispatch-tree)
          (ext:system "dot -Tpdf -O /tmp/dispatch.dot")
          (sleep 0.2)
          (ext:system "open /tmp/dispatch.dot.pdf")))))
  

(defun clos::invalidated-dispatch-function (generic-function va-list-args)
  (core:stack-monitor (lambda () (format t "In clos::invalidated-dispatch-function with generic function ~a~%" (instance-ref generic-function 0))))
  (when *monitor-dispatch*
    (push (list :invalidated-dispatch-function generic-function) *dispatch-log*))
  (cmp::gf-log "invalidated-dispatch-function generic-function -> ~a   arguments -> ~a~%" (clos::generic-function-name generic-function) va-list-args)
  (maybe-update-instances (core:list-from-va-list va-list-args))
  (multiple-value-prog1
      (clos::dispatch-miss generic-function va-list-args)
    (let ((dispatcher (calculate-strandh-dispatch-function generic-function)))
      ;; replace the old dispatch function with the new one
      (safe-set-funcallable-instance-function generic-function dispatcher))))


(defun maybe-invalidate-generic-function (gf)
  (when (typep (clos:get-funcallable-instance-function gf) 'core:compiled-dispatch-function)
            (safe-set-funcallable-instance-function gf 'clos::invalidated-dispatch-function)))

(defun method-spec-matches-entry-spec (method-spec entry-spec)
  (or
   (and (consp method-spec)
        (consp entry-spec)
        (eq (car method-spec) 'eql)
        (eql (second method-spec) (car entry-spec)))
   (and (classp method-spec) (classp entry-spec)
        (member method-spec (clos:class-precedence-list entry-spec)))))

(defun call-history-entry-involves-method-with-specializers (entry method-specializers)
  (let ((key (car entry)))
    (loop for method-spec in method-specializers
       for entry-spec across key
       always (method-spec-matches-entry-spec method-spec entry-spec))))

(defun call-history-after-method-with-specializers-change (gf method-specializers)
  (loop for entry in (clos::generic-function-call-history gf)
     unless (call-history-entry-involves-method-with-specializers entry method-specializers)
     collect entry))

(defun call-history-after-class-change (gf class)
  (loop for entry in (clos::generic-function-call-history gf)
     unless (loop for subclass in (clos::subclasses* class)
               thereis (core:call-history-entry-key-contains-specializer (car entry) subclass))
     collect entry))

(defun invalidate-generic-functions-with-class-selector (class)
  (let* ((generic-functions (loop for method in (clos:specializer-direct-methods class)
			       collect (clos:method-generic-function method)))
	 (unique-generic-functions (remove-duplicates generic-functions)))
    (loop for gf in unique-generic-functions
       do (let ((keep-entries (loop for entry in (clos::generic-function-call-history gf)
				 unless (loop for specializer in (clos::subclasses* class)
                                           thereis (core:call-history-entry-key-contains-specializer (car entry) class))
				 collect entry)))
	    (setf (clos::generic-function-call-history gf) keep-entries))
       do (maybe-invalidate-generic-function gf))))

(defun switch-to-fastgf (gf)
  (let ((dispatcher (calculate-strandh-dispatch-function gf)))
    (safe-set-funcallable-instance-function gf dispatcher)))

(export '(invalidate-generic-functions-with-class-selector
          switch-to-fastgf))


(defun cache-status ()
  (format t "                method-cache: ~a~%" (multiple-value-list (core:method-cache-status)))
  (format t "single-dispatch-method-cache: ~a~%" (multiple-value-list (core:single-dispatch-method-cache-status)))
  (format t "                  slot-cache: ~a~%" (multiple-value-list (core:slot-cache-status))))

(export 'cache-status)
  
#|
(defun permutations (specializers)
  (if (cdr specializers)
      (let ((rest-specs (permutations (cdr specializers))))
        (loop for first in (subclasses* (car specializers))
           nconcing (loop for rest-spec in rest-specs
                       collect (list first rest-spec))))
      (subclasses* (car specializers))))


(defun satiate-method-specializers (method-specializers)
  (let* ((all-permutations (loop for spec in method-specializers
                              collect (permutations spec))))
    all-permutations))
|#