;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-INTERPRETER")

;;; *APPLYHOOK* works more-or-less as described in CLtL2, which is
;;; not at all like the *SELF-APPLYHOOK* that hooks every call
;;; into a function as part of the function itself.
;;; Don't bind it to an interpreted-function; probably don't bind to a
;;; symbol, and definitely not a lambda expression- just a compiled function.
;;; Also note: it's never rebound to NIL around each application,
;;; because that would make EVAL non-tail-recursive.  It is assumed that
;;; anyone messing with it knows what (s)he is doing.
(defvar *applyhook* nil)

;;; Retrieve the value of the binding (either lexical or special) of
;;; the variable named by SYMBOL in the environment ENV. For symbol
;;; macros the expansion is returned instead.
;;; Second values is T if the primary value is a macroexpansion.
;;; Tertiary value is the type to assert, or NIL if no type should be asserted.
;;; That is, policy-related decisions need to be made here, not in the caller.
(defun expand-or-eval-symbol (env symbol)
  (declare (symbol symbol))
  (binding* (((binding kind frame-ptr value) (find-lexical-var env symbol))
             (type (var-type-assertion env frame-ptr (or binding symbol) :read))
             ((macro-p value)
              (if kind
                  (case kind
                    (:normal (values nil value))
                    (:macro  (values t (symexpand env symbol value)))
                    (t       (values nil (symbol-value symbol))))
                  (case (info :variable :kind symbol)
                    (:macro  (values t (symexpand env symbol)))
                    (:alien  (values nil (alien-value symbol)))
                    (t       (values nil (symbol-value symbol)))))))
    (values value macro-p type)))

