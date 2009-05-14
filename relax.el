;;; relax.el --- For browsing and interacting with CouchDB

;; Copyright (C) 2009 Phil Hagelberg
;;
;; Author: Phil Hagelberg
;; URL: http://github.com/technomancy/relax.el
;; Version: 0.1
;; Keywords: database http
;; Created: 2009-05-11
;; Package-Requires: ((json "1.2") (javascript "1.99.8"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Interact with CouchDB databases from within Emacs, with ease!

;; Needs the json.el package, which comes with Emacs 23, but is also
;; available from ELPA or from http://edward.oconnor.cx/elisp/json.el

;; javascript.el is also required. Get it from
;; http://www.brgeight.se/downloads/emacs/javascript.el and replace
;; (provide 'javascript-mode) with (provide 'javascript)

;;; TODO:

;; All kinds of things:
;; * attachment handling
;; * pagination
;; * hide _rev and _id fields?
;; * error handling
;; * fix provide line of javascript.el or switch to espresso.el

;;; License:

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.
;; 
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; 
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Code:

(require 'thingatpt)
(require 'url)
(require 'json)
(require 'javascript)
(require 'mm-util) ;; for replace-regexp-in-string

(defvar relax-host "127.0.0.1")
(defvar relax-port 5984)
(defvar relax-db-path "")

;;; Utilities

(defun relax-url (&optional id)
  "Return a URL for the given id using relax- host, port, and db-path."
  ;; remove double slashes that sneak in
  (replace-regexp-in-string "\\([^:]\\)//*" "\\1/"
                            (format "http://%s:%s/%s/%s"
                                    relax-host (number-to-string relax-port)
                                    relax-db-path (or id ""))))

(defun relax-trim-headers ()
  "Remove HTTP headers from the current buffer."
  (goto-char (point-min))
  (search-forward "\n\n")
  (delete-region (point-min) (point)))

(defun relax-json-encode (obj)
  (let ((json-array-type 'list)
        (json-object-type 'plist))
    (json-encode obj)))

(defun relax-json-decode (str)
  (let ((json-array-type 'list)
        (json-object-type 'plist))
    (json-read-from-string str)))

(defun relax-load-json-buffer (json-buffer)
  (with-current-buffer json-buffer
    (relax-json-decode
     (buffer-substring (point-min) (point-max)))))

(defun relax-kill-http-buffer ()
  (kill-buffer http-buffer))

(defun relax-kill-document (doc rev &optional callback)
  (let ((url-request-method "DELETE")
        (url (concat (relax-url doc) "?rev=" rev)))
    (url-retrieve url (or callback 'message))))

(defun relax-parse-db-line ()
  "Return the id and rev of the document at point."
  (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
    (unless (string-match "\\[\\(.*\\) @rev \\(.*\\)\\]" line)
      (error "Not on a document line"))
    (list (match-string 1 line) (match-string 2 line))))

;;; DB-level

(defvar relax-mode-hook nil)

(defvar relax-mode-map (let ((map (make-sparse-keymap)))
                         (define-key map (kbd "RET") 'relax-doc)
                         (define-key map (kbd "C-o") 'relax-new-doc)
                         (define-key map (kbd "g") 'relax-update-db)

                         (define-key map (kbd "SPC") 'scroll-down)
                         (define-key map (kbd "<backspace>") 'scroll-up)
                         (define-key map "q" 'quit-window)
                         (define-key map (kbd "C-k") 'relax-kill-doc-from-db)
                         ;; (define-key map "[" 'relax-prev-page)
                         ;; (define-key map "]" 'relax-next-page)
                         map))

(defun relax-url-completions ()
  "A list of all DB URLs at the server given by relax-host:relax-port."
  (mapcar (lambda (db-name) (let ((relax-db-path ""))
                         (relax-url db-name)))
          (with-current-buffer (url-retrieve-synchronously
                                (let ((relax-db-path ""))
                                  (relax-url "_all_dbs")))
            (relax-trim-headers)
            (relax-json-decode (buffer-substring (point-min) (point-max))))))

(defun relax (db-url)
  "Connect to the CouchDB database at db-url."
  (interactive (list (completing-read "CouchDB URL: " (relax-url-completions)
                                      nil nil (relax-url))))
  (let ((url (url-generic-parse-url db-url)))
    (setq relax-host (url-host url)
          relax-port (url-port url)
          relax-db-path (url-filename url)))
  (if (boundp 'doc-list) ;; buffer has been initialized; needs refresh
        (relax-update-db)
      (url-retrieve (relax-url "_all_docs") 'relax-mode (list db-url))))

(defun relax-mode (status database-url)
  "Major mode for interacting with CouchDB databases."
  (let ((json-buffer (current-buffer)))
    (relax-trim-headers)
    (switch-to-buffer (concat "*relax " database-url "*"))
    (buffer-disable-undo)
    (kill-all-local-variables)

    (set (make-local-variable 'http-buffer) json-buffer)
    (set (make-local-variable 'kill-buffer-hook) '(relax-kill-http-buffer))
    (set (make-local-variable 'db-url) database-url)
    (set (make-local-variable 'doc-list)
         (relax-load-json-buffer json-buffer)))

  (use-local-map relax-mode-map)
  (setq mode-name "relax")
  (setq major-mode 'relax-mode)

  (insert "== " db-url "\n")
  (insert (format "Total: %s, offset %s\n\n"
                  (getf doc-list :total_rows)
                  (getf doc-list :offset)))
  (relax-insert-doc-list (getf doc-list :rows))
  (setq buffer-read-only t)

  (run-hooks 'relax-mode-hook))

(defun relax-insert-doc-list (docs)
  "Given a list of documents, insert them into the buffer."
  (dolist (doc docs)
    ;; If this changes, change relax-parse-db-line to match.
    (insert (format "  [%s @rev %s]\n" (getf doc :id) (getf (getf doc :value) :rev)))))

(defun relax-new-doc (choose-id)
  "Create a new document. With prefix arg, prompt for a document ID."
  (interactive "P")
  (let ((url-request-method (if choose-id "PUT" "POST"))
        (url-request-data "{}")
        (id (if choose-id (read-from-minibuffer "Document ID: "))))
    (url-retrieve (relax-url id) 'relax-visit-new-doc)))

(defun relax-visit-new-doc (status)
  "Open a buffer for a newly-created document. Used as a callback."
  (goto-char (point-min))
  (search-forward "Location: ")
  (let ((doc-url (buffer-substring (point) (progn (end-of-line) (point)))))
    (url-retrieve doc-url 'relax-doc-load (list doc-url))))

(defun relax-update-db ()
  "Update the DB buffer with the current document list."
  (interactive)
  (setq buffer-read-only nil)
  (delete-region (point-min) (point-max))
  (url-retrieve (relax-url "_all_docs") 'relax-mode (list db-url)))

(defun relax-kill-doc-from-db ()
  "Issue a delete for the document under point."
  (interactive)
  (apply 'relax-kill-document (append (relax-parse-db-line)
                                      '(relax-update-db))))

;;; Document-level

(defvar relax-doc-mode-hook nil)

(defvar relax-doc-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x C-s") 'relax-submit)
    (define-key map (kbd "C-c C-u") 'relax-update-doc)
    (define-key map (kbd "C-c C-k") 'relax-kill-doc)
    map))

(defun relax-doc-load (status document-url)
  "Create and switch to a buffer for a newly-retrieved document."
  (let ((json-buffer (current-buffer)))
    (relax-trim-headers)
    (let ((doc-string (buffer-substring-no-properties (point-min) (point-max))))
      (switch-to-buffer (concat "*relax " document-url "*"))

      (javascript-mode)
      (relax-doc-mode t)
      (set (make-local-variable 'http-buffer) json-buffer)
      (set (make-local-variable 'kill-buffer-hook) '(relax-kill-http-buffer))
      (set (make-local-variable 'doc-url) document-url)
      (set (make-local-variable 'doc)
           (relax-load-json-buffer json-buffer))
      (insert doc-string)))

  (save-excursion ;; prettify
    (goto-char (point-min))
    (replace-string "\",\"" "\",\n\"")
    (indent-region (point-min) (point-max))
    (font-lock-fontify-buffer))
  (message "Loaded %s" doc-url))

(define-minor-mode relax-doc-mode
  "Minor mode for interacting with CouchDB documents."
  nil
  "relax doc")

(defun relax-doc ()
  "Open a buffer viewing the document at point."
  (interactive)
  (let ((doc-url (relax-url (car (relax-parse-db-line)))))
    (url-retrieve doc-url 'relax-doc-load (list doc-url))))

(defun relax-submit ()
  "Save the current status of the buffer to the server."
  (interactive)
  (let ((url-request-method "PUT")
        (url-request-data (buffer-substring (point-max) (point-min))))
    (lexical-let ((doc-buffer (current-buffer)))
      (url-retrieve doc-url (lambda (status)
                              (switch-to-buffer doc-buffer)
                              (relax-update-doc))))))

(defun relax-update-doc ()
  "Update the current buffer with the latest version of the document."
  (interactive)
  (delete-region (point-min) (point-max))
  (url-retrieve doc-url 'relax-doc-load (list doc-url)))

(defun relax-kill-doc ()
  "Delete this revision of the current document from the server."
  (interactive)
  (lexical-let ((target-buffer (current-buffer)))
    (relax-kill-document (getf doc :_id) (getf doc :_rev)
                         (lambda (status)
                           (kill-buffer target-buffer)
                           (relax-update-db)))))

(provide 'relax) ;;; relax.el ends here