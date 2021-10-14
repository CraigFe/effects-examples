(* Asynchronous IO scheduler.
 *
 * For each blocking action, if the action can be performed immediately, then it
 * is. Otherwise, the thread performing the blocking task is suspended and
 * automatically wakes up when the action completes. The suspend/resume is
 * transparent to the programmer.
 *)

type file_descr = Unix.file_descr
type sockaddr = Unix.sockaddr
type msg_flag = Unix.msg_flag

exception%effect Fork  : (unit -> unit) -> unit
exception%effect Yield : unit
exception%effect Accept : file_descr -> (file_descr * sockaddr)
exception%effect Recv : file_descr * bytes * int * int * msg_flag list -> int
exception%effect Send : file_descr * bytes * int * int * msg_flag list -> int
exception%effect Sleep : float -> unit

let fork f =
  perform (Fork f)

let yield () =
  perform Yield

let accept fd =
  perform (Accept fd)

let recv fd buf pos len mode =
  perform (Recv (fd, buf, pos, len, mode))

let send fd bus pos len mode =
  perform (Send (fd, bus, pos, len, mode))

let sleep timeout =
  perform (Sleep timeout)

(** Poll to see if the file descriptor is available to read. *)
let poll_rd fd =
  let r,_,_ = Unix.select [fd] [] [] 0. in
  match r with
  | [] -> false
  | _ -> true

(** Poll to see if the file descriptor is available to write. *)
let poll_wr fd =
  let _,r,_ = Unix.select [] [fd] [] 0. in
  match r with
  | [] -> false
  | _ -> true

type read =
  | Accept of (file_descr * sockaddr, unit) continuation
  | Recv of bytes * int * int * msg_flag list * (int, unit) continuation

type write =
  | Send of bytes * int * int * msg_flag list * (int, unit) continuation

type timeout =
  | Sleep of (unit, unit) continuation

type runnable =
  | Thread : ('a, unit) continuation * 'a -> runnable
  | Read : file_descr * read -> runnable
  | Write : file_descr * write -> runnable

type state =
  { run_q : runnable Queue.t;
    read_ht : (file_descr, read) Hashtbl.t;
    write_ht : (file_descr, write) Hashtbl.t;
    sleep_ht : (float, timeout) Hashtbl.t; }

let init () =
  { run_q = Queue.create ();
    read_ht = Hashtbl.create 13;
    write_ht = Hashtbl.create 13;
    sleep_ht = Hashtbl.create 13; }

let enqueue_thread st k x =
  Queue.push (Thread(k, x)) st.run_q

let enqueue_read st fd op =
  Queue.push (Read(fd, op)) st.run_q

let enqueue_write st fd op =
  Queue.push (Write(fd, op)) st.run_q

let dequeue st =
  match Queue.pop st.run_q with
  | Thread(k, x) -> continue k x
  | Read(fd, Accept k) ->
    let res = Unix.accept fd in
    continue k res
  | Read(fd, Recv(buf, pos, len, mode, k)) ->
    let res = Unix.recv fd buf pos len mode in
    continue k res
  | Write(fd, Send(buf, pos, len, mode, k)) ->
    let res = Unix.send fd buf pos len mode in
    continue k res

let block_accept st fd k =
  Hashtbl.add st.read_ht fd (Accept k)

let block_recv st fd buf pos len mode k =
  Hashtbl.add st.read_ht fd (Recv(buf, pos, len, mode, k))

let block_send st fd buf pos len mode k =
  Hashtbl.add st.write_ht fd (Send(buf, pos, len, mode, k))

let block_sleep st span k =
  let time = Unix.gettimeofday () +. span in
  Hashtbl.add st.sleep_ht time (Sleep k)

(* Wakes up sleeping threads.
 *
 * Returns [(b, t)] where [t] is the eariest time in the future when a thread
 * needs to wake up, and [b] is true if some thread is woken up.
 *)
let wakeup st now : bool * float =
  let (l,w,n) =
    Hashtbl.fold
      (fun t (Sleep k) (l, w, next) ->
        if t <= now then
          (enqueue_thread st k (); (t::l, true, next))
        else if t < next then
          (l, w, t)
        else (l, w, next))
      st.sleep_ht ([], false, max_float)
  in
  List.iter (fun t -> Hashtbl.remove st.sleep_ht t) l;
  (w, n)

let rec schedule st =
  if Queue.is_empty st.run_q then (* No runnable threads *)
    if Hashtbl.length st.read_ht = 0 &&
       Hashtbl.length st.write_ht = 0 &&
       Hashtbl.length st.sleep_ht = 0 then () (* We are done. *)
    else
      let now = Unix.gettimeofday () in
      let (thrd_has_woken_up, next_wakeup_time) = wakeup st now in
      if thrd_has_woken_up then
        schedule st
      else if next_wakeup_time = max_float then
        perform_io st (-1.)
      else perform_io st (next_wakeup_time -. now)
  else (* Still have runnable threads *)
    dequeue st

and perform_io st timeout =
  let rd_fds = Hashtbl.fold (fun fd _ acc -> fd::acc) st.read_ht [] in
  let wr_fds = Hashtbl.fold (fun fd _ acc -> fd::acc) st.write_ht [] in
  let rdy_rd_fds, rdy_wr_fds, _ = Unix.select rd_fds wr_fds [] timeout in
  let rec resume ht enqueue = function
  | [] -> ()
  | x::xs ->
      enqueue st x (Hashtbl.find ht x);
      Hashtbl.remove ht x;
      resume ht enqueue xs
  in
  resume st.read_ht enqueue_read rdy_rd_fds;
  resume st.write_ht enqueue_write rdy_wr_fds;
  if timeout > 0. then ignore (wakeup st (Unix.gettimeofday ())) else ();
  schedule st

let run main =
  let st = init () in
  let rec fork st f =
    match f () with
    | () -> schedule st
    | exception exn ->
        print_string (Printexc.to_string exn);
        schedule st
    | [%effect? Yield , k] ->
        enqueue_thread st k ();
        schedule st
    | [%effect? (Fork f), k] ->
        enqueue_thread st k ();
        fork st f
    | [%effect? (Accept fd), k] ->
        if poll_rd fd then begin
          let res = Unix.accept fd in
          continue k res
        end else begin
          block_accept st fd k;
          schedule st
        end
    | [%effect? (Recv (fd, buf, pos, len, mode)), k] ->
        if poll_rd fd then begin
          let res = Unix.recv fd buf pos len mode in
          continue k res
        end else begin
          block_recv st fd buf pos len mode k;
          schedule st
        end
    | [%effect? (Send (fd, buf, pos, len, mode)), k] ->
        if poll_wr fd then begin
          let res = Unix.send fd buf pos len mode in
          continue k res
        end else begin
          block_send st fd buf pos len mode k;
          schedule st
        end
    | [%effect? (Sleep t), k] ->
        if t <= 0. then continue k ()
        else begin
          block_sleep st t k;
          schedule st
        end
  in
  fork st main
