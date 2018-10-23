From Equations Require Import Equations.
Check le.

Inductive le : nat -> nat -> Prop :=
| le_0 n : le 0 n
| le_S n m (H : le n m) : le (S n) (S m).
Derive Invert for le.

Section Image.
  Context {A B : Type} (f : A -> B).

  Inductive Im : B -> Type :=
  | im x : Im (f x).

  Inductive ImI : forall (b : B) (im : Im b), Type :=
  | imf x : ImI (f x) (im x).

  Derive Invert for ImI.
  Print invert_ImI.
End Image.

Section Vector.
  Inductive vector (A : Type) : nat -> Type :=
  | vnil : vector A 0
  | vcons (a : A) (n : nat) (v : vector A n) : vector A (S n).

  Derive Invert for vector.
  Print invert_vector.
End Vector.

(* Local Variables: *)
(* coq-prog-name: "/Volumes/Dev/coq/trunk/bin/coqtop.byte" *)
(* coq-prog-args: ("-emacs" "-bt" "-I" "../src" "-R" "../theories" "Equations") *)
(* coq-load-path: nil *)
(* End: *)
