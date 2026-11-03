;;; -*- Mode: LISP; Syntax: Common-Lisp; Package: CL-USER; Base: 10 -*-
;;;
;;; The Lisp-Machine user's init file, XL1200:>lispm>lispm-init.lisp on the
;;; prebuilt disk; Login loads it.  It makes the MiSTer core's color screen
;;; once per boot (color:make-mister-color-screen, in the fat world), so the
;;; System Menu's color programs have a screen to draw on.  The core's
;;; Display option, or Pause, shows it.

(defvar *color-screen* nil
  "The color screen this file made at the first Login since the boot.")

(unless *color-screen*
  (setq *color-screen*
	(conditions:handler-case (color:make-mister-color-screen)
	  (error (e)
	    (format t "~&No color screen made: ~A~%" e)
	    nil))))
