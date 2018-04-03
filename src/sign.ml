(** Signature for symbols. *)

open Console
open Files
open Terms
open Pos

(** Representation of a signature. It roughly corresponds to a set of symbols,
    defined in a single module (or file). *)
type t =
  { symbols : (string, symbol) Hashtbl.t
  ; path    : module_path (*FIXME: remove*)
  ; deps    : (module_path, (string * rule) list) Hashtbl.t }

(* NOTE the [deps] field contains a hashtable binding the [module_path] of the
   external modules on which the current signature depends to an association
   list. This association list then maps definable symbols of the external
   module to additional reduction rules defined in the current signature. *)

(** [create path] creates an empty signature with module path [path]. *)
let create : module_path -> t = fun path ->
  { path ; symbols = Hashtbl.create 37 ; deps = Hashtbl.create 11 }

(** [find sign name] finds the symbol named [name] in [sign] if it exists, and
    raises the [Not_found] exception otherwise. *)
let find : t -> string -> symbol =
  fun sign name -> Hashtbl.find sign.symbols name

(** System state.*)
type state =
  (** [loaded] stores the signatures of the known (already compiled) modules. An
    important invariant is that all the occurrences of a symbol are physically
    equal (even across different signatures). In particular, this requires the
      objects to be copied when loading an object file. *)
  { s_loaded : (module_path, t) Hashtbl.t

  (** [loading] contains the [module_path] of the signatures (or files) that are
    being processed. They are stored in a stack due to dependencies. Note that
    the topmost element corresponds to the current module.  If a [module_path]
    appears twice in the stack, then there is a circular dependency. *)
  ; s_loading : module_path Stack.t

  ; s_path : module_path

  ; s_sign : t }

(** Initial state. *)
let initial_state (mp:module_path) : state =
  { s_loaded = Hashtbl.create 7
  ; s_loading = Stack.create ()
  ; s_path = mp
  ; s_sign = create mp }

(** Current state. *)
let current_state = ref (initial_state [])

(** [link sign] establishes physical links to the external symbols. *)
let link : t -> unit = fun sign ->
  let rec link_term t =
    let link_binder b =
      let (x,t) = Bindlib.unbind mkfree b in
      Bindlib.unbox (Bindlib.bind_var x (lift (link_term t)))
    in
    match unfold t with
    | Vari(x)     -> t
    | Type        -> t
    | Kind        -> t
    | Symb(s)     -> Symb(link_symb s)
    | Prod(a,b)   -> Prod(link_term a, link_binder b)
    | Abst(a,t)   -> Abst(link_term a, link_binder t)
    | Appl(t,u)   -> Appl(link_term t, link_term u)
    | Meta(_,_)   -> assert false
    | Patt(i,n,m) -> Patt(i, n, Array.map link_term m)
    | TEnv(t,m)   -> TEnv(t, Array.map link_term m)
  and link_rule r =
    let lhs = List.map link_term r.lhs in
    let (xs, rhs) = Bindlib.unmbind te_mkfree r.rhs in
    let rhs = lift (link_term rhs) in
    let rhs = Bindlib.unbox (Bindlib.bind_mvar xs rhs) in
    {r with lhs ; rhs}
  and link_symb s =
    if s.sym_path = sign.path then s else
    try
      let sign = Hashtbl.find !current_state.s_loaded s.sym_path in
      try find sign s.sym_name with Not_found -> assert false
    with Not_found -> assert false
  in
  let fn _ s =
    s.sym_type <- link_term s.sym_type;
    s.sym_rules <- List.map link_rule s.sym_rules;
  in
  Hashtbl.iter fn sign.symbols;
  let gn path ls =
    let sign =
      try Hashtbl.find !current_state.s_loaded path
      with Not_found -> assert false in
    let h (n, r) =
      let r = link_rule r in
      let s = find sign n in
      s.sym_rules <- s.sym_rules @ [r];
      (n, r)
    in
    Some(List.map h ls)
  in
  Hashtbl.filter_map_inplace gn sign.deps

