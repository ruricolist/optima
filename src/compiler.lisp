(in-package :optima)

(defun compile-clause-body (body)
  (cond ((null body)
         ;; Empty body.
         nil)
        ((and (consp (first body))
              (eq (car (first body)) 'declare))
         ;; Wrap with LOCALLY for declarations.
         `(locally ,.body))
        ((= (length body) 1)
         ;; Singleton form.
         (first body))
        (t
         ;; Otherwise, wrap with PROGN.
         `(progn ,.body))))

(defun compile-match-fail (form else)
  (if (equal else '(fail))
      ;; No need to introduce %OR anymore.
      form
      `(%or ,form ,else)))

(defun compile-match-variable-group (vars clauses else)
  (let ((clauses
          (loop for ((pattern . rest) . then) in clauses
                for name = (variable-pattern-name pattern)
                collect
                (if name
                    `(,rest (let ((,name ,(car vars))) ,.then))
                    `(,rest ,.then)))))
    `(%match ,(cdr vars)
             ,clauses
             ,else)))

(defun compile-match-place-group (vars clauses else)
  (let ((clauses
          (loop for ((pattern . rest) . then) in clauses
                for name = (place-pattern-name pattern)
                collect
                (if name
                    `(,rest (symbol-macrolet ((,name ,(car vars))) ,.then))
                    `(,rest ,.then)))))
    `(%match ,(cdr vars)
             ,clauses
             ,else)))

(defun compile-match-constant-group (vars clauses else)
  `(%if ,(with-slots (value) (caaar clauses)
           `(equals ,(car vars) ,value))
        (%match ,(cdr vars)
                ,(loop for ((nil . rest) . then) in clauses
                       collect `(,rest ,.then))
                ,else)
        ,else))

(defun compile-match-constructor-group (vars clauses else)
  (with-slots (arguments predicate accessor) (caaar clauses)
    (let* ((arity (length arguments))
           (var (car vars))
           (new-vars (make-gensym-list arity))
           (then `(%match ,(append new-vars (cdr vars))
                          ,(loop for ((pattern . rest) . then) in clauses
                                 for args = (constructor-pattern-arguments pattern)
                                 collect `((,@args ,.rest) ,.then))
                          ,else))
           (wrap #'identity))
      (multiple-value-bind (test-form bind-var-p)
          (funcall predicate var)
        ;; FIXME: BIND-VAR-P is ugly...
        (when bind-var-p
          (let ((new-var (gensym))
                (test test-form))
            (setq wrap (lambda (form) `(let ((,new-var ,test)) ,form))
                  var new-var
                  test-form new-var)))
        (loop for i from 0 below arity
              for new-var in new-vars
              for access = (funcall accessor var i)
              for binding = `(,new-var ,access)
              if (loop for ((pattern . nil) . nil) in clauses
                       for arg = (nth i (constructor-pattern-arguments pattern))
                       never (place-pattern-included-p arg))
                collect binding into let-bindings
              else
                collect binding into symbol-bindings
              finally
                 (when symbol-bindings
                   (setq then `(symbol-macrolet ,symbol-bindings
                                 (declare (ignorable ,@(mapcar #'car symbol-bindings)))
                                 ,then)))
                 (when let-bindings
                   (setq then `(let ,let-bindings
                                 (declare (ignorable ,@(mapcar #'car let-bindings)))
                                 ,then)))
                 (return
                   (funcall wrap
                            `(%if ,test-form
                                  ,then
                                  ,else))))))))

(defun compile-match-or-group (vars clauses else)
  (assert (= (length clauses) 1))
  (destructuring-bind ((pattern . rest) . then)
      (first clauses)
    (let ((patterns (or-pattern-sub-patterns pattern)))
      (unless patterns
        (return-from compile-match-or-group else))
      (let ((new-vars (pattern-variables (car patterns))))
        (loop for pattern in (cdr patterns)
              for vars = (pattern-variables pattern)
              unless (set-equal new-vars vars)
                do (error "Or-pattern must share the same set of variables: ~S, ~S"
                          (sort vars #'string<)
                          (sort new-vars #'string<)))
        `(%or (multiple-value-bind ,new-vars
                  (%match (,(first vars))
                          ,(loop for pattern in patterns
                                 collect `((,pattern) (values ,@new-vars)))
                          (fail))
                (%match ,(cdr vars)
                        ((,rest ,.then))
                        (fail)))
              ,else)))))

(defun compile-match-not-group (vars clauses else)
  (assert (= (length clauses) 1))
  (destructuring-bind ((pattern . rest) . then)
      (first clauses)
    (let ((pattern (not-pattern-sub-pattern pattern)))
      `(if (%match (,(first vars))
                   (((,pattern) nil))
                   t)
           (%match ,(cdr vars)
                   ((,rest ,.then))
                   ,else)
           ,else))))

(defun compile-match-empty-group (clauses else)
  `(%or ,@(loop for (nil . then) in clauses
                collect (compile-clause-body then))
        ,else))

(defun compile-match-group (vars group else)
  (let ((fail '(fail)))
    (compile-match-fail
     (if-let (it (and vars (caaar group)))
             (etypecase it
               (variable-pattern
                (compile-match-variable-group vars group fail))
               (place-pattern
                (compile-match-place-group vars group fail))
               (constant-pattern
                (compile-match-constant-group vars group fail))
               (constructor-pattern
                (compile-match-constructor-group vars group fail))
               (not-pattern
                (compile-match-not-group vars group fail))
               (or-pattern
                (compile-match-or-group vars group fail)))
             (compile-match-empty-group group fail))
     else)))

(defun compile-match-groups (vars groups else)
  (reduce (lambda (group else) (compile-match-group vars group else))
          groups
          :initial-value else
          :from-end t))

(defun group-match-clauses (clauses)
  (flet ((same-group-p (x y)
           (and (eq (type-of x) (type-of y))
                (typecase x
                  (constant-pattern
                   (%equal (constant-pattern-value x)
                           (constant-pattern-value y)))
                  (constructor-pattern
                   (equal (constructor-pattern-signature x)
                          (constructor-pattern-signature y)))
                  ((or guard-pattern and-pattern)
                   (error "Something wrong."))
                  ((or not-pattern or-pattern)
                   nil)
                  (otherwise t)))))
    (group clauses :test #'same-group-p :key #'caar)))

(defun preprocess-match-clause (clause)
  (if (and (consp clause)
           (car clause))
      (destructuring-bind (patterns . then) clause
        ;; Parse and check patterns here.
        (setq patterns (mapcar #'parse-pattern patterns))
        (check-patterns patterns)
        ;; Desugar WHEN/UNLESS here.
        (cond ((and (>= (length then) 2)
                    (eq (first then) 'when))
               (setq then `((if ,(second then)
                                ,(compile-clause-body (cddr then))
                                (fail)))))
              ((and (>= (length then) 2)
                    (eq (first then) 'unless))
               (setq then `((if (not ,(second then))
                                ,(compile-clause-body (cddr then))
                                (fail))))))
        (let ((pattern (first patterns))
              (rest (rest patterns)))
          ;; Recursively expand AND pattern here like:
          ;; 
          ;;     (AND)   => _
          ;;     (AND x) => x
          ;; 
          (loop while (and-pattern-p pattern)
                for sub-patterns = (and-pattern-sub-patterns pattern)
                do (case (length sub-patterns)
                     (0 (setq pattern (parse-pattern '_)))
                     (1 (setq pattern (first sub-patterns)))
                     (t (return))))
          ;; Recursively expand GUARD pattern here.
          (loop while (guard-pattern-p pattern) do
            (setq then `((if ,(guard-pattern-test-form pattern)
                             ,(compile-clause-body then)
                             (fail)))
                  pattern (guard-pattern-sub-pattern pattern)))
          `((,pattern ,.rest) ,.then)))
      clause))

(defun preprocess-match-clauses (vars clauses)
  (let* ((clauses (mapcar #'preprocess-match-clause clauses))
         (and-clauses
           (loop for clause in clauses
                 for (patterns . nil) = clause
                 if (and-pattern-p (first patterns))
                   collect clause)))
    (if and-clauses
        ;; Recursively expand AND patterns here like:
        ;; 
        ;;     (((AND x y) z)
        ;;      ((AND a b c) d)
        ;;      (p))
        ;; =>
        ;;      ((x y _ z)
        ;;       (a b c d)
        ;;       (p _ _ _))
        ;;    
        (loop with arity
                = (loop for ((pattern . nil) . nil) in and-clauses
                        maximize (length (and-pattern-sub-patterns pattern)))
              for clause in clauses
              for (patterns . then) = clause
              for pattern = (first patterns)
              for prefix
                = (cond ((and-pattern-p pattern)
                         (and-pattern-sub-patterns pattern))
                        (pattern
                         (list pattern)))
              for postfix
                = (make-list (- arity (length prefix))
                             :initial-element (parse-pattern '_))
              for new-patterns = (append prefix postfix (rest patterns))
              collect `(,new-patterns ,.then) into new-clauses
              finally (let ((new-vars
                              (and vars
                                   (append (make-list arity
                                                      :initial-element (first vars))
                                           (rest vars)))))
                        (return (preprocess-match-clauses new-vars new-clauses))))
        ;; Otherwise, just return the variables and the clauses.
        (list vars clauses))))

(defun compile-match (vars clauses else)
  ;; FIXME: don't call PREPROCESS-MATCH-CLAUSES two or more times
  (destructuring-bind (vars clauses)
      (preprocess-match-clauses vars clauses)
    (let ((groups (group-match-clauses clauses)))
      (compile-match-groups vars groups else))))

(defun compile-match-1 (form clauses else)
  (let ((clauses (mapcar (lambda (c) (cons (list (car c)) (cdr c))) clauses)))
    (if (symbolp form)
        (compile-match (list form) clauses else)
        (let ((form-var (gensym "FORM")))
          `(let ((,form-var ,form))
             (declare (ignorable ,form-var))
             ,(compile-match (list form-var) clauses else))))))

(defun compile-multiple-value-match (values-form clauses else)
  (let* ((arity (loop for (patterns . nil) in clauses
                      maximize (length patterns)))
         (vars (make-gensym-list arity "VAR")))
    `(multiple-value-bind ,vars ,values-form
       (declare (ignorable ,@vars))
       ,(compile-match vars clauses else))))

(defmacro %match (vars clauses else)
  "Compiler cushion macro. This is useful for seeing and debugging the
process of pattern matching compiler."
  (compile-match vars clauses else))
