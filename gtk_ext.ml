(* 
 * prooftree --- proof tree display for Proof General
 * 
 * Copyright (C) 2011 Hendrik Tews
 * 
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * General Public License in file COPYING in this or one of the
 * parent directories for more details.
 * 
 * $Id: gtk_ext.ml,v 1.4 2011/04/13 07:56:47 tews Exp $
 * 
 * Commentary: some misc LablGtk extensions
 *)


class better_drawable ?colormap w pc = 
object (self)
  inherit GDraw.drawable ?colormap w

  val pango_context = (pc : GPango.context_rw)
  method pango_context = pango_context    

  method get_foreground = (Gdk.GC.get_values gc).Gdk.GC.foreground
  method get_background = (Gdk.GC.get_values gc).Gdk.GC.background

end


let error_message_dialog message =
  let err = GWindow.message_dialog ~message
    ~message_type:`ERROR
    ~buttons:GWindow.Buttons.ok () 
  in
  (* ignore(err#connect#response ~callback:(fun _ -> err#destroy())); *)
  ignore(err#connect#response ~callback:(fun _ -> exit 1));
  err#show()

