(**********************************************************************)
(* Equations                                                          *)
(* Copyright (c) 2009-2016 Matthieu Sozeau <matthieu.sozeau@inria.fr> *)
(**********************************************************************)
(* This file is distributed under the terms of the                    *)
(* GNU Lesser General Public License Version 2.1                      *)
(**********************************************************************)

From Equations Require Import Equations Fin DepElimDec.
Require Import Omega Utf8.

Require Import List.

Equations map_In {A B : Type}
     (l : list A) (f : forall (x : A), In x l -> B) : list B :=
  map_In nil _ := nil;
  map_In (cons x xs) f := cons (f x _) (map_In xs (fun x H => f x _)).

Lemma map_In_spec {A B : Type} (f : A -> B) (l : list A) :
  map_In l (fun (x : A) (_ : In x l) => f x) = List.map f l.
Proof.
  remember (fun (x : A) (_ : In x l) => f x) as g.
  funelim (map_In l g); rewrite ?H; trivial.
Qed.
  
Section list_size.
  Context {A : Type} (f : A -> nat).
  Equations list_size (l : list A) : nat :=
  list_size nil := 0;
  list_size (cons x xs) := S (f x + list_size xs).
  
  Lemma In_list_size:
    forall x xs, In x xs -> f x < S (list_size xs).
  Proof.
    intros. funelim (list_size xs); simpl in *; destruct H0.
    * subst; omega.
    * specialize (H _ H0). intuition.
  Qed.
End list_size.

Module RoseTree.

  Section roserec.
    Context {A : Set} {A_eqdec : EqDec.EqDec A}.

    Inductive t : Set :=
    | leaf (a : A) : t
    | node (l : list t) : t.
    Derive NoConfusion for t.

    Fixpoint size (r : t) :=
      match r with
      | leaf a => 0
      | node l => S (list_size size l)
      end.

    Section elimtree.
      Context (P : t -> Type) (Pleaf : forall a, P (leaf a))
              (Pnil : P (node nil))
              (Pnode : forall x xs, P x -> P (node xs) -> P (node (cons x xs))).
              
      Equations(noind) elim (r : t) : P r :=
      elim r by rec r (MR lt size) :=
      elim (leaf a) := Pleaf a;
      elim (node nil) := Pnil;
      elim (node (cons x xs)) := Pnode x xs (elim x) (elim (node xs)).

      Next Obligation.
        red. simpl. omega.
      Defined.
      Next Obligation.
        red. simpl. omega.
      Defined.
    End elimtree.

    Equations elements (r : t) : list A :=
    elements l by rec r (MR lt size) :=
    elements (leaf a) := [a];
    elements (node l) := concat (map_In l (fun x H => elements x)).
    
    Next Obligation.
      intros. simpl in *. red. simpl.
      apply In_list_size. auto.
    Defined.
      
    Equations elements_def (r : t) : list A :=
    elements_def (leaf a) := [a];
    elements_def (node l) := concat (List.map elements l).
    Lemma elements_equation (r : t) : elements r = elements_def r.
    Proof.
      funelim (elements r); simp elements_def.
      now rewrite map_In_spec.
    Qed.

    (** To solve measure subgoals *)
    Hint Extern 4 (_ < _) => abstract (simpl; omega) : rec_decision.
    Hint Extern 4 (MR _ _ _ _) => abstract (repeat red; simpl in *; omega) : rec_decision.

    (* Nested rec *) 
    Equations elements' (r : t) : list A :=
    elements' l by rec r (MR lt size) :=
    elements' (leaf a) := [a];
    elements' (node l) := fn l hidebody

    where fn (x : list t) (H : list_size size x < size (node l)) : list A :=
    fn x H by rec x (MR lt (list_size size)) :=
    fn nil _ := nil;
    fn (cons x xs) _ := elements' x ++ fn xs hidebody.

    Next Obligation.
      abstract (simpl; omega).
    Defined.

    Equations elements'_def (r : t) : list A :=
    elements'_def (leaf a) := [a];
    elements'_def (node l) := concat (List.map elements' l).

    Lemma elements'_equation (r : t) : elements' r = elements'_def r.
    Proof.
      pose (fun_elim (f:=elements')).
      apply (p (fun r f => f = elements'_def r) (fun l x H r => r = concat (List.map elements' x)));
        clear p; intros; simp elements'_def.
      simpl. f_equal. apply H2.
    Qed.
    
  End roserec.
  Arguments t : clear implicits.

  Section fns.
    Context {A B : Set} (f : A -> B) (g : B -> A -> B) (h : A -> B -> B).
    
    Equations map (r : t A) : t B :=
    map (leaf a) := leaf (f a);
    map (node l) := node (List.map map l).

    Equations fold (acc : B) (r : t A) : B :=
    fold acc (leaf a) := g acc a;
    fold acc (node l) := List.fold_left fold l acc.

    Equations fold_right (r : t A) (acc : B) : B :=
    fold_right (leaf a) acc := h a acc;
    fold_right (node l) acc := List.fold_right fold_right acc l.
  End fns.    

End RoseTree.
