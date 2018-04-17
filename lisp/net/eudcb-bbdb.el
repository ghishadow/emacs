;;; eudcb-bbdb.el --- Emacs Unified Directory Client - BBDB Backend

;; Copyright (C) 1998-2017 Free Software Foundation, Inc.

;; Author: Oscar Figueiredo <oscar@cpe.fr>
;;         Pavel Janík <Pavel@Janik.cz>
;; Maintainer: Thomas Fitzsimmons <fitzsim@fitzsim.org>
;; Keywords: comm
;; Package: eudc

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;    This library provides an interface to use BBDB as a backend of
;;    the Emacs Unified Directory Client.

;;; Code:

(require 'eudc)
(require 'bbdb)
(require 'bbdb-com)

;;{{{      Internal cooking

;; I don't like this but mapcar does not accept a parameter to the function and
;; I don't want to use mapcar*
(defvar eudc-bbdb-current-query nil)
(defvar eudc-bbdb-current-return-attributes nil)

(defun eudc-bbdb-field (field-symbol)
  "Convert FIELD-SYMBOL so that it is recognized by the current BBDB version.
BBDB < 3 used `company', `phones', `addresses' and `net' where
BBDB >= 3 uses `organization', `phone', `address' and `mail'
respectively.

EUDC users may be referring to old BBDB fields in their
configuration, so for convenience this function enables support
for continued use of those old names."
  (cond
   ((eq field-symbol 'company) 'organization)
   ((eq field-symbol 'phones) 'phone)
   ((eq field-symbol 'addresses) 'address)
   ((eq field-symbol 'net) 'mail)
   (t field-symbol)))

(defvar eudc-bbdb-attributes-translation-alist
  '((name . lastname)
    (email . mail)
    (phone . phone))
  "Alist mapping EUDC attribute names to BBDB names.")

(eudc-protocol-set 'eudc-query-function 'eudc-bbdb-query-internal 'bbdb)
(eudc-protocol-set 'eudc-list-attributes-function nil 'bbdb)
(eudc-protocol-set 'eudc-protocol-attributes-translation-alist
		   'eudc-bbdb-attributes-translation-alist 'bbdb)
(eudc-protocol-set 'eudc-bbdb-conversion-alist nil 'bbdb)
(eudc-protocol-set 'eudc-protocol-has-default-query-attributes nil 'bbdb)

(defun eudc-bbdb-format-query (query)
  "Format QUERY, an EUDC alist, into a list suitable to `bbdb-search'."
  (let* ((firstname (cdr (assq 'firstname query)))
	 (lastname (cdr (assq 'lastname query)))
	 (name (or (and firstname lastname
			(concat firstname " " lastname))
		   firstname
		   lastname))
	 (organization (or (cdr (assq 'organization query))
			   (cdr (assq 'company query))))
	 (mail (or (cdr (assq 'mail query))
		   (cdr (assq 'net query))))
	 (notes (cdr (assq 'notes query)))
	 (phone (cdr (assq 'phone query))))
    (list name organization mail notes phone)))


(defun eudc-bbdb-filter-non-matching-record (record)
  "Return RECORD if it is a match for `eudc-bbdb-current-query', nil otherwise."
  (catch 'unmatch
    (progn
      (dolist (condition eudc-bbdb-current-query)
	(let ((attr (car condition))
	      (val (cdr condition))
	      (case-fold-search t)
	      bbdb-val)
	  (or (and (memq attr '(firstname lastname aka
					  organization phone address mail
					  ;; BBDB < 3 fields.
					  company phones addresses net))
		   (progn
		     (setq bbdb-val (bbdb-record-field record
						       (eudc-bbdb-field attr)))
		     (if (listp bbdb-val)
			 (if eudc-bbdb-enable-substring-matches
			     (eval `(or ,@(mapcar (lambda (subval)
						    (string-match val subval))
						  bbdb-val)))
			   (member (downcase val)
				   (mapcar 'downcase bbdb-val)))
		       (if eudc-bbdb-enable-substring-matches
			   (string-match val bbdb-val)
			 (string-equal (downcase val) (downcase bbdb-val))))))
	      (throw 'unmatch nil))))
      record)))

(defun eudc-bbdb-extract-phones (record)
  "Extract phone numbers from BBDB RECORD."
  ;; Keep same order as in BBDB record.
  (nreverse
   (mapcar (function
	    (lambda (phone)
	      (if eudc-bbdb-use-locations-as-attribute-names
		  (cons (intern (bbdb-phone-label phone))
			(bbdb-phone-string phone))
		(cons 'phones (format "%s: %s"
				      (bbdb-phone-label phone)
				      (bbdb-phone-string phone))))))
	   (bbdb-record-phone record))))

(defun eudc-bbdb-extract-addresses (record)
  "Extract addresses from BBDB RECORD."
  (let (s c val)
    (nreverse
     (mapcar (lambda (address)
	       (setq val nil)
	       (setq c (bbdb-address-streets address))
	       (dotimes (n 3)
		 (unless (zerop (length (setq s (nth n c))))
		   (setq val (concat val s "\n"))))
	       (setq c (bbdb-address-city address)
		     s (bbdb-address-state address))
	       (setq val (concat val
				 (if (and (> (length c) 0) (> (length s) 0))
				     (concat c ", " s)
				   c)
				 " "
				 (bbdb-address-postcode address)))
	       (if eudc-bbdb-use-locations-as-attribute-names
		   (cons (intern (bbdb-address-label address)) val)
		 (cons 'address (concat (bbdb-address-label address)
					"\n" val))))
	     (bbdb-record-address record)))))

(defun eudc-bbdb-format-record-as-result (record)
  "Format the BBDB RECORD as a EUDC query result record.
The record is filtered according to `eudc-bbdb-current-return-attributes'"
  (let ((attrs (or eudc-bbdb-current-return-attributes
		   '(firstname lastname aka organization phone address mail
			       notes)))
	attr
	eudc-rec
	val)
    (while (prog1
	       (setq attr (car attrs))
	     (setq attrs (cdr attrs)))
      (cond
       ((or (eq attr 'phone)
	    ;; BBDB < 3 field.
	    (eq attr 'phones))
	(setq val (eudc-bbdb-extract-phones record)))
       ((or (eq attr 'address)
	    ;; BBDB < 3 field.
	    (eq attr 'addresses))
	(setq val (eudc-bbdb-extract-addresses record)))
       ((memq attr '(firstname lastname aka
			       organization mail notes
			       ;; BBDB < 3 fields.
			       company net))
	(setq val (bbdb-record-field record (eudc-bbdb-field attr))))
       (t
	(error "Unknown BBDB attribute")))
      (cond
       ((or (not val) (equal val ""))) ; do nothing
       ((memq attr '(phone address
			   ;; BBDB < 3 fields.
			   phones addresses))
	(setq eudc-rec (append val eudc-rec)))
       ((and (listp val)
	     (= 1 (length val)))
	(setq eudc-rec (cons (cons attr (car val)) eudc-rec)))
       ((> (length val) 0)
	(setq eudc-rec (cons (cons attr val) eudc-rec)))
       (t
	(error "Unexpected attribute value"))))
    (nreverse eudc-rec)))



(defun eudc-bbdb-query-internal (query &optional return-attrs)
  "Query BBDB  with QUERY.
QUERY is a list of cons cells (ATTR . VALUE) where ATTRs should be valid
BBDB attribute names.
RETURN-ATTRS is a list of attributes to return, defaulting to
`eudc-default-return-attributes'."
  (let ((eudc-bbdb-current-query query)
	(eudc-bbdb-current-return-attributes return-attrs)
	(query-attrs (eudc-bbdb-format-query query))
	bbdb-attrs
	(records (bbdb-records))
	result
	filtered)
    ;; BBDB ORs its query attributes while EUDC ANDs them, hence we need to
    ;; call bbdb-search iteratively on the returned records for each of the
    ;; requested attributes
    (while (and records (> (length query-attrs) 0))
      (setq bbdb-attrs (append bbdb-attrs (list (car query-attrs))))
      (if (car query-attrs)
	  (setq records (eval `(bbdb-search ,(quote records) ,@bbdb-attrs))))
      (setq query-attrs (cdr query-attrs)))
    (mapc (function
	   (lambda (record)
	     (setq filtered (eudc-filter-duplicate-attributes record))
	     ;; If there were duplicate attributes reverse the order of the
	     ;; record so the unique attributes appear first
	     (if (> (length filtered) 1)
		 (setq filtered (mapcar (function
					 (lambda (rec)
					   (reverse rec)))
					filtered)))
	     (setq result (append result filtered))))
	  (delq nil
		(mapcar 'eudc-bbdb-format-record-as-result
			(delq nil
			      (mapcar 'eudc-bbdb-filter-non-matching-record
				      records)))))
    result))

;;}}}

;;{{{      High-level interfaces (interactive functions)

(defun eudc-bbdb-set-server (dummy)
  "Set the EUDC server to BBDB.
Take a DUMMY argument to match other EUDC backend set-server
functions."
  (interactive)
  (eudc-set-server dummy 'bbdb)
  (message "BBDB server selected"))

;;}}}


(eudc-register-protocol 'bbdb)

(provide 'eudcb-bbdb)

;;; eudcb-bbdb.el ends here
