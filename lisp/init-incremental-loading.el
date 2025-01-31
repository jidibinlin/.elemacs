;; init-incremental-loading.el --- Initialize incremental-loading configurations.	-*- lexical-binding: t -*-

;; Copyright (C) 2019-2021 by Eli

;; Author: Eli <eli.q.qian@gmail.com>
;; URL: https://github.com/Elilif/.emacs.d

;; This file is not part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth
;; Floor, Boston, MA 02110-1301, USA.
;;

;;; Commentary:
;;
;;
;;

;;; Code:

(defvar elemacs-incremental-packages '(t)
  "A list of packages to load incrementally after startup. Any large packages
  here may cause noticeable pauses, so it's recommended you break them up into
  sub-packages. For example, `org' is comprised of many packages, and can be
  broken up into:

    (elemacs-load-packages-incrementally
     \='(calendar find-func format-spec org-macs org-compat
       org-faces org-entities org-list org-pcomplete org-src
       org-footnote org-macro ob org org-clock org-agenda
       org-capture))

  Incremental loading does not occur in daemon sessions (they are
  loaded immediately at startup).")

(defvar elemacs-incremental-first-idle-timer (if (daemonp) 0 0.5)
  "How long (in idle seconds) until incremental loading starts.

 Set this to nil to disable incremental loading. Set this to 0 to
load all incrementally deferred packages immediately at
`emacs-startup-hook'.")

(defvar elemacs-incremental-idle-timer 0.5
  "How long (in idle seconds) in between incrementally loading packages.")

(defun elemacs-load-packages-incrementally (packages &optional now)
  "Registers PACKAGES to be loaded incrementally.

If NOW is non-nil, load PACKAGES incrementally,
in `elemacs-incremental-idle-timer' intervals."
  (let ((gc-cons-threshold most-positive-fixnum))
    (if (not now)
        (cl-callf append elemacs-incremental-packages packages)
      (while packages
        (let ((req (pop packages)))
          (condition-case-unless-debug e
              (or (not
                   (while-no-input
                     ;; (message "Loading %s (%d left)" req (length packages))
                     ;; If `default-directory' doesn't exist or is
                     ;; unreadable, Emacs throws file errors.
                     (let ((default-directory user-emacs-directory)
                           (inhibit-message t)
                           (file-name-handler-alist
                            (list (rassq 'jka-compr-handler file-name-handler-alist))))
                       (require req nil t)
                       nil)))
                  (push req packages))
            (error
             (message "Error: failed to incrementally load %S because: %s" req e)
             (setq packages nil)))
          (if (null packages)
              (message "Incrementally loading finished!")
            (run-with-idle-timer elemacs-incremental-idle-timer
                                 nil #'elemacs-load-packages-incrementally
                                 packages t)
            (setq packages nil)))))))

(defun elemacs-load-packages-incrementally-h ()
  "Begin incrementally loading packages in `elemacs-incremental-packages'.

If this is a daemon session, load them all immediately instead."
  (when (numberp elemacs-incremental-first-idle-timer)
    (if (zerop elemacs-incremental-first-idle-timer)
        (mapc #'require (cdr elemacs-incremental-packages))
      (run-with-idle-timer elemacs-incremental-first-idle-timer
                           nil #'elemacs-load-packages-incrementally
                           (cdr elemacs-incremental-packages) t))))

(add-hook 'emacs-startup-hook #'elemacs-load-packages-incrementally-h)

(elemacs-load-packages-incrementally
 '(borg init-hydra calendar find-func format-spec org-macs org-compat
	    org-faces org-entities org-list org-pcomplete org-src
	    org-footnote org-macro ob org org-clock org-agenda
	    org-capture dired-x ispell all-the-icons mu4e embark emms-setup org-roam
        tex-site texmath))

;; pdf
(elemacs-load-packages-incrementally
 '(image-mode pdf-macs pdf-util pdf-info pdf-cache jka-compr
              pdf-view pdf-annot pdf-tools pdf-occur org-noter org-refile))

