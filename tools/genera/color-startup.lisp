;;; -*- Mode: LISP; Syntax: Common-Lisp; Package: CL-USER; Base: 10 -*-
;;;
;;; The animation world's color screen: load after FEP7:>mister-color.lisp.
;;; Makes the MiSTer core's Univision color screen now and at every boot
;;; (a warm initialization), so the core's Display option or Pause shows it.

(defvar *color-screen* nil
  "The color screen made at this boot.")

(defun make-color-screen-at-boot ()
  (setq *color-screen*
	(conditions:handler-case (color::make-mister-color-screen)
	  (error (e)
	    (format t "~&No color screen made: ~A~%" e)
	    nil))))

(si:add-initialization "MiSTer color screen" '(make-color-screen-at-boot) '(:warm))

(make-color-screen-at-boot)
