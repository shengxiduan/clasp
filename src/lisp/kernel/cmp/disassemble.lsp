;;;
;;;    File: disassemble.lsp
;;;

;; Copyright (c) 2014, Christian E. Schafmeister
;;
;; CLASP is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Library General Public
;; License as published by the Free Software Foundation; either
;; version 2 of the License, or (at your option) any later version.
;;
;; See directory 'clasp/licenses' for full details.
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;; THE SOFTWARE.

;; -^-

;;
(in-package :cmp)

(defun safe-llvm-get-name (what)
  (llvm-sys:get-name what))

#+(or)
(defun disassemble-assembly-for-llvm-functions (llvm-function-list)
  "Given a list of llvm::Functions that were JITted - generate disassembly for them.
Return T if disassembly was achieved - otherwise NIL"
  (bformat t "There are %d associated functions - disassembling them.%N" (length llvm-function-list))
  (let ((success nil))
    (dolist (llvm-func llvm-function-list)
      (bformat t "%N%s-----%N" (safe-llvm-get-name llvm-func))
      (let* ((llvm-function-name (bformat nil "_%s" (safe-llvm-get-name llvm-func)))
             (symbol-info (gethash llvm-function-name *jit-saved-symbol-info*)))
        (if symbol-info
            (let ((bytes (first symbol-info))
                  (address (second symbol-info)))
              (llvm-sys:disassemble-instructions (get-builtin-target-triple-and-data-layout)
                                                 
                                                 address
                                                 :start-byte-offset 09
                                                 :end-byte-offset bytes)
              (setf success t))
            (progn
              (bformat t "Could not disassemble associated function%N")))))
    success))

(defun disassemble-assembly (start end)
  (format t "disassemble-assembly ~s ~s~%" start end)
  (llvm-sys:disassemble-instructions (get-builtin-target-triple-and-data-layout)
                                     start end))

(defun disassemble-from-address (address &key (start-instruction-index 0) (num-instructions 16)
                                           start-byte-offset end-byte-offset)
  (llvm-sys:disassemble-instructions (get-builtin-target-triple-and-data-layout)
                                     address
                                     :start-instruction-index start-instruction-index
                                     :num-instructions num-instructions
                                     :start-byte-offset start-byte-offset
                                     :end-byte-offset end-byte-offset))

(defun disassemble (desig &key (type :asm))
  "If type is :ASM then disassemble to assembly language from the START instruction, disassembling NUM instructions
   if type is :IR then dump the llvm-ir for all of the associated functions and ignore START and NUM"
  (check-type type (member :ir :asm))
  (multiple-value-bind (func-or-lambda name)
      (cond
        ((null desig) (error 'type-error :datum desig :expected-type '(or symbol function (CONS (EQL SETF) (CONS SYMBOL NULL)))))
        ((symbolp desig) (if (fboundp desig)
                             (values (fdefinition desig) desig)
                             (error "No function bound to ~A" desig)))
        ((functionp desig) (multiple-value-bind (fn-lambda closurep name)
                               (function-lambda-expression desig)
                             (values desig name)))
        ((and (consp desig) (eq (car desig) 'lambda))
         (let* ((*save-module-for-disassemble* t)
                (cmp:*saved-module-from-clasp-jit* nil))
           (compile nil desig)
           (let ((module cmp:*saved-module-from-clasp-jit*))
             (if module
                 (cond
                   ((eq type :ir) (llvm-sys:dump-module module))
                   ((eq type :asm) (warn "Handle disassemble of lambda-form to assembly"))
                   (t (error 'type-error :datum type :expected-type '(or :ir :asm))))
                 (error "Could not recover jitted module -> ~a" module))))
         (return-from disassemble nil))
         ;; treat setf functions
         ((and (consp desig) (eq (car desig) 'setf)(fdefinition desig))
         (values (fdefinition desig) desig))
        (t (error 'type-error :datum desig :expected-type '(or symbol function (CONS (EQL SETF) (CONS SYMBOL NULL))))))
    (setq name (if name name 'lambda))
    (bformat t "Disassembling function: %s%N" (repr func-or-lambda))
    (cond
      ((functionp func-or-lambda)
       (let ((fn func-or-lambda))
         (cond
           ((compiled-function-p fn)
            (if (eq type :asm)
                (multiple-value-bind (symbol start end type)
                    (core:lookup-address (core:function-pointer fn))
                  (disassemble-assembly start end)
                  (bformat t "Done%N"))
                (error "LLVM-IR is not saved for functions - use :type :asm to disassemble to native code")))
           ((interpreted-function-p fn)
            (format t "This is a interpreted function - compile it first~%")
	        (error 'type-error :datum fn :expected-type '(or symbol function (CONS (EQL SETF) (CONS SYMBOL NULL)))))
           ((eq type :asm)
	        ;;; How is it possible to come to this branch
            (llvm-sys:disassemble-instructions (get-builtin-target-triple-and-data-layout) (core:function-pointer fn)))
           (t (error 'type-error :datum fn :expected-type '(or symbol function (CONS (EQL SETF) (CONS SYMBOL NULL))))))))
      (t (error 'type-error :datum func-or-lambda :expected-type '(or symbol function (CONS (EQL SETF) (CONS SYMBOL NULL)))))))
  nil)
