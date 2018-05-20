;;; core-lib.el -*- lexical-binding: t; -*-

(require 'subr-x)
(require 'cl-lib)
(require 'map)

(eval-and-compile
  (unless EMACS26+
    (with-no-warnings
      (defalias 'if-let* #'if-let)
      (defalias 'when-let* #'when-let))))


;;
;; Helpers
;;

(defun doom--resolve-path-forms (paths &optional root)
  (cond ((stringp paths)
         `(file-exists-p
           (expand-file-name
            ,paths ,(if (or (string-prefix-p "./" paths)
                            (string-prefix-p "../" paths))
                        'default-directory
                      (or root `(doom-project-root))))))
        ((listp paths)
         (cl-loop for i in paths
                  collect (doom--resolve-path-forms i root)))
        (t paths)))

(defun doom--resolve-hook-forms (hooks)
  (cl-loop with quoted-p = (eq (car-safe hooks) 'quote)
           for hook in (doom-enlist (doom-unquote hooks))
           if (eq (car-safe hook) 'quote)
            collect (cadr hook)
           else if quoted-p
            collect hook
           else collect (intern (format "%s-hook" (symbol-name hook)))))

(defun doom-unquote (exp)
  "Return EXP unquoted."
  (while (memq (car-safe exp) '(quote function))
    (setq exp (cadr exp)))
  exp)

(defun doom-enlist (exp)
  "Return EXP wrapped in a list, or as-is if already a list."
  (if (listp exp) exp (list exp)))

(defun doom-file-cookie-p (file)
  "Returns the value of the ;;;###if predicate form in FILE."
  (with-temp-buffer
    (insert-file-contents-literally file nil 0 256)
    (if (and (re-search-forward "^;;;###if " nil t)
             (<= (line-number-at-pos) 3))
        (let ((load-file-name file))
          (eval (sexp-at-point)))
      t)))

(defun doom-keyword-intern (str)
  "TODO"
  (intern (concat ":" str)))

(defun doom-keyword-name (keyword)
  "TODO"
  (or (keywordp keyword)
      (signal 'wrong-type-argument (list 'keyword keyword)))
  (substring (symbol-name keyword) 1))

(cl-defun doom-files-in (dirs &key when unless full map (nosort t) (match "^[^.]"))
  "TODO"
  (let ((results (cl-loop for dir in (doom-enlist dirs)
                          if (file-directory-p dir)
                          nconc (directory-files dir full match nosort))))
    (when when
      (cl-delete-if-not when results))
    (when unless
      (cl-delete-if unless results))
    (when map
      (setq results (mapcar map results)))
    results))

(cl-defun doom-files-under (dirs &key include-dirs (match "^[^.]"))
  "Like `directory-files-recursively', but traverses symlinks."
  (cl-letf (((symbol-function #'file-symlink-p) #'ignore))
    (cl-loop for dir in (doom-enlist dirs)
             if (file-directory-p dir)
             nconc (directory-files-recursively dir match include-dirs))))

(defun doom*shut-up (orig-fn &rest args)
  "Generic advisor for silencing noisy functions."
  (quiet! (apply orig-fn args)))


;;
;; Macros
;;

(defmacro λ! (&rest body)
  "A shortcut for inline interactive lambdas."
  (declare (doc-string 1))
  `(lambda () (interactive) ,@body))

(defalias 'lambda! 'λ!)

(defmacro after! (targets &rest body)
  "A smart wrapper around `with-eval-after-load'. Supresses warnings during
compilation."
  (declare (indent defun) (debug t))
  (unless (and (symbolp targets)
               (memq targets doom-disabled-packages))
    (list (if (or (not (bound-and-true-p byte-compile-current-file))
                  (dolist (next (doom-enlist targets))
                    (if (symbolp next)
                        (require next nil :no-error)
                      (load next :no-message :no-error))))
              #'progn
            #'with-no-warnings)
          (cond ((symbolp targets)
                 `(eval-after-load ',targets '(progn ,@body)))
                ((and (consp targets)
                      (memq (car targets) '(:or :any)))
                 `(progn
                    ,@(cl-loop for next in (cdr targets)
                               collect `(after! ,next ,@body))))
                ((and (consp targets)
                      (memq (car targets) '(:and :all)))
                 (dolist (next (cdr targets))
                   (setq body `(after! ,next ,@body)))
                 body)
                ((listp targets)
                 `(after! (:all ,@targets) ,@body))))))

(defmacro quiet! (&rest forms)
  "Run FORMS without making any output."
  `(if doom-debug-mode
       (progn ,@forms)
     (let ((old-fn (symbol-function 'write-region)))
       (cl-letf* ((standard-output (lambda (&rest _)))
                  ((symbol-function 'load-file) (lambda (file) (load file nil t)))
                  ((symbol-function 'message) (lambda (&rest _)))
                  ((symbol-function 'write-region)
                   (lambda (start end filename &optional append visit lockname mustbenew)
                     (unless visit (setq visit 'no-message))
                     (funcall old-fn start end filename append visit lockname mustbenew)))
                  (inhibit-message t)
                  (save-silently t))
         ,@forms))))

(defvar doom--transient-counter 0)
(defmacro add-transient-hook! (hook &rest forms)
  "Attaches transient forms to a HOOK.

This means FORMS will be evaluated once when that function/hook is first
invoked, then never again.

HOOK can be a quoted hook or a sharp-quoted function (which will be advised)."
  (declare (indent 1))
  (let ((append (if (eq (car forms) :after) (pop forms)))
        (fn (intern (format "doom|transient-hook-%s"
                            (if (not (symbolp (car forms)))
                                (cl-incf doom--transient-counter)
                              (pop forms))))))
    `(progn
       (fset ',fn
             (lambda (&rest _)
               ,@forms
               (cond ((functionp ,hook) (advice-remove ,hook #',fn))
                     ((symbolp ,hook)   (remove-hook ,hook #',fn)))
               (unintern ',fn nil)))
       (cond ((functionp ,hook)
              (advice-add ,hook ,(if append :after :before) #',fn))
             ((symbolp ,hook)
              (add-hook ,hook #',fn ,append))))))

(defmacro add-hook! (&rest args)
  "A convenience macro for `add-hook'. Takes, in order:

  1. Optional properties :local and/or :append, which will make the hook
     buffer-local or append to the list of hooks (respectively),
  2. The hooks: either an unquoted major mode, an unquoted list of major-modes,
     a quoted hook variable or a quoted list of hook variables. If unquoted, the
     hooks will be resolved by appending -hook to each symbol.
  3. A function, list of functions, or body forms to be wrapped in a lambda.

Examples:
    (add-hook! 'some-mode-hook 'enable-something)
    (add-hook! some-mode '(enable-something and-another))
    (add-hook! '(one-mode-hook second-mode-hook) 'enable-something)
    (add-hook! (one-mode second-mode) 'enable-something)
    (add-hook! :append (one-mode second-mode) 'enable-something)
    (add-hook! :local (one-mode second-mode) 'enable-something)
    (add-hook! (one-mode second-mode) (setq v 5) (setq a 2))
    (add-hook! :append :local (one-mode second-mode) (setq v 5) (setq a 2))

Body forms can access the hook's arguments through the let-bound variable
`args'."
  (declare (indent defun) (debug t))
  (let ((hook-fn 'add-hook)
        append-p local-p)
    (while (keywordp (car args))
      (pcase (pop args)
        (:append (setq append-p t))
        (:local  (setq local-p t))
        (:remove (setq hook-fn 'remove-hook))))
    (let ((hooks (doom--resolve-hook-forms (pop args)))
          (funcs
           (let ((val (car args)))
             (if (memq (car-safe val) '(quote function))
                 (if (cdr-safe (cadr val))
                     (cadr val)
                   (list (cadr val)))
               (list args))))
          forms)
      (dolist (fn funcs)
        (setq fn (if (symbolp fn)
                     `(function ,fn)
                   `(lambda (&rest _) ,@args)))
        (dolist (hook hooks)
          (push (if (eq hook-fn 'remove-hook)
                    `(remove-hook ',hook ,fn ,local-p)
                  `(add-hook ',hook ,fn ,append-p ,local-p))
                forms)))
      `(progn ,@forms))))

(defmacro remove-hook! (&rest args)
  "Convenience macro for `remove-hook'. Takes the same arguments as
`add-hook!'."
  (declare (indent defun) (debug t))
  `(add-hook! :remove ,@args))

(defmacro setq-hook! (hooks &rest rest)
  "Convenience macro for setting buffer-local variables in a hook.

  (setq-hook! 'markdown-mode-hook
    line-spacing 2
    fill-column 80)"
  (declare (indent 1))
  (unless (= 0 (% (length rest) 2))
    (signal 'wrong-number-of-arguments (length rest)))
  `(add-hook! ,hooks
     ,@(let (forms)
         (while rest
           (let ((var (pop rest))
                 (val (pop rest)))
             (push `(setq-local ,var ,val) forms)))
         (nreverse forms))))

(defmacro associate! (mode &rest plist)
  "Associate a minor mode to certain patterns and project files."
  (declare (indent 1))
  (unless noninteractive
    (let ((modes (plist-get plist :modes))
          (match (plist-get plist :match))
          (files (plist-get plist :files))
          (pred-form (plist-get plist :when)))
      (cond ((or files modes pred-form)
             (when (and files
                        (not (or (listp files)
                                 (stringp files))))
               (user-error "associate! :files expects a string or list of strings"))
             (let ((hook-name (intern (format "doom--init-mode-%s" mode))))
               `(progn
                  (defun ,hook-name ()
                    (when (and (fboundp ',mode)
                               (not ,mode)
                               (and buffer-file-name (not (file-remote-p buffer-file-name)))
                               ,(if match `(if buffer-file-name (string-match-p ,match buffer-file-name)) t)
                               ,(if files (doom--resolve-path-forms files) t)
                               ,(or pred-form t))
                      (,mode 1)))
                  ,@(if (and modes (listp modes))
                        (cl-loop for hook in (doom--resolve-hook-forms modes)
                                 collect `(add-hook ',hook #',hook-name))
                      `((add-hook 'after-change-major-mode-hook ',hook-name))))))
            (match
             `(map-put doom-auto-minor-mode-alist ,match ',mode))
            (t (user-error "associate! invalid rules for mode [%s] (modes %s) (match %s) (files %s)"
                           mode modes match files))))))

(provide 'core-lib)
;;; core-lib.el ends here
