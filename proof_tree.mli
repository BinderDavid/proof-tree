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
 * $Id: proof_tree.mli,v 1.10 2011/10/20 21:08:11 tews Exp $
 *)


(** Internal representation of proof trees with undo info *)


(** Process a current-goals command from Proof General, updating the
    proof-tree display in the right way. With the help of the internal
    state, especially the {!current_proof_tree}, the following cases
    are distinguished:

    {ol
    {- A new proof has just been started (in this case argument
    [proof_command] is ignored). This case applies when there is no
    {!current_proof_tree} or if the name of {!current_proof_tree}
    differs from argument [proof_name]. In the latter case the old
    current proof is finished.}
    {- The old current branch has been finished (possibly with a
    cheating command such as [admit]) and the proof assistant has
    switched to the next open goal. This case applies when the new
    current goal [current_sequent_id] is in the hash of known
    sequents and differs from the old current sequent.}
    {- A proof command has been applied to the current sequent,
    yielding a new current sequent and possibly some additional
    subgoals. This is the remaining case that applies when the two
    cases above do not apply. More specifically, this case applies
    when the new current sequent [current_sequent_id] is not in the
    hash of known sequents. As a special exception, this case does
    also apply when the new current sequent equals the old current
    sequent and is therefore found in the hash of known sequents (this
    happens if the user applied a non-failing command, that didn't
    change the goal, auch as [auto] in some cases.)
    } }

    @param state state for undo
    @param proof_name name of the proof
    @param proof_command command issued to the prover
    @param cheated_flag is true if the command is a cheating one
    @param current_sequent_id ID of current sequent
    @param current_sequent_text the current sequent itself
    @param additional_ids ID's of the additionally open goals
    @param uninstantiated existential variables
*)
val process_current_goals :
  int -> string -> string -> 
  bool -> string -> string -> string list -> string list -> unit


(** Process an [update-sequent] command. This function is a wrapper
    around {!update_sequent_element}, which looks up the right sequent
    object and produces appropriate errors, if something goes wrong.

    @param state state for undo
    @param proof_name name of proof
    @param sequent_id ID of sequent to update
    @param sequent_text new sequent text
*)
val update_sequent : int -> string -> string -> string -> unit


(** Switch to a different open goal.

    @param state state for undo
    @param proof_name name of proof
    @param new_current_id id of new current goal
*)
val switch_to : int -> string -> string -> unit


(** Finish the current proof.

    @param state state for undo
    @param proof_name name of the proof
    @param proof_command last command
    @param cheated_flag is true if the command is a cheating one
*)
val process_proof_complete : int -> string -> string -> bool -> unit

(** Undo all changes to reach state [state]. That is, all changes with
    a strictly greater state number are undone. Proof trees started
    later than [state] will be deleted. Those finished earlier than
    [state] remain untouched. All proof trees will be identical to the
    point in time before the first action with a state strictly
    greater than [state] has been processed.
*)
val undo : int -> unit


(** Close the proof window for [proof_name].

    @param proof_name name of the proof
*)
val quit_proof : string -> unit


(** For efficiency in proof replay the proof tree display and the
    sequent area are not redrawn after every change. Changes are only
    recorded in the internal data structures. This function cases a
    redisplay of those items.
*)
val finish_drawing : unit -> unit


(** Take the necessary actions when the configuration record changed.
    Calls the {!Proof_window.proof_window.configuration_updated}
    method on all live proof windows.
*)
val configuration_updated : unit -> unit

