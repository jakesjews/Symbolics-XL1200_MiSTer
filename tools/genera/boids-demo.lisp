;;; -*- Mode: LISP; Syntax: Zetalisp; Package: BOIDS; Base: 10 -*-
;;;
;;; Craig Reynolds' Boids (boids.lisp, version 2, 1988) in the animation world
;;; (Genera 8.1.1, S-Geometry).  Load it after boids.lisp:
;;;
;;;   Compile File FEP7:>boids.lisp
;;;   Load File FEP7:>boids.ibin
;;;   Load File FEP7:>boids-demo.lisp
;;;
;;; then in S-Geometry's Lisp listener (Select G):  (boids:demo)
;;; Any key stops the flock; (boids:demo :population 44) is Reynolds' default.
;;;
;;; Boids reads its bird from W:>cwr>Boids>Very-low-res-boid, a model on
;;; Reynolds' file server that didn't survive.  The stand-in is a delta wing
;;; one unit long (his obstacles allow half a body length of clearance), nose
;;; on +Z with Y up, as :FLY moves a boid.  The flock flies Reynolds'
;;; WANDER-INSIDE-SPHERE-SETUP, kept inside his 19-unit sphere obstacle.

(defun STAND-IN-BOID-BODY ()
  (or (ignore-errors
	(3d:make-lamina '((0.0 0.0 0.5) (0.3 0.0 -0.5) (-0.3 0.0 -0.5))))
      (3d:make-tetrahedron 0.5)))

;;; As DEFAULT-BOID-TEMPLATE does with the object it reads: in the global
;;; object list, invisible, a copy made a BOID.
(defun MAKE-STAND-IN-BOID-TEMPLATE ()
  (let ((object (make-instance '3d:object :name "boid" :body (stand-in-boid-body))))
    (3d:add-object-to-view object)
    (send object :make-invisible)
    (change-instance-flavor (send object :copy-self) 'boid)))

(defun DEMO (&key (population 20) (obstacles *wander-inside-sphere-obstacle*))
  (unless *default-boid-template*
    (setq *default-boid-template* (make-stand-in-boid-template)))
  (let ((flock (make-flock :menu nil :population population
			   :flock-recording-mode :record :make-visible t)))
    (setq *default-flock* flock)
    ;; WANDER-INSIDE-SPHERE-SETUP without its FIND-FLOCK menu
    (let* ((outer-radius (* 2.2 (radius-for-spherical-flock flock)))
	   (inner-radius (* 0.8 outer-radius))
	   (center-y (- outer-radius (send (first obstacles) :radius))))
      (send flock :initialize-members
	    :move (list 0 center-y 0)
	    :randomize-radius-min inner-radius
	    :randomize-radius-max outer-radius
	    :randomize-yaw-max 360
	    :randomize-pitch-min -10 :randomize-pitch-max 10
	    :randomize-max-speed-min 0.47 :randomize-max-speed-max 0.53
	    :randomize-speed-min 0 :randomize-speed-max 0.6))
    (send flock :make-visible)
    (let ((*environmental-obstacles* obstacles))
      (flock-test flock))))
