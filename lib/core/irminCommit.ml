(*
 * Copyright (c) 2013-2014 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Core_kernel.Std

type 'key t = {
  node   : 'key option;
  parents: 'key list;
  date   : float;
  origin : string;
} with bin_io, compare, sexp

let to_json json_of_key t =
  `O (
    ("parents", Ezjsonm.list json_of_key t.parents) ::
    ("date"   , Ezjsonm.string (Float.to_string t.date)) ::
    ("origin" , Ezjsonm.string t.origin) ::
    match t.node with
    | None   -> []
    | Some t -> [ ("node", json_of_key t) ]
  )

let of_json key_of_json json =
  let parents =
    Ezjsonm.get_list key_of_json (Ezjsonm.find json ["parents"]) in
  let origin =
    Ezjsonm.get_string (Ezjsonm.find json ["origin"]) in
  let date =
    Float.of_string (Ezjsonm.get_string (Ezjsonm.find json ["date"])) in
  let node =
    try Some (key_of_json (Ezjsonm.find json ["node"]))
    with Not_found -> None in
  { node; parents; date; origin }

module L = Log.Make(struct let section = "COMMIT" end)

module type S = sig
  type key
  include IrminContents.S with type t = key t
end

module S (K: IrminKey.S) = struct

  type key = K.t

  module S = IrminMisc.Identifiable(struct
      type nonrec t = K.t t
      with bin_io, compare, sexp
    end)
  include S

  let to_json =
    to_json K.to_json

  let of_json =
    of_json K.of_json

  let merge =
    IrminMerge.default (module S)

  let of_bytes str =
    IrminMisc.read bin_t (Bigstring.of_string str)

  let of_bytes_exn str =
    let buf = Bigstring.of_string str in
    bin_read_t ~pos_ref:(ref 0) buf

  let key t =
    K.of_bigarray (IrminMisc.write bin_t t)

end

module SHA1 = S(IrminKey.SHA1)

module type STORE = sig
  type key
  type value = key t
  include IrminStore.AO with type key := key
                         and type value := value
  val commit: t -> date:float -> origin:string -> ?node:key IrminNode.t ->
    parents:value list -> (key * value) Lwt.t
  val node: t -> value -> key IrminNode.t Lwt.t option
  val parents: t -> value -> value Lwt.t list
  val merge: t -> date:float -> origin:string -> key IrminMerge.t
  module Key: IrminKey.S with type t = key
  module Value: S with type key = key
end

module Make
    (K     : IrminKey.S)
    (Node  : IrminNode.STORE with type key = K.t and type value = K.t IrminNode.t)
    (Commit: IrminStore.AO   with type key = K.t and type value = K.t t)
= struct

  type key = K.t
  type value = key t
  type t = Node.t * Commit.t

  module Key = K
  module Value = S(K)

  open Lwt

  let create () =
    Node.create ()   >>= fun n ->
    Commit.create () >>= fun c ->
    return (n, c)

  let add (_, t) c =
    Commit.add t c

  let read (_, t) c =
    Commit.read t c

  let read_exn (_, t) c =
    Commit.read_exn t c

  let mem (_, t) c =
    Commit.mem t c

  let node (n, _) c =
    match c.node with
    | None   -> None
    | Some k -> Some (Node.read_exn n k)

  let commit (n, c) ~date ~origin ?node ~parents =
    begin match node with
      | None      -> return_none
      | Some node -> Node.add n node >>= fun k -> return (Some k)
    end
    >>= fun node ->
    Lwt_list.map_p (Commit.add c) parents
    >>= fun parents ->
    let commit = { node; parents; date; origin } in
    Commit.add c commit >>= fun key ->
    return (key, commit)

  let parents t c =
    List.map ~f:(read_exn t) c.parents

  module Graph = IrminGraph.Make(K)(IrminReference.String)

  let list t key =
    L.debugf "list %s" (K.to_string key);
    let pred = function
      | `Commit k ->
        read_exn t k >>= fun r ->
        return (List.map ~f:(fun k -> `Commit k) r.parents)
      | _ -> return_nil in
    Graph.closure pred ~min:[] ~max:[`Commit key] >>= fun g ->
    let commits = IrminGraph.to_commits (Graph.vertex g) in
    return commits

  let dump (_, t) =
    Commit.dump t

  let merge_node n =
    IrminMerge.some (Node.merge n)

  let merge (n, _ as t) ~date ~origin =
    let merge ~old k1 k2 =
      read_exn t old >>= fun vold ->
      read_exn t k1  >>= fun v1   ->
      read_exn t k2  >>= fun v2   ->
      IrminMerge.merge (merge_node n) ~old:vold.node v1.node v2.node >>= fun node ->
      let parents = [k1; k2] in
      let commit = { node; parents; date; origin } in
      add t commit
    in
    IrminMerge.create' (module K) merge

end