;; vc
(elemacs-load-packages-incrementally
 '(dash f s with-editor package eieio transient git-commit))

(defvar elemacs-first-input-hook nil
  "Transient hooks run before the first user input.")
(put 'elemacs-first-input-hook 'permanent-local t)

(defvar elemacs-first-buffer-hook nil
  "Transient hooks run before the first interactively opened file.")
(put 'elemacs-first-file-hook 'permanent-local t)

(defvar elemacs-first-buffer-hook nil
  "Transient hooks run before the first interactively opened buffer.")
(put 'elemacs-first-buffer-hook 'permanent-local t)

(defvar elemacs-switch-buffer-hook nil
  "A list of hooks run after changing the current buffer.")

(define-error 'elemacs-error "Error in  Elemacs")
(define-error 'elemacs-hook-error "Error in a Elemacs startup hook" 'elemacs-error)

(defun elemacs-run-hook (hook)
  "Run HOOK (a hook function) with better error handling.
Meant to be used with `run-hook-wrapped'."
  (condition-case-unless-debug e
      (funcall hook)
    (error
     (signal 'elemacs-hook-error (list hook e))))
  ;; return nil so `run-hook-wrapped' won't short circuit
  nil)

(defun elemacs-run-hooks (&rest hooks)
  "Run HOOKS (a list of hook variable symbols) with better error handling.
Is used as advice to replace `run-hooks'."
  (dolist (hook hooks)
    (condition-case-unless-debug e
        (run-hook-wrapped hook #'elemacs-run-hook)
      (elemacs-hook-error
       (unless debug-on-error
         (lwarn hook :error "Error running hook %S because: %s"
                (if (symbolp (cadr e))
                    (symbol-name (cadr e))
                  (cadr e))
                (caddr e)))
       (signal 'elemacs-hook-error (cons hook (cdr e)))))))

(defun elemacs-run-hook-on (hook-var trigger-hooks)
  "Configure HOOK-VAR to be invoked exactly once when any of the TRIGGER-HOOKS
are invoked *after* Emacs has initialized (to reduce false positives). Once
HOOK-VAR is triggered, it is reset to nil.

HOOK-VAR is a quoted hook.
TRIGGER-HOOK is a list of quoted hooks and/or sharp-quoted functions."
  (dolist (hook trigger-hooks)
    (let ((fn (make-symbol (format "%s-init-on-%s-h" hook-var hook)))
          running-p)
      (fset
       fn (lambda (&rest _)
            ;; Only trigger this after Emacs has initialized.
            (when (and after-init-time
                       (not running-p)
                       (or (daemonp)
                           ;; In some cases, hooks may be lexically unset to
                           ;; inhibit them during expensive batch operations on
                           ;; buffers (such as when processing buffers
                           ;; internally). In these cases we should assume this
                           ;; hook wasn't invoked interactively.
                           (and (boundp hook)
                                (symbol-value hook))))
              (setq running-p t)
              (elemacs-run-hooks hook-var)
              (set hook-var nil))))
      (cond ((daemonp)
             ;; In a daemon session we don't need all these lazy loading
             ;; shenanigans. Just load everything immediately.
             (add-hook 'after-init-hook fn 'append))
            ((eq hook 'find-file-hook)
             ;; Advise `after-find-file' instead of using `find-file-hook'
             ;; because the latter is triggered too late (after the file has
             ;; opened and modes are all set up).
             (advice-add 'after-find-file :before fn '((depth . -101))))
            ((add-hook hook fn -101)))
      fn)))

(elemacs-run-hook-on 'elemacs-first-buffer-hook '(find-file-hook elemacs-switch-buffer-hook))
(elemacs-run-hook-on 'elemacs-first-file-hook   '(find-file-hook dired-initial-position-hook))
(elemacs-run-hook-on 'elemacs-first-input-hook  '(pre-command-hook))

(provide 'init-incremental-loading)
;;; init-incremental-loading.el ends here.
