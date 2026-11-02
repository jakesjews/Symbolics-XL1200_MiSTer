;;; -*- Mode: LISP; Syntax: Zetalisp; Package: COLOR; Base: 10; Lowercase: Yes -*-
;;;
;;; The MiSTer XL1200 core's color screen: a Univision UDC-3400 on the
;;; VMEbus, shown on the console's 1152 x 880 raster (docs/color.md in the
;;; core's repository).
;;;
;;; With the Color system loaded (Load System Color), Load File this, then
;;;   (color:make-mister-color-screen)
;;; Function-X moves the mouse between the screens.  Save World keeps the
;;; screen for the next boot.

;; The board shows the console's raster, not the 1280 x 1024 its driver
;; assumes.
(putprop 'sync-programs
	 (make-sync-format hardware-type :univision
			   interlace? nil
			   number-of-lines 880.
			   pixels-per-line 1152.
			   pixel-width 0
			   pixel-aspect-ratio 1.0)
	 'tv:univision-mister-sync)

(defun make-mister-color-screen (&rest keys)
  "Make the Univision color screen on the MiSTer's raster.  The board's
82786 graphics coprocessor isn't there, so Genera draws into the frame
buffer itself (remote drawing off)."
  (let ((screen (lexpr-funcall #'make-color-screen
			       :setup :univision
			       :sync-program 'tv:univision-mister-sync
			       :property-list '(:turn-on-video-for-mouse t)
			       :expose-p nil
			       keys)))
    (send screen :set-remote-drawing-enabled nil)
    (send screen :expose)
    screen))
