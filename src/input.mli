(* 
 * prooftree --- proof tree display for Proof General
 * 
 * Copyright (C) 2011 - 2016 Hendrik Tews
 * 
 * This file is part of "prooftree".
 * 
 * "prooftree" is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 * 
 * "prooftree" is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * General Public License in file COPYING in this or one of the parent
 * directories for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with "prooftree". If not, see <http://www.gnu.org/licenses/>.
 * 
 * $Id: input.mli,v 1.12 2016/01/23 12:57:14 tews Exp $
 *)


(** Reading commands from nonblocking stdin *)


(* for documentation, see input.ml *)

(** Take the necessary actions when the configuration record changed.
*)
val configuration_updated : unit -> unit


(** Initialize this module and setup the GTK main loop callback for
    [stdin]. Puts [stdin] into non-blocking mode.
*)
val setup_input : unit -> unit
