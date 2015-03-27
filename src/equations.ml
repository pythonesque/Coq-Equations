(**********************************************************************)
(* Equations                                                          *)
(* Copyright (c) 2009-2015 Matthieu Sozeau <matthieu.sozeau@inria.fr> *)
(**********************************************************************)
(* This file is distributed under the terms of the                    *)
(* GNU Lesser General Public License Version 2.1                      *)
(**********************************************************************)

open Cases
open Util
open Errors
open Names
open Nameops
open Term
open Termops
open Declarations
open Inductiveops
open Environ
open Vars
open Globnames
open Reductionops
open Typeops
open Type_errors
open Pp
open Proof_type
open Errors
open Glob_term
open Retyping
open Pretype_errors
open Evarutil
open Evarconv
open List
open Libnames
open Topconstr
open Entries
open Constrexpr
open Vars
open Tacexpr
open Tactics
open Tacticals
open Tacmach
open Context

open Equations_common
open Depelim

(* Debugging infrastructure. *)

let debug = true

let new_untyped_evar () =
  let _, ev = new_pure_evar empty_named_context_val Evd.empty mkProp in
    ev

let check_term env evd c t =
  Typing.check env (ref evd) c t

let check_type env evd t =
  ignore(Typing.sort_of env (ref evd) t)

let abstract_undefined evd =
  Evd.from_env ~ctx:(Evd.abstract_undefined_variables 
		       (Evd.evar_universe_context evd))
    (Global.env ())
      
let typecheck_rel_context evd ctx =
  let _ =
    List.fold_right
      (fun (na, b, t as rel) env ->
	 check_type env evd t;
	 Option.iter (fun c -> check_term env evd c t) b;
	 push_rel rel env)
      ctx (Global.env ())
  in ()

(** Bindings to Coq *)

let below_tactics_path =
  make_dirpath (List.map id_of_string ["Below";"Equations"])

let below_tac s =
  make_kn (MPfile below_tactics_path) (make_dirpath []) (mk_label s)

let tacident_arg h =
  Reference (Ident (dummy_loc,h))

let tacvar_arg h =
  let ipat = Genarg.in_gen (Genarg.rawwit Constrarg.wit_intro_pattern) 
    (dummy_loc, Misctypes.IntroNaming (Misctypes.IntroIdentifier h)) in
    TacGeneric ipat