(** [unlink sign] removes references to external symbols (and thus signatures)
    in the signature [sign]. This function is used to minimize the size of our
    object files, by preventing a recursive inclusion of all the dependencies.
    Note however that [unlink] processes [sign] in place, which means that the
    signature is invalidated in the process. *)
let unlink : t -> unit = fun sign ->
  let unlink_sym s = s.sym_type <- Kind; s.sym_rules <- [] in
  let rec unlink_term t =
    let unlink_binder b = unlink_term (snd (Bindlib.unbind mkfree b)) in
    let unlink_term_env t =
      match t with
      | TE_Vari(_) -> ()
      | _          -> assert false (* Should not happen, matching-specific. *)
    in
    match unfold t with
    | Vari(x)      -> ()
    | Type         -> ()
    | Kind         -> ()
    | Symb(s)      -> if s.sym_path <> sign.path then unlink_sym s
    | Prod(a,b)    -> unlink_term a; unlink_binder b
    | Abst(a,t)    -> unlink_term a; unlink_binder t
    | Appl(t,u)    -> unlink_term t; unlink_term u
    | Meta(_,_)    -> assert false (* Should not happen, uninstantiated. *)
    | Patt(_,_,_)  -> () (* The environment only contains variables. *)
    | TEnv(t,m)    -> unlink_term_env t; Array.iter unlink_term m
  and unlink_rule r =
    List.iter unlink_term r.lhs;
    let (xs, rhs) = Bindlib.unmbind te_mkfree r.rhs in
    unlink_term rhs
  in
  let fn _ s = unlink_term s.sym_type; List.iter unlink_rule s.sym_rules in
  Hashtbl.iter fn sign.symbols;
  let gn _ ls = List.iter (fun (_, r) -> unlink_rule r) ls in
  Hashtbl.iter gn sign.deps

(** [new_symbol sign name a definable] creates a new symbol named
    [name] of type [a] in the signature [sign]. The created symbol is
    also returned. *)
let new_symbol : t -> bool -> strloc -> term -> symbol =
  fun sign definable s sym_type ->
  let { elt = sym_name; pos } = s in
  if Hashtbl.mem sign.symbols sym_name then
    wrn "Redefinition of symbol %S at %a.\n" sym_name Pos.print pos;
  let sym = { sym_name = sym_name
            ; sym_type = sym_type
            ; sym_path = sign.path
            ; sym_rules = []
            ; sym_definable = definable } in
  Hashtbl.add sign.symbols sym_name (sym);
  out 3 "(stat) %s\n" sym_name; sym

(** [write sign file] writes the signature [sign] to the file [fname]. *)
let write : t -> string -> unit = fun sign fname ->
  match Unix.fork () with
  | 0 -> let oc = open_out fname in
         unlink sign; Marshal.to_channel oc sign [Marshal.Closures];
         close_out oc; exit 0
  | i -> ignore (Unix.waitpid [] i)

(* NOTE [Unix.fork] is used to safely [unlink] and write an object file, while
   preserving a valid copy of the written signature in the parent process. *)

(** [read fname] reads a signature from the object file [fname]. Note that the
    file can only be read properly if it was build with the same binary as the
    one being evaluated. If this is not the case, the program gracefully fails
    with an error message. *)
let read : string -> t = fun fname ->
  let ic = open_in fname in
  try
    let sign = Marshal.from_channel ic in
    close_in ic; sign
  with Failure _ ->
    close_in ic;
    fatal "File [%s] is incompatible with the current binary...\n" fname

(* NOTE here, we rely on the fact that a marshaled closure can only be read by
   processes running the same binary as the one that produced it. *)

(** [add_rule def r] adds the new rule [r] to the definable symbol [def]. When
    the rule does not correspond to a symbol of the current signature,  it  is
    also stored in the dependencies. *)
let add_rule : t -> symbol -> rule -> unit = fun sign sym r ->
  sym.sym_rules <- sym.sym_rules @ [r];
  out 3 "(rule) added a rule for symbol %s\n" sym.sym_name;
  if sym.sym_path <> sign.path then
    let m =
      try Hashtbl.find sign.deps sym.sym_path
      with Not_found -> assert false
    in
    Hashtbl.replace sign.deps sym.sym_path ((sym.sym_name, r) :: m)
