(* Why is `clone_continuation` in `Obj` module?
 * This is because one-shot continuations and multi-shot continuations mix
 * badly. This program illustrates that an resuming an inner one-shot
 * continuation within an outer multi-shot context causes runtime error.
 *)

exception%effect Foo : unit
exception%effect Bar : unit

let _ =
  try begin
    try perform Foo
    with [%effect? Foo, k] -> (* This continuation is resumed twice *)
      continue k (perform Bar)
  end with [%effect? Bar, k] ->
    continue (k (* XXX: continuation cloning currently unsupported *)) (); continue k ()