let rec_tac h h' = 
  TacArg(dummy_loc, TacCall(dummy_loc, 
			    Qualid (dummy_loc, qualid_of_string "Equations.Below.rec"),
		[tacident_arg h;
		 tacvar_arg h']))

let rec_wf_tac h h' rel = 
  TacArg(dummy_loc, TacCall(dummy_loc, 
    Qualid (dummy_loc, qualid_of_string "Equations.Subterm.rec_wf_eqns_rel"),
			    [tacident_arg h;tacvar_arg h';			     
			     ConstrMayEval (Genredexpr.ConstrTerm rel)]))

let unfold_recursor_tac () = tac_of_string "Equations.Subterm.unfold_recursor" []

let equations_tac_expr () = 
  (TacArg(dummy_loc, TacCall(dummy_loc, 
   Qualid (dummy_loc, qualid_of_string "Equations.DepElim.equations"), [])))

let equations_tac () = tac_of_string "Equations.DepElim.equations" []

let set_eos_tac () = tac_of_string "Equations.DepElim.set_eos" []
    
let solve_rec_tac () = tac_of_string "Equations.Below.solve_rec" []

let find_empty_tac () = tac_of_string "Equations.DepElim.find_empty" []

let pi_tac () = tac_of_string "Equations.Subterm.pi" []

let noconf_tac () = tac_of_string "Equations.NoConfusion.solve_noconf" []

let simpl_equations_tac () = tac_of_string "Equations.DepElim.simpl_equations" []

let reference_of_global c =
  Qualid (dummy_loc, Nametab.shortest_qualid_of_global Idset.empty c)

let solve_equation_tac c = tac_of_string "Equations.DepElim.solve_equation"

let impossible_call_tac c = Tacintern.glob_tactic
  (TacArg(dummy_loc,TacCall(dummy_loc,
  Qualid (dummy_loc, qualid_of_string "Equations.DepElim.impossible_call"),
  [ConstrMayEval (Genredexpr.ConstrTerm (Constrexpr.CRef (reference_of_global c, None)))])))

let depelim_tac h = tac_of_string "Equations.DepElim.depelim"
  [tacident_arg h]

let do_empty_tac h = tac_of_string "Equations.DepElim.do_empty"
  [tacident_arg h]

let depelim_nosimpl_tac h = tac_of_string "Equations.DepElim.depelim_nosimpl"
  [tacident_arg h]

let simpl_dep_elim_tac () = tac_of_string "Equations.DepElim.simpl_dep_elim" []

let depind_tac h = tac_of_string "Equations.DepElim.depind"
  [tacident_arg h]

(* let mkEq t x y =  *)
(*   mkApp (Coqlib.build_coq_eq (), [| t; x; y |]) *)

let mkNot t =
  mkApp (Coqlib.build_coq_not (), [| t |])

let mkNot t =
  mkApp (Coqlib.build_coq_not (), [| t |])
      
let mkProd_or_subst (na,body,t) c =
  match body with
    | None -> mkProd (na, t, c)
    | Some b -> subst1 b c

let mkProd_or_clear decl c =
  if not (dependent (mkRel 1) c) then
    subst1 mkProp c
  else mkProd_or_LetIn decl c

let it_mkProd_or_clear ty ctx = 
  fold_left (fun c d -> mkProd_or_clear d c) ty ctx
      
let mkLambda_or_subst (na,body,t) c =
  match body with
    | None -> mkLambda (na, t, c)
    | Some b -> subst1 b c

let mkLambda_or_subst_or_clear (na,body,t) c =
  match body with
  | None when dependent (mkRel 1) c -> mkLambda (na, t, c)
  | None -> subst1 mkProp c
  | Some b -> subst1 b c

let mkProd_or_subst_or_clear (na,body,t) c =
  match body with
  | None when dependent (mkRel 1) c -> mkProd (na, t, c)
  | None -> subst1 mkProp c
  | Some b -> subst1 b c

let it_mkProd_or_subst ty ctx = 
  nf_beta Evd.empty (List.fold_left 
		       (fun c d -> whd_betalet Evd.empty (mkProd_or_LetIn d c)) ty ctx)

let it_mkProd_or_clean ty ctx = 
  nf_beta Evd.empty (List.fold_left 
		       (fun c (na,_,_ as d) -> whd_betalet Evd.empty 
			 (if na == Anonymous then subst1 mkProp c
			  else (mkProd_or_LetIn d c))) ty ctx)

let it_mkLambda_or_subst ty ctx = 
  whd_betalet Evd.empty
    (List.fold_left (fun c d -> mkLambda_or_LetIn d c) ty ctx)

let it_mkLambda_or_subst_or_clear ty ctx = 
  (List.fold_left (fun c d -> mkLambda_or_subst_or_clear d c) ty ctx)

let it_mkProd_or_subst_or_clear ty ctx = 
  (List.fold_left (fun c d -> mkProd_or_subst_or_clear d c) ty ctx)


(** Abstract syntax for dependent pattern-matching. *)

type pat =
  | PRel of int
  | PCstr of pconstructor * pat list
  | PInac of constr
  | PHide of int

type user_pat =
  | PUVar of identifier
  | PUCstr of constructor * int * user_pat list
  | PUInac of constr_expr

type user_pats = user_pat list

type context_map = rel_context * pat list * rel_context

open Termops

let mkInac env c =
  mkApp (Lazy.force coq_inacc, [| Typing.type_of env Evd.empty c ; c |])

let mkHide env c =
  mkApp (Lazy.force coq_hide, [| Typing.type_of env Evd.empty c ; c |])

let rec pat_constr = function
  | PRel i -> mkRel i
  | PCstr (c, p) -> 
      let c' = mkConstructU c in
	mkApp (c', Array.of_list (map pat_constr p))
  | PInac r -> r
  | PHide c -> mkRel c
    
let rec constr_of_pat ?(inacc=true) env = function
  | PRel i -> mkRel i
  | PCstr (c, p) ->
      let c' = mkConstructU c in
	mkApp (c', Array.of_list (constrs_of_pats ~inacc env p))
  | PInac r ->
      if inacc then try mkInac env r with _ -> r else r
  | PHide i -> mkHide env (mkRel i)

and constrs_of_pats ?(inacc=true) env l = map (constr_of_pat ~inacc env) l

let rec pat_vars = function
  | PRel i -> Int.Set.singleton i
  | PCstr (c, p) -> pats_vars p
  | PInac _ -> Int.Set.empty
  | PHide _ -> Int.Set.empty

and pats_vars l =
  fold_left (fun vars p ->
    let pvars = pat_vars p in
    let inter = Int.Set.inter pvars vars in
      if Int.Set.is_empty inter then
	Int.Set.union pvars vars
      else error ("Non-linear pattern: variable " ^
		     string_of_int (Int.Set.choose inter) ^ " appears twice"))
    Int.Set.empty l

let inaccs_of_constrs l = map (fun x -> PInac x) l

let rec pats_of_constrs l = map pat_of_constr l
and pat_of_constr c =
  match kind_of_term c with
  | Rel i -> PRel i
  | App (f, [| a ; c |]) when eq_constr f (Lazy.force coq_inacc) ->
      PInac c
  | App (f, [| a ; c |]) when eq_constr f (Lazy.force coq_hide) ->
      PHide (destRel c)
  | App (f, args) when isConstruct f ->
      let ((ind,_),_ as cstr) = destConstruct f in
      let nparams = Inductiveops.inductive_nparams ind in
      let params, args = Array.chop nparams args in
      PCstr (cstr, inaccs_of_constrs (Array.to_list params) @ pats_of_constrs (Array.to_list args))
  | Construct f -> PCstr (f, [])
  | _ -> PInac c


(** Pretty-printing *)

let pr_constr_pat env c =
  let pr = print_constr_env env c in
    match kind_of_term c with
    | App _ -> str "(" ++ pr ++ str ")"
    | _ -> pr

let pr_pat env c =
  let patc = constr_of_pat env c in
    pr_constr_pat env patc

let pr_context env c =
  let pr_decl env (id,b,t) = 
    let bstr = match b with Some b -> str ":=" ++ spc () ++ print_constr_env env b | None -> mt() in
    let idstr = match id with Name id -> pr_id id | Anonymous -> str"_" in
      idstr ++ bstr ++ str " : " ++ print_constr_env env t
  in
  let (_, pp) =
    match List.rev c with
    | decl :: decls -> 
	List.fold_left (fun (env, pp) decl ->
	  (push_rel decl env, pp ++ str ";" ++ spc () ++ pr_decl env decl))
	  (push_rel decl env, pr_decl env decl) decls
    | [] -> env, mt ()
  in pp

let ppcontext c = pp (pr_context (Global.env ()) c)

let pr_context_map env (delta, patcs, gamma) =
  let env' = push_rel_context delta env in
  let ctx = pr_context env delta in
  let ctx' = pr_context env gamma in
    (if List.is_empty delta then ctx else ctx ++ spc ()) ++ str "|-" ++ spc ()
    ++ prlist_with_sep spc (pr_pat env') (List.rev patcs) ++
      str " : "  ++ ctx'

let ppcontext_map context_map = pp (pr_context_map (Global.env ()) context_map)

(** Debugging functions *)

let typecheck_map evars (ctx, subst, ctx') =
  typecheck_rel_context evars ctx;
  typecheck_rel_context evars ctx';
  let env = push_rel_context ctx (Global.env ()) in
  let _ = 
    List.fold_right2 
      (fun (na, b, t) p subst ->
	 let c = constr_of_pat env p in
	   check_term env evars c (substl subst t);
	   (c :: subst))
      ctx' subst []
  in ()

let check_ctx_map evars map =
  if debug then
    try typecheck_map evars map; map
    with Type_errors.TypeError (env, e) ->
      errorlabstrm "equations"
	(str"Type error while building context map: " ++ pr_context_map (Global.env ()) map ++
	   spc () ++ Himsg.explain_type_error env evars e)
  else map
    
let mk_ctx_map evars ctx subst ctx' =
  let map = (ctx, subst, ctx') in check_ctx_map evars map

(** Specialize by a substitution. *)

let subst_pats_constr k s c = 
  let rec aux depth c =
    match kind_of_term c with
    | Rel n -> 
	let k = n - depth in 
	  if k > 0 then
	    try lift depth (pat_constr (nth s (pred k)))
	    with Failure "nth" -> c
	  else c
    | _ -> map_constr_with_binders succ aux depth c
  in aux k c

let subst_context s ctx =
  let (_, ctx') = fold_right
    (fun (id, b, t) (k, ctx') ->
      (succ k, (id, Option.map (subst_pats_constr k s) b, subst_pats_constr k s t) :: ctx'))
    ctx (0, [])
  in ctx'

let rec specialize s p = 
  match p with
  | PRel i -> (try nth s (pred i) with Failure "nth" -> p)
  | PCstr(c, pl) -> PCstr (c, specialize_pats s pl)
  | PInac r -> PInac (specialize_constr s r)
  | PHide i -> 
      (match nth s (pred i) (* FIXME *) with
      | PRel i -> PHide i
      | PHide i -> PHide i
      | PInac r -> PInac r
      | _ -> assert(false))

and specialize_constr s c = subst_pats_constr 0 s c
and specialize_pats s = map (specialize s)

let specialize_rel_context s ctx =
  let subst, res = List.fold_right
    (fun decl (k, acc) ->
      let decl = map_rel_declaration (subst_pats_constr k s) decl in
	(succ k, decl :: acc))
    ctx (0, [])
  in res

let mapping_constr (s : context_map) c = specialize_constr (pi2 s) c

(* Substitute a constr in a pattern. *)

let rec subst_constr_pat k t p = 
  match p with
  | PRel i -> 
      if i == k then PInac t
      else if i > k then PRel (pred i)
      else p
  | PCstr(c, pl) ->
      PCstr (c, subst_constr_pats k t pl)
  | PInac r -> PInac (substnl [t] (pred k) r)
  | PHide i -> PHide (destRel (substnl [t] (pred k) (mkRel i)))

and subst_constr_pats k t = map (subst_constr_pat k t)

(* Substitute a constr [cstr] in rel_context [ctx] for variable [k]. *)

let subst_rel_context k cstr ctx = 
  let (_, ctx') = fold_right 
    (fun (id, b, t) (k, ctx') ->
      (succ k, (id, Option.map (substnl [cstr] k) b, substnl [cstr] k t) :: ctx'))
    ctx (k, [])
  in ctx'

(* A telescope is a reversed rel_context *)

let subst_telescope cstr ctx = 
  let (_, ctx') = fold_left
    (fun (k, ctx') (id, b, t) ->
      (succ k, (id, Option.map (substnl [cstr] k) b, substnl [cstr] k t) :: ctx'))
    (0, []) ctx
  in rev ctx'

(* Substitute rel [n] by [c] in [ctx]
   Precondition: [c] is typable in [ctx] using variables 
   above [n] *)
    
let subst_in_ctx (n : int) (c : constr) (ctx : rel_context) : rel_context =
  let rec aux k after = function
    | [] -> []
    | (name, b, t as decl) :: before ->
	if k == n then (subst_rel_context 0 (lift (-k) c) (rev after)) @ before
	else aux (succ k) (decl :: after) before
  in aux 1 [] ctx

let set_in_ctx (n : int) (c : constr) (ctx : rel_context) : rel_context =
  let rec aux k after = function
    | [] -> []
    | (name, b, t as decl) :: before ->
	if k == n then (rev after) @ (name, Some (lift (-k) c), t) :: before
	else aux (succ k) (decl :: after) before
  in aux 1 [] ctx

(* Lifting patterns. *)

let rec lift_patn n k p = 
  match p with
  | PRel i ->
      if i >= k then PRel (i + n)
      else p
  | PCstr(c, pl) -> PCstr (c, lift_patns n k pl)
  | PInac r -> PInac (liftn n (succ k) r)
  | PHide r -> PHide (destRel (liftn n (succ k) (mkRel r)))
      
and lift_patns n k = map (lift_patn n k)

let lift_pat n p = lift_patn n 0 p
let lift_pats n p = lift_patns n 0 p

type program = 
  signature * clause list

and signature = identifier * rel_context * constr
  
and clause = lhs * clause rhs
  
and lhs = user_pats

and 'a rhs = 
  | Program of constr_expr
  | Empty of identifier Loc.located
  | Rec of identifier Loc.located * constr_expr option * 'a list
  | Refine of constr_expr * 'a list
  | By of (Tacexpr.raw_tactic_expr, Tacexpr.glob_tactic_expr) union * 'a list

type path = Evd.evar list

type splitting = 
  | Compute of context_map * types * splitting_rhs
  | Split of context_map * int * types * splitting option array
  | Valid of context_map * types * identifier list * tactic *
      (Proofview.entry * Proofview.proofview) *
      (goal * constr list * context_map * splitting) list
  | RecValid of identifier * splitting
  | Refined of context_map * refined_node * splitting

and refined_node = 
  { refined_obj : identifier * constr * types;
    refined_rettyp : types; 
    refined_arg : int;
    refined_path : path;
    refined_ex : existential_key;
    refined_app : constr * constr list;
    refined_revctx : context_map;
    refined_newprob : context_map;
    refined_newprob_to_lhs : context_map;
    refined_newty : types }

and splitting_rhs = 
  | RProgram of constr
  | REmpty of int
      
and unification_result = 
  (context_map * int * constr * pat) option

type problem = identifier * lhs

let specialize_mapping_constr (m : context_map) c = 
  specialize_constr (pi2 m) c

let rels_of_tele tele = rel_list 0 (List.length tele)

let patvars_of_tele tele = map (fun c -> PRel (destRel c)) (rels_of_tele tele)

let pat_vars_list n = list_tabulate (fun i -> PRel (succ i)) n

let intset_of_list =
  fold_left (fun s x -> Int.Set.add x s) Int.Set.empty

let split_context n c =
  let after, before = List.chop n c in
    match before with
    | hd :: tl -> after, hd, tl
    | [] -> raise (Invalid_argument "split_context")

let split_tele n (ctx : rel_context) =
  let rec aux after n l =
    match n, l with
    | 0, decl :: before -> before, decl, List.rev after
    | n, decl :: before -> aux (decl :: after) (pred n) before
    | _ -> raise (Invalid_argument "split_tele")
  in aux [] n ctx

(* Compute the transitive closure of the dependency relation for a term in a context *)

let rels_above ctx x =
  let len = List.length ctx in
    intset_of_list (list_tabulate (fun i -> x + succ i) (len - x))



let is_fix_proto t =
  match kind_of_term t with
  | App (f, args) when is_global (Lazy.force coq_fix_proto) f ->
      true
  | _ -> false

let fix_rels ctx =
  List.fold_left_i (fun i acc (_, _, t) -> 
    if is_fix_proto t then Int.Set.add i acc else acc)
    1 Int.Set.empty ctx

let rec dependencies_of_rel ctx k =
  let (n,b,t) = nth ctx (pred k) in
  let b = Option.map (lift k) b and t = lift k t in
  let bdeps = match b with Some b -> dependencies_of_term ctx b | None -> Int.Set.empty in
    Int.Set.union (Int.Set.singleton k) (Int.Set.union bdeps (dependencies_of_term ctx t))

and dependencies_of_term ctx t =
  let rels = free_rels t in
    Int.Set.fold (fun i -> Int.Set.union (dependencies_of_rel ctx i)) rels Int.Set.empty

let non_dependent ctx c =
  List.fold_left_i (fun i acc (_, _, t) -> 
    if not (dependent (lift (-i) c) t) then Int.Set.add i acc else acc)
    1 Int.Set.empty ctx

let subst_term_in_context t ctx =
  let (term, rel, newctx) = 
    List.fold_right 
      (fun (n, b, t) (term, rel, newctx) -> 
	 let decl' = (n, b, replace_term term (mkRel rel) t) in
	   (lift 1 term, succ rel, decl' :: newctx))
      ctx (t, 1, [])
  in newctx

let strengthen ?(full=true) ?(abstract=false) (ctx : rel_context) x (t : constr) =
  let rels = Int.Set.union (if full then rels_above ctx x else Int.Set.singleton x)
    (* (Int.Set.union *) (Int.Set.union (dependencies_of_term ctx t) (fix_rels ctx))
    (* (non_dependent ctx t)) *)
  in
  let len = length ctx in
  let nbdeps = Int.Set.cardinal rels in
  let lifting = len - nbdeps in (* Number of variables not linked to t *)
  let rec aux k n acc m rest s = function
    | decl :: ctx' ->
	if Int.Set.mem k rels then
	  let rest' = subst_telescope (mkRel (nbdeps + lifting - pred m)) rest in
	    aux (succ k) (succ n) (decl :: acc) m rest' (Inl n :: s) ctx'
	else aux (succ k) n (subst_telescope mkProp acc) (succ m) (decl :: rest) (Inr m :: s) ctx'
    | [] -> rev acc, rev rest, s
  in
  let (min, rest, subst) = aux 1 1 [] 1 [] [] ctx in
  let lenrest = length rest in
  let subst = rev subst in
  let reorder = List.map_i (fun i -> function Inl x -> (x + lenrest, i) | Inr x -> (x, i)) 1 subst in
  let subst = map (function Inl x -> PRel (x + lenrest) | Inr x -> PRel x) subst in
  let ctx' = 
    if abstract then 
      subst_term_in_context (lift (-lenrest) (specialize_constr subst t)) rest @ min
    else rest @ min 
  in
    (ctx', subst, ctx), reorder

let id_subst g = (g, rev (patvars_of_tele g), g)
	
let eq_context_nolet env sigma (g : rel_context) (d : rel_context) =
  try 
    snd 
      (List.fold_right2 (fun (na,_,t as decl) (na',_,t') (env, acc) ->
	if acc then 
	  (push_rel decl env,
	  (eq_constr t t' || is_conv env sigma t t'))
	else env, acc) g d (env, true))
  with Invalid_argument "List.fold_right2" -> false

let check_eq_context_nolet env sigma (_, _, g as snd) (d, _, _ as fst) =
  if eq_context_nolet env sigma g d then ()
  else errorlabstrm "check_eq_context_nolet"
    (str "Contexts do not agree for composition: "
       ++ pr_context_map env snd ++ str " and " ++ pr_context_map env fst)

let compose_subst ?(sigma=Evd.empty) ((g',p',d') as snd) ((g,p,d) as fst) =
  if debug then check_eq_context_nolet (Global.env ()) sigma snd fst;
  mk_ctx_map sigma g' (specialize_pats p' p) d
(*     (g', (specialize_pats p' p), d) *)

let push_mapping_context (n, b, t as decl) (g,p,d) =
  ((n, Option.map (specialize_constr p) b, specialize_constr p t) :: g,
   (PRel 1 :: map (lift_pat 1) p), decl :: d)
    
let lift_subst evd (ctx : context_map) (g : rel_context) = 
  let map = List.fold_right (fun decl acc -> push_mapping_context decl acc) g ctx in
    check_ctx_map evd map
    
let single_subst evd x p g =
  let t = pat_constr p in
    if eq_constr t (mkRel x) then
      id_subst g
    else if noccur_between 1 x t then
      (* The term to substitute refers only to previous variables. *)
      let substctx = subst_in_ctx x t g in
      let pats = list_tabulate
      	(fun i -> let k = succ i in
      		    if k == x then (lift_pat (-1) p) 
		    else if k > x then PRel (pred k) 
		    else PRel k)
      	(List.length g)
      (* let substctx = set_in_ctx x t g in *)
      (* let pats = list_tabulate  *)
      (* 	(fun i -> let k = succ i in if k = x then p else PRel k) *)
      (* 	(List.length g) *)
      in mk_ctx_map evd substctx pats g
    else
      let (ctx, s, g), _ = strengthen g x t in
      let x' = match nth s (pred x) with PRel i -> i | _ -> error "Occurs check singleton subst"
      and t' = specialize_constr s t in
	(* t' is in ctx. Do the substitution of [x'] by [t] now 
	   in the context and the patterns. *)
      let substctx = subst_in_ctx x' t' ctx in
      let pats = List.map_i (fun i p -> subst_constr_pat x' (lift (-1) t') p) 1 s in
	mk_ctx_map evd substctx pats g
    
exception Conflict
exception Stuck

type 'a unif_result = UnifSuccess of 'a | UnifFailure | UnifStuck
      
let rec unify evd flex g x y =
  if eq_constr x y then id_subst g
  else
    match kind_of_term x with
    | Rel i -> 
      if Int.Set.mem i flex then
	single_subst evd i (PInac y) g
      else raise Stuck
    | _ ->
      match kind_of_term y with
      | Rel i ->
	if Int.Set.mem i flex then
	  single_subst evd i (PInac x) g
	else raise Stuck
      | _ ->
	let (c, l) = decompose_app x 
	and (c', l') = decompose_app y in
	  if isConstruct c && isConstruct c' then
	    if eq_constr c c' then
	      unify_constrs evd flex g l l'
	    else raise Conflict
	  else raise Stuck

and unify_constrs evd flex g l l' = 
  match l, l' with
  | [], [] -> id_subst g
  | hd :: tl, hd' :: tl' ->
    let (d,s,_ as hdunif) = unify evd flex g hd hd' in
    let specrest = map (specialize_constr s) in
    let tl = specrest tl and tl' = specrest tl' in
    let tlunif = unify_constrs evd flex d tl tl' in
      compose_subst ~sigma:evd tlunif hdunif
  | _, _ -> raise Conflict

let flexible pats gamma =
  let (_, flex) =
    fold_left2 (fun (k,flex) pat decl ->
      match pat with
      | PInac _ -> (succ k, Int.Set.add k flex)
      | p -> (succ k, flex))
      (1, Int.Set.empty) pats gamma
  in flex

let rec accessible = function
  | PRel i -> Int.Set.singleton i
  | PCstr (c, l) -> accessibles l
  | PInac _ | PHide _ -> Int.Set.empty

and accessibles l =
  fold_left (fun acc p -> Int.Set.union acc (accessible p)) 
    Int.Set.empty l
  
let hidden = function PHide _ -> true | _ -> false

let rec match_pattern p c =
  match p, c with
  | PUVar i, t -> [i, t]
  | PUCstr (c, i, pl), PCstr ((c',u), pl') -> 
      if eq_constructor c c' then
	let params, args = List.chop i pl' in
	  match_patterns pl args
      else raise Conflict
  | PUInac _, _ -> []
  | _, _ -> raise Stuck

and match_patterns pl l =
  match pl, l with
  | [], [] -> []
  | hd :: tl, hd' :: tl' -> 
      let l = 
	try Some (match_pattern hd hd')
	with Stuck -> None
      in
      let l' = 
	try Some (match_patterns tl tl')
	with Stuck -> None
      in
	(match l, l' with
	| Some l, Some l' -> l @ l'
	| _, _ -> raise Stuck)
  | _ -> raise Conflict
      

open Constrintern

let matches (p : user_pats) ((phi,p',g') : context_map) = 
  try
    let p' = filter (fun x -> not (hidden x)) (rev p') in
      UnifSuccess (match_patterns p p')
  with Conflict -> UnifFailure | Stuck -> UnifStuck

let rec match_user_pattern p c =
  match p, c with
  | PRel i, t -> [i, t], []
  | PCstr ((c',_), pl'), PUCstr (c, i, pl) -> 
    if eq_constructor c c' then
      let params, args = List.chop i pl' in
	match_user_patterns args pl
    else raise Conflict
  | PCstr _, PUVar n -> [], [n, p]
  | PInac _, _ -> [], []
  | _, _ -> raise Stuck

and match_user_patterns pl l =
  match pl, l with
  | [], [] -> [], []
  | hd :: tl, hd' :: tl' -> 
    let l = 
      try Some (match_user_pattern hd hd')
      with Stuck -> None
    in
    let l' = 
      try Some (match_user_patterns tl tl')
      with Stuck -> None
    in
      (match l, l' with
      | Some (l1, l2), Some (l1', l2') -> l1 @ l1', l2 @ l2'
      | _, _ -> raise Stuck)
  | _ -> raise Conflict
      
let matches_user ((phi,p',g') : context_map) (p : user_pats) = 
  try UnifSuccess (match_user_patterns (filter (fun x -> not (hidden x)) (rev p')) p)
  with Conflict -> UnifFailure | Stuck -> UnifStuck

let lets_of_ctx env ctx evars s =
  let envctx = push_rel_context ctx env in
  let ctxs, pats, varsubst, len, ids = fold_left (fun (ctx', cs, varsubst, k, ids) (id, pat) -> 
    let c = pat_constr pat in
      match pat with
      | PRel i -> (ctx', cs, (i, id) :: varsubst, k, id :: ids)
      | _ -> 
	  let evars', ty = Typing.e_type_of envctx !evars c in
	    (evars := evars';
	     ((Name id, Some (lift k c), lift k ty) :: ctx', (c :: cs), varsubst, succ k, id :: ids)))
    ([],[],[],0,[]) s
  in
  let _, _, ctx' = List.fold_right (fun (n, b, t) (ids, i, ctx') ->
    try ids, pred i, ((Name (List.assoc i varsubst), b, t) :: ctx')
    with Not_found -> 
      let id' = Namegen.next_name_away n ids in
	id' :: ids, pred i, ((Name id', b, t) :: ctx')) ctx (ids, List.length ctx, [])
  in pats, ctxs, ctx'
      
let interp_constr_in_rhs env ctx evars (i,comp,impls) ty s lets c =
  let envctx = push_rel_context ctx env in
  let patslets, letslen = 
    fold_right (fun (n, b, t) (acc, len) -> 
      ((* lift len *)(Option.get b) :: acc, succ len)) lets ([], 0)
  in
  let pats, ctx, len = 
    let (pats, x, y) = lets_of_ctx env (lets @ ctx) evars 
      (map (fun (id, pat) -> id, lift_pat letslen pat) s) in
      pats, x @ y, List.length x 
  in
  let pats = pats @ map (lift len) patslets in
    match ty with
    | None ->
	let c, _ = interp_constr_evars_impls (push_rel_context ctx env) evars ~impls c 
	in
	let c' = substnl pats 0 c in
	  evars := Typeclasses.resolve_typeclasses ~filter:Typeclasses.all_evars env !evars;
	  let c' = nf_evar !evars c' in
	    c', Typing.type_of envctx !evars c'
	    
    | Some ty -> 
	let ty' = lift (len + letslen) ty in
	let ty' = nf_evar !evars ty' in
	let c, _ = interp_casted_constr_evars_impls 
	  (push_rel_context ctx env) evars ~impls c ty'
	in
	  evars := Typeclasses.resolve_typeclasses ~filter:Typeclasses.all_evars env !evars;
	  let c' = nf_evar !evars (substnl pats 0 c) in
	    c', nf_evar !evars (substnl pats 0 ty')
	  
let unify_type evars before id ty after =
  try
    let envids = ids_of_rel_context before @ ids_of_rel_context after in
    let envb = push_rel_context before (Global.env()) in
    let IndType (indf, args) = find_rectype envb !evars ty in
    let ind, params = dest_ind_family indf in
    let vs = map (Tacred.whd_simpl envb !evars) args in
    let params = map (Tacred.whd_simpl envb !evars) params in
    let newty = applistc (mkIndU ind) (params @ vs) in
    let cstrs = Inductiveops.type_of_constructors envb ind in
    let cstrs = 
      Array.mapi (fun i ty ->
	let ty = prod_applist ty params in
	let ctx, ty = decompose_prod_assum ty in
	let ctx, ids = 
	  fold_right (fun (n, b, t) (acc, ids) ->
	    match n with
	    | Name id -> let id' = Namegen.next_ident_away id ids in
		((Name id', b, t) :: acc), (id' :: ids)
	    | Anonymous ->
		let x = Namegen.id_of_name_using_hdchar
		  (push_rel_context acc envb) t Anonymous in
		let id = Namegen.next_name_away (Name x) ids in
		  ((Name id, b, t) :: acc), (id :: ids))
	    ctx ([], envids)
	in
	let env' = push_rel_context ctx (Global.env ()) in
	let IndType (indf, args) = find_rectype env' !evars ty in
	let ind, params = dest_ind_family indf in
	let constr = applist (mkConstructUi (ind, succ i), params @ rels_of_tele ctx) in
	let q = inaccs_of_constrs (rels_of_tele ctx) in	
	let constrpat = PCstr (((fst ind, succ i), snd ind), 
			       inaccs_of_constrs params @ patvars_of_tele ctx) in
	  env', ctx, constr, constrpat, q, args)
	cstrs
    in
    let res = 
      Array.map (fun (env', ctxc, c, cpat, q, us) -> 
	let _beforelen = length before and ctxclen = length ctxc in
	let fullctx = ctxc @ before in
	  try
	    let vs' = map (lift ctxclen) vs in
	    let p1 = lift_pats ctxclen (inaccs_of_constrs (rels_of_tele before)) in
	    let flex = flexible (p1 @ q) fullctx in
	    let s = unify_constrs !evars flex fullctx vs' us in
	      UnifSuccess (s, ctxclen, c, cpat)
	  with Conflict -> UnifFailure | Stuck -> UnifStuck) cstrs
    in Some (newty, res)
  with Not_found -> (* not an inductive type *)
    None

let blockers curpats ((_, patcs, _) : context_map) =
  let rec pattern_blockers p c =
    match p, c with
    | PUVar i, t -> []
    | PUCstr (c, i, pl), PCstr ((c',_), pl') -> 
	if eq_constructor c c' then patterns_blockers pl (snd (List.chop i pl'))
	else []
    | PUInac _, _ -> []
    | _, PRel i -> [i]
    | _, _ -> []

  and patterns_blockers pl l =
    match pl, l with
    | [], [] -> []
    | hd :: tl, PHide _ :: tl' -> patterns_blockers pl tl'
    | hd :: tl, hd' :: tl' -> 
	(pattern_blockers hd hd') @ (patterns_blockers tl tl')
    | _ -> []
	
  in patterns_blockers curpats (rev patcs)
    
open Printer
open Ppconstr

let rec pr_user_pat env = function
  | PUVar i -> pr_id i
  | PUCstr (c, i, f) -> 
      let pc = pr_constructor env c in
	if not (List.is_empty f) then str "(" ++ pc ++ spc () ++ pr_user_pats env f ++ str ")"
	else pc
  | PUInac c -> str "?(" ++ pr_constr_expr c ++ str ")"

and pr_user_pats env pats =
  prlist_with_sep spc (pr_user_pat env) pats

let pr_lhs = pr_user_pats

let pplhs lhs = pp (pr_lhs (Global.env ()) lhs)

let rec pr_rhs env = function
  | Empty (loc, var) -> spc () ++ str ":=!" ++ spc () ++ pr_id var
  | Rec ((loc, var), rel, s) -> spc () ++ str "=>" ++ spc () ++ str"rec " ++ pr_id var ++ spc () ++
      hov 1 (str "{" ++ pr_clauses env s ++ str "}")
  | Program rhs -> spc () ++ str ":=" ++ spc () ++ pr_constr_expr rhs
  | Refine (rhs, s) -> spc () ++ str "<=" ++ spc () ++ pr_constr_expr rhs ++ 
      spc () ++ str "=>" ++ spc () ++
      hov 1 (str "{" ++ pr_clauses env s ++ str "}")
  | By (Inl tac, s) -> spc () ++ str "by" ++ spc () ++ Pptactic.pr_raw_tactic tac
      ++ spc () ++ hov 1 (str "{" ++ pr_clauses env s ++ str "}")
  | By (Inr tac, s) -> spc () ++ str "by" ++ spc () ++ Pptactic.pr_glob_tactic env tac
      ++ spc () ++ hov 1 (str "{" ++ pr_clauses env s ++ str "}")
      
and pr_clause env (lhs, rhs) =
  pr_lhs env lhs ++ pr_rhs env rhs

and pr_clauses env =
  prlist_with_sep fnl (pr_clause env)

let ppclause clause = pp(pr_clause (Global.env ()) clause)

let pr_rel_name env i =
  pr_name (pi1 (lookup_rel i env))

let pr_splitting env split =
  let rec aux = function
    | Compute (lhs, ty, c) -> 
	let env' = push_rel_context (pi1 lhs) env in
	  hov 2 
	    ((match c with
	     | RProgram c -> str":=" ++ spc () ++
		 print_constr_env env' c ++ str " : " ++
		 print_constr_env env' ty
	     | REmpty i -> str":=!" ++ spc () ++ pr_rel_name (rel_context env') i)
	     ++ spc () ++ str " in context " ++  pr_context_map env lhs)
    | Split (lhs, var, ty, cs) ->
	let env' = push_rel_context (pi1 lhs) env in
	  hov 2
	  (str "Split: " ++ spc () ++ 
	    pr_rel_name (rel_context env') var ++ str" : " ++
	    print_constr_env env' ty ++ spc () ++ 
	    str " in context " ++ pr_context_map env lhs ++ spc () ++ spc () ++
	    Array.fold_left 
	      (fun acc so -> acc ++ 
		 match so with
		 | None -> str "*impossible case*"
		 | Some s -> aux s)
	      (mt ()) cs) ++ spc ()
    | RecValid (id, c) -> 
	hov 2 (str "RecValid " ++ pr_id id ++ aux c)
    | Valid (lhs, ty, ids, ev, tac, cs) ->
	let _env' = push_rel_context (pi1 lhs) env in
	  hov 2 (str "Valid " ++ str " in context " ++ pr_context_map env lhs ++ spc () ++
		   List.fold_left 
		   (fun acc (gl, cl, subst, s) -> acc ++ aux s) (mt ()) cs)
    | Refined (lhs, info, s) -> 
	let (id, c, cty), ty, arg, path, ev, (scf, scargs), revctx, newprob, newty =
	  info.refined_obj, info.refined_rettyp,
	  info.refined_arg, info.refined_path,
	  info.refined_ex, info.refined_app,
	  info.refined_revctx, info.refined_newprob, info.refined_newty
	in
	let env' = push_rel_context (pi1 lhs) env in
	  hov 2 (str "Refined " ++ pr_id id ++ spc () ++ 
	      print_constr_env env' (mapping_constr revctx c) ++ str " : " ++ print_constr_env env' cty ++ spc () ++
	      print_constr_env env' ty ++ spc () ++
	      str " in " ++ pr_context_map env lhs ++ spc () ++
	      str "New problem: " ++ pr_context_map env newprob ++ str " for type " ++
	      print_constr_env (push_rel_context (pi1 newprob) env) newty ++ spc () ++
	      spc () ++ str" eliminating " ++ pr_rel_name (pi1 newprob) arg ++ spc () ++
	      str "Revctx is: " ++ pr_context_map env revctx ++ spc () ++
	      str "New problem to problem substitution is: " ++ 
	      pr_context_map env info.refined_newprob_to_lhs ++ spc () ++
	      aux s)
  in aux split

let ppsplit s =
  pp (pr_splitting (Global.env ()) s)
    
let subst_matches_constr k s c = 
  let rec aux depth c =
    match kind_of_term c with
    | Rel n -> 
 	let k = n - depth in 
	  if k >= 0 then 
	    try lift depth (assoc k s)
	    with Not_found -> c
	  else c
    | _ -> map_constr_with_binders succ aux depth c
  in aux k c

let is_all_variables (delta, pats, gamma) =
  List.for_all (function PInac _ | PHide _ -> true | PRel _ -> true | PCstr _ -> false) pats

let do_renamings ctx =
  let avoid, ctx' =
    List.fold_right (fun (n, b, t) (ids, acc) ->
      match n with
      | Name id -> 
	  let id' = Namegen.next_ident_away id ids in
	  let decl' = (Name id', b, t) in
	    (id' :: ids, decl' :: acc)
      | Anonymous -> assert false)
      ctx ([], [])
  in ctx'

let split_var (env,evars) var delta =
  (* delta = before; id; after |- curpats : gamma *)	    
  let before, (id, b, ty as decl), after = split_tele (pred var) delta in
  let unify = unify_type evars before id ty after in
  let branch = function
    | UnifFailure -> None
    | UnifStuck -> assert false
    | UnifSuccess ((ctx',s,ctx), ctxlen, cstr, cstrpat) ->
	(* ctx' |- s : before ; ctxc *)
	(* ctx' |- cpat : ty *)
	let cpat = specialize s cstrpat in
	let ctx' = do_renamings ctx' in
	(* ctx' |- spat : before ; id *)
	let spat =
	  let ctxcsubst, beforesubst = List.chop ctxlen s in
	    check_ctx_map !evars (ctx', cpat :: beforesubst, decl :: before)
	in
	  (* ctx' ; after |- safter : before ; id ; after = delta *)
	  Some (lift_subst !evars spat after)
  in
    match unify with
    | None -> None
    | Some (newty, unify) ->
	(* Some constructor's type is not refined enough to match ty *)
	if Array.exists (fun x -> x == UnifStuck) unify then
	  None
(* 	  user_err_loc (dummy_loc, "split_var",  *)
(* 		       str"Unable to split variable " ++ pr_name id ++ str" of (reduced) type " ++ *)
(* 			 print_constr_env (push_rel_context before env) newty  *)
(* 		       ++ str" to match a user pattern") *)
	else 
	  let newdelta = after @ ((id, b, newty) :: before) in
	    Some (var, do_renamings newdelta, Array.map branch unify)

let find_empty env delta =
  let r = List.filter (fun v -> 
    match split_var env v delta with
    | None -> false
    | Some (v, _, r) -> Array.for_all (fun x -> x == None) r)
    (list_tabulate (fun i -> succ i) (List.length delta))
  in match r with x :: _ -> Some x | _ -> None
    
open Evd
open Refiner

let rel_of_named_context ctx = 
  List.fold_right (fun (n,b,t) (ctx',subst) ->
    let decl = (Name n, Option.map (subst_vars subst) b, subst_vars subst t) in 
      (decl :: ctx', n :: subst)) ctx ([],[])
    
(* The list of variables appearing in a list of patterns, 
   ordered increasingly. *)
let variables_of_pats pats = 
  let rec aux acc pats = 
    List.fold_right (fun p acc ->
      match p with
      | PRel i -> (i, false) :: acc
      | PCstr (c, ps) -> aux [] (rev ps) @ acc
      | PInac c -> acc
      | PHide i -> (i, true) :: acc)
      pats acc
  in List.sort (fun (i, _) (i', _) -> i - i') (aux [] pats)

let pats_of_variables = map (fun (i, hide) ->
  if hide then PHide i else PRel i)

let lift_rel_declaration k (n, b, t) =
  (n, Option.map (lift k) b, lift k t)

let named_of_rel_context l =
  let (subst, _, ctx) = 
    List.fold_right
      (fun (na, b, t) (subst, ids, ctx) ->
	 let id = match na with
	   | Anonymous -> raise (Invalid_argument "named_of_rel_context") 
	   | Name id -> Namegen.next_ident_away id ids
	 in
	 let d = (id, Option.map (substl subst) b, substl subst t) in
	   (mkVar id :: subst, id :: ids, d :: ctx))
      l ([], [], [])
  in subst, ctx
    
let lookup_named_i id =
  let rec aux i = function
    | (id',_,_ as decl) :: _ when Id.equal id id' -> i, decl
    | _ :: sign -> aux (succ i) sign
    | [] -> raise Not_found
  in aux 1
	
let instance_of_pats env evars (ctx : rel_context) (pats : (int * bool) list) =
  let subst, nctx = named_of_rel_context ctx in
  let subst = map destVar subst in
  let ctx' =
    List.fold_right (fun (i, hide) ctx' ->
      let decl =
	let id = List.nth subst (pred i) in
  	let i, decl = lookup_named_i id nctx in
  	  decl
      in decl :: ctx')
      pats []
  in
  let pats' =
    List.map_i (fun i id ->
      let i', _ = lookup_named_i id ctx' in
	list_try_find (fun (i'', hide) ->
	  if i'' == i then if hide then PHide i' else PRel i'
	  else failwith "") pats)
      1 subst
  in
  let pats'' =
    List.map_i (fun i (id, b, t) ->
      let i', _ = lookup_named_i id nctx in
	list_try_find (fun (i'', hide) ->
	  if i'' == i' then if hide then PHide i else PRel i
	  else failwith "") pats)
      1 ctx'
  in fst (rel_of_named_context ctx'), pats', pats''

let push_rel_context_eos ctx env =
  if named_context env <> [] then
    let env' =
      push_named (id_of_string "eos", Some (Lazy.force coq_end_of_section_constr), 
		 Lazy.force coq_end_of_section) env
    in push_rel_context ctx env'
  else push_rel_context ctx env
    
let split_at_eos ctx =
  List.split_when (fun (id, b, t) ->
		   eq_constr t (Lazy.force coq_end_of_section)) ctx

let pr_problem (id, _, _) env (delta, patcs, _) =
  let env' = push_rel_context delta env in
  let ctx = pr_context env delta in
  pr_id id ++ spc () ++ 
    prlist_with_sep spc (pr_pat env') (List.rev patcs) ++
    (if List.is_empty delta then ctx else fnl () ++ str "In context: " ++ fnl () ++ ctx)

let rel_id ctx n = 
  out_name (pi1 (List.nth ctx (pred n)))

let push_named_context = List.fold_right push_named
      
let rec covering_aux env evars data prev clauses path (ctx,pats,ctx' as prob) lets ty =
  match clauses with
  | ((lhs, rhs), used as clause) :: clauses' -> 
    (match matches lhs prob with
    | UnifSuccess s -> 
      let prevmatch = List.filter (fun ((lhs',rhs'),used) -> matches lhs' prob <> UnifFailure) prev in
	(* 	    if List.exists (fun (_, used) -> not used) prev then *)
	(* 	      user_err_loc (dummy_loc, "equations", str "Unused clause: " ++ pr_clause env (lhs, rhs)); *)
	if List.is_empty prevmatch then
	  let env' = push_rel_context_eos ctx env in
	  let get_var loc i s =
	    match assoc i s with
	    | PRel i -> i
	    | _ -> user_err_loc (loc, "equations", str"Unbound variable " ++ pr_id i)
	  in
	    match rhs with
	    | Program c -> 
	      let c', _ = interp_constr_in_rhs env ctx evars data (Some ty) s lets c in
		Some (Compute (prob, ty, RProgram c'))

	    | Empty (loc,i) ->
	      Some (Compute (prob, ty, REmpty (get_var loc i s)))

	    | Rec ((loc, i), rel, spl) ->
	      let var = rel_id ctx (get_var loc i s) in
	      let tac = 
		match rel with
		| None -> rec_tac var (pi1 data)
		| Some r -> rec_wf_tac var (pi1 data) r
	      in
	      let rhs = By (Inl tac, spl) in
		(match covering_aux env evars data [] [(lhs,rhs),false] path prob lets ty with
		| None -> None
		| Some split -> Some (RecValid (pi1 data, split)))
		  
	    | By (tac, s) ->
	      let sign, t', rels, _, _ = push_rel_context_to_named_context env' ty in
	      let sign = named_context_of_val sign in
	      let sign', secsign = split_at_eos sign in
	      let ids = List.map pi1 sign in
	      let tac = match tac with
		| Inl tac -> 
		  Tacinterp.interp_tac_gen Id.Map.empty ids Tactic_debug.DebugOff tac 
		| Inr tac -> Tacinterp.eval_tactic tac
	      in
	      let env' = reset_with_named_context (val_of_named_context sign) env in
	      let entry, proof = Proofview.init !evars [(env', t')] in
	      let _, res, _, _ = Proofview.apply env' tac proof in
	      let gls = Proofview.V82.goals res in
		evars := gls.sigma;
		if Proofview.finished res then
		  let c = List.hd (Proofview.partial_proof entry res) in
		    Some (Compute (prob, ty, RProgram c))
		else
		  let solve_goal gl =
		    let nctx = named_context_of_val (Goal.V82.hyps !evars gl) in
		    let concl = Goal.V82.concl !evars gl in
		    let nctx, secctx = split_at_eos nctx in
		    let rctx, subst = rel_of_named_context nctx in
		    let ty' = subst_vars subst concl in
		    let ty', prob, subst = match kind_of_term ty' with
		      | App (f, args) -> 
			if eq_constr f (Lazy.force coq_add_pattern) then
			  let comp = args.(1) and newpattern = pat_of_constr args.(2) in
			    if pi2 data (* with_comp *) then
			      let pats = rev_map pat_of_constr (snd (decompose_app comp)) in
			      let newprob = 
				rctx, (newpattern :: pats), rctx
				      (* ((newpatname, None, newpatty) :: ctx') *)
			      in 
			      let ty' = 
				match newpattern with
				| PHide _ -> comp
				| _ -> ty'
			      in ty', newprob, (rctx, pats, ctx)
			    else 
			      let pats =
				let l = pat_vars_list (List.length rctx) in
				  newpattern :: List.tl l
			      in
			      let newprob = rctx, pats, rctx in
				comp, newprob, (rctx, List.tl pats, List.tl rctx)
			else
			  let pats = rev_map pat_of_constr (Array.to_list args) in
			  let newprob = rctx, pats, ctx' in
			    ty', newprob, id_subst ctx'
		      | _ -> raise (Invalid_argument "covering_aux: unexpected output of tactic call")
		    in 
		      match covering_aux env evars data [] (map (fun x -> x, false) s) path prob lets ty' with
		      | None ->
			Errors.anomaly ~label:"covering"
			  (str "Unable to find a covering for the result of a by clause:" 
			   ++ fnl () ++ pr_clause env (lhs, rhs) ++
			     spc () ++ str"refining" ++ spc () ++ pr_context_map env prob)
		      | Some s ->
			let args = rev (List.map_filter (fun (id,b,t) ->
			  if b == None then Some (mkVar id) else None) nctx)
			in gl, args, subst, s
		  in Some (Valid (prob, ty, map pi1 sign', Proofview.V82.of_tactic tac, 
				  (entry, res), map solve_goal gls.it))

	    | Refine (c, cls) -> 
		    (* The refined term and its type *)
	      let cconstr, cty = interp_constr_in_rhs env ctx evars data None s lets c in

	      let vars = variables_of_pats pats in
	      let newctx, pats', pats'' = instance_of_pats env evars ctx vars in
		    (* 		    let _s' = (ctx, vars, newctx) in *)
		    (* revctx is a variable substitution from a reordered context to the
		       current context. Needed for ?? *)
	      let revctx = check_ctx_map !evars (newctx, pats', ctx) in
	      let idref = Namegen.next_ident_away (id_of_string "refine") (ids_of_rel_context newctx) in
	      let decl = (Name idref, None, mapping_constr revctx cty) in
	      let extnewctx = decl :: newctx in
		    (* cmap : Δ -> ctx, cty,
		       strinv associates to indexes in the strenghtened context to
		       variables in the original context.
		    *)
	      let refterm = lift 1 (mapping_constr revctx cconstr) in
	      let cmap, strinv = strengthen ~full:false ~abstract:true extnewctx 1 refterm in
	      let (idx_of_refined, _) = List.find (fun (i, j) -> j = 1) strinv in
	      let newprob_to_lhs =
		let inst_refctx = set_in_ctx idx_of_refined (mapping_constr cmap refterm) (pi1 cmap) in
		let str_to_new =
		  inst_refctx, (specialize_pats (pi2 cmap) (lift_pats 1 pats')), newctx
		in
			(* 		      let extprob = check_ctx_map (extnewctx, PRel 1 :: lift_pats 1 pats'', extnewctx) in *)
			(* 		      let ext_to_new = check_ctx_map (extnewctx, lift_pats 1 pats'', newctx) in *)
			(* (compose_subst cmap extprob) (compose_subst ext_to_new *)
		  compose_subst ~sigma:!evars str_to_new revctx
	      in	
	      let newprob = 
		let ctx = pi1 cmap in
		let pats = 
		  rev_map (fun c -> 
		    let idx = destRel c in
				     (* find out if idx in ctx should be hidden depending
					on its use in newprob_to_lhs *)
		      if List.exists (function PHide idx' -> idx == idx' | _ -> false)
			(pi2 newprob_to_lhs) then
			PHide idx
		      else PRel idx) (rels_of_tele ctx) in
		  (ctx, pats, ctx)
	      in
	      let newty =
		let env' = push_rel_context extnewctx env in
		  subst_term refterm
		    (Tacred.simpl env'
		       !evars (lift 1 (mapping_constr revctx ty)))
	      in
	      let newty = mapping_constr cmap newty in
		    (* The new problem forces a reordering of patterns under the refinement
		       to make them match up to the context map. *)
	      let sortinv = List.sort (fun (i, _) (i', _) -> i' - i) strinv in
	      let vars' = List.rev_map snd sortinv in
	      let rec cls' n cls =
		let next_unknown =
		  let str = id_of_string "unknown" in
		  let i = ref (-1) in fun () ->
		    incr i; add_suffix str (string_of_int !i)
		in
		  List.map_filter (fun (lhs, rhs) -> 
		    let oldpats, newpats = List.chop (List.length lhs - n) lhs in
		    let newref, prevrefs = match newpats with hd :: tl -> hd, tl | [] -> assert false in
		      match matches_user prob oldpats with
		      | UnifSuccess (s, alias) -> 
			      (* A substitution from the problem variables to user patterns and 
				 from user pattern variables to patterns instantiating problem variables. *)
			let newlhs = 
			  List.map_filter 
			    (fun i ->
			      if i == 1 then Some newref
			      else
				if List.exists (fun (i', b) -> i' == pred i && b) vars then None
				else
				  try Some (List.assoc (pred i) s)
				  with Not_found -> (* The problem is more refined than the user vars*)
				    Some (PUVar (next_unknown ())))
			    vars'
			in
			let newrhs = match rhs with
			  | Refine (c, cls) -> Refine (c, cls' (succ n) cls)
			  | Rec (v, rel, s) -> Rec (v, rel, cls' n s)
			  | By (v, s) -> By (v, cls' n s)
			  | _ -> rhs
			in
			  Some (rev (prevrefs @ newlhs), newrhs)
		      | _ -> 
			errorlabstrm "covering"
			  (str "Non-matching clause in with subprogram:" ++ fnl () ++
			     str"Problem is " ++ spc () ++ pr_context_map env prob ++ 
			     str"And the user patterns are: " ++ fnl () ++
			     pr_user_pats env lhs)) cls
	      in
	      let cls' = cls' 1 cls in
	      let strength_app, refarg =
		let sortinv = List.sort (fun (i, _) (i', _) -> i' - i) strinv in
		let argref = ref 0 in
		let args = 
		  map (fun (i, j) (* i variable in strengthened context, 
				     j variable in the original one *) -> 
		    if j == 1 then (argref := (List.length strinv - i); 
				   cconstr)
		    else let (var, _) = List.nth vars (pred (pred j)) in
			   mkRel var) sortinv
		in args, !argref
	      in
	      let evar = new_untyped_evar () in
	      let path' = evar :: path in
	      let lets' =
		let letslen = length lets in
		let _, ctxs, _ = lets_of_ctx env ctx evars s in
		let newlets = (lift_rel_context (succ letslen) ctxs) 
		  @ (lift_rel_context 1 lets) 
		in specialize_rel_context (pi2 cmap) newlets
	      in
		match covering_aux env evars data [] (map (fun x -> x, false) cls') path' newprob lets' newty with
		| None -> None
		| Some s -> 
		  let info =
		    { refined_obj = (idref, cconstr, cty);
		      refined_rettyp = ty;
		      refined_arg = refarg;
		      refined_path = path';
		      refined_ex = evar;
		      refined_app = (mkEvar (evar, [||]), strength_app);
		      refined_revctx = revctx;
		      refined_newprob = newprob;
		      refined_newprob_to_lhs = newprob_to_lhs;
		      refined_newty = newty }
		  in  Some (Refined (prob, info, s))
	else 
	  anomaly ~label:"covering"
	    (str "Found overlapping clauses:" ++ fnl () ++ pr_clauses env (map fst prevmatch) ++
	       spc () ++ str"refining" ++ spc () ++ pr_context_map env prob)

    | UnifFailure -> covering_aux env evars data (clause :: prev) clauses' path prob lets ty
    | UnifStuck -> 
      let blocks = blockers lhs prob in
	fold_left (fun acc var ->
	  match acc with
	  | None -> 
	    (match split_var (env,evars) var (pi1 prob) with
	    | Some (var, newctx, s) ->
	      let prob' = (newctx, pats, ctx') in
	      let coverrec s = covering_aux env evars data []
		(List.rev prev @ clauses) path (compose_subst ~sigma:!evars s prob')
		(specialize_rel_context (pi2 s) lets)
		(specialize_constr (pi2 s) ty)
	      in
		(try 
		   let rest = Array.map (Option.map (fun x -> 
		     match coverrec x with
		     | None -> raise Not_found
		     | Some s -> s)) s 
		   in Some (Split (prob', var, ty, rest))
		 with Not_found -> None)
	    | None -> None) 
	  | _ -> acc) None blocks)
	    | [] -> (* Every clause failed for the problem, it's either uninhabited or
		       the clauses are not exhaustive *)
	      match find_empty (env,evars) (pi1 prob) with
	      | Some i -> Some (Compute (prob, ty, REmpty i))
	      | None ->
		errorlabstrm "deppat"
		  (str "Non-exhaustive pattern-matching, no clause found for:" ++ fnl () ++
		     pr_problem data env prob)

let covering env evars data (clauses : clause list) prob ty =
  match covering_aux env evars data [] (map (fun x -> (x,false)) clauses) [] prob [] ty with
  | Some cov -> cov
  | None ->
      errorlabstrm "deppat"
	(str "Unable to build a covering for:" ++ fnl () ++
	   pr_problem data env prob)
    
open Evd
open Evarutil

let helper_evar evm evar env typ src =
  let sign, typ', instance, _, _ = push_rel_context_to_named_context env typ in
  let evm' = evar_declare sign evar typ' ~src evm in
    evm', mkEvar (evar, Array.of_list instance)

let gen_constant dir s = Coqlib.gen_constant "equations" dir s

let coq_zero = lazy (gen_constant ["Init"; "Datatypes"] "O")
let coq_succ = lazy (gen_constant ["Init"; "Datatypes"] "S")
let coq_nat = lazy (gen_constant ["Init"; "Datatypes"] "nat")

let rec coq_nat_of_int = function
  | 0 -> Lazy.force coq_zero
  | n -> mkApp (Lazy.force coq_succ, [| coq_nat_of_int (pred n) |])

(* let make_sensitive_from_oc oc = *)
(*   Refinable.bind *)
(*     (Goal.Refinable.make *)
(*        (fun h -> Goal.Refinable.constr_of_open_constr h false oc)) *)
(*     Goal.refine *)

open Evar_kinds

let term_of_tree status isevar env (i, delta, ty) ann tree =
  let oblevars = ref Evar.Set.empty in
  let helpers = ref [] in
  let rec aux evm = function
    | Compute ((ctx, _, _), ty, RProgram rhs) -> 
	let body = it_mkLambda_or_LetIn rhs ctx and typ = it_mkProd_or_subst ty ctx in
	  evm, body, typ

    | Compute ((ctx, _, _), ty, REmpty split) ->
	let split = (Name (id_of_string "split"), 
		    Some (coq_nat_of_int (succ (length ctx - split))),
		    Lazy.force coq_nat)
	in
	let ty' = it_mkProd_or_LetIn ty ctx in
	let let_ty' = mkLambda_or_LetIn split (lift 1 ty') in
	let evm, term = new_evar env evm ~src:(dummy_loc, QuestionMark (Define true)) let_ty' in
	let ev = fst (destEvar term) in
	  oblevars := Evar.Set.add ev !oblevars;
	  evm, term, ty'
	   
    | RecValid (id, rest) -> aux evm rest

    | Refined ((ctx, _, _), info, rest) ->
	let (id, _, _), ty, rarg, path, ev, (f, args), newprob, newty =
	  info.refined_obj, info.refined_rettyp,
	  info.refined_arg, info.refined_path,
	  info.refined_ex, info.refined_app, info.refined_newprob, info.refined_newty
	in
	let evm, sterm, sty = aux evm rest in
	let evm, term, ty = 
	  let term = mkLetIn (Name (id_of_string "prog"), sterm, sty, lift 1 sty) in
	  let evm, term = helper_evar evm ev (Global.env ()) term
	    (dummy_loc, QuestionMark (Define false)) 
	  in
	    oblevars := Evar.Set.add ev !oblevars;
	    helpers := (ev, rarg) :: !helpers;
	    evm, term, ty
	in
	let term = applist (f, args) in
	let term = it_mkLambda_or_LetIn term ctx in
	let ty = it_mkProd_or_subst ty ctx in
	  evm, term, ty

    | Valid ((ctx, _, _), ty, substc, tac, (entry, pv), rest) ->
	let tac = Proofview.tclDISPATCH 
	  (map (fun (goal, args, subst, x) -> 
	    Proofview.Refine.refine (fun evm -> 
	      let evm, term, ty = aux evm x in
		evm, applistc term args)) rest)
	in
	let pv : Proofview_monad.proofview = Obj.magic pv in
	let pv = { pv with Proofview_monad.solution = evm } in
	let _, pv', _, _ = Proofview.apply env tac (Obj.magic pv) in
	let c = List.hd (Proofview.partial_proof entry pv') in
	  Proofview.return pv', 
	  it_mkLambda_or_LetIn (subst_vars substc c) ctx, it_mkProd_or_LetIn ty ctx
	      
    | Split ((ctx, _, _), rel, ty, sp) -> 
	let before, decl, after = split_tele (pred rel) ctx in
	let evd = ref evm in
	let branches = 
	  Array.map (fun split -> 
	    match split with
	    | Some s -> let evm', c, t = aux !evd s in evd := evm'; c,t
	    | None ->
		(* dead code, inversion will find a proof of False by splitting on the rel'th hyp *)
	      coq_nat_of_int rel, Lazy.force coq_nat)
	    sp 
	in
	let evm = !evd in
	let branches_ctx =
	  Array.mapi (fun i (br, brt) -> (id_of_string ("m_" ^ string_of_int i), Some br, brt))
	    branches
	in
	let n, branches_lets =
	  Array.fold_left (fun (n, lets) (id, b, t) ->
	    (succ n, (Name id, Option.map (lift n) b, lift n t) :: lets))
	    (0, []) branches_ctx
	in
	let liftctx = lift_context (Array.length branches) ctx in
	let evm, case =
	  let ty = it_mkProd_or_LetIn ty liftctx in
	  let ty = it_mkLambda_or_LetIn ty branches_lets in
	  let nbbranches = (Name (id_of_string "branches"),
			   Some (coq_nat_of_int (length branches_lets)),
			   Lazy.force coq_nat)
	  in
	  let nbdiscr = (Name (id_of_string "target"),
			Some (coq_nat_of_int (length before)),
			Lazy.force coq_nat)
	  in
	  let ty = it_mkLambda_or_LetIn (lift 2 ty) [nbbranches;nbdiscr] in
	  let evm, term = new_evar env evm ~src:(dummy_loc, QuestionMark status) ty in
	  let ev = fst (destEvar term) in
	    oblevars := Evar.Set.add ev !oblevars;
	    evm, term
	in       
	let casetyp = it_mkProd_or_subst ty ctx in
	  evm, mkCast(case, DEFAULTcast, casetyp), casetyp
  in 
  let evm, term, typ = aux !isevar tree in
    isevar := evm;
    !helpers, !oblevars, term, typ

open Constrintern
open Decl_kinds

type 'a located = 'a Loc.located

type pat_expr = 
  | PEApp of reference Misctypes.or_by_notation located * pat_expr located list
  | PEWildcard
  | PEInac of constr_expr
  | PEPat of cases_pattern_expr

type user_pat_expr = pat_expr located

type user_pat_exprs = user_pat_expr located

type input_pats =
  | SignPats of user_pat_expr list
  | RefinePats of user_pat_expr list

type pre_equation = 
  identifier located option * input_pats * pre_equation rhs

let next_ident_away s ids =
  let n' = Namegen.next_ident_away s !ids in
    ids := n' :: !ids; n'
    
type rec_type = 
  | Structural
  | Logical of rec_info

(* comp, comp applied to rels, comp projection *)
and rec_info = { comp : constant;
		 comp_app : constr;
		 comp_proj : constant;
		 comp_recarg : int }

let lift_constrs n cs = map (lift n) cs
    
let array_remove_last a =
  Array.sub a 0 (Array.length a - 1)

let array_chop_last a =
  Array.chop (Array.length a - 1) a

let abstract_rec_calls ?(do_subst=true) is_rec len protos c =
  let lenprotos = length protos in
  let proto_fs = map (fun (f, _, _, _) -> f) protos in
  let find_rec_call f =
    try Some (List.find (fun (f', alias, idx, arity) ->
      eq_constr (fst (decompose_app f')) f || 
	(match alias with Some f' -> eq_constr f' f | None -> false)) protos) 
    with Not_found -> None
  in
  let find_rec_call f args =
    match find_rec_call f with
    | Some (f', _, i, arity) -> 
	let args' = snd (Array.chop (length (snd (decompose_app f'))) args) in
	Some (i, arity, args')
    | None -> 
	match is_rec with
	| Some (Logical r) when eq_constr (mkConst r.comp_proj) f -> 
	    Some (lenprotos - 1, r.comp_app, array_remove_last args)
	| _ -> None
  in
  let rec aux n env c =
    match kind_of_term c with
    | App (f', args) ->
	let (ctx, lenctx, args) = 
	  Array.fold_left (fun (ctx,len,c) arg -> 
	    let ctx', lenctx', arg' = aux n env arg in
	    let len' = lenctx' + len in
	    let ctx'' = lift_context len ctx' in
	    let c' = (liftn len (succ lenctx') arg') :: map (lift lenctx') c in
	      (ctx''@ctx, len', c'))
	    ([],0,[]) args
	in
	let args = Array.of_list (List.rev args) in
	let f' = lift lenctx f' in
	  (match find_rec_call f' args with
	  | Some (i, arity, args') ->
	      let resty = substl (rev (Array.to_list args')) arity in
	      let result = (Name (id_of_string "recres"), Some (mkApp (f', args)), resty) in
	      let hypty = mkApp (mkApp (mkRel (i + len + lenctx + 2 + n), 
				       Array.map (lift 1) args'), [| mkRel 1 |]) 
	      in
	      let hyp = (Name (id_of_string "Hind"), None, hypty) in
		[hyp;result]@ctx, lenctx + 2, mkRel 2
	  | None -> (ctx, lenctx, mkApp (f', args)))
	    
    | Lambda (na,t,b) ->
	let ctx',lenctx',b' = aux (succ n) ((na,None,t) :: env) b in
	  (match ctx' with
	   | [] -> [], 0, c
	   | hyp :: rest -> 
	       let ty = mkProd (na, t, it_mkProd_or_LetIn (pi3 hyp) rest) in
		 [Anonymous, None, ty], 1, lift 1 c)

    (* | Cast (_, _, f) when is_comp f -> aux n f *)
	  
    | LetIn (na,b,t,c) ->
	let ctx',lenctx',b' = aux n env b in
	let ctx'',lenctx'',c' = aux (succ n) ((na,Some b,t) :: env) c in
	let ctx'' = lift_rel_contextn 1 lenctx' ctx'' in
	let fullctx = ctx'' @ [na,Some b',lift lenctx' t] @ ctx' in
	  fullctx, lenctx'+lenctx''+1, liftn lenctx' (lenctx'' + 2) c'

    | Prod (na, d, c) when not (dependent (mkRel 1) c)  -> 
	let ctx',lenctx',d' = aux n env d in
	let ctx'',lenctx'',c' = aux n env (subst1 mkProp c) in
	  lift_context lenctx' ctx'' @ ctx', lenctx' + lenctx'', 
	mkProd (na, lift lenctx'' d', 
	       liftn lenctx' (lenctx'' + 2) 
		 (lift 1 c'))

    | Case (ci, p, c, br) ->
	let ctx', lenctx', c' = aux n env c in
	let case' = mkCase (ci, lift lenctx' p, c', Array.map (lift lenctx') br) in
	  ctx', lenctx', substnl proto_fs (succ len + lenctx') case'

    | _ -> [], 0, if do_subst then (substnl proto_fs (len + n) c) else c
  in aux 0 [] c

let below_transparent_state () =
  Hints.Hint_db.transparent_state (Hints.searchtable_map "Below")

let simpl_star = 
  tclTHEN simpl_in_concl (onAllHyps (fun id -> simpl_in_hyp (id, Locus.InHyp)))

let eauto_with_below l =
  Class_tactics.typeclasses_eauto
    ~st:(below_transparent_state ()) (l@["subterm_relation"; "Below"])

let simp_eqns l =
  tclREPEAT (tclTHENLIST [Proofview.V82.of_tactic 
			     (Autorewrite.autorewrite (Tacticals.New.tclIDTAC) l);
			  (* simpl_star; Autorewrite.autorewrite tclIDTAC l; *)
			  tclTRY (eauto_with_below l)])

let simp_eqns_in clause l =
  tclREPEAT (tclTHENLIST 
		[Proofview.V82.of_tactic
		    (Autorewrite.auto_multi_rewrite l clause);
		 tclTRY (eauto_with_below l)])

let autorewrites b = 
  tclREPEAT (Proofview.V82.of_tactic (Autorewrite.autorewrite Tacticals.New.tclIDTAC [b]))

let autorewrite_one b =  (*FIXME*)
  (Proofview.V82.of_tactic (Autorewrite.autorewrite Tacticals.New.tclIDTAC [b]))

(* let autorewrite_one b = Rewrite.cl_rewrite_clause_strat  *)
(*   (Rewrite.Strategies.innermost (Rewrite.Strategies.hints b)) *)
(*   None *)

type term_info = {
  base_id : string;
  polymorphic : bool;
  helpers_info : (existential_key * int * identifier) list }

let find_helper_info info f =
  try List.find (fun (ev', arg', id') ->
    eq_constr (global_reference id') f) info.helpers_info
  with Not_found -> anomaly (str"Helper not found while proving induction lemma.")

let find_helper_arg info f args =
  let (ev, arg, id) = find_helper_info info f in
    ev, args.(arg)
      
let find_splitting_var pats var constrs =
  let rec find_pat_var p c =
    match p, decompose_app c with
    | PRel i, (c, l) when i = var -> Some (destVar c)
    | PCstr (c, ps), (f,l) -> aux ps l
    | _, _ -> None
  and aux pats constrs =
    List.fold_left2 (fun acc p c ->
      match acc with None -> find_pat_var p c | _ -> acc)
      None pats constrs
  in
    Option.get (aux (rev pats) constrs)

let rec intros_reducing gl =
  let concl = pf_concl gl in
    match kind_of_term concl with
    | LetIn (_, _, _, _) -> tclTHEN hnf_in_concl intros_reducing gl
    | Prod (_, _, _) -> tclTHEN intro intros_reducing gl
    | _ -> tclIDTAC gl

let rec aux_ind_fun info = function
  | Split ((ctx,pats,_), var, _, splits) ->
      tclTHEN_i (fun gl ->
	match kind_of_term (pf_concl gl) with
	| App (ind, args) -> 
	    let pats' = List.drop_last (Array.to_list args) in
	    let pats = filter (fun x -> not (hidden x)) pats in
	    let id = find_splitting_var pats var pats' in
	      to82 (depelim_nosimpl_tac id) gl
	| _ -> tclFAIL 0 (str"Unexpected goal in functional induction proof") gl)
	(fun i -> 
	  match splits.(pred i) with
	  | None -> to82 (simpl_dep_elim_tac ())
	  | Some s ->
	      tclTHEN (to82 (simpl_dep_elim_tac ()))
		(aux_ind_fun info s))
	  
  | Valid ((ctx, _, _), ty, substc, tac, valid, rest) -> tclTHEN (to82 intros)
      (tclTHEN_i tac (fun i -> let _, _, subst, split = nth rest (pred i) in
				 tclTHEN (Lazy.force unfold_add_pattern) 
				   (aux_ind_fun info split)))
      
  | RecValid (id, cs) -> aux_ind_fun info cs
      
  | Refined ((ctx, _, _), refinfo, s) -> 
      let id = pi1 refinfo.refined_obj in
      let elimtac gl =
	match kind_of_term (pf_concl gl) with
	| App (ind, args) ->
	    let last_arg = args.(Array.length args - 1) in
	    let f, args = destApp last_arg in
	    let _, elim = find_helper_arg info f args in
	    let id = pf_get_new_id id gl in
	      tclTHENLIST
		[to82 (letin_tac None (Name id) elim None Locusops.allHypsAndConcl); 
		 Proofview.V82.of_tactic (clear_body [id]); aux_ind_fun info s] gl
	| _ -> tclFAIL 0 (str"Unexpected refinement goal in functional induction proof") gl
      in
      let cstrtac =
	tclTHENLIST [tclTRY (autorewrite_one info.base_id); to82 (any_constructor false None)]
      in tclTHENLIST [ to82 intros; tclTHENLAST cstrtac (tclSOLVE [elimtac]); to82 (solve_rec_tac ())]

  | Compute (_, _, REmpty _) ->
      tclTHENLIST [intros_reducing; to82 (find_empty_tac ())]
	
  | Compute (_, _, _) ->
      tclTHENLIST [intros_reducing; autorewrite_one info.base_id; eauto_with_below [info.base_id]]
	
  (* | Compute ((ctx,_,_), _, REmpty id) -> *)
  (*     let (na,_,_) = nth ctx (pred id) in *)
  (*     let id = out_name na in *)
  (* 	do_empty_tac id *)

let is_structural = function Some Structural -> true | _ -> false

let ind_fun_tac is_rec f info fid split ind =
  if is_structural is_rec then
    let c = constant_value_in (Global.env ()) (destConst f) in
    let i = let (inds, _), _ = destFix c in inds.(0) in
    let recid = add_suffix fid "_rec" in
      (* tclCOMPLETE  *)
      (tclTHENLIST
	  [fix (Some recid) (succ i);
	   onLastDecl (fun (n,b,t) gl ->
	     let sort = pf_type_of gl t in
	     let fixprot = mkApp ((*FIXME*)Universes.constr_of_global (Lazy.force coq_fix_proto), [|sort; t|]) in
	       Proofview.V82.of_tactic (change_in_hyp None (fun evd -> evd, fixprot) (n, Locus.InHyp)) gl);
	   to82 intros; aux_ind_fun info split])
  else tclCOMPLETE (tclTHEN (to82 intros) (aux_ind_fun info split))
    
let mapping_rhs s = function
  | RProgram c -> RProgram (mapping_constr s c)
  | REmpty i -> 
      try match nth (pi2 s) (pred i) with 
      | PRel i' -> REmpty i'
      | _ -> assert false
      with Not_found -> assert false

let map_rhs f g = function
  | RProgram c -> RProgram (f c)
  | REmpty i -> REmpty (g i)

let clean_clause (ctx, pats, ty, c) =
  (ctx, pats, ty, 
  map_rhs (nf_beta Evd.empty) (fun x -> x) c)

let map_evars_in_constr evar_map c = 
  evar_map (fun id -> Universes.constr_of_global (Nametab.global (Qualid (dummy_loc, qualid_of_ident id)))) c
(*  list_try_find  *)
(* 	      (fun (id', c, filter) ->  *)
(* 		 if id = id' then (c, filter) else failwith "") subst) c *)

let map_ctx_map f (g, p, d) =
  map_rel_context f g, p, map_rel_context f d

let map_split f split =
  let rec aux = function
    | Compute (lhs, ty, RProgram c) -> Compute (lhs, ty, RProgram (f c))
    | Split (lhs, y, z, cs) -> Split (lhs, y, z, Array.map (Option.map aux) cs)
    | RecValid (id, c) -> RecValid (id, aux c)
    | Valid (lhs, y, z, w, u, cs) ->
	Valid (lhs, y, z, w, u, List.map (fun (gl, cl, subst, s) -> (gl, cl, subst, aux s)) cs)
    | Refined (lhs, info, s) ->
	let (id, c, cty) = info.refined_obj in
	let (scf, scargs) = info.refined_app in
	  Refined (lhs, { info with refined_obj = (id, f c, f cty);
			    refined_app = (f scf, List.map f scargs);
			    refined_newprob_to_lhs = map_ctx_map f info.refined_newprob_to_lhs }, 
		   aux s)
    | Compute (_, _, REmpty _) as c -> c
  in aux split


let map_evars_in_split m = map_split (map_evars_in_constr m)

let (&&&) f g (x, y) = (f x, g y)

let array_filter_map f a =
  let l' =
    Array.fold_right (fun c acc -> 
		      Option.cata (fun r -> r :: acc) acc (f c))
    a []
  in Array.of_list l'

let subst_rec_split redefine f prob s split = 
  let subst_rec cutprob s (ctx, p, _ as lhs) =
    let subst = 
      fold_left (fun (ctx, _, _ as lhs') (id, b) ->
	  let rel, _, ty = lookup_rel_id id ctx in
	  let fK = 
	    if redefine then
	      let lctx, ty = decompose_prod_assum (lift rel ty) in
	      let fcomp, args = decompose_app ty in
		it_mkLambda_or_LetIn (applistc f args) lctx
	    else f
	  in
	  let substf = single_subst Evd.empty rel (PInac fK) ctx (* ctx[n := f] |- _ : ctx *) in
	    compose_subst substf lhs') (id_subst ctx) s
    in
      subst, compose_subst subst (compose_subst lhs cutprob)
  in
  let rec aux cutprob s path = function
    | Compute ((ctx,pats,del as lhs), ty, c) ->
	let subst, lhs' = subst_rec cutprob s lhs in	  
	  Compute (lhs', mapping_constr subst ty, mapping_rhs subst c)
	  
    | Split (lhs, n, ty, cs) -> 
	let subst, lhs' = subst_rec cutprob s lhs in
	let n' = destRel (mapping_constr subst (mkRel n)) in
	  Split (lhs', n', mapping_constr subst ty, Array.map (Option.map (aux cutprob s path)) cs)
	  
    | RecValid (id, c) ->
	RecValid (id, aux cutprob s path c)
	  
    | Refined (lhs, info, sp) -> 
	let (id, c, cty), ty, arg, ev, (fev, args), revctx, newprob, newty =
	  info.refined_obj, info.refined_rettyp,
	  info.refined_arg, info.refined_ex, info.refined_app,
	  info.refined_revctx, info.refined_newprob, info.refined_newty
	in
	let subst, lhs' = subst_rec cutprob s lhs in
	let cutprob pb = 
	  let (ctx, pats, ctx') = pb in
	  let pats, cutctx', _, _ =
	    (* From Γ |- ps, prec, ps' : Δ, rec, Δ', build
	       Γ |- ps, ps' : Δ, Δ' *)
	    fold_right (fun (n, b, t) (pats, ctx', i, subs) ->
			match n with
			| Name n when mem_assoc n s ->
			  let term = assoc n s in
			    (pats, ctx', pred i, term :: subs)
			| _ -> (i :: pats, (n, Option.map (substl subs) b, substl subs t) :: ctx', 
				pred i, mkRel 1 :: map (lift 1) subs))
	    ctx' ([], [], length ctx', [])
 	  in (ctx', map (fun i -> PRel i) pats, cutctx')
	in
        let _, revctx' = subst_rec (cutprob (id_subst (pi3 revctx))) s revctx in
	let cutnewprob = cutprob newprob in
	let subst', newprob' = subst_rec cutnewprob s newprob in
	let _, newprob_to_prob' = subst_rec (cutprob info.refined_newprob_to_lhs) s info.refined_newprob_to_lhs in
	let ev' = if redefine then new_untyped_evar () else ev in
	let path' = ev' :: path in
	let app', arg' =
	  if redefine then
	    let refarg = ref 0 in
  	    let args' = List.fold_left_i
	      (fun i acc c -> 
		 if i == arg then (refarg := List.length acc);
		 if isRel c then
		   let (n, _, ty) = List.nth (pi1 lhs) (pred (destRel c)) in
		     if mem_assoc (out_name n) s then acc
		     else (mapping_constr subst c) :: acc
		 else (mapping_constr subst c) :: acc) 0 [] args 
	    in (mkEvar (ev', [||]), rev args'), !refarg
	  else 
	    let first, last = List.chop (length s) (map (mapping_constr subst) args) in
	      (applistc (mapping_constr subst fev) first, last), arg - length s (* FIXME , needs substituted position too *)
	in
	let info =
	  { refined_obj = (id, mapping_constr subst c, mapping_constr subst cty);
	    refined_rettyp = mapping_constr subst ty;
	    refined_arg = arg';
	    refined_path = path';
	    refined_ex = ev';
	    refined_app = app';
	    refined_revctx = revctx';
	    refined_newprob = newprob';
	    refined_newprob_to_lhs = newprob_to_prob';
	    refined_newty = mapping_constr subst' newty }
	in Refined (lhs', info, aux cutnewprob s path' sp)

    | Valid (lhs, x, y, w, u, cs) -> 
	let subst, lhs' = subst_rec cutprob s lhs in
	  Valid (lhs', x, y, w, u, 
		List.map (fun (g, l, subst, sp) -> (g, l, subst, aux cutprob s path sp)) cs)
  in aux prob s [] split

type statement = constr * types option
type statements = statement list

let subst_app f fn c = 
  let rec aux n c =
    match kind_of_term c with
    | App (f', args) when eq_constr f f' -> 
      let args' = Array.map (map_constr_with_binders succ aux n) args in
	fn n f' args'
    | _ -> map_constr_with_binders succ aux n c
  in aux 0 c
  
let subst_comp_proj f proj c =
  subst_app proj (fun n x args -> 
    mkApp (f, Array.sub args 0 (Array.length args - 1)))
    c

let subst_comp_proj_split f proj s =
  map_split (subst_comp_proj f proj) s

let reference_of_id s = 
  Ident (dummy_loc, s)

let clear_ind_assums ind ctx = 
  let rec clear_assums c =
    match kind_of_term c with
    | Prod (na, b, c) ->
	let t, _ = decompose_app b in
	  if isInd t then
	    let (ind', _), _ = destInd t in
	      if eq_mind ind' ind then (
		assert(not (dependent (mkRel 1) c));
		clear_assums (subst1 mkProp c))
	      else mkProd (na, b, clear_assums c)
	  else mkProd (na, b, clear_assums c)
    | LetIn (na, b, t, c) ->
	mkLetIn (na, b, t, clear_assums c)
    | _ -> c
  in map_rel_context clear_assums ctx

let unfold s = Tactics.unfold_in_concl [Locus.AllOccurrences, s]

let ind_elim_tac indid inds info gl = 
  let eauto = Class_tactics.typeclasses_eauto [info.base_id; "funelim"] in
  let _nhyps = List.length (pf_hyps gl) in
  let prove_methods tac gl = 
    tclTHEN tac eauto gl
  in
  let rec applyind args gl =
    match kind_of_term (pf_concl gl) with
    | LetIn (Name id, b, t, t') ->
	tclTHENLIST [Proofview.V82.of_tactic (convert_concl_no_check (subst1 b t') DEFAULTcast);
		     applyind (b :: args)] gl
    | _ -> tclTHENLIST [simpl_in_concl; to82 intros; 
			prove_methods (Proofview.V82.of_tactic (apply (nf_beta (project gl) (applistc indid (rev args)))))] gl
  in
    tclTHENLIST [intro; onLastHypId (fun id -> applyind [mkVar id])] gl

let pr_path evd = prlist_with_sep (fun () -> str":") (pr_existential_key evd)

let eq_path path path' =
  let rec aux path path' =
    match path, path' with
    | [], [] -> true
    | hd :: tl, hd' :: tl' -> Evar.equal hd hd' && aux tl tl'
    | _, _ -> false
  in 
    aux path path'

let build_equations with_ind env id info data sign is_rec arity cst 
    f ?(alias:(constr * constr * splitting) option) prob split =
  let rec computations prob f = function
    | Compute (lhs, ty, c) ->
	let (ctx', pats', _) = compose_subst lhs prob in
	let c' = map_rhs (nf_beta Evd.empty) (fun x -> x) c in
	let patsconstrs = rev_map pat_constr pats' in
	  [ctx', patsconstrs, ty, f, false, c', None]
	    
    | Split (_, _, _, cs) -> Array.fold_left (fun acc c ->
	match c with None -> acc | Some c -> 
	  acc @ computations prob f c) [] cs

    | RecValid (id, cs) -> computations prob f cs
	
    | Refined (lhs, info, cs) ->
	let (id, c, t) = info.refined_obj in
	let (ctx', pats', _ as s) = compose_subst lhs prob in
	let patsconstrs = rev_map pat_constr pats' in
	  [pi1 lhs, patsconstrs, info.refined_rettyp, f, true, RProgram (applist info.refined_app),
	   Some (fst (info.refined_app), info.refined_path, pi1 info.refined_newprob,  info.refined_newty,
	         rev_map pat_constr (pi2 (compose_subst info.refined_newprob_to_lhs s)), 
		 [mapping_constr info.refined_newprob_to_lhs c, info.refined_arg],
		 computations info.refined_newprob (fst info.refined_app) cs)]
	   
    | Valid ((ctx,pats,del), _, _, _, _, cs) -> 
	List.fold_left (fun acc (_, _, subst, c) ->
	  acc @ computations (compose_subst subst prob) f c) [] cs
  in
  let comps = computations prob f split in
  let rec flatten_comp (ctx, pats, ty, f, refine, c, rest) =
    let rest = match rest with
      | None -> []
      | Some (f, path, ctx, ty, pats, newargs, rest) ->
	  let nextlevel, rest = flatten_comps rest in
	    ((f, path, ctx, ty, pats, newargs), nextlevel) :: rest
    in (ctx, pats, ty, f, refine, c), rest
  and flatten_comps r =
    fold_right (fun cmp (acc, rest) -> 
      let stmt, rest' = flatten_comp cmp in
	(stmt :: acc, rest' @ rest)) r ([], [])
  in
  let comps =
    let (top, rest) = flatten_comps comps in
      ((f, [], sign, arity, rev_map pat_constr (pi2 prob), []), top) :: rest
  in
  let protos = map fst comps in
  let lenprotos = length protos in
  let protos = 
    List.map_i (fun i (f', path, sign, arity, pats, args) -> 
      (f', (if eq_constr f' f then Option.map pi1 alias else None), lenprotos - i, arity))
      1 protos
  in
  let evd = ref (Evd.from_env env) in
  let rec statement i f (ctx, pats, ty, f', refine, c) =
    let comp = applistc f pats in
    let body =
      let b = match c with
	| RProgram c ->
	    mkEq evd ty comp (nf_beta Evd.empty c)
	| REmpty i ->
	    (* mkLetIn (Anonymous, comp, ty,  *)
	  let t = mkApp (Lazy.force coq_ImpossibleCall, [| ty; comp |]) in
	    t
      in it_mkProd_or_LetIn b ctx
    in
    let cstr = 
      match c with
      | RProgram c ->
	  let len = List.length ctx in
	  let hyps, hypslen, c' = abstract_rec_calls is_rec len protos (nf_beta Evd.empty c) in
	    Some (it_mkProd_or_clear
		     (it_mkProd_or_clean
			 (applistc (mkRel (len + (lenprotos - i) + hypslen))
			     (lift_constrs hypslen pats @ [c']))
			 hyps) ctx)
      | REmpty i -> None
    in (refine, body, cstr)
  in
  let statements i ((f', path, sign, arity, pats, args as fs), c) = 
    let fs, f', unftac = 
      if eq_constr f' f then 
	match alias with
	| Some (f', unf, split) -> 
	    (f', path, sign, arity, pats, args), f', Equality.rewriteLR unf
	| None -> fs, f', Tacticals.New.tclIDTAC
      else fs, f', Tacticals.New.tclIDTAC
    in fs, unftac, map (statement i f') c in
  let stmts = List.map_i statements 0 comps in
  let ind_stmts = List.map_i 
    (fun i (f, unf, c) -> i, f, unf, List.map_i (fun j x -> j, x) 1 c) 0 stmts 
  in
  let all_stmts = concat (map (fun (f, unf, c) -> c) stmts) in 
  let declare_one_ind (i, (f, path, sign, arity, pats, refs), unf, stmts) = 
    let indid = add_suffix id (if i == 0 then "_ind" else ("_ind_" ^ string_of_int i)) in
    let constructors = List.map_filter (fun (_, (_, _, n)) -> n) stmts in
    let consnames = List.map_filter (fun (i, (r, _, n)) -> 
      Option.map (fun _ -> 
	let suff = (if not r then "_equation_" else "_refinement_") ^ string_of_int i in
	  add_suffix indid suff) n) stmts
    in
      { mind_entry_typename = indid;
	mind_entry_arity = it_mkProd_or_LetIn (mkProd (Anonymous, arity, mkProp)) sign;
	mind_entry_consnames = consnames;	      
	mind_entry_lc = constructors;
	mind_entry_template = false }
  in
  let declare_ind () =
    let inds = map declare_one_ind ind_stmts in
    let inductive =
      { mind_entry_record = None;
	mind_entry_polymorphic = false;
	mind_entry_universes = Evd.universe_context !evd;
	mind_entry_private = None;
	mind_entry_finite = Finite;
	mind_entry_params = []; (* (identifier * local_entry) list; *)
	mind_entry_inds = inds }
    in
    let k = Command.declare_mutual_inductive_with_eliminations inductive [] in
    let ind = mkInd (k,0) in
    let _ =
      List.iteri (fun i ind ->
	let constrs = 
	  List.map_i (fun j _ -> None, info.polymorphic, true, Hints.PathAny, 
	    Hints.IsGlobRef (ConstructRef ((k,i),j))) 1 ind.mind_entry_lc in
	  Hints.add_hints false [info.base_id] (Hints.HintsResolveEntry constrs))
	inds
    in
    let indid = add_suffix id "_ind_fun" in
    let args = rel_list 0 (List.length sign) in
    let f, split = match alias with Some (f, _, split) -> f, split | None -> f, split in
    let app = applist (f, args) in
    let statement = it_mkProd_or_subst (applist (ind, args @ [app])) sign in
    let evd = Evd.empty in
    let hookind subst gr = 
      let env = Global.env () in (* refresh *)
      Hints.add_hints false [info.base_id] 
	(Hints.HintsImmediateEntry [Hints.PathAny, info.polymorphic, Hints.IsGlobRef gr]);
      let _funind_stmt =
	let evd = ref Evd.empty in
	let leninds = List.length inds in
	let elim =
	  if leninds > 1 then
	    (Indschemes.do_mutual_induction_scheme
		(List.map_i (fun i ind ->
		  let id = (dummy_loc, add_suffix ind.mind_entry_typename "_mut") in
		    (id, false, (k, i), Misctypes.GProp)) 0 inds);
	     let elimid = 
	       add_suffix (List.hd inds).mind_entry_typename "_mut"
	     in Smartlocate.global_with_alias (reference_of_id elimid))
	  else 
	    let elimid = add_suffix id "_ind_ind" in
	      Smartlocate.global_with_alias (reference_of_id elimid) 
	in
	let elimty = Global.type_of_global_unsafe elim in
	let ctx, arity = decompose_prod_assum elimty in
	let newctx = List.skipn (length sign + 2) ctx in
	let newarity = it_mkProd_or_LetIn (substl [mkProp; app] arity) sign in
	let newctx' = clear_ind_assums k newctx in
	let newty =
	  if leninds == 1 then it_mkProd_or_LetIn newarity newctx'
	  else
	    let methods, preds = List.chop (List.length newctx - leninds) newctx' in
	    let ppred, preds = List.sep_last preds in
	    let newpreds =
	      List.map2_i (fun i (n, b, t) (idx, (f', path, sign, arity, pats, args), _, _) ->
		let signlen = List.length sign in
		let ctx = (Anonymous, None, arity) :: sign in
		let app =
		  let argsinfo =
		    List.map_i (fun i (c, arg) -> 
				  let idx = signlen - arg + 1 in (* lift 1, over return value *)
				  let ty = lift (idx (* 1 for return value *)) 
				    (pi3 (List.nth sign (pred (pred idx)))) 
				  in
				    (idx, ty, lift 1 c, mkRel idx)) 
		      0 args
		  in
		  let lenargs = length argsinfo in
		  let result, _ = 
		    fold_left
  		      (fun (acc, pred) (i, ty, c, rel) -> 
		       let idx = i + 2 * lenargs in
			 if dependent (mkRel idx) pred then
			   let app = 
			     mkApp (global_reference (id_of_string "eq_rect_r"),
				    [| lift lenargs ty; lift lenargs rel;
				       mkLambda (Name (id_of_string "refine"), lift lenargs ty, 
						 (replace_term (mkRel idx) (mkRel 1) pred)); 
				       acc; (lift lenargs c); mkRel 1 (* equality *) |])
			   in (app, subst1 c pred)
			 else (acc, subst1 c pred))
		    (mkRel (succ lenargs), lift (succ (lenargs * 2)) arity)
		    argsinfo
		  in
		  let ppath = (* The preceding P *) 
		    match path with
		    | [] -> assert false
		    | ev :: path -> 
			let res = 
			  list_try_find_i (fun i' (_, (_, path', _, _, _, _), _, _) ->
			    if eq_path path' path then Some (idx + 1 - i')
			    else None) 1 ind_stmts
			in match res with None -> assert false | Some i -> i
		  in
		  let papp =
		    applistc (lift (succ signlen + lenargs) (mkRel ppath)) 
		      (map (lift (lenargs + 1)) pats (* for equalities + return value *))
		  in
		  let papp = fold_right 
		    (fun (i, ty, c, rel) app -> 
		      replace_term (lift (lenargs) c) (lift (lenargs) rel) app) 
		    argsinfo papp 
		  in
		  let papp = applistc papp [result] in
		  let refeqs = map (fun (i, ty, c, rel) -> mkEq evd ty c rel) argsinfo in
		  let app c = fold_right
		    (fun c acc ->
		      mkProd (Name (id_of_string "Heq"), c, acc))
		    refeqs c
		  in
		  let indhyps =
		    concat
		      (map (fun (c, _) ->
			let hyps, hypslen, c' = 
			  abstract_rec_calls ~do_subst:false
			    is_rec signlen protos (nf_beta Evd.empty (lift 1 c)) 
			in 
			let lifthyps = lift_rel_contextn (signlen + 2) (- (pred i)) hyps in
			  lifthyps) args)
		  in
		    it_mkLambda_or_LetIn
		      (app (it_mkProd_or_clean (lift (length indhyps) papp) 
			       (lift_rel_context lenargs indhyps)))
		      ctx
		in
		let ty = it_mkProd_or_LetIn mkProp ctx in
		  (n, Some app, ty)) 
		1 preds (rev (List.tl ind_stmts))
	    in
	    let skipped, methods' = (* Skip the indirection methods due to refinements, 
			      as they are trivially provable *)
	      let rec aux stmts meths n meths' = 
		match stmts, meths with
		| (true, _, _) :: stmts, decl :: decls ->
		    aux stmts (subst_telescope mkProp decls) (succ n) meths'
		| (false, _, _) :: stmts, decl :: decls ->
		    aux stmts decls n (decl :: meths')
		| [], [] -> n, meths'
		| [], decls -> n, List.rev decls @ meths'
		| _, _ -> assert false
	      in aux all_stmts (rev methods) 0 []
	    in
	      it_mkProd_or_LetIn (lift (-skipped) newarity)
		(methods' @ newpreds @ [ppred])
	in
	let hookelim _ elimgr =
	  let env = Global.env () in
	  let elimcgr = Universes.constr_of_global elimgr in
	  let cl = functional_elimination_class () in
	  let args = [Typing.type_of env Evd.empty f; f; 
		      Typing.type_of env Evd.empty elimcgr; elimcgr]
	  in
	  let instid = add_prefix "FunctionalElimination_" id in
	    ignore(declare_instance instid info.polymorphic 
		     (if info.polymorphic then !evd else Evd.empty) [] cl args)
	in
	  try 
	    (* Conv_oracle.set_strategy (ConstKey cst) Conv_oracle.Expand; *)
	    ignore(Obligations.add_definition (add_suffix id "_elim")
		     ~tactic:(of82 (ind_elim_tac (Universes.constr_of_global elim) leninds info))
		     ~hook:(Lemmas.mk_hook hookelim)
		     newty (Evd.evar_universe_context !evd) [||])
	  with e ->
	    msg_warning 
	      (str "Elimination principle could not be proved automatically: " ++ fnl () ++
		 Errors.print e)
      in
      let cl = functional_induction_class () in
      let evd = Evd.empty in
      let args = [Typing.type_of env evd f; f; 
		  Global.type_of_global_unsafe gr; Universes.constr_of_global gr]
      in
      let instid = add_prefix "FunctionalInduction_" id in
	ignore(declare_instance instid info.polymorphic 
		 (if info.polymorphic then evd else Evd.empty) [] cl args)
    in
      try ignore(Obligations.add_definition ~hook:(Lemmas.mk_hook hookind)
		   indid statement ~tactic:(of82 (ind_fun_tac is_rec f info id split ind))
		   (Evd.evar_universe_context (if info.polymorphic then evd else Evd.empty))
		    [||])
      with e ->
	msg_warning (str "Induction principle could not be proved automatically: " ++ fnl () ++
		Errors.print e)
	  (* ignore(Subtac_obligations.add_definition ~hook:hookind indid statement [||]) *)
  in
  let proof (j, f, unf, stmts) =
    let eqns = Array.make (List.length stmts) false in
    let id = if j != 0 then add_suffix id ("_helper_" ^ string_of_int j) else id in
    let proof (i, (r, c, n)) = 
      let ideq = add_suffix id ("_equation_" ^ string_of_int i) in
      let hook subst gr = 
	if n != None then
	  Autorewrite.add_rew_rules info.base_id 
	    [dummy_loc, Universes.fresh_global_instance (Global.env()) gr, true, None]
	else (Typeclasses.declare_instance None true gr;
	      Hints.add_hints false [info.base_id] 
		(Hints.HintsExternEntry (0, None, impossible_call_tac (ConstRef cst))));
	eqns.(pred i) <- true;
	if Array.for_all (fun x -> x) eqns then (
	  (* From now on, we don't need the reduction behavior of the constant anymore *)
	  Typeclasses.set_typeclass_transparency (EvalConstRef cst) false false;
	  Global.set_strategy (ConstKey cst) Conv_oracle.Opaque;
	  if with_ind && succ j == List.length ind_stmts then declare_ind ())
      in
      let tac = 
	tclTHENLIST [to82 intros; to82 unf; to82 (solve_equation_tac (ConstRef cst) [])]
      in
      let evd = ref Evd.empty in
      let _ = Evarutil.evd_comb1 (Typing.e_type_of (Global.env ())) evd c in
	ignore(Obligations.add_definition
		  ideq c ~tactic:(of82 tac) ~hook:(Lemmas.mk_hook hook)
		  (Evd.evar_universe_context !evd) [||])
    in iter proof stmts
  in iter proof ind_stmts

open Typeclasses

let rev_assoc eq k =
  let rec loop = function
    | [] -> raise Not_found | (v,k')::_ when eq k k' -> v | _ :: l -> loop l 
  in
  loop

type equation_option = 
  | OInd | ORec | OComp | OEquations

let is_comp_obl comp hole_kind =
  match comp with
  | None -> false
  | Some r -> 
      match hole_kind with 
      | ImplicitArg (ConstRef c, (n, _), _) ->
	Constant.equal c r.comp_proj && n == r.comp_recarg 
      | _ -> false

let hintdb_set_transparency cst b db =
  Hints.add_hints false [db] 
    (Hints.HintsTransparencyEntry ([EvalConstRef cst], b))

let define_tree is_recursive impls status isevar env (i, sign, arity) comp ann split hook =
  let _ = isevar := Evarutil.nf_evar_map_undefined !isevar in
  let helpers, oblevs, t, ty = term_of_tree status isevar env (i, sign, arity) ann split in
  let obls, (emap, cmap), t', ty' = 
    Obligations.eterm_obligations env i !isevar
      0 ~status t (whd_betalet !isevar ty)
  in
  let obls = 
    Array.map (fun (id, ty, loc, s, d, t) ->
      let tac = 
	if Evar.Set.mem (rev_assoc Id.equal id emap) oblevs 
	then Some (equations_tac ()) 
	else if is_comp_obl comp (snd loc) then
	  Some (of82 (tclTRY (to82 (solve_rec_tac ()))))
	else Some (snd (Obligations.get_default_tactic ()))
      in (id, ty, loc, s, d, tac)) obls
  in
  let term_info = map (fun (ev, arg) ->
    (ev, arg, List.assoc ev emap)) helpers
  in
  let hook = Lemmas.mk_hook (hook cmap term_info) in
    if is_structural is_recursive then
      ignore(Obligations.add_mutual_definitions [(i, t', ty', impls, obls)] 
	       (Evd.evar_universe_context !isevar) [] 
	       ~hook (Obligations.IsFixpoint [None, CStructRec]))
    else
      ignore(Obligations.add_definition ~hook
		~implicits:impls i ~term:t' ty' 
		(Evd.evar_universe_context !isevar) obls)

let conv_proj_call proj f_cst c =
  let rec aux n c =
    match kind_of_term c with
    | App (f, args) when eq_constr f proj ->
	mkApp (mkConst f_cst, array_remove_last args)
    | _ -> map_constr_with_binders succ aux n c
  in aux 0 c

let convert_projection proj f_cst = fun gl ->
  let concl = pf_concl gl in
  let concl' = conv_proj_call proj f_cst concl in
    if eq_constr concl concl' then tclIDTAC gl
    else Proofview.V82.of_tactic (convert_concl_no_check concl' DEFAULTcast) gl

let unfold_constr c = 
  unfold_in_concl [(Locus.AllOccurrences, EvalConstRef (fst (destConst c)))]

let simpl_except (ids, csts) =
  let csts = Cset.fold Cpred.remove csts Cpred.full in
  let ids = Idset.fold Idpred.remove ids Idpred.full in
    Closure.RedFlags.red_add_transparent Closure.betadeltaiota
      (ids, csts)
      
let simpl_of csts =
  (* let (ids, csts) = Hints.Hint_db.unfolds (Hints.searchtable_map db) in *)
  (* let (ids', csts') = Hints.Hint_db.unfolds (Hints.searchtable_map (db ^ "_unfold")) in *)
  (* let ids, csts = (Idset.union ids ids', Cset.union csts csts') in *)
  let opacify () = List.iter (fun cst -> 
    Global.set_strategy (ConstKey cst) Conv_oracle.Opaque) csts
  and transp () = List.iter (fun cst -> 
    Global.set_strategy (ConstKey cst) Conv_oracle.Expand) csts
  in opacify, transp

  (* let flags = simpl_except  in *)
  (*   reduct_in_concl (Tacred.cbv_norm_flags flags, DEFAULTcast) *)

let prove_unfolding_lemma info proj f_cst funf_cst split gl =
  let depelim h = depelim_tac h in
  let helpercsts = List.map (fun (_, _, i) -> fst (destConst (global_reference i))) info.helpers_info in
  let opacify, transp = simpl_of helpercsts in
  let simpltac gl = opacify ();
    let res = to82 (simpl_equations_tac ()) gl in
      transp (); res
  in
  let unfolds = tclTHEN (autounfold_first [info.base_id] None)
    (autounfold_first [info.base_id ^ "_unfold"] None)
  in
  let solve_rec_eq gl =
    match kind_of_term (pf_concl gl) with
    | App (eq, [| ty; x; y |]) ->
	let xf, _ = decompose_app x and yf, _ = decompose_app y in
	  if eq_constr (mkConst f_cst) xf && eq_constr proj yf then
	    let unfolds = unfold_in_concl 
	      [((Locus.OnlyOccurrences [1]), EvalConstRef f_cst); 
	       ((Locus.OnlyOccurrences [1]), EvalConstRef (fst (destConst proj)))]
	    in 
	      tclTHENLIST [unfolds; simpltac; to82 (pi_tac ())] gl
	  else to82 reflexivity gl
    | _ -> to82 reflexivity gl
  in
  let solve_eq =
    tclORELSE (to82 reflexivity)
      (tclTHEN (tclTRY (to82 Cctac.f_equal)) solve_rec_eq)
  in
  let abstract tac = tclABSTRACT None tac in
  let rec aux = function
    | Split ((ctx,pats,_), var, _, splits) ->
	(fun gl ->
	  match kind_of_term (pf_concl gl) with
	  | App (eq, [| ty; x; y |]) -> 
	      let f, pats' = decompose_app y in
	      let id = find_splitting_var pats var pats' in
	      let splits = List.map_filter (fun x -> x) (Array.to_list splits) in
		to82 (abstract (of82 (tclTHEN_i (to82 (depelim id))
				  (fun i -> let split = nth splits (pred i) in
					      tclTHENLIST [aux split])))) gl
	  | _ -> tclFAIL 0 (str"Unexpected unfolding goal") gl)
	    
    | Valid ((ctx, _, _), ty, substc, tac, valid, rest) ->
	tclTHEN_i tac (fun i -> let _, _, subst, split = nth rest (pred i) in
				  tclTHEN (Lazy.force unfold_add_pattern) (aux split))

    | RecValid (id, cs) -> 
	tclTHEN (to82 (unfold_recursor_tac ())) (aux cs)
	  
    | Refined ((ctx, _, _), refinfo, s) ->
	let id = pi1 refinfo.refined_obj in
	let ev = refinfo.refined_ex in
	let rec reftac gl = 
	  match kind_of_term (pf_concl gl) with
	  | App (f, [| ty; term1; term2 |]) ->
	      let f1, arg1 = destApp term1 and f2, arg2 = destApp term2 in
	      let _, a1 = find_helper_arg info f1 arg1 
	      and ev2, a2 = find_helper_arg info f2 arg2 in
	      let id = pf_get_new_id id gl in
		if Evar.equal ev2 ev then 
	  	  tclTHENLIST
	  	    [to82 (Equality.replace_by a1 a2
	  		     (of82 (tclTHENLIST [solve_eq])));
	  	     to82 (letin_tac None (Name id) a2 None Locusops.allHypsAndConcl);
	  	     Proofview.V82.of_tactic (clear_body [id]); aux s] gl
		else tclTHENLIST [unfolds; simpltac; reftac] gl
	  | _ -> tclFAIL 0 (str"Unexpected unfolding lemma goal") gl
	in
	  to82 (abstract (of82 (tclTHENLIST [to82 intros; simpltac; reftac])))
	    
    | Compute (_, _, RProgram c) ->
      to82 (abstract (of82 (tclTHENLIST [to82 intros; tclTRY unfolds; simpltac; solve_eq])))
	  
    | Compute ((ctx,_,_), _, REmpty id) ->
	let (na,_,_) = nth ctx (pred id) in
	let id = out_name na in
	  to82 (abstract (depelim id))
  in
    try
      let unfolds = unfold_in_concl
	[Locus.OnlyOccurrences [1], EvalConstRef f_cst; 
	 (Locus.OnlyOccurrences [1], EvalConstRef funf_cst)]
      in
      let res =
	tclTHENLIST 
	  [to82 (set_eos_tac ()); to82 intros; unfolds; simpl_in_concl; 
	   to82 (unfold_recursor_tac ());
	   (fun gl -> 
	     Global.set_strategy (ConstKey f_cst) Conv_oracle.Opaque;
	     Global.set_strategy (ConstKey funf_cst) Conv_oracle.Opaque;
	     aux split gl)] gl
      in Global.set_strategy (ConstKey f_cst) Conv_oracle.Expand;
	Global.set_strategy (ConstKey funf_cst) Conv_oracle.Expand;
	res
    with e ->
      Global.set_strategy (ConstKey f_cst) Conv_oracle.Expand;
      Global.set_strategy (ConstKey funf_cst) Conv_oracle.Expand;
      raise e
      
let update_split is_rec cmap f prob id split =
  let split' = map_evars_in_split cmap split in
    match is_rec with
    | Some Structural -> subst_rec_split false f prob [(id, f)] split'
    | Some (Logical r) -> 
      let split' = subst_comp_proj_split f (mkConst r.comp_proj) split' in
      let rec aux = function
	| RecValid (_, Valid (ctx, ty, args, tac, view, 
			       [ctx', _, newprob, rest])) ->	  
	    aux (subst_rec_split true f newprob [(id, f)] rest)
	| Split (lhs, y, z, cs) -> Split (lhs, y, z, Array.map (Option.map aux) cs)
	| RecValid (id, c) -> RecValid (id, aux c)
	| Valid (lhs, y, z, w, u, cs) ->
	  Valid (lhs, y, z, w, u, 
		 List.map (fun (gl, cl, subst, s) -> (gl, cl, subst, aux s)) cs)
	| Refined (lhs, info, s) -> Refined (lhs, info, aux s)
	| (Compute _) as x -> x
      in aux split'
    | _ -> split'

let rec translate_cases_pattern env avoid = function
  | PatVar (loc, Name id) -> PUVar id
  | PatVar (loc, Anonymous) -> 
      let n = next_ident_away (id_of_string "wildcard") avoid in
	avoid := n :: !avoid; PUVar n
  | PatCstr (loc, (ind, _ as cstr), pats, Anonymous) ->
      PUCstr (cstr, (Inductiveops.inductive_nparams ind), map (translate_cases_pattern env avoid) pats)
  | PatCstr (loc, cstr, pats, Name id) ->
      user_err_loc (loc, "interp_pats", str "Aliases not supported by Equations")

let pr_smart_global = Pptactic.pr_or_by_notation pr_reference
let string_of_smart_global = function
  | Misctypes.AN ref -> string_of_reference ref
  | Misctypes.ByNotation (loc, s, _) -> s

let ident_of_smart_global x = 
  id_of_string (string_of_smart_global x)

let rec ids_of_pats pats =
  fold_left (fun ids (_,p) ->
    match p with
    | PEApp ((loc,f), l) -> 
	let lids = ids_of_pats l in
	  (try ident_of_smart_global f :: lids with _ -> lids) @ ids
    | PEWildcard -> ids
    | PEInac _ -> ids
    | PEPat _ -> ids)
    [] pats

let interp_eqn i is_rec isevar env impls sign arity recu eqn =
  let avoid = ref [] in
  let rec interp_pat (loc, p) =
    match p with
    | PEApp ((loc,f), l) -> 
	let r =
	  try Inl (Smartlocate.smart_global f)
	  with e -> Inr (PUVar (ident_of_smart_global f))
	in
	  (match r with
	   | Inl (ConstructRef c) ->
	       let (ind,_) = c in
	       let nparams = Inductiveops.inductive_nparams ind in
	       let nargs = constructor_nrealargs c in
	       let len = List.length l in
	       let l' =
		 if len < nargs then 
		   List.make (nargs - len) (loc,PEWildcard) @ l
		 else l
	       in 
		 Dumpglob.add_glob loc (ConstructRef c);
		 PUCstr (c, nparams, map interp_pat l')
	   | Inl _ ->
	       if l != [] then 
		 user_err_loc (loc, "interp_pats",
			       str "Pattern variable " ++ pr_smart_global f ++ str" cannot be applied ")
	       else PUVar (ident_of_smart_global f)
	   | Inr p -> p)
    | PEInac c -> PUInac c
    | PEWildcard -> 
	let n = next_ident_away (id_of_string "wildcard") avoid in
	  avoid := n :: !avoid; PUVar n

    | PEPat p ->
	let ids, pats = intern_pattern env p in
	  (* Names.identifier list * *)
	  (*   ((Names.identifier * Names.identifier) list * Rawterm.cases_pattern) list *)
	let upat = 
	  match pats with
	  | [(l, pat)] -> translate_cases_pattern env avoid pat
	  | _ -> user_err_loc (loc, "interp_pats", str "Or patterns not supported by equations")
	in upat
  in
  let rec aux curpats (idopt, pats, rhs) =
    let curpats' = 
      match pats with
      | SignPats l -> l
      | RefinePats l -> curpats @ l
    in
    avoid := !avoid @ ids_of_pats curpats';
    Option.iter (fun (loc,id) ->
      if not (Id.equal id i) then
	user_err_loc (loc, "interp_pats",
		     str "Expecting a pattern for " ++ pr_id i);
      Dumpglob.dump_reference loc "<>" (string_of_id id) "def")
      idopt;
    (*   if List.length pats <> List.length sign then *)
    (*     user_err_loc (loc, "interp_pats", *)
    (* 		 str "Patterns do not match the signature " ++  *)
    (* 		   pr_rel_context env sign); *)
    let pats = map interp_pat curpats' in
      match is_rec with
      | Some Structural -> (PUVar i :: pats, interp_rhs curpats' None rhs)
      | Some (Logical r) -> (pats, interp_rhs curpats' (Some (ConstRef r.comp_proj)) rhs)
      | None -> (pats, interp_rhs curpats' None rhs)
  and interp_rhs curpats compproj = function
    | Refine (c, eqs) -> Refine (interp_constr_expr compproj !avoid c, map (aux curpats) eqs)
    | Program c -> Program (interp_constr_expr compproj !avoid c)
    | Empty i -> Empty i
    | Rec (i, r, s) -> Rec (i, r, map (aux curpats) s)
    | By (x, s) -> By (x, map (aux curpats) s)
  and interp_constr_expr compproj ids c = 
    match c, compproj with
    (* |   | CAppExpl of loc * (proj_flag * reference) * constr_expr list *)
    | CApp (loc, (None, CRef (Ident (loc',id'), _)), args), Some cproj when Id.equal i id' ->
	let qidproj = Nametab.shortest_qualid_of_global Idset.empty cproj in
	  CApp (loc, (None, CRef (Qualid (loc', qidproj), None)),
		List.map (fun (c, expl) -> interp_constr_expr compproj ids c, expl) args)
    | _ -> map_constr_expr_with_binders (fun id l -> id :: l) 
	(interp_constr_expr compproj) ids c
  in aux [] eqn
	
let make_ref dir s = Coqlib.gen_reference "Program" dir s

let fix_proto_ref () = 
  match make_ref ["Program";"Tactics"] "fix_proto" with
  | ConstRef c -> c
  | _ -> assert false

let constr_of_global = Universes.constr_of_global

let define_by_eqs opts i (l,ann) t nt eqs =
  let with_comp, with_rec, with_eqns, with_ind =
    let try_opt default opt =
      try List.assoc opt opts with Not_found -> default
    in
      try_opt true OComp, try_opt true ORec, 
    try_opt true OEquations, try_opt true OInd
  in
  let env = Global.env () in
  let poly = Flags.is_universe_polymorphism () in
  let isevar = ref (create_evar_defs Evd.empty) in
  let ienv, ((env', sign), impls) = interp_context_evars env isevar l in
  let arity = interp_type_evars env' isevar t in
  let sign = nf_rel_context_evar ( !isevar) sign in
  let arity = nf_evar ( !isevar) arity in
  let arity, comp = 
    let body = it_mkLambda_or_LetIn arity sign in
    let _ = check_evars env Evd.empty !isevar body in
      if with_comp then
	let compid = add_suffix i "_comp" in
	let ce = make_definition isevar body in
	let comp =
	  Declare.declare_constant compid (DefinitionEntry ce, IsDefinition Definition)
	in (*Typeclasses.add_constant_class c;*)
	let compapp = mkApp (mkConst comp, rel_vect 0 (length sign)) in
	let projid = add_suffix i "_comp_proj" in
	let compproj = 
	  let body = it_mkLambda_or_LetIn (mkRel 1)
	    ((Name (id_of_string "comp"), None, compapp) :: sign)
	  in
	  let ce = Declare.definition_entry body in
	    Declare.declare_constant projid (DefinitionEntry ce, IsDefinition Definition)
	in
	  Impargs.declare_manual_implicits true (ConstRef comp) [impls];
	  Impargs.declare_manual_implicits true (ConstRef compproj) 
	    [(impls @ [ExplByPos (succ (List.length sign), None), (true, false, true)])];
	  hintdb_set_transparency comp false "Below";
	  hintdb_set_transparency comp false "program";
	  hintdb_set_transparency comp false "subterm_relation";
	  compapp, Some { comp = comp; comp_app = compapp; 
			  comp_proj = compproj; comp_recarg = succ (length sign) }
      else arity, None
  in
  let env = Global.env () in (* To find the comp constant *)
  let ty = it_mkProd_or_LetIn arity sign in
  let data = Constrintern.compute_internalization_env
    env Constrintern.Recursive [i] [ty] [impls] 
  in
  let sort = Retyping.get_type_of env !isevar ty in
  let sort = Evarutil.evd_comb1 (Evarsolve.refresh_universes (Some false) env) isevar sort in
  let fixprot = mkApp (Universes.constr_of_global (Lazy.force coq_fix_proto), [|sort; ty|]) in
  let _fixprot_ty = Evarutil.evd_comb1 (Typing.e_type_of env) isevar fixprot in
  let fixdecls = [(Name i, None, fixprot)] in
  let is_recursive =
    let rec occur_eqn (_, _, rhs) =
      match rhs with
      | Program c -> if occur_var_constr_expr i c then Some false else None
      | Refine (c, eqs) -> 
	  if occur_var_constr_expr i c then Some false
	  else occur_eqns eqs
      | Rec _ -> Some true
      | _ -> None
    and occur_eqns eqs =
      let occurs = map occur_eqn eqs in
	if for_all Option.is_empty occurs then None
	else if exists (function Some true -> true | _ -> false) occurs then Some true
	else Some false
    in 
      match occur_eqns eqs with
      | None -> None 
      | Some true -> Option.map (fun c -> Logical c) comp
      | Some false -> Some Structural
  in
  let equations = 
    Metasyntax.with_syntax_protection (fun () ->
      List.iter (Metasyntax.set_notation_for_interpretation data) nt;
      map (interp_eqn i is_recursive isevar env data sign arity None) eqs)
      ()
  in
  let sign = nf_rel_context_evar ( !isevar) sign in
  let arity = nf_evar ( !isevar) arity in
  let fixdecls = nf_rel_context_evar ( !isevar) fixdecls in
    (*   let ce = check_evars fixenv Evd.empty !isevar in *)
    (*   List.iter (function (_, _, Program rhs) -> ce rhs | _ -> ()) equations; *)
  let prob = 
    if is_structural is_recursive then
      id_subst (sign @ fixdecls)
    else id_subst sign
  in
  let split = covering env isevar (i,with_comp,data) equations prob arity in
    (* if valid_tree prob split then *)
  let status = (* if is_recursive then Expand else *) Define false in
  let baseid = string_of_id i in
  let (ids, csts) = full_transparent_state in
  let fix_proto_ref = destConstRef (Lazy.force coq_fix_proto) in
  Hints.create_hint_db false baseid (ids, Cpred.remove fix_proto_ref csts) true;
  let hook cmap helpers subst gr = 
    let info = { base_id = baseid; helpers_info = helpers; polymorphic = poly } in
    let f_cst = match gr with ConstRef c -> c | _ -> assert false in
    let env = Global.env () in
    let f = constr_of_global gr in
      if with_eqns || with_ind then
	match is_recursive with
	| Some Structural ->
	    let cutprob, norecprob = 
	      let (ctx, pats, ctx' as ids) = id_subst sign in
	      let fixdecls' = [Name i, Some f, fixprot] in
		(ctx @ fixdecls', pats, ctx'), ids
	    in
	    let split = update_split is_recursive cmap f cutprob i split in
	      build_equations with_ind env i info data sign is_recursive arity 
		f_cst (constr_of_global gr) norecprob split
	| None ->
	    let split = update_split is_recursive cmap f prob i split in
	    build_equations with_ind env i info data sign is_recursive arity 
	      f_cst (constr_of_global gr) prob split
	| Some (Logical r) ->
	    let unfold_split = update_split is_recursive cmap f prob i split in
	    (* We first define the unfolding and show the fixpoint equation. *)
	    isevar := Evd.empty;
	    let unfoldi = add_suffix i "_unfold" in
	    let hook_unfold cmap helpers' vis gr' = 
	      let info = { base_id = baseid; helpers_info = helpers @ helpers'; 
			   polymorphic = poly } in
	      let funf_cst = match gr' with ConstRef c -> c | _ -> assert false in
	      let funfc =  mkConst funf_cst in
	      let unfold_split = map_evars_in_split cmap unfold_split in
	      let hook_eqs subst grunfold =
		Global.set_strategy (ConstKey funf_cst) Conv_oracle.transparent;
		build_equations with_ind env i info data sign None arity
		  funf_cst funfc ~alias:(f, constr_of_global grunfold, split) prob unfold_split
	      in
	      let evd = ref Evd.empty in
	      let stmt = it_mkProd_or_LetIn 
		(mkEq evd arity (mkApp (f, extended_rel_vect 0 sign))
		    (mkApp (mkConst funf_cst, extended_rel_vect 0 sign))) sign 
	      in
	      let tac = prove_unfolding_lemma info (mkConst r.comp_proj) f_cst funf_cst unfold_split in
	      let unfold_eq_id = add_suffix unfoldi "_eq" in
		ignore(Obligations.add_definition ~hook:(Lemmas.mk_hook hook_eqs)
			 ~reduce:(fun x -> x)
			 ~implicits:impls unfold_eq_id stmt ~tactic:(of82 tac)
			  (Evd.evar_universe_context !evd) [||])
	    in
	      define_tree None impls status isevar env (unfoldi, sign, arity) None ann unfold_split hook_unfold
      else ()
  in define_tree is_recursive impls status isevar env (i, sign, arity) comp ann split hook

type binders_let2_argtype = (local_binder list * (identifier located option * recursion_order_expr)) Genarg.uniform_genarg_type

    
type equation_user_option = (equation_option * bool)

type equation_options = ((equation_option * bool) list)

(* let wit_equation_options : equation_options Genarg.uniform_genarg_type = *)
(*   Genarg.create_arg None "equation_options" *)

let pr_r_equation_user_option _prc _prlc _prt l =
  mt ()

let pr_equation_options  _prc _prlc _prt l =
  mt ()

(* type decl_notation_argtype = (Vernacexpr.decl_notation list) Genarg.uniform_genarg_type *)

(* let wit_decl_notation : decl_notation_argtype = *)
(*   Genarg.create_arg None "decl_notation" *)

(* let decl_notation = Pcoq.Vernac_.decl_notation *)

(* let pr_raw_decl_notation _ _ _ x = mt () *)
(* let pr_glob_decl_notation _ _ _ x = mt () *)
(* let pr_decl_notation _ _ _ x = mt () *)

(* let _ = Pptactic.declare_extra_genarg_pprule wit_decl_notation *)
(*   pr_raw_decl_notation pr_glob_decl_notation pr_decl_notation *)

(* type identref_argtype = identifier located (\* Genarg.uniform_genarg_type *\) *)

(* let wit_ident_reference : identref_argtype Genarg.uniform_genarg_type = *)
(*   Genarg.create_arg None "ident_reference" *)

(* let pr_r_identref  _prc _prlc _prt l = *)
(*   mt () *)

(* ARGUMENT EXTEND ident_reference *)
(* TYPED AS identref_argtype *)
(* PRINTED BY pr_r_identref *)
(* | [ ident(i) ] -> [ loc, i ] *)
(* END *)

(* let proof_instr : raw_proof_instr Gram.entry = *)
(*   Pcoq.create_generic_entry "proof_instr" (Genarg.rawwit wit_proof_instr) *)

(* let _ = Pptactic.declare_extra_genarg_pprule wit_proof_instr *)
(*   pr_raw_proof_instr pr_glob_proof_instr pr_proof_instr *)

let with_rollback f x =
  (* States.with_heavy_rollback f *)
  (*   Cerrors.process_vernac_interp_error x *)
  f x
(*   let st = States.freeze () in *)
(*     try f x with e -> msg (Toplevel.print_toplevel_error e); States.unfreeze st *)

let equations opts (loc, i) l t nt eqs =
  Dumpglob.dump_definition (loc, i) false "def";
  with_rollback (define_by_eqs opts i l t nt) eqs


let rec int_of_coq_nat c = 
  match kind_of_term c with
  | App (f, [| arg |]) -> succ (int_of_coq_nat arg)
  | _ -> 0

let gclause_none =
  { Locus.onhyps=Some []; concl_occs=Locus.NoOccurrences}

let solve_equations_goal destruct_tac tac gl =
  let concl = pf_concl gl in
  let targetn, branchesn, targ, brs, b =
    match kind_of_term concl with
    | LetIn (Name target, targ, _, b) ->
	(match kind_of_term b with
	| LetIn (Name branches, brs, _, b) ->
	    target, branches, int_of_coq_nat targ, int_of_coq_nat brs, b
	| _ -> error "Unnexpected goal")
    | _ -> error "Unnexpected goal"
  in
  let branches, b =
    let rec aux n c =
      if n == 0 then [], c
      else match kind_of_term c with
      | LetIn (Name id, br, brt, b) ->
	  let rest, b = aux (pred n) b in
	    (id, br, brt) :: rest, b
      | _ -> error "Unnexpected goal"
    in aux brs b
  in
  let ids = targetn :: branchesn :: map pi1 branches in
  let cleantac = tclTHEN (to82 (intros_using ids)) (thin ids) in
  let dotac = tclDO (succ targ) intro in
  let letintac (id, br, brt) = 
    tclTHEN (to82 (letin_tac None (Name id) br (Some brt) gclause_none)) tac 
  in
  let subtacs =
    tclTHENS destruct_tac (map letintac branches)
  in tclTHENLIST [cleantac ; dotac ; subtacs] gl

let rec db_of_constr c = match kind_of_term c with
  | Const (c,_) -> string_of_label (con_label c)
  | App (c,al) -> db_of_constr c
  | _ -> assert false

let dbs_of_constrs = map db_of_constr

let depcase (mind, i as ind) =
  let indid = Nametab.basename_of_global (IndRef ind) in
  let mindb, oneind = Global.lookup_inductive ind in
  let inds = List.rev (Array.to_list (Array.mapi (fun i oib -> mkInd (mind, i)) mindb.mind_packets)) in
  let ctx = oneind.mind_arity_ctxt in
  let nparams = mindb.mind_nparams in
  let args, params = List.chop (List.length ctx - nparams) ctx in
  let nargs = List.length args in
  let indapp = mkApp (mkInd ind, extended_rel_vect 0 ctx) in
  let evd = ref Evd.empty in
  let pred = it_mkProd_or_LetIn (e_new_Type (Global.env ()) evd) 
    ((Anonymous, None, indapp) :: args)
  in
  let nconstrs = Array.length oneind.mind_nf_lc in
  let branches = 
    Array.map2_i (fun i id cty ->
      let substcty = substl inds cty in
      let (args, arity) = decompose_prod_assum substcty in
      let _, indices = decompose_app arity in
      let _, indices = List.chop nparams indices in
      let ncargs = List.length args - nparams in
      let realargs, pars = List.chop ncargs args in
      let realargs = lift_rel_context (i + 1) realargs in
      let arity = applistc (mkRel (ncargs + i + 1)) 
	(indices @ [mkApp (mkConstruct (ind, succ i), 
			  Array.append (extended_rel_vect (ncargs + i + 1) params)
			    (extended_rel_vect 0 realargs))])
      in
      let body = mkRel (1 + nconstrs - i) in
      let br = it_mkProd_or_LetIn arity realargs in
	(Name (id_of_string ("P" ^ string_of_int i)), None, br), body)
      oneind.mind_consnames oneind.mind_nf_lc
  in
  let ci = {
    ci_ind = ind;
    ci_npar = nparams;
    ci_cstr_nargs = oneind.mind_consnrealargs;
    ci_cstr_ndecls = oneind.mind_consnrealdecls;
    ci_pp_info = { ind_tags = []; cstr_tags = [||]; style = RegularStyle; } }
  in
  let obj i =
    mkApp (mkInd ind,
	  (Array.append (extended_rel_vect (nargs + nconstrs + i) params)
	      (extended_rel_vect 0 args)))
  in
  let ctxpred = (Anonymous, None, obj (2 + nargs)) :: args in
  let app = mkApp (mkRel (nargs + nconstrs + 3),
		  (extended_rel_vect 0 ctxpred))
  in
  let ty = it_mkLambda_or_LetIn app ctxpred in
  let case = mkCase (ci, ty, mkRel 1, Array.map snd branches) in
  let xty = obj 1 in
  let xid = Namegen.named_hd (Global.env ()) xty Anonymous in
  let body = 
    let len = 1 (* P *) + Array.length branches in
    it_mkLambda_or_LetIn case 
      ((xid, None, lift len indapp) 
	:: ((List.rev (Array.to_list (Array.map fst branches))) 
	    @ ((Name (id_of_string "P"), None, pred) :: ctx)))
  in
  let ce = Declare.definition_entry body in
  let kn = 
    let id = add_suffix indid "_dep_elim" in
      ConstRef (Declare.declare_constant id
		  (DefinitionEntry ce, IsDefinition Scheme))
  in ctx, indapp, kn

let derive_dep_elimination ctx (i,u) loc =
  let evd = Evd.from_env ~ctx (Global.env ()) in
  let ctx, ty, gref = depcase i in
  let indid = Nametab.basename_of_global (IndRef i) in
  let id = add_prefix "DependentElimination_" indid in
  let cl = dependent_elimination_class () in
  let casety = Global.type_of_global_unsafe gref in
  let poly = false in (*FIXME*)
  let args = extended_rel_vect 0 ctx in
    Equations_common.declare_instance id poly evd ctx cl [ty; prod_appvect casety args; 
				mkApp (constr_of_global gref, args)]


let mkcase env c ty constrs =
  let cty = Typing.type_of env Evd.empty c in
  let ind, origargs = decompose_app cty in
  let mind, ind = match kind_of_term ind with
    | Ind ((mu, n),_ as i) -> mu, i
    | _ -> assert false
  in
  let mindb, oneind = Global.lookup_inductive (fst ind) in
  let inds = List.rev (Array.to_list (Array.mapi (fun i oib -> mkIndU ((mind, i),snd ind)) mindb.mind_packets)) in
  let ctx = oneind.mind_arity_ctxt in
  let _len = List.length ctx in
  let params = mindb.mind_nparams in
  let origparams, _ = List.chop params origargs in
  let ci = {
    ci_ind = fst ind;
    ci_npar = params;
    ci_cstr_nargs = oneind.mind_consnrealargs;
    ci_cstr_ndecls = oneind.mind_consnrealdecls;
    ci_pp_info = { ind_tags = []; cstr_tags = [||]; style = RegularStyle; } }
  in
  let brs = 
    Array.map2_i (fun i id cty ->
      let (args, arity) = decompose_prod_assum (substl inds cty) in
      let realargs, pars = List.chop (List.length args - params) args in
      let args = substl (List.rev origparams) (it_mkProd_or_LetIn arity realargs) in
      let args, arity = decompose_prod_assum args in
      let res = constrs ind i id params args arity in
	it_mkLambda_or_LetIn res args)
      oneind.mind_consnames oneind.mind_nf_lc
  in
    mkCase (ci, ty, c, brs)
      


(* let mkEq t x y =  *)
(*   mkApp (Coqlib.build_coq_eq (), [| refresh_universes t; x; y |]) *)
    
(* let mkRefl t x =  *)
(*   mkApp ((Coqlib.build_coq_eq_data ()).Coqlib.refl, [| refresh_universes t; x |]) *)

(* let mkHEq t x u y = *)
(*   mkApp (Coqlib.coq_constant "mkHEq" ["Logic";"JMeq"] "JMeq", *)
(* 	[| refresh_universes t; x; refresh_universes u; y |]) *)
    
(* let mkHRefl t x = *)
(*   mkApp (Coqlib.coq_constant "mkHEq" ["Logic";"JMeq"] "JMeq_refl", *)
(* 	[| refresh_universes t; x |]) *)

(* let mk_term_eq env sigma ty t ty' t' = *)
(*   if Reductionops.is_conv env sigma ty ty' then *)
(*     mkEq ty t t', mkRefl ty' t' *)
(*   else *)
(*     mkHEq ty t ty' t', mkHRefl ty' t' *)

let mk_eqs env evd args args' pv = 
  let prf =
    List.fold_right2 (fun x y c -> 
      let tyx = Typing.type_of env Evd.empty x 
      and tyy = Typing.type_of env Evd.empty y in
      let hyp, prf = mk_term_eq env evd tyx x tyy y in
	mkProd (Anonymous, hyp, lift 1 c))
      args args' pv
  in mkProd (Anonymous, prf, pv)
	
let derive_no_confusion env evd (ind,u) =
  let evd = ref evd in
  let poly = Flags.is_universe_polymorphism () in
  let mindb, oneind = Global.lookup_inductive ind in
  let ctx = (* map_rel_context refresh_universes *) oneind.mind_arity_ctxt in
  let len = List.length ctx in
  let params = mindb.mind_nparams in
  let args = oneind.mind_nrealargs in
  let argsvect = rel_vect 0 len in
  let paramsvect, rest = Array.chop params argsvect in
  let indty = mkApp (mkInd ind, argsvect) in
  let pid = (id_of_string "P") in
  let pvar = mkVar pid in
  let xid = id_of_string "x" and yid = id_of_string "y" in
  let xdecl = (Name xid, None, lift 1 indty) in
  let pty = e_new_Type env evd in
  let binders = xdecl :: (Name pid, None, pty) :: ctx in
  let ydecl = (Name yid, None, lift 2 indty) in
  let fullbinders = ydecl :: binders in
  let arity = it_mkProd_or_LetIn pty fullbinders in
  let env = push_rel_context binders env in
  let ind_with_parlift n =
    mkApp (mkInd ind, Array.append (Array.map (lift n) paramsvect) rest) 
  in
  let lenargs = List.length ctx - params in
  let pred =
    let elim =
      let app = ind_with_parlift (args + 2) in
	it_mkLambda_or_LetIn 
	  (mkProd_or_LetIn (Anonymous, None, lift 1 app) pty)
	  ((Name xid, None, ind_with_parlift (2 + lenargs)) :: List.firstn lenargs ctx)
    in
      mkcase env (mkRel 1) elim (fun ind i id nparams args arity ->
	let ydecl = (Name yid, None, arity) in
	let env' = push_rel_context (ydecl :: args) env in
	let decl = (Name yid, None, ind_with_parlift (lenargs + List.length args + 3)) in
	  mkLambda_or_LetIn ydecl
	    (mkcase env' (mkRel 1) 
		(it_mkLambda_or_LetIn pty (decl :: List.firstn lenargs ctx))
		(fun _ i' id' nparams args' arity' ->
		  if i = i' then 
		    mk_eqs (push_rel_context args' env') evd
		      (rel_list (List.length args' + 1) (List.length args))
		      (rel_list 0 (List.length args')) pvar
		  else pvar)))
  in
  let app = it_mkLambda_or_LetIn (replace_vars [(pid, mkRel 2)] pred) binders in
  let ce = make_definition ~poly evd ~types:arity app in
  let indid = Nametab.basename_of_global (IndRef ind) in
  let id = add_prefix "NoConfusion_" indid
  and noid = add_prefix "noConfusion_" indid
  and packid = add_prefix "NoConfusionPackage_" indid in
  let cstNoConf = Declare.declare_constant id (DefinitionEntry ce, IsDefinition Definition) in
  let stmt = it_mkProd_or_LetIn
    (mkApp (mkConst cstNoConf, rel_vect 1 (List.length fullbinders)))
    ((Anonymous, None, mkEq evd (lift 3 indty) (mkRel 2) (mkRel 1)) :: fullbinders)
  in
  let hook vis gr = 
    let evd = ref (Evd.from_env (Global.env ())) in
    let tc = class_info (global_of_constr (Lazy.force coq_noconfusion_class)) in
    let b, ty = instance_constructor (tc,Univ.Instance.empty)
      [indty; mkApp (mkConst cstNoConf, argsvect) ; 
       mkApp (constr_of_global gr, argsvect) ] in
    match b with
      | Some b ->
        let ce = make_definition ~poly evd ~types:(it_mkProd_or_LetIn ty ctx)
	  (it_mkLambda_or_LetIn b ctx)
        in
        let inst = Declare.declare_constant packid (DefinitionEntry ce, IsDefinition Instance) in
        Typeclasses.add_instance (Typeclasses.new_instance tc None true poly (ConstRef inst))
      | None -> error "Could not find constructor"
  in
    ignore(Obligations.add_definition ~hook:(Lemmas.mk_hook hook) noid 
	      stmt ~tactic:(noconf_tac ()) 
	      (Evd.empty_evar_universe_context) [||])
     

let pattern_call ?(pattern_term=true) c gl =
  let env = pf_env gl in
  let cty = pf_type_of gl c in
  let ids = ids_of_named_context (pf_hyps gl) in
  let deps =
    match kind_of_term c with
    | App (f, args) -> Array.to_list args
    | _ -> []
  in
  let varname c = match kind_of_term c with
    | Var id -> id
    | _ -> Namegen.next_ident_away (id_of_string (Namegen.hdchar (pf_env gl) c))
	ids
  in
  let mklambda ty (c, id, cty) =
    let conclvar, _ = Find_subterm.subst_closed_term_occ env (project gl) 
      (Locus.AtOccs Locus.AllOccurrences) c ty in
      mkNamedLambda id cty conclvar
  in
  let subst = 
    let deps = List.rev_map (fun c -> (c, varname c, pf_type_of gl c)) deps in
      if pattern_term then (c, varname c, cty) :: deps
      else deps
  in
  let concllda = List.fold_left mklambda (pf_concl gl) subst in
  let conclapp = applistc concllda (List.rev_map pi1 subst) in
    Proofview.V82.of_tactic (convert_concl_no_check conclapp DEFAULTcast) gl

let dependencies env c ctx =
  let init = global_vars_set env c in
  let deps =
    Context.fold_named_context_reverse 
      (fun variables (n, _, _ as decl) ->
	let dvars = global_vars_set_of_decl env decl in
	  if Idset.mem n variables then Idset.union dvars variables
	  else variables)
      ~init:init ctx
  in
    (init, Idset.diff deps init)