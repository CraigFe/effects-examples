type 'a cont
(** Represents a blocked computation that waits for a value of type 'a. *)

exception%effect Suspend : ('a cont -> unit) -> 'a
(** [Perform @@ Suspend f] applies [f] to the current continuation, and suspends the
    execution of the current thread, and switches to the next thread in the
    scheduler's queue. *)

exception%effect Resume : ('a cont * 'a) -> unit
(** [perform @@ Resume (k,v)] prepares the suspended continuation [k] with value [v] and
    enqueues it to the scheduler queue. *)

exception%effect Fork : (unit -> unit) -> unit
(** [perform @@ Fork f] forks [f] as a new thread to which control immediately switches to. *)

exception%effect Yield : unit
(** [perform Yield] suspends the current thread and switches to the next thread from
    the run queue. *)

val run : (unit -> unit) -> unit
(** [run f] runs [f] with the cooperative-threaded scheduler. *)
