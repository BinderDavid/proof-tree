## 
## prooftree --- proof tree display for Proof General
## 
## Copyright (C) 2011 Hendrik Tews
## 
## This program is free software; you can redistribute it and/or
## modify it under the terms of the GNU General Public License as
## published by the Free Software Foundation; either version 2 of
## the License, or (at your option) any later version.
## 
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
## General Public License in file COPYING in this or one of the
## parent directories for more details.
## 
## $Id: Makefile,v 1.4 2011/04/13 07:56:46 tews Exp $
## 
## Commentary: Makefile
## 


SOURCES:=\
	version.ml \
	util.ml \
	configuration.ml \
	gtk_ext.ml \
	draw_tree.ml \
	proof_window.ml \
	proof_tree.ml \
	input.ml \
	main.ml

TOCLEAN+=prooftree
prooftree: prooftree.opt

.PHONY: prooftree.opt
prooftree.opt: $(SOURCES)
	ocamlopt.opt -inline 0 -g -I +lablgtk2 -o prooftree \
		unix.cmxa lablgtk.cmxa \
		gtkInit.cmx $(SOURCES)

.PHONY: prooftree.byte
prooftree.byte: $(SOURCES)
	ocamlc.opt -g -I +lablgtk2 -o prooftree \
		unix.cma lablgtk.cma \
		gtkInit.cmo $(SOURCES)

version.ml: version.txt
	echo '(* This file is automatically generated from version. *)' > $@
	echo '(* DO NOT EDIT! *)' >> $@
	echo -n 'let version = "' >> $@
	cat version.txt >> $@
	echo '"' >> $@

clean:
	rm -f $(TOCLEAN)
	rm -f *.cmi *.cmo *.cmx *.o *.cma *.cmxa *.a

TAGS: $(SOURCES)
	otags $(SOURCES)
