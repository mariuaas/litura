;;; Common Lisp: defmacro, loop, format, reader syntax. Ünïcode ✓
(defpackage :demo (:use :cl) (:export #:area))
(in-package :demo)

#| block comment #| nested |# ends here |#
(defstruct point (x 0 :type integer) (y 0 :type integer))

(defgeneric area (shape))
(defmethod area ((shape (eql :unit))) 1)

(defmacro with-twice ((var form) &body body)
  `(let ((,var (* 2 ,form)))
     ,@body))

(defun walk (tree &key (depth 0) (visit #'print))
  (cond ((null tree) nil)
        ((atom tree) (funcall visit (list depth tree)))
        (t (walk (car tree) :depth (1+ depth) :visit visit)
           (walk (cdr tree) :depth depth :visit visit))))

(defun main ()
  (let ((p (make-point :x 1 :y 2))
        (chars (list #\a #\Space #\Newline))
        (ratio 3/4)
        (vec #(1 2 3)))
    (with-twice (n (point-x p))
      (loop for i from 0 below n
            collect (* i i) into squares
            finally (format t "~a ~a ~a ~s~%" squares ratio chars "ünïcode")))
    (walk '(1 (2 3) . 4))
    (values vec (area :unit))))
