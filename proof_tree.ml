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
 * $Id: proof_tree.ml,v 1.23 2011/09/27 06:47:27 tews Exp $
 *)


(** Internal representation of proof trees with undo info 

    This module processes the proof-tree display commands that are
    read from standard input. It keeps a state record (of type
    {!proof_tree}) for all proof trees currently displayed. 
*)

open Util
open Configuration
open Draw_tree
open Proof_window


(** Internal exception for state mismatches. This exception is raised
    when the internal state of one proof tree in this module is
    inconsistent with the proof-tree display command that has been
    read. In a correct setup (with the right Proof General version)
    such an error indicates a bug in either prooftree or in the Proof
    General preprocessing code. This exception can also be raised if
    prooftree is used with a wrong version of Proof General or if
    somebody manipulates the internal data structures of Proof
    General.
*)
exception Proof_tree_error of string


type proof_tree = {
  window : proof_window;
  (** The window displaying this tree. *)

  proof_name : string; 
  (** The name of the proof *)

  pa_start_state : int;
  (** Internal proof assistant state number where this proof starts. 
      Used to detect bulk undos.
  *)

  mutable pa_end_state : int;
  (** Internal proof assistant state number where this proof finishes,
      or [-1] if this proof is not finished yet. Used to speed up undo
      processing.
  *)

  mutable cheated : bool;
  (** [true] if a cheating command has been used somewhere in the proof. *)

  sequent_hash : (string, turnstile) Hashtbl.t;
  (** Hash table mapping all currently known sequents of this proof
      tree to {!Draw_tree.turnstile} objects. Used to detect new
      sequents and to update sequents.
  *)

  mutable current_sequent_id : string;
  (** The ID of the current sequent. Needed to distinguish the
      peculiar case, where a non-failing proof command (such as
      [auto]) does not change the proof state. 
  *)

  mutable current_sequent : proof_tree_element;
  (** The object of the current sequent. Used for coloring branches. *)

  mutable other_open_goals : string list;
  (** List containing the ID's of all open goals, except for
      {!current_sequent_id}. *)

  mutable need_redraw : bool;
  (** [true] if the display needs a redraw. Used to delay redrawing. *)

  mutable undo_actions : (int * (unit -> unit) list) list;
(** List of undo actions for this proof tree. Each element has the
    form [(state, action_list)], where [action_list] is the list of
    undo actions that must be performed if the user retracts to a
    state equal or lesser than [state].
*)
}
(** State record for displayed proof trees. The code maintains the
    following invariants.
    {ul 
    {- Each live state is in precisely one the lists
    {!all_proof_trees_for_undo}, {!undo_surviver_trees} or
    {!Proof_window.cloned_proof_windows}.}
    {- {!current_sequent_id} is never contained in {!other_open_goals}}
    }
*)


(** Add an undo action to the current state [pa_state] of the proof
    [pt]. This action is performed if the user retracts to a state
    equal or lesser than [pa_state].
*)
let add_undo_action pt pa_state undo_fun =
  match pt.undo_actions with
    | [] -> pt.undo_actions <- [(pa_state, [undo_fun])]
    | (prev_pa_state, prev_undos) :: undo_tail ->
      assert(pa_state >= prev_pa_state);
      if pa_state = prev_pa_state 
      then
	pt.undo_actions <- (prev_pa_state, undo_fun :: prev_undos) :: undo_tail
      else
	pt.undo_actions <- (pa_state, [undo_fun]) :: pt.undo_actions


(** Contains all proof trees that should be affected by undo
    operations. Cloned proof trees and proof trees that survived a
    bulk undo are not in this list.
*)
let all_proof_trees_for_undo = ref []

(** Contains proof trees that survived a bulk undo. Like cloned proof
    trees these trees do not take part in undo actions. Unlike cloned
    proof trees these proof trees should be reused, when the user
    eventually starts on the proof again.

    (There is another list cloned_proof_windows in proof_window.ml.)
*)
let undo_surviver_trees = ref []