;; Macros must go through the hook, but we can avoid it if the hook is FUNCALL.
(defun symexpand (env sym
                  &optional (expansion (info :variable :macro-expansion sym)))
  (let ((hook (valid-macroexpand-hook)))
    (if (eq hook #'funcall)
        expansion
        (funcall hook
                 (lambda (form env) (declare (ignore form env)) expansion)
                 sym env))))

;;; Implementation note: APPLY is the main reason the interpreter conses.
;;; It would be nice if you could preallocate a DX arglist and pass that
;;; on the stack. Applying directly from a DX arglist would make the
;;; interpreter non-tail-recursive, so we don't want to do that.
;;; There is sort of a way - assuming MAKE-LIST is made to be DXable -
;;; but it is probably much worse for performance:
;;; (multiple-value-call thing
;;;    (let ((foo (make-list n)))
;;;       (setf (nth 0 foo) (eval-nth-arg ...))
;;;       (values-list foo)
;;;
;;; Dispatch to the appropriate immediate handler based on the contents of EXP.
;;; This is the double-secret entry point: do not use except in %EVAL.
(declaim (inline %%eval))
(defun %%eval (exp env)
  (cond ((symbolp exp)
         ;; CLHS 3.1.2.1.1 Symbols as Forms
         (binding* (((val expanded-p type) (expand-or-eval-symbol env exp))
                    (eval-val (if expanded-p (%eval val env) val)))
           (when (and type (not (itypep eval-val type)))
             (typecheck-fail/ref exp eval-val type))
           (return-from %%eval eval-val)))
        ;; CLHS 3.1.2.1.3 Self-Evaluating Objects
        ;; We can save a few instructions vs. testing ATOM
        ;; because SYMBOLP was already picked off.
        ((not (listp exp))
         (return-from %%eval exp)))
  (flet ((apply-it (f)
           (let ((args (mapcar (lambda (arg) (%eval arg env))
                               (cdr exp)))
                 (h *applyhook*))
             (if (or (null h)
                     (eq h (load-time-value #'funcall t))
                     (eq h 'funcall))
                 (apply f args)
               (funcall h f args)))))
    ;; CLHS 3.1.2.1.2 Conses as Forms
    (let ((fname (car exp)))
      ;; CLHS 3.1.2.1.2.4 Lambda Forms
      (cond ((eq fname 'setq)
             (eval-setq (cdr exp) env nil)) ; SEXPR = nil
            ((typep fname '(cons (eql lambda)))
             ;; It should be possible to avoid consing a function,
             ;; but this syntax isn't common enough to matter.
             (apply-it (locally (declare (notinline %%eval))
                                (%%eval `(function ,fname) env))))
            ((not (symbolp fname))
             (ip-error "Invalid function name: ~S" fname))
            (t
             ;; CLHS 3.1.2.1.2.1 Special Forms
             ;; Pick off special forms first for speed. Special operators
             ;; can't be shadowed by local defs.
             (let ((fdefn (sb-impl::symbol-fdefn fname)))
               (acond
                ((and fdefn (!special-form-handler fdefn))
                 (funcall (truly-the function (car it)) (cdr exp) env))
                (t
                 ;; Everything else: macros and functions.
                 (multiple-value-bind (fn macro-p) (get-function (car exp) env)
                   (if macro-p
                       (%eval (funcall (valid-macroexpand-hook) fn exp env) env)
                       (apply-it fn)))))))))))

(defparameter *eval-level* -1)
(defparameter *eval-verbose* nil)

(defun %eval (exp env)
  (incf *eval-calls*)
  ;; Binding *EVAL-LEVEL* inhibits tail-call, so try to avoid it
  (if *eval-verbose*
      (let ((*eval-level* (1+ *eval-level*)))
        (let ((*print-circle* t))
          (format t "~&~vA~S~%" *eval-level* "" `(%eval ,exp)))
        (%%eval exp env))
      (%%eval exp env)))

;; DIGEST-FORM both "digests" and EVALs a form.
;; It should stash an optimized handler into the SEXPR so that DIGEST-FORM
;; will (ideally) not be called again on this SEXPR.
;; The new handler is invoked right away.
;;
;; A few special-form-processors exist for standard macros. I test INFO on
;; special-forms before considering FIND-LEXICAL-FUN. After I apply my
;; globaldb speedups, it will actually be faster to use the two-part test
;; than just check the lexical environment. Usually existence of a processor
;; implies a special form, which is illegal to rebind lexically; whereas
;; technically it's legal to rebind standard macros, though weird and
;; scoring no readability points.
;;
(defun digest-form (form env sexpr)
  (declare (sexpr sexpr))
  (cond ((symbolp form) ; CLHS 3.1.2.1.1 Symbols as Forms
         (return-from digest-form (symeval form env sexpr)))
        ((not (listp form)) ; CLHS 3.1.2.1.3 Self-Evaluating Objects
         (setf (sexpr-handler sexpr) (return-constant form))
         (return-from digest-form form)))
  ;; CLHS 3.1.2.1.2 Conses as Forms
  (let ((fname (car form)))
    (cond ((eq fname 'setq)
           ;; SETQ mandates a different protocol which slightly
           ;; simplifies the treatment of symbol macros.
           (return-from digest-form
             (eval-setq (cdr form) env sexpr)))
          ((typep fname '(cons (eql lambda)))
           ;; CLHS 3.1.2.1.2.4 "A lambda form is equivalent to using funcall of
           ;; a lexical closure of the lambda expression on the given arguments."
           (return-from digest-form
             (digest-form `(funcall #',fname ,@(cdr form)) env sexpr)))
          ((not (symbolp fname))
           (ip-error "Invalid function name: ~S" fname)))
    ;; CLHS 3.1.2.1.2.1 Special Forms.
    (let ((fdefn (sb-impl::symbol-fdefn fname)))
      (awhen (and fdefn (!special-form-handler fdefn))
        (return-from digest-form
          (let ((digested-form
                 (funcall (truly-the function (cdr it)) (cdr form) env)))
            (cond (digested-form
                   (setf (sexpr-handler sexpr) digested-form)
                   (%dispatch sexpr env))
                  ((eq (info :function :kind fname) :special-form)
                   ;; Special operators that reimplement macros can decline,
                   ;; falling back upon the macro. This allows faster
                   ;; implementations of things like AND,OR,COND,INCF
                   ;; without having to deal with their full generality.
                   (error "Operator ~S mustn't decline to handle ~S"
                          fname form)))))))
    (let ((frame-ptr (local-fn-frame-ptr fname env)))
      (if (eq frame-ptr :macro)
          ;; CLHS 3.1.2.1.2.2 Macro Forms
          (multiple-value-bind (expansion keys)
              (tracing-macroexpand-1 form env)
            (cond ((or (not keys) ; only builtin macros were used
                       (eq *re-expand-macros* :NEVER))
                   (digest-form expansion env sexpr))
                  (t (setf expansion (%sexpr expansion)
                           (sexpr-handler sexpr)
                           (digest-macro-form expansion fname keys))
                     (dispatch expansion env))))
        (progn
          (setf (sexpr-handler sexpr)
                (if frame-ptr ; a lexical function
                    (digest-local-call frame-ptr (cdr form))
                  (digest-global-call fname (cdr form) env)))
          (%dispatch sexpr env))))))

;;; full-eval has compiler-error-resignalling stuff in here.
;;; I think it was better to wrap the handler for EVAL-ERROR around everything
;;; due to the relative expense of establishing a handler-binding.
;;; In this interpreter it is better to establish handlers for EVAL-ERROR
;;; on an as-needed localized basis, when the preprocessor knows that
;;; condition might be signaled. Otherwise there should be no handler.
(defun eval-in-environment (form env)
  (%eval form
         (typecase env (sb-kernel:lexenv (env-from-lexenv env)) (t env))))