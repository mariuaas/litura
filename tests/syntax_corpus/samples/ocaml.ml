(* OCaml: nested (* comments *), variants, modules, functors, labels. Ünïcode ✓ *)
open Printf

type shape =
  | Circle of float
  | Rect of { width : float; height : float }
  | Named of string

module type ORDERED = sig
  type t
  val compare : t -> t -> int
end

module Make_set (O : ORDERED) = struct
  type elt = O.t
  type t = elt list
  let empty : t = []
  let rec add x = function
    | [] -> [ x ]
    | y :: rest as l ->
        let c = O.compare x y in
        if c = 0 then l else if c < 0 then x :: l else y :: add x rest
end

module Int_set = Make_set (struct
  type t = int
  let compare = compare
end)

let area ?(scale = 1.0) ~shape () =
  match shape with
  | Circle r when r > 0. -> scale *. Float.pi *. r *. r
  | Circle _ -> 0.
  | Rect { width; height } -> scale *. width *. height
  | Named name -> float_of_int (String.length name)

let () =
  let s = List.fold_left (fun acc x -> Int_set.add x acc) Int_set.empty [ 3; 1; 2 ] in
  let text = {|a quoted "string" — ünïcode|} in
  printf "%d %f %s %c\n" (List.length s) (area ~shape:(Circle 1.5) ()) text 'x';
  try raise Not_found with Not_found -> ()