(** Take the necessary actions when the configuration record changed.
    Calls the {!Proof_window.proof_window.configuration_updated}
    method on all live proof windows.
*)
let configuration_updated () =
  List.iter (fun pt -> pt.window#configuration_updated) 
    !all_proof_trees_for_undo;
  List.iter (fun pt -> pt.window#configuration_updated) 
    !undo_surviver_trees;
  List.iter (fun ptw -> ptw#configuration_updated)
    !cloned_proof_windows


(** Holds the state for the currently active proof window, if any.
    Mainly used for {!finish_drawing} to delay redrawing.
*)
let current_proof_tree = ref None


(** Finishes proof tree [pt] by leaving the current branch open.
    Additionally clear {!current_proof_tree}.
*)
let stop_proof_tree pt pa_state = 
  (* Keep undo actions, never know if the prover supports jumping in
   * to the middle of a proof.
   *)
  pt.pa_end_state <- pa_state;
  pt.window#disconnect_proof;
  pt.window#refresh_and_position;
  pt.need_redraw <- false;
  current_proof_tree := None


(** Same as {!stop_proof_tree} but make the current sequent the
    selected one, if there is no selected sequent.
*)
let stop_proof_tree_last_selected pt pa_state =
  (match pt.window#get_selected_node with
    | None -> 
      add_undo_action pt pa_state (fun () -> pt.window#set_selected_node None);
      pt.window#set_selected_node (Some pt.current_sequent);
    | Some _ -> ());
  stop_proof_tree pt pa_state


(** Result values for [undo_tree] that tell the calling function
    [undo] what to do with the argument proof tree.
*)
type proof_tree_undo_result =
  | PT_undo_delete    (** Argument proof tree should be deleted  *)
  | PT_undo_current   (** Argument proof tree should be kept as current *)
  | PT_undo_keep      (** Argument proof tree should be kept non-current *)
  | PT_undo_surviver  (** Argument proof tree should be kept as surviver *)


(** Process all undo actions with a state greater than [undo_state].
    Return the list of unprocessed undo actions (with state strictly
    less than [undo_state]).
*)
let rec fire_undo_actions undo_state = function
  | [] -> []
  | ((state, undos) :: undo_rest) as undo_list ->
    if state > undo_state 
    then begin
      List.iter (fun f -> f()) undos;
      fire_undo_actions undo_state undo_rest
    end else
      undo_list


(** Perform undo actions in proof tree [pt] to reach state [pa_state].
    This means that either 
    {ul
    {- nothing is done (because [pt] was finished in a state less than
    [pa_state]),}
    {- some of the nodes in [pt] are deleted,}
    {- the complete window belonging to [pt] is deleted, or}
    {- no node of [pt] is deleted and pt is kept as surviver (because
    a bulk undo with a state less than the starting state of [pt] was
    detected.)}
    }
*)
let undo_tree pt pa_state =
  if pa_state <= pt.pa_start_state
  then begin
    if pt.window#survive_undo_before_start 
    then begin
      pt.window#message "Retract before start";
      stop_proof_tree pt (-1);
      PT_undo_surviver
    end
    else begin
      pt.window#delete_proof_window;
      PT_undo_delete
    end
  end 
  else if pt.pa_end_state >= 0 && pa_state > pt.pa_end_state 
  then PT_undo_keep
  else begin
    pt.pa_end_state <- -1;
    pt.undo_actions <- fire_undo_actions pa_state pt.undo_actions;
    pt.current_sequent#mark_current;
    pt.window#set_current_node pt.current_sequent;
    pt.window#refresh_sequent_area;
    pt.window#message (Printf.sprintf "Retract to %d" pa_state);
    pt.need_redraw <- true;
    PT_undo_current
  end


(** Perform undo to state [pa_state] in all proof trees currently
    affected by undo ({!all_proof_trees_for_undo}). As result some of
    the proof windows might get deleted, some proof trees might get
    changed, and some might be kept as surviver (in
    {!undo_surviver_trees}). {!current_proof_tree} might be cleared or
    changed.
*)
let undo pa_state =
  let new_current = ref None in
  all_proof_trees_for_undo :=
    List.fold_left
    (fun pts pt -> match undo_tree pt pa_state with
      | PT_undo_delete -> pts
      | PT_undo_current -> 
	new_current := Some pt;
	pt :: pts
      | PT_undo_keep -> pt :: pts
      | PT_undo_surviver -> 
	undo_surviver_trees := pt :: !undo_surviver_trees;
	pts
    )
    [] !all_proof_trees_for_undo;
  current_proof_tree := !new_current


(** Try to find a surviver proof window for [proof_name]. If found, it
    is dequeued from the surviver list ({!undo_surviver_trees}) and
    returned. (The caller will then reuse it.)
*)
let get_surviver proof_name =
  let rec doit res = function
    | [] -> None
    | pt :: pts ->
      if pt.proof_name = proof_name
      then begin
	undo_surviver_trees := List.rev_append res pts;
	Some pt
      end 
      else doit (pt::res) pts
  in
  doit [] !undo_surviver_trees


(** Create a new proof-tree state (especially a new proof-tree window)
    for [proof_name] with starting state [state] and initial sequent
    [current_sequent].
*)
let create_new_proof_tree proof_name state 
    current_sequent_id current_sequent_text =
  let pt_win = make_proof_window proof_name !geometry_string in
  let sw = pt_win#new_turnstile current_sequent_id current_sequent_text in
  let hash = Hashtbl.create 503 in
  Hashtbl.add hash current_sequent_id sw;
  let sw = (sw :> proof_tree_element) in
  let pt = {
    window = pt_win;
    proof_name = proof_name;
    pa_start_state = state;
    pa_end_state = -1;
    cheated = false;
    sequent_hash = hash;
    current_sequent_id = current_sequent_id;
    current_sequent = sw;
    other_open_goals = [];
    need_redraw = true;
    undo_actions = [];
  } in
  pt_win#set_root sw;
  pt


(** Initialize a surviver proof-tree state (and window) for reuse with
    the initial sequent [current_sequent] and start state [state].
*)
let reuse_surviver pt state current_sequent_id current_sequent_text =
  let pt_win = pt.window in
  let proof_name = pt.proof_name in
  let hash = pt.sequent_hash in
  let sw = pt_win#new_turnstile current_sequent_id current_sequent_text in
  pt_win#clear_for_reuse;
  Hashtbl.clear hash;
  Hashtbl.add pt.sequent_hash current_sequent_id sw;
  let sw = (sw :> proof_tree_element) in
  let pt = {
    window = pt_win;
    proof_name = proof_name;
    pa_start_state = state;
    pa_end_state = -1;
    cheated = false;
    sequent_hash = hash;
    current_sequent_id = current_sequent_id;
    current_sequent = sw;
    other_open_goals = [];
    need_redraw = true;
    undo_actions = [];
  } in
  pt_win#set_root sw;
  pt_win#message "";
  pt


(** Start a new proof [proof_name] with [current_sequent] as initial
    sequent in state [state]. If a surviver proof tree is found it is
    reused. Otherwise a new proof-tree state and window is created.
*)
let start_new_proof state proof_name current_sequent_id current_sequent_text =
  assert(List.for_all 
	   (fun pt -> pt.proof_name <> proof_name) !all_proof_trees_for_undo);
  let pt =
    match get_surviver proof_name with
      | None -> 
	create_new_proof_tree proof_name state 
	  current_sequent_id current_sequent_text
      | Some pt -> 
	reuse_surviver pt state current_sequent_id current_sequent_text
  in
  pt.current_sequent#mark_current;
  pt.window#set_current_node pt.current_sequent;
  pt.window#message "Initial sequent";
  pt.need_redraw <- true;
  current_proof_tree := Some pt;
  all_proof_trees_for_undo := pt :: !all_proof_trees_for_undo


(** Add a new proof command with the new current sequent
    [current_sequent] and the additionally spawned subgoals. The
    additionally spawned subgoals are computed from [additional_ids]
    which must contain the ID's of all new subgoals (except for
    [current_sequent_id]). Old, currently unfinished subgoals in
    [additional_ids] are filtered out with the help of
    [pt.other_open_goals]. Except for the [current_sequent], the newly
    created subgoals contain no sequent text yet. This is expected to
    arrive soon with an [update-sequent] command.

    [cheated_flag] is asserted to be false, because the code assumes
    that a cheating command solves the current subgoal.
*)
let add_new_goal pt state proof_command cheated_flag 
    current_sequent_id current_sequent_text additional_ids =
  assert(cheated_flag = false);
  let pc = pt.window#new_proof_command proof_command in
  let pc = (pc :> proof_tree_element) in
  set_children pt.current_sequent [pc];
  let sw = pt.window#new_turnstile current_sequent_id current_sequent_text in
  Hashtbl.add pt.sequent_hash current_sequent_id sw;
  let sw = (sw :> proof_tree_element) in
  (* It is tempting to assert
   * 
   *     assert(list_set_subset pt.other_open_goals additional_ids);
   * 
   * However, in Coq the Focus command temporarily narrows the display of
   * the additionally open subgoals.
   *)
  let new_goal_ids_rev = list_set_diff_rev additional_ids pt.other_open_goals in
  assert(List.for_all 
	   (fun id -> not (Hashtbl.mem pt.sequent_hash id)) new_goal_ids_rev);
  let new_goals =
    List.fold_left
      (fun res id ->
	let sw = pt.window#new_turnstile id "waiting for sequent text" in
	Hashtbl.add pt.sequent_hash id sw;
	let sw = (sw :> proof_tree_element) in
	sw :: res)
      [] new_goal_ids_rev
  in
  let all_subgoals = sw :: new_goals in
  set_children pc all_subgoals;
  sw#mark_current;
  pt.window#set_current_node sw;
  let unhash_sequent_ids = current_sequent_id :: new_goal_ids_rev in
  let old_current_sequent_id = pt.current_sequent_id in
  let old_current_sequent = pt.current_sequent in
  let old_other_open_goals = pt.other_open_goals in
  pt.current_sequent_id <- current_sequent_id;
  pt.current_sequent <- sw;
  pt.other_open_goals <- 
    list_set_union_disjoint new_goal_ids_rev pt.other_open_goals;
  let open_goal_count = List.length pt.other_open_goals  + 1 in
  let message = match List.length all_subgoals with
    | 0 -> assert false
    | 1 -> 
      Printf.sprintf "%d open goal%s (no new)" 
	open_goal_count (if open_goal_count > 1 then "s" else "")
    | n ->
      Printf.sprintf "%d open goal%s (%d new)"
	open_goal_count (if open_goal_count > 1 then "s" else "") (n - 1)
  in
  pt.window#message message;
  let undo () =
    pc#delete_non_sticky_external_windows;
    List.iter (fun s -> s#delete_non_sticky_external_windows) all_subgoals;
    clear_children old_current_sequent;
    old_current_sequent#mark_current;
    List.iter (fun id -> Hashtbl.remove pt.sequent_hash id) unhash_sequent_ids;
    List.iter 
      (fun sw -> if sw#is_selected then pt.window#set_selected_node None)
      all_subgoals;
    if pc#is_selected then pt.window#set_selected_node None;
    pt.current_sequent_id <- old_current_sequent_id;
    pt.current_sequent <- old_current_sequent;
    pt.other_open_goals <- old_other_open_goals;
  in
  add_undo_action pt state undo;
  pt.need_redraw <- true


(** Add [proof_command] as final command, which solved the current
    goal, to the current branch. If [cheated_flag] is set, the branch
    is marked as cheated. This function only finishes the current
    branch, moving to the next open subgoal (if necessary) is done by
    {!internal_switch_to}.
*)
let finish_branch pt state proof_command cheated_flag =
  let pc = pt.window#new_proof_command proof_command in
  let pc = (pc :> proof_tree_element) in
  pt.current_sequent#unmark_current;
  set_children pt.current_sequent [pc];
  if cheated_flag 
  then pc#mark_cheated
  else pc#mark_proved;
  let old_cheated = pt.cheated in
  let old_current_sequent = pt.current_sequent in
  let undo () =
    pc#delete_non_sticky_external_windows;
    clear_children old_current_sequent;
    old_current_sequent#unmark_proved_or_cheated;
    pt.cheated <- old_cheated;
  in
  add_undo_action pt state undo;
  if cheated_flag then pt.cheated <- true;
  pt.need_redraw <- true


(** Switch to [new_current_sequent_id], that is, mark this sequent as
    the current one. If [old_open_sequent_id] equals [None] the switch
    occurs because the preceeding current sequent has been solved.
    Otherwise, there is a real focus switch and [old_open_sequent_id]
    contains the old current sequent, which is marked as normal open
    goal now.
*)
let internal_switch_to pt state old_open_sequent_id new_current_sequent_id =
  assert(match old_open_sequent_id with 
    | None -> true
    | Some id -> not (List.mem id pt.other_open_goals));
  (* The user might switch to the current sequent *)
  assert(new_current_sequent_id = pt.current_sequent_id ||
      List.mem new_current_sequent_id pt.other_open_goals);
  let new_current_sequent = 
    Hashtbl.find pt.sequent_hash new_current_sequent_id 
  in
  let new_current_sequent = (new_current_sequent :> proof_tree_element) in
  new_current_sequent#mark_current;
  pt.window#set_current_node new_current_sequent;
  let old_current_sequent_id = pt.current_sequent_id in
  let old_current_sequent = pt.current_sequent in
  let old_other_open_goals = pt.other_open_goals in
  let undo () =
    new_current_sequent#unmark_current;
    pt.current_sequent_id <- old_current_sequent_id;
    pt.current_sequent <- old_current_sequent;
    pt.other_open_goals <- old_other_open_goals;
  in
  pt.current_sequent_id <- new_current_sequent_id;
  pt.current_sequent <- new_current_sequent;
  let all_open_goals = 
    (match old_open_sequent_id with
      | None -> pt.other_open_goals
      | Some id -> list_set_add_nonpresent_element id pt.other_open_goals
    )
  in
  pt.other_open_goals <- 
    list_set_remove_element new_current_sequent_id all_open_goals;
  add_undo_action pt state undo;
  pt.need_redraw <- true


(** Finish the current branch with [proof_command] and switch to
    [current_sequent] as next current sequent.
*)
let finish_branch_and_switch_to pt state proof_command cheated_flag
    current_sequent_id additional_ids =
  assert(not (List.mem current_sequent_id additional_ids));
  assert(list_set_subset additional_ids pt.other_open_goals);
  finish_branch pt state proof_command cheated_flag;
  internal_switch_to pt state None current_sequent_id;
  let open_goal_count = List.length pt.other_open_goals + 1 in
  let message = 
    Printf.sprintf "%s (%d goal%s remaining)" 
      (if cheated_flag
       then Gtk_ext.pango_markup_bold_color "Branch aborted" 
	  !cheated_gdk_color
       else Gtk_ext.pango_markup_bold_color "Branch finished" 
	  !proved_gdk_color)
      open_goal_count
      (if open_goal_count > 1 then "s" else "")
  in
  pt.window#message message


(* See mli for doc *)
let process_current_goals state proof_name proof_command cheated_flag
    current_sequent_id current_sequent_text additional_ids =
  (match !current_proof_tree with
    | Some pt -> 
      if pt.proof_name <> proof_name 
      then stop_proof_tree_last_selected pt state
    | None -> ());
  match !current_proof_tree with
    | None -> 
      assert(additional_ids = []);
      assert(cheated_flag = false);
      start_new_proof state proof_name current_sequent_id current_sequent_text
    | Some pt ->
      if pt.current_sequent_id <> current_sequent_id &&
	Hashtbl.mem pt.sequent_hash current_sequent_id
      then
	finish_branch_and_switch_to pt state proof_command cheated_flag
	  current_sequent_id additional_ids
      else
	add_new_goal pt state proof_command cheated_flag current_sequent_id 
	  current_sequent_text additional_ids


(** Update the sequent text for some sequent. This function is used
    for both, setting the new sequent text as well as reseting to the
    old sequent text in the undo action. 
*)
let change_sequent_text proof_window sequent text () =
  sequent#update_sequent text;
  if sequent#is_selected then proof_window#refresh_sequent_area


(** Udate the sequent text for some sequent text and set an
    appropriate undo action.
*)
let update_sequent_element pt state sw sequent_text =
  let old_sequent_text = sw#content in
  change_sequent_text pt.window sw sequent_text ();
  add_undo_action pt state (change_sequent_text pt.window sw old_sequent_text)  


(* See mli for doc *)
let update_sequent state proof_name sequent_id sequent_text =
  match !current_proof_tree with
    | None ->
      raise (Proof_tree_error "Update sequent without current proof tree")
    | Some pt ->
      if pt.proof_name <> proof_name
      then raise (Proof_tree_error "Update sequent on other non-current proof");
      try
	update_sequent_element pt state 
	  (Hashtbl.find pt.sequent_hash sequent_id) sequent_text
      with
	| Not_found ->
	  raise (Proof_tree_error "Update unknown sequent")


(* See mli for doc *)
let switch_to state proof_name new_current_sequent_id =
  match !current_proof_tree with
    | None ->
      raise (Proof_tree_error "Switch to sequent without current proof tree")
    | Some pt ->
      if pt.proof_name <> proof_name
      then raise (Proof_tree_error "Switch to sequent on other proof");
      pt.current_sequent#unmark_current;
      internal_switch_to pt state
	(Some pt.current_sequent_id) new_current_sequent_id;
      let open_goal_count = List.length pt.other_open_goals + 1 in
      let message = 
	Printf.sprintf "Branch changed (%d goal%s remaining)" 
	  open_goal_count
	  (if open_goal_count > 1 then "s" else "")
      in
      pt.window#message message


let process_proof_complete state proof_name proof_command cheated_flag =
  match !current_proof_tree with
    | None -> raise (Proof_tree_error "Finish proof without current proof tree")
    | Some pt -> 
      if pt.proof_name <> proof_name
      then raise (Proof_tree_error "Finish other non-current proof");
      finish_branch pt state proof_command cheated_flag;
      let message = 
	if pt.cheated 
	then Gtk_ext.pango_markup_bold_color "False proof finished" 
	  !cheated_gdk_color
	else Gtk_ext.pango_markup_bold_color "Proof finished" 
	  !proved_gdk_color
      in
      pt.window#message message;
      stop_proof_tree_last_selected pt state


(** Delete the proof tree structure with the given name from the lists
    of live and not-cloned proof tree structures. This function is
    used for {!Proof_window.delete_proof_tree_callback}.
*)
let clear_proof_tree_lists proof_name =
  let proof_tree_list_fold_fun pts pt =
    if pt.proof_name = proof_name
    then begin
      pt.window#delete_proof_window;
      pts
    end
    else pt :: pts
  in
  all_proof_trees_for_undo := 
    List.fold_left proof_tree_list_fold_fun [] !all_proof_trees_for_undo;
  undo_surviver_trees :=
    List.fold_left proof_tree_list_fold_fun [] !undo_surviver_trees

let _ = delete_proof_tree_callback := clear_proof_tree_lists


let quit_proof proof_name =
  (match !current_proof_tree with 
    | None -> ()
    | Some pt ->
      if pt.proof_name = proof_name
      then current_proof_tree := None
  );
  clear_proof_tree_lists proof_name

let finish_drawing () = match !current_proof_tree with
  | None -> ()
  | Some pt -> 
    if pt.need_redraw then 
      pt.window#refresh_and_position;
    pt.need_redraw <- false
      

