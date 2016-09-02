#|
 This file is a part of Qtools
 (c) 2015 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.qtools.libs.generator)

(defvar *max-cpus* most-positive-fixnum)

(defun externalize (thing)
  (typecase thing
    (list (mapcar #'externalize thing))
    (string thing)
    (pathname (uiop:native-namestring thing))
    (T (princ-to-string thing))))

(defun status (n string &rest format-args)
  (format T "~&~a ~a~%"
          (case n (0 ">") (1 " ->") (2 " ==>") (T "  >>>"))
          (apply #'format NIL string format-args)))

(defun run-here (string &rest format-args)
  (let ((program (apply #'format NIL string (mapcar #'externalize format-args))))
    (status 1 "Running ~a" program)
    (let ((status (nth-value 2 (uiop:run-program program :output T :error-output T :ignore-error-status T))))
      (unless (= 0 status)
        (error "Running the external program~%  ~a~%failed with return code ~a."
               program status)))))

(defun ensure-system (system &optional (package system))
  (unless (find-package package)
    (let (#+sbcl (sb-ext:*muffled-warnings* 'style-warning))
      #-quicklisp (asdf:load-system system)
      #+quicklisp (ql:quickload system))))

(defun application-available-p (&rest alternatives)
  (zerop (nth-value 2 (uiop:run-program (format NIL "~{command -v ~s~^ || ~}" alternatives) :ignore-error-status T))))

(defun check-prerequisite (name &rest alternatives)
  (with-simple-restart (continue "I know what I'm doing, skip this test.")
    (loop until (if (apply #'application-available-p alternatives)
                    T
                    (with-simple-restart (retry "I installed it now, test again.")
                      (error "~a is required, but could not be found. Please ensure it is installed properly." name))))))

(defun cpu-count ()
  (min (or (parse-integer (uiop:run-program "nproc" :ignore-error-status T :output :string) :junk-allowed T)
           2)
       *max-cpus*))

(defun check-file-exists (file)
  (unless (probe-file file)
    (error "The file is required but does not exist:~%  ~s" file)))

(defmacro with-retry-restart ((name report &rest report-args) &body body)
  (let ((tag (gensym "RETRY-TAG"))
        (return (gensym "RETURN"))
        (stream (gensym "STREAM")))
    `(block ,return
       (tagbody
          ,tag (restart-case
                   (return-from ,return
                     (progn ,@body))
                 (,name ()
                   :report (lambda (,stream) (format ,stream ,report ,@report-args))
                   (go ,tag)))))))

(defun qt-libs-cache-directory ()
  (uiop:pathname-directory-pathname
   (asdf:output-file 'asdf:compile-op (asdf:find-component (asdf:find-system :qt-libs) "qt-libs"))))

(defun platform ()
  #+windows :win
  #+linux :lin
  #+darwin :mac
  #-(or windows linux darwin)
  (error "This platform is unsupported."))

(defun arch ()
  #+x86-64 :64
  #+x86 :32
  #-(or x86-64 x86)
  (error "This architecture is unsupported."))

(defmacro with-chdir ((to) &body body)
  (let ((current (gensym "CURRENT")))
    `(let ((,current (uiop:getcwd)))
       (unwind-protect
            (progn
              (uiop:chdir
               (uiop:pathname-directory-pathname
                (ensure-directories-exist ,to)))
              ,@body)
         (uiop:chdir ,current)))))

(defun copy-directory-files (dir to &key replace)
  (dolist (file (uiop:directory* (merge-pathnames uiop:*wild-file* dir)))
    (copy-file file to :replace replace)))

(defun copy-file (file to &key replace)
  (cond ((uiop:directory-pathname-p file)
         (let ((to (subdirectory to (directory-name file))))
           (ensure-directories-exist to)
           (copy-directory-files file to)))
        (T
         (let ((to (make-pathname :name (pathname-name file)
                                  :type (pathname-type file)
                                  :defaults to)))
           (when (or replace (not (uiop:file-exists-p to)))
             (uiop:copy-file file to))))))

(defun shared-library-file (&rest args &key host device directory name version defaults)
  (declare (ignore host device directory version))
  (apply #'make-pathname :type #+windows "dll" #+darwin "dylib" #-(or windows darwin) "so"
                         :name (or (and name #-windows (concatenate 'string "lib" name))
                                   (pathname-name defaults))
                         args))

(defun make-shared-library-files (names defaults &key (key #'identity))
  (loop for name in names
        append (loop for default in (if (listp defaults) defaults (list defaults))
                     for file = (first (or (uiop:directory* (funcall key (shared-library-file :name name :defaults default)))
                                           #+(or osx-brew osx-fink) (uiop:directory* (funcall key (merge-pathnames name default)))))
                     when (uiop:file-exists-p file)
                     collect file)))

(defun determine-shared-library-type (pathname)
  (cond ((search ".so." (pathname-name pathname))
         "so")
        (T (or (pathname-type pathname)
               #+darwin "dylib"
               #+unix "so"
               #+windows "dll"))))

(defun determine-shared-library-name (pathname)
  (cond ((search ".so." (pathname-name pathname))
         (subseq (pathname-name pathname) 0 (search ".so." (pathname-name pathname))))
        (T
         (or (cl-ppcre:register-groups-bind (name) ("^(.+)\\.\\d\\.\\d\\.\\d$" (pathname-name pathname)) name)
             (cl-ppcre:register-groups-bind (NIL name) ("^(lib)?(.+)$" (pathname-name pathname))
               #+windows name #-windows (concatenate 'string "lib" name))))))

(defun checksum-string (vector)
  (with-output-to-string (*standard-output*)
    (map NIL (lambda (c) (write c :base 36)) vector)))

(defun checksum-file (target)
  (ensure-system :sha3)
  (funcall (find-symbol (string :sha3-digest-file) :sha3) target))

(defun download-file (url target)
  (status 1 "Downloading ~a to ~a" url (uiop:native-namestring target))
  (ensure-system :drakma)
  (with-open-file (output target :direction :output
                                 :if-exists :supersede
                                 :if-does-not-exist :create
                                 :element-type '(unsigned-byte 8))
    (multiple-value-bind (input status) (funcall (find-symbol (string :http-request) :drakma) url :want-stream T)
      (unwind-protect
           (progn
             (unless (= status 200)
               (error "Bad status code: ~s" status))
             (loop for byte = (read-byte input NIL NIL)
                   while byte
                   do (write-byte byte output)))
        (close input))))
  target)

(defun extract-archive (from to &key (strip-folder))
  (ensure-system :zip)
  (funcall (find-symbol (string :unzip) :zip) from to)
  (when strip-folder
    (let ((sub (first (uiop:subdirectories to))))
      (dolist (file (append (uiop:directory-files sub) (uiop:subdirectories sub)))
        (rename-file file (upwards file)))
      (uiop:delete-file-if-exists sub)))
  to)

(defun check-checksum (file checksum)
  (let ((received (checksum-file file)))
    (unless (equalp received checksum)
      (cerror "I am sure that this is fine."
              "SHA3 file mismatch for ~s!~
             ~&Expected ~a~
             ~&Got      ~a"
              file (checksum-string checksum) (checksum-string received)))))

(defun setenv (envvar new-value)
  #+sbcl (sb-posix:setenv envvar new-value 1)
  #+ccl (ccl:setenv envvar new-value T)
  #+ecl (ext:setenv envvar new-value)
  #-(or sbcl ccl ecl) (warn "Don't know how to perform SETENV.~
                           ~&Please set the environment variable ~s to ~s to ensure proper operation."
                            envvar new-value)
  new-value)

(defun get-path (&optional (envvar "PATH"))
  (cl-ppcre:split #+windows ";+" #-windows ":+" (uiop:getenv envvar)))

(defun set-path (paths &optional (envvar "PATH"))
  (setenv envvar (etypecase paths
                   (string paths)
                   (list (format NIL (load-time-value (format NIL "~~{~~a~~^~a~~}" #+windows ";" #-windows ":")) paths)))))

(defun pushnew-path (path &optional (envvar "PATH"))
  (let ((path (etypecase path
                (pathname (uiop:native-namestring path))
                (string path)))
        (paths (get-path envvar)))
    (pushnew path paths :test #'string=)
    (set-path paths envvar)))
