(* 
 * prooftree --- proof tree display for Proof General
 * 
 * Copyright (C) 2011 Hendrik Tews
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
 * $Id: proof_window.ml,v 1.22 2011/07/28 12:53:07 tews Exp $
 *)


(** Creation, display and drawing of the proof tree window *)


open Configuration
open Gtk_ext
open Draw_tree
open Node_window
open Help_window
open About_window

let delete_proof_tree_callback = ref (fun (_ : string) -> ())

class proof_window top_window 
  drawing_h_adjustment drawing_v_adjustment (drawing_area : GMisc.drawing_area)
  drawable_arg labeled_sequent_frame sequent_window sequent_v_adjustment
  message_label menu proof_name
  =
object (self)

  (***************************************************************************
   *
   * Internal state and setters/accessors
   *
   ***************************************************************************)
  val top_window = (top_window : GWindow.window)
  val drawing_h_adjustment = drawing_h_adjustment
  val drawing_v_adjustment = drawing_v_adjustment
  val drawing_area = drawing_area
  val drawable : better_drawable = drawable_arg
  val labeled_sequent_frame = labeled_sequent_frame
  val sequent_window = sequent_window
  val sequent_v_adjustment = sequent_v_adjustment
  val message_label : GMisc.label = message_label
  val menu = menu
  val proof_name = proof_name

  val mutable top_left = 0
  val top_top = 0

  val mutable sequent_window_scroll_to_bottom = false

  val mutable root = None

  val mutable current_node = None
  val mutable current_node_offset_cache = None
  val mutable position_to_current_node = true

  val mutable selected_node = None

  val mutable node_windows = []

  method set_root r = 
    root <- Some (r : proof_tree_element)

  method clear_root = root <- None

  method clear_selected_node =
    selected_node <- None

  (***************************************************************************
   *
   * Messages
   *
   ***************************************************************************)

  method message text = message_label#set_label text

  (***************************************************************************
   *
   * Sequent window
   *
   ***************************************************************************)

  method sequent_area_changed () =
    if sequent_window_scroll_to_bottom then
      let a = sequent_v_adjustment in
      a#set_value (max a#lower (a#upper -. a#page_size))

  method private update_sequent label content scroll_to_bottom =
    labeled_sequent_frame#set_label (Some label);
    sequent_window#buffer#set_text content;
    sequent_window_scroll_to_bottom <- scroll_to_bottom

  method private clear_sequent_area =
    labeled_sequent_frame#set_label (Some "no sequent");
    sequent_window#buffer#set_text "";
    sequent_window_scroll_to_bottom <- false;

  method refresh_sequent_area =
    match selected_node with
      | Some node ->
	let (frame_text, scroll_to_bottom) = match node#node_kind with
	  | Turnstile -> ("Selected sequent", true)
	  | Proof_command -> ("Selected command", false)
	in
	self#update_sequent frame_text node#content scroll_to_bottom
      | None -> 
	match current_node with
	  | None -> self#clear_sequent_area
	  | Some node ->
	    if node#node_kind = Turnstile
	    then
	      match node#parent with
		| None -> self#clear_sequent_area
		| Some p -> match p#parent with
		    | None -> self#clear_sequent_area
		    | Some p ->
		      self#update_sequent "Previous sequent" p#content true
	    else
	      self#clear_sequent_area

  (***************************************************************************
   *
   * Current node
   *
   ***************************************************************************)

  method set_current_node n =
    current_node_offset_cache <- None;
    current_node <- Some (n : proof_tree_element);
    if selected_node = None && n#node_kind = Turnstile 
    then self#refresh_sequent_area

  method private clear_current_node =
    current_node_offset_cache <- None;
    current_node <- None;
    if selected_node = None
    then self#refresh_sequent_area

  (***************************************************************************
   *
   * Unclassified methods
   *
   ***************************************************************************)

  method survive_undo_before_start =
    match root with
      | None -> false
      | Some root -> root#children <> []

  method disconnect_proof =
    self#clear_current_node;
    match root with
      | None -> ()
      | Some root -> root#disconnect_proof

  (***************************************************************************
   *
   * Key events
   *
   ***************************************************************************)

  method private scroll (adjustment : GData.adjustment) direction =
    let a = adjustment in
    let new_val = a#value +. float_of_int(direction) *. a#step_increment in
    let new_val = if new_val < 0.0 then 0.0 else new_val in
    let max = max 0.0 (a#upper -. a#page_size) in
    let new_val = if new_val > max then max else new_val in
    a#set_value new_val

  method delete_proof_window =
    List.iter (fun w -> w#delete_node_window_maybe) node_windows;
    top_window#destroy()

  method user_delete_proof_window () =
    !delete_proof_tree_callback proof_name;
    self#delete_proof_window

  method private delete_proof_window_event _ =
    self#user_delete_proof_window ();
    true

  method key_pressed_callback ev =
    match GdkEvent.Key.keyval ev with 
      | ks when (ks = GdkKeysyms._Q or ks = GdkKeysyms._q)  -> 
	self#delete_proof_window_event ev
      | ks when ks = GdkKeysyms._Left -> 
	self#scroll drawing_h_adjustment (-1); true
      | ks when ks = GdkKeysyms._Right -> 
	self#scroll drawing_h_adjustment 1; true
      | ks when ks = GdkKeysyms._Up -> 
	self#scroll drawing_v_adjustment (-1); true
      | ks when ks = GdkKeysyms._Down -> 
	self#scroll drawing_v_adjustment 1; true

      | _ -> false

  (***************************************************************************
   *
   * Redraw / expose events
   *
   ***************************************************************************)

  method private get_current_offset =
    match current_node_offset_cache with
      | Some _ as res -> res
      | None -> match current_node with
	  | None -> None
	  | Some node ->
	    let width = node#width in
	    let height = node#height in
	    let (x_off, y_off) = node#x_y_offsets in
	    let res = Some((x_off, y_off, width, height)) in
	    current_node_offset_cache <- res;
	    res

  method private erase = 
    (* Printf.eprintf "ERASE\n%!"; *)
    let (x,y) = drawable#size in
    let fg = drawable#get_foreground in
    drawable#set_foreground (`NAME("white"));
    drawable#polygon ~filled:true [(0,0); (x,0); (x,y); (0,y)];
    drawable#set_foreground (`COLOR fg)

  method private try_adjustment = 
    if position_to_current_node = true then
      match self#get_current_offset with
	| None -> 
	  position_to_current_node <- false
	| Some((x_off, y_off, width, height)) ->
	  (* Printf.eprintf "TRY ADJUSTMENT %!"; *)
	  let x_page_size = int_of_float drawing_h_adjustment#page_size in
	  let y_page_size = int_of_float drawing_v_adjustment#page_size in
	  let x_l_f = float_of_int(top_left + x_off - width / 2) in
	  let x_u_f = float_of_int(top_left + x_off + width / 2) in
	  let y_l_f = float_of_int(top_top + y_off - height / 2) in
	  let y_u_i = top_top + y_off + height / 2 in
	  let y_u_f = float_of_int y_u_i in
	  let success = ref true in
          (* The following code might immediately trigger
	   * expose events, which will call try_adjustment again. To avoid
	   * entering this function a second time before leaving it, I
	   * temporarily switch position_to_current_node off.
	   *)
	  position_to_current_node <- false;

	  if x_page_size >= width && y_page_size >= height
	  then begin
	    (* current node fits into the viewport, be sophisticated *)
	    if y_u_f > drawing_v_adjustment#upper
	    then begin
	      (* The resize request for the drawing are has not 
	       * been processed. It might happen that this resize
	       * request causes the addition of some scrollbars. In
	       * this case the viewport gets smaller and the 
	       * current node would possible (partially) hidden.
	       * Therefore we mimic an adjustment error. Note that 
	       * in this case also clamp_page would not give a proper
	       * adjustment.
	       *)
	      success := false;
	      (* Printf.eprintf "clever forced error %!" *)
	    end else begin
	      let y_val = 
		max drawing_v_adjustment#lower 
		  (float_of_int (y_u_i - y_page_size))
	      in
	      drawing_v_adjustment#set_value y_val;
	      drawing_h_adjustment#clamp_page ~lower:x_l_f ~upper:x_u_f;
	      (* 
               * Printf.eprintf "clever y_u_i %d up %d y_val %d %!"
	       * 	y_u_i
	       * 	(int_of_float drawing_v_adjustment#upper)
	       * 	(int_of_float y_val);
               *)
	    end
	  end else begin
	    (* very small viewport, use dump strategy *)
	    (* Printf.eprintf "dump clamp %!"; *)
	    drawing_h_adjustment#clamp_page ~lower:x_l_f ~upper:x_u_f;
	    drawing_v_adjustment#clamp_page ~lower:y_l_f ~upper:y_u_f;
	  end;

	  let x_val = drawing_h_adjustment#value in
	  let x_page_size = drawing_h_adjustment#page_size in
	  let y_val = drawing_v_adjustment#value in
	  let y_page_size = drawing_v_adjustment#page_size in
	  if !success &&
	    x_l_f >= x_val && x_u_f <= x_val +. x_page_size &&
	    y_l_f >= y_val && y_u_f <= y_val +. y_page_size
	  then begin
	    (* Printf.eprintf "SUCCESSFUL\n%!"; *)
	    () (* Do nothing: leave position_to_current_node disabled *)
	  end else begin
	    (* Printf.eprintf "UNSUCCESSFUL\n%!"; *)
	    (* Schedule the adjustment again, hope that we are more
	     * successful next time.
	     *)
	    position_to_current_node <- true;
	  end
          (* 
	   * (let a = drawing_v_adjustment in
	   *  Printf.eprintf 
	   * 	 "TA %s VADJ low %f val %f up %f size %f step %f page %f\n%!"
	   * 	 (match scheduled_adjustment with | None -> "N" | Some _ -> "S")
	   * 	 a#lower a#value a#upper a#page_size 
	   * 	 a#step_increment a#page_increment)
	   *)

  method private expand_drawing_area =
    match root with
      | None -> ()
      | Some root -> 
	let new_width = root#subtree_width in
	let new_height = root#subtree_height in
	(* 
         * Printf.eprintf "DRAWING AREA SIZE REQUEST %d x %d\n%!" 
	 *   new_width new_height;
         *)
	(* 
         * if new_width > current_width || new_height > current_height then
	 *   drawing_area#misc#set_size_request
	 *     ~width:(max current_width new_width)
	 *     ~height:(max current_height new_height) ();
         *)
	drawing_area#misc#set_size_request
	  ~width:new_width ~height:new_height ();

  (** Sets the position of the proof tree in the drawing area by 
      computing [top_left]. Returns true if the position changed. 
      In that case the complete drawing area must be redrawn.
  *)
  method private position_tree =
    match root with
      | None -> false
      | Some root -> 
	let old_top_left = top_left in
	let (width, _) = drawable#size in
	top_left <- max 0 ((width - root#subtree_width) / 2);
	top_left <> old_top_left

  method private redraw =
    (* 
     * (let a = drawing_v_adjustment in
     *  Printf.eprintf 
     *    "RD %s VADJ low %f val %f up %f size %f step %f page %f\n%!"
     *    (match scheduled_adjustment with | None -> "N" | Some _ -> "S")
     *    a#lower a#value a#upper a#page_size 
     *    a#step_increment a#page_increment);
     *)
    self#try_adjustment;
    self#erase;
    (* let left = 0 in *)
    match root with
      | None -> ()
      | Some root ->
	(* Printf.eprintf "REDRAW\n%!"; *)
	ignore(root#draw_tree_root top_left top_top)

  method invalidate_drawing_area =
    (* Printf.eprintf "INVALIDATE\n%!"; *)
    GtkBase.Widget.queue_draw drawing_area#as_widget

  method refresh_and_position =
    (* Printf.eprintf "REFRESH & POSITION\n%!"; *)
    position_to_current_node <- true;
    self#expand_drawing_area;
    ignore(self#position_tree);
    self#try_adjustment;
    self#invalidate_drawing_area;

  method draw_scroll_size_allocate_callback (_size : Gtk.rectangle) =
    (* 
     * Printf.eprintf "SCROLLING SIZE ALLOC SIGNAL size %d x %d\n%!"
     *   (int_of_float (drawing_h_adjustment#upper +. 0.5))
     *   (int_of_float (drawing_v_adjustment#upper +. 0.5));
     *)
    let need_redraw = self#position_tree in
    (* 
     * (let a = drawing_v_adjustment in
     *  Printf.eprintf 
     *    "SA %s VADJ low %f val %f up %f size %f step %f page %f\n%!"
     *    (match scheduled_adjustment with | None -> "N" | Some _ -> "S")
     *    a#lower a#value a#upper a#page_size 
     *    a#step_increment a#page_increment);
     *)
    self#try_adjustment;
    if need_redraw 
    then self#invalidate_drawing_area

  (* 
   * method draw_area_size_allocate_callback (_size : Gtk.rectangle) =
   *   Printf.eprintf "AREA SIZE ALLOC SIGNAL size %d x %d\n%!"
   *     (int_of_float (drawing_h_adjustment#upper +. 0.5))
   *     (int_of_float (drawing_v_adjustment#upper +. 0.5));
   *)
  
  (* 
   * method draw_area_configure_callback configure_event =
   *   Printf.eprintf 
   *     "AREA CONFIGURE SIGNAL area size %d x %d scroll size %d x %d\n%!"
   *     (GdkEvent.Configure.width configure_event)
   *     (GdkEvent.Configure.height configure_event)
   *     (int_of_float (drawing_h_adjustment#upper +. 0.5))
   *     (int_of_float (drawing_v_adjustment#upper +. 0.5));
   *   false
   *)

  method expose_callback (ev : GdkEvent.Expose.t) =
    (* 
     * (let a = drawing_v_adjustment in
     *  Printf.eprintf "EX VADJ low %f val %f up %f size %f step %f page %f\n%!"
     *    a#lower a#value a#upper a#page_size 
     *    a#step_increment a#page_increment);
     *)
    (* 
     * (let a = drawing_h_adjustment in
     *  Printf.eprintf "HADJ low %f val %f up %f size %f step %f page %f\n"
     *    a#lower a#value a#upper a#page_size a#step_increment a#page_increment);
     * (let a = drawing_v_adjustment in
     *  Printf.eprintf "VADJ low %f val %f up %f size %f step %f page %f\n%!"
     *    a#lower a#value a#upper a#page_size a#step_increment a#page_increment);
     *)
    (* 
     * let r = GdkEvent.Expose.area ev in
     * Printf.eprintf "EXPOSE count %d %d x %d at %d x %d\n%!"
     *   (GdkEvent.Expose.count ev)
     *   (Gdk.Rectangle.width r) (Gdk.Rectangle.height r)
     *   (Gdk.Rectangle.x r) (Gdk.Rectangle.y r);
     *)
    self#redraw;
    (* prerr_endline "END EXPOSE EVENT"; *)
    false

  (***************************************************************************
   *
   * numbers for external node windows
   *
   ***************************************************************************)

  val mutable last_node_number = 0

  method private next_node_number =
    last_node_number <- last_node_number + 1;
    last_node_number

  (***************************************************************************
   *
   * Button events
   *
   ***************************************************************************)

  val mutable last_button_press_top_x = 0
  val mutable last_button_press_top_y = 0
  val mutable last_button_press_v_adjustment_value = 0.0
  val mutable last_button_press_h_adjustment_value = 0.0

  method private remember_for_dragging =
    let (x, y) = Gdk.Window.get_pointer_location top_window#misc#window in
    (* 
     * Printf.printf "Button press %d x %d\n%!" 
     *   (fst new_poi_loc) (snd new_poi_loc);
     *)
    last_button_press_top_x <- x;
    last_button_press_top_y <- y;
    last_button_press_v_adjustment_value <- drawing_v_adjustment#value;
    last_button_press_h_adjustment_value <- drawing_h_adjustment#value;


  val mutable old_old_selected_node = None
  val mutable old_selected_node = None
  val mutable restored_selected_node = false

  method set_selected_node node_opt =
    (match selected_node with
      | None -> ()
      | Some node -> node#selected false);
    selected_node <- node_opt;
    (match node_opt with
      | None -> ()
      | Some node -> node#selected true);
    self#invalidate_drawing_area;
    self#refresh_sequent_area

  method private save_selected_node_state =
    old_old_selected_node <- old_selected_node;
    old_selected_node <- selected_node;
    restored_selected_node <- false

  method private single_restore_selected_node =
    self#set_selected_node old_selected_node;
    restored_selected_node <- true

  method private double_restore_selected_node =
    self#set_selected_node old_old_selected_node;
    restored_selected_node <- true

  method private locate_button_node x y node_click_fun outside_click_fun =
    let node_opt = match root with 
      | None -> None
      | Some root ->
	root#mouse_button_tree_root top_left top_top x y
    in
    match node_opt with
      | None -> outside_click_fun ()
      | Some node -> node_click_fun node

  method private external_node_window (node : proof_tree_element) =
    let n = string_of_int(self#next_node_number) in
    let win = 
      make_node_window (self :> proof_window_interface) proof_name node n 
    in 
    node_windows <- win :: node_windows;
    self#invalidate_drawing_area

  method private button_1_press x y shifted double =
    self#remember_for_dragging;
    if (not double) && (not shifted)
    then self#save_selected_node_state;
    if double && (not shifted)
    then self#double_restore_selected_node;
    if double || shifted 
    then self#locate_button_node x y self#external_node_window (fun () -> ())
    else 
      self#locate_button_node x y 
	(fun node -> self#set_selected_node (Some node))
	(fun () -> self#set_selected_node None)

  (* val mutable last_button_press_time = 0l *)

  method button_press ev =
    let x = int_of_float(GdkEvent.Button.x ev +. 0.5) in
    let y = int_of_float(GdkEvent.Button.y ev +. 0.5) in
    let button = GdkEvent.Button.button ev in
    let shifted = Gdk.Convert.test_modifier `SHIFT (GdkEvent.Button.state ev) in
    let double = match GdkEvent.get_type ev with
      | `BUTTON_PRESS -> false
      | `TWO_BUTTON_PRESS -> true
      | `THREE_BUTTON_PRESS -> false
      | `BUTTON_RELEASE -> false
    in
    (* 
     * let state = B.state ev in
     * let mod_list = Gdk.Convert.modifier state in
     * let _ = Gdk.Convert.test_modifier `SHIFT state in
     *)
    (* 
     * let time_diff = 
     * Int32.sub (GdkEvent.Button.time ev) last_button_press_time 
     * in
     * last_button_press_time <- GdkEvent.Button.time ev;
     *)
    (* 
     * Printf.printf "%s Button %s%d at %d x %d\n%!" 
     *   (match GdkEvent.get_type ev with
     * 	| `BUTTON_PRESS -> "single"
     * 	| `TWO_BUTTON_PRESS -> "double"
     * 	| `THREE_BUTTON_PRESS -> "triple"
     * 	| `BUTTON_RELEASE -> "release")
     *   (if shifted then "shift " else "")
     *   button x y;
     *)
    (match button with
      | 1 -> self#button_1_press x y shifted double
      | 3 -> menu#popup ~button ~time:(GdkEvent.Button.time ev)
      | _ -> ());
    true


  (***************************************************************************
   *
   * Pointer motion events
   *
   ***************************************************************************)

  method pointer_motion (_ : GdkEvent.Motion.t) =
    let (x, y) = Gdk.Window.get_pointer_location top_window#misc#window in
    let new_h_value = 
      last_button_press_h_adjustment_value +.
    	!current_config.button_1_drag_acceleration *.
	   (float_of_int (x - last_button_press_top_x))
    in
    let new_v_value = 
      last_button_press_v_adjustment_value +.
    	!current_config.button_1_drag_acceleration *. 
	   (float_of_int (y - last_button_press_top_y))
    in
    (* 
     * let hint = GdkEvent.Motion.is_hint ev in
     * Printf.printf "PM %d %d%s\n%!" new_x new_y (if hint then " H" else "");
     *)
    if not restored_selected_node 
    then self#single_restore_selected_node;
    drawing_h_adjustment#set_value 
      (min new_h_value 
    	 (drawing_h_adjustment#upper -. drawing_h_adjustment#page_size));
    drawing_v_adjustment#set_value 
      (min new_v_value
    	 (drawing_v_adjustment#upper -. drawing_v_adjustment#page_size));
    (* 
     * last_button_1_x <- x;
     * last_button_1_y <- y;
     *)
    true


  (***************************************************************************
   *
   * Cloning
   *
   ***************************************************************************)

  method clone (owin : proof_window) =
    let become_selected = match current_node with
      | Some _ -> current_node
      | None -> selected_node
    in
    let cloned_selected = ref None in
    let rec clone_tree node =
      let cloned_children = List.map clone_tree node#children in
      let clone = match node#node_kind with
	| Proof_command -> 
	  (owin#new_proof_command node#content :> proof_tree_element)
	| Turnstile -> 
	  (owin#new_turnstile node#id node#content :> proof_tree_element)
      in
      if Some node = become_selected
      then cloned_selected := Some clone;
      set_children clone cloned_children;
      (match node#branch_state with
	| Cheated
	| Proven -> clone#set_branch_state node#branch_state
	| Unproven
	| CurrentNode
	| Current -> ()
      );
      clone
    in    
    (match root with
      | None -> ()
      | Some root_node ->
	owin#set_root (clone_tree root_node)
    );
    owin#set_selected_node !cloned_selected;
    owin#refresh_and_position

  (***************************************************************************
   *
   * Proof element creation
   *
   ***************************************************************************)

  method new_turnstile sequent_id sequent_text =
    new turnstile drawable sequent_id sequent_text

  method new_proof_command command =
    new proof_command drawable command command
end



(*****************************************************************************
 *
 * proof window creation
 *
 *****************************************************************************)

let rec make_proof_window name geometry_string =
  let top_window = GWindow.window () in
  top_window#set_default_size ~width:400 ~height:400;
      (* top_v_box for the pane and the button hbox *)
  let top_v_box = GPack.vbox ~packing:top_window#add () in
      (* top_paned for the drawing area and the sequent *)
  let top_paned = GPack.paned `VERTICAL 
    ~packing:(top_v_box#pack ~expand:true) ()
  in
  let drawing_scrolling = GBin.scrolled_window (* ~border_width:1 *)
    ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC 
    ~packing:(top_paned#pack1 ~resize:true ~shrink:false) () 
  in
  let drawing_h_adjustment = drawing_scrolling#hadjustment in
  let drawing_v_adjustment = drawing_scrolling#vadjustment in
  let drawing_area = GMisc.drawing_area 
    ~packing:drawing_scrolling#add_with_viewport () 
  in
  let _ = drawing_area#misc#realize () in
  let drawable = 
    new better_drawable drawing_area#misc#window 
      drawing_area#misc#create_pango_context
  in
  let outer_sequent_frame = GBin.frame ~shadow_type:`IN 
    ~packing:(top_paned#pack2 ~resize:false ~shrink:false) () 
  in
  let labeled_sequent_frame = GBin.frame ~label:"no sequent" ~shadow_type:`NONE
    ~packing:outer_sequent_frame#add ()
  in
  let sequent_scrolling = GBin.scrolled_window 
    ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC 
    ~packing:labeled_sequent_frame#add () 
  in
  (* 
   * let sequent_h_adjustment = sequent_scrolling#hadjustment in
   *)
  let sequent_v_adjustment = sequent_scrolling#vadjustment in
  let sequent_window = GText.view ~editable:false ~cursor_visible:false
    (* ~height:50 *)
    ~packing:sequent_scrolling#add () 
  in
  let button_h_box = GPack.hbox ~packing:top_v_box#pack () in
  let dismiss_button = 
    GButton.button ~label:"Dismiss" ~packing:button_h_box#pack ()
  in
  let message_label =
    GMisc.label ~selectable:true ~ellipsize:`END 
      ~packing:(button_h_box#pack ~expand:true ~fill:true) ()
  in
  message_label#set_use_markup true;
  let menu_button = 
    GButton.button ~label:"Menu" ~packing:(button_h_box#pack) ()
  in

  let menu = GMenu.menu () in
  let menu_factory = new GMenu.factory menu in

  let proof_window = 
    new proof_window top_window 
      drawing_h_adjustment drawing_v_adjustment drawing_area
      drawable labeled_sequent_frame sequent_window sequent_v_adjustment
      message_label menu name
  in
  let clone_fun () =
    let owin = make_proof_window name geometry_string in
    proof_window#clone owin
  in
  top_window#set_title (name ^ " proof tree");
  drawable#set_line_attributes 
    ~width:(!current_config.turnstile_line_width) ();
  ignore(drawing_scrolling#misc#connect#size_allocate
	   ~callback:proof_window#draw_scroll_size_allocate_callback);
  (* 
   * ignore(drawing_area#misc#connect#size_allocate
   * 	   ~callback:proof_window#draw_area_size_allocate_callback);
   *)
  (* 
   * ignore(drawing_area#event#connect#configure
   * 	   ~callback:proof_window#draw_area_configure_callback);
   *)
  ignore(top_window#connect#destroy 
	   ~callback:proof_window#user_delete_proof_window);
  (* the delete event yields a destroy signal if not handled *)
    (* ignore(top_window#event#connect#delete 
       ~callback:proof_window#delete_proof_window); *)
    (* 
     * ignore(drawing_area#misc#set_can_focus true);
     * ignore(drawing_area#event#connect#key_press 
     *                  proof_window#key_pressed_callback);
     *)
  ignore(top_window#event#connect#key_press proof_window#key_pressed_callback);
  ignore(drawing_area#event#connect#expose 
	   ~callback:proof_window#expose_callback);
  (* ignore(drawing_area#misc#connect#size_allocate ~callback:resize); *)

  (* events to receive: 
   *  - all button presses, 
   *  - pointer motion when button 1 is pressed
   *  - reduced number of pointer motion events
   *)
  ignore(drawing_area#event#add 
	   [`BUTTON_PRESS; `BUTTON1_MOTION; `POINTER_MOTION_HINT]);
  ignore(drawing_area#event#connect#button_press 
	   ~callback:proof_window#button_press);
  ignore(drawing_area#event#connect#motion_notify
	   ~callback:proof_window#pointer_motion);

  ignore(sequent_v_adjustment#connect#changed 
	   ~callback:proof_window#sequent_area_changed);

  ignore(dismiss_button#connect#clicked 
	   ~callback:proof_window#user_delete_proof_window);
  ignore(menu_button#connect#clicked 
	   ~callback:(fun () -> 
	     menu#popup ~button:0 
	       ~time:(GtkMain.Main.get_current_event_time ())));

  ignore(menu_factory#add_item "Clone" ~callback:clone_fun);
  ignore(menu_factory#add_item "Configuration" ~callback:show_config_window);
  ignore(menu_factory#add_item "Help" ~callback:show_help_window);
  ignore(menu_factory#add_item "About" ~callback:show_about_window);
  ignore(menu_factory#add_item "Exit" ~callback:(fun _ -> exit 0));

  top_window#show ();
  if geometry_string <> "" then
    ignore(top_window#parse_geometry geometry_string);

  proof_window
