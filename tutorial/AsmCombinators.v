(** * Composition of [asm] programs *)

(** We develop in this file a theory of linking for [asm] programs.
    To this end, we will equip them with four main combinators:
    - [par_asm], linking them vertically
    - [loop_asm], hiding internal links
    - [relable_asm], allowing to rename labels
    - [pure_asm], casting pure functions into [asm]. 
    Viewing [asm] units as diagrams, this theory can be seen in particular
    as showing that they enjoy a structure of _traced monoidal category_ by
    interpreting [ktree]s as a theory of linking at the denotational level.
    Each linking combinator is therefore proved correct by showing that its
    denotation can be swapped with the corresponding [ktree] combinator.
 *)

(* begin hide *)
Require Import Asm Utils_tutorial Label LabelFacts.

From Coq Require Import
     List
     Strings.String
     Program.Basics
     Vectors.Fin
     ZArith.
Import ListNotations.

From ITree Require Import
     Basics.Basics
     Basics.Function
     Basics.Category.

Typeclasses eauto := 5.
(* end hide *)

(** ** Internal structures *)

Definition fmap_branch {A B : Type} (f: A -> B): branch A -> branch B :=
  fun b =>
    match b with
    | Bjmp a => Bjmp (f a)
    | Bbrz c a a' => Bbrz c (f a) (f a')
    | Bhalt => Bhalt
    end.

Definition fmap_block {A B: Type} (f: A -> B): block A -> block B :=
  fix fmap b :=
    match b with
    | bbb a => bbb (fmap_branch f a)
    | bbi i b => bbi i (fmap b)
    end.
         
Definition relabel_bks {A B X D : nat} (f : FinC A B) (g : FinC X D)
           (b : bks B X) : bks A D :=
  fun a => fmap_block g (b (f a)).

Fixpoint after {A: Type} (is : list instr) (bch : branch A) : block A :=
  match is with
  | nil => bbb bch
  | i :: is => bbi i (after is bch)
  end.

(** ** Low-level interface with [asm] *)

(** Any collection of blocks forms an [asm] program with no hidden blocks. *)
Definition raw_asm {A B} (b : bks A B) : asm A B :=
  {| internal := 0;
     code := fun l => b l
  |}.

(** Wrap a single block as [asm]. *)
Definition raw_asm_block {A: nat} (b : block (Fin.t A)) : asm 1 A :=
  raw_asm (fun _ => b).

(** ** [asm] combinators *)

(** An [asm] program made only of external jumps. This is
      useful to connect programs with [app_asm]. *)
Definition pure_asm {A B: nat} (f : Fin.t A -> Fin.t B) : asm A B :=
  raw_asm (fun a => bbb (Bjmp (f a))).

Definition id_asm {A} : asm A A := pure_asm id.

(* Internal relabeling functions for [app_asm] *)
Definition _app_B {I J B D: nat} :
  block (Fin.t (I + B)) -> block (Fin.t ((I + J) + (B + D))) :=
  fmap_block (fun l =>
                match split_fin_sum l with
                | inl i => L _ (L _ i)
                | inr b => R _ (L _ b)
                end).

Definition _app_D {I J B D} :
  block (Fin.t (J + D)) -> block (Fin.t ((I + J) + (B + D))) :=
  fmap_block (fun l =>
                match split_fin_sum l with
                | inl j => L _ (R _ j)
                | inr d => R _ (R _ d)
                end).

(** Append two asm programs, preserving their internal links. *)
Definition app_asm {A B C D} (ab : asm A B) (cd : asm C D) :
  asm (A + C) (B + D) :=
  {| internal := ab.(internal) + cd.(internal);
     code := fun l =>
               match split_fin_sum l with
               | inl iac => match split_fin_sum iac with
                           | inl ia => _app_B (ab.(code) (L _ ia))
                           | inr ic => _app_D (cd.(code) (L _ ic))
                           end
               | inr ac => match split_fin_sum ac with
                          | inl a => _app_B (ab.(code) (R _ a))
                          | inr c => _app_D (cd.(code) (R _ c))
                          end
               end
  |}.

(** Rename visible program labels. *)
Definition relabel_asm {A B C D} (f : FinC A B) (g : FinC C D)
           (bc : asm B C) : asm A D :=
  {| code := relabel_bks (bimap id f) (bimap id g)  bc.(code); |}.

(** Link labels from two programs together. *)
Definition link_asm {I A B} (ab : asm (I + A) (I + B)) : asm A B :=
  {| internal := ab.(internal) + I;
     code := relabel_bks assoc_r assoc_l ab.(code);
  |}.

(** ** Correctness *)
(** The combinators above map to their denotational counterparts. *)

(* TODO: don't import stuff in the middle of modules *)
From ExtLib Require Import
     Structures.Monad.
Import MonadNotation.
From ITree Require Import
     ITree KTree KTreeFacts.
Import ITreeNotations.
Import CatNotations.
Local Open Scope cat.

Require Import Imp. (* TODO: remove this *)

Section Correctness.

Context {E : Type -> Type}.
Context {HasLocals : Locals -< E}.
Context {HasMemory : Memory -< E}.
Context {HasExit : Exit -< E}.

(** *** Internal structures *)

Lemma fmap_block_map:
  forall  {L L'} b (f: FinC L L'),
    denote_block (fmap_block f b) ≅ ITree.map f (denote_block b).
Proof.
  induction b as [i b | br]; intros f.
  - simpl.
    unfold ITree.map; rewrite bind_bind.
    eapply eq_itree_eq_bind; try reflexivity.
    intros []; apply IHb.
  - simpl.
    destruct br; simpl.
    + unfold ITree.map; rewrite bind_ret; reflexivity.
    + unfold ITree.map; rewrite bind_bind. 
      eapply eq_itree_eq_bind; try reflexivity.
      intros ?.
      flatten_goal; rewrite bind_ret; reflexivity.
    + rewrite (itree_eta (ITree.map _ _)).
      cbn. apply eq_itree_Vis. intros [].
Qed.

Definition denote_list: list instr -> itree E unit :=
  traverse_ denote_instr.

Lemma after_correct :
  forall {label: nat} instrs (b: branch (Fin.t label)),
    denote_block (after instrs b) ≅ (denote_list instrs ;; denote_branch b).
Proof.
  induction instrs as [| i instrs IH]; intros b.
  - simpl; rewrite bind_ret; reflexivity.
  - simpl; rewrite bind_bind.
    eapply eq_itree_eq_bind; try reflexivity.
    intros []; apply IH.
Qed.

Lemma denote_list_app:
  forall is1 is2,
    @denote_list (is1 ++ is2) ≅
                 (@denote_list is1;; denote_list is2).
Proof.
  intros is1 is2; induction is1 as [| i is1 IH]; simpl; intros; [rewrite bind_ret; reflexivity |].
  rewrite bind_bind; setoid_rewrite IH; reflexivity.
Qed.


Lemma raw_asm_block_correct_lifted {A} (b : block (Fin.t A)) :
   denote_asm (raw_asm_block b) ⩯
          ((fun _ => denote_block b) : ktree _ _ _).
Proof.
  unfold denote_asm. simpl.
  rewrite vanishing_Label.
  rewrite case_l_Label'.
  setoid_rewrite case_l_Label .
  unfold denote_b; simpl.
  reflexivity.
Qed.

Lemma raw_asm_block_correct {A} (b : block (t A)) :
  eutt eq (denote_asm (raw_asm_block b) F1)
          (denote_block b).
Proof.
  apply raw_asm_block_correct_lifted.
Qed.

(** *** [asm] combinators *)

Theorem pure_asm_correct {A B} (f : FinC A B) :
    denote_asm (pure_asm f)
  ⩯ @lift_ktree E _ _ f.
Proof.
  unfold denote_asm .
  rewrite vanishing_Label.
  rewrite case_l_Label'.
  setoid_rewrite case_l_Label.
  unfold denote_b; simpl.
  intros ?.
  reflexivity.
Qed.

Definition id_asm_correct {A} :
    denote_asm (pure_asm id)
  ⩯ id_ A.
Proof.
  rewrite pure_asm_correct; reflexivity.
Defined.

Lemma fwd_eqn {a b : Type} (f g : ktree E a b) :
  (forall h, h ⩯ f -> h ⩯ g) -> f ⩯ g.
Proof.
  intro H; apply H; reflexivity.
Qed.

Lemma cat_eq2_l {a b c : Type} (h : ktree E a b) (f g : ktree E b c) :
  f ⩯ g -> h >>> f ⩯ h >>> g.
Proof.
  intros H; rewrite H; reflexivity.
Qed.

Lemma cat_eq2_r {a b c : Type} (h : ktree E b c) (f g : ktree E a b) :
  f ⩯ g -> f >>> h ⩯ g >>> h.
Proof.
  intros H; rewrite H; reflexivity.
Qed.

Lemma local_rewrite1 {a b c : Type}:
    bimap (id_ a) (@swap _ (ktree E) _ _ b c) >>> assoc_l >>> swap
  ⩯ assoc_l >>> bimap swap (id_ c) >>> assoc_r.
Proof.
  symmetry.
  apply fwd_eqn; intros h Eq.
  do 2 apply (cat_eq2_l (bimap (id_ _) swap)) in Eq.
  rewrite <- cat_assoc, bimap_cat, swap_involutive, cat_id_l,
    bimap_id, cat_id_l in Eq.
  rewrite <- (cat_assoc _ _ _ assoc_r), <- (cat_assoc _ _ assoc_l _)
    in Eq.
  rewrite <- swap_assoc_l in Eq.
  rewrite (cat_assoc _ _ _ assoc_r) in Eq.
  rewrite assoc_l_mono in Eq.
  rewrite cat_id_r in Eq.
  rewrite cat_assoc.
  assumption.
  all: typeclasses eauto.
Qed.

Lemma local_rewrite2 {a b c : Type}:
    swap >>> assoc_r >>> bimap (id_ _) swap
  ⩯ @assoc_l _ (ktree E) _ _ a b c >>> bimap swap (id_ _) >>> assoc_r.
Proof.
  symmetry.
  apply fwd_eqn; intros h Eq.
  do 2 apply (cat_eq2_r (bimap (id_ _) swap)) in Eq.
  rewrite cat_assoc, bimap_cat, swap_involutive, cat_id_l,
    bimap_id, cat_id_r in Eq.
  rewrite 2 (cat_assoc _ assoc_l) in Eq.
  rewrite <- swap_assoc_r in Eq.
  rewrite <- 2 (cat_assoc _ assoc_l) in Eq.
  rewrite assoc_l_mono, cat_id_l in Eq.
  assumption.
  all: try typeclasses eauto.
Qed.

Lemma loop_bimap_ktree {I A B C D}
      (ab : ktree E A B) (cd : ktree E (I + C) (I + D)) :
    bimap ab (loop cd)
  ⩯ loop (assoc_l >>> bimap swap (id_ _)
                  >>> assoc_r
                  >>> bimap ab cd
                  >>> assoc_l >>> bimap swap (id_ _) >>> assoc_r).
Proof.
  rewrite swap_bimap, bimap_ktree_loop.
  rewrite <- compose_loop, <- loop_compose.
  rewrite (swap_bimap _ _ cd ab).
  rewrite <- !cat_assoc.
  rewrite local_rewrite1.
  rewrite 2 cat_assoc.
  rewrite <- (cat_assoc _ swap assoc_r).
  rewrite local_rewrite2.
  rewrite <- !cat_assoc.
  reflexivity.
  all: typeclasses eauto.
Qed.

Definition app_asm_correct {A B C D} (ab : asm A B) (cd : asm C D) :
     denote_asm (app_asm ab cd)
  ⩯ bimap (denote_asm ab) (denote_asm cd).
Proof.
  unfold denote_asm.

  match goal with | |- ?x ⩯ _ => set (lhs := x) end.
  rewrite bimap_Label_loop.
  (*
  rewrite loop_bimap_ktree.
  rewrite <- compose_loop.
  rewrite <- loop_compose.
  rewrite loop_loop.
  subst lhs.
  rewrite <- (loop_rename_internal' swap swap).
  2: apply swap_involutive; typeclasses eauto.
  apply eq_ktree_loop.
  rewrite !cat_assoc.
  rewrite <- !sym_ktree_unfold, !assoc_l_ktree, !assoc_r_ktree, !bimap_lift_id, !bimap_id_lift, !compose_lift_ktree_l, compose_lift_ktree.
  unfold cat, Cat_ktree, ITree.cat, lift_ktree.
  intro x. rewrite bind_ret; simpl.
  destruct x as [[|]|[|]]; cbn.
  (* ... *)
  all: unfold cat, Cat_ktree, ITree.cat.
  all: try typeclasses eauto.
  all: try rewrite bind_bind.
  all: unfold _app_B, _app_D.
  all: rewrite fmap_block_map.
  all: unfold ITree.map.
  all: apply eutt_bind; try reflexivity.
  all: intros []; rewrite (itree_eta (ITree.bind _ _)); cbn; reflexivity.
Qed.
*)
Admitted.

Definition relabel_bks_correct {A B C D} (f : FinC A B) (g : FinC C D)
           (bc : bks B C) :
    denote_b (relabel_bks f g bc)
  ⩯ lift_ktree f >>> denote_b bc >>> lift_ktree g.
Proof.
  (*
  rewrite lift_compose_ktree.
  rewrite compose_ktree_lift.
  intro a.
  unfold denote_b, relabel_bks.
  rewrite fmap_block_map.
  reflexivity.
Qed.
   *)
Admitted.

Definition relabel_asm_correct {A B C D} (f : FinC A B) (g : FinC C D)
           (bc : asm B C) :
    denote_asm (relabel_asm f g bc)
  ⩯ lift_ktree f >>> denote_asm bc >>> lift_ktree g.
Proof.
  (*
  unfold denote_asm.
  simpl.
  rewrite relabel_bks_correct.
  rewrite <- compose_loop.
  rewrite <- loop_compose.
  apply eq_ktree_loop.
  rewrite !bimap_id_lift.
  reflexivity.
Qed.
   *)
Admitted.

Definition link_asm_correct {I A B} (ab : asm (I + A) (I + B)) :
    denote_asm (link_asm ab) ⩯ loop_Label (denote_asm ab).
Proof.
  unfold denote_asm.
  (*
  rewrite loop_loop.
  apply eq_ktree_loop.
  simpl.
  rewrite relabel_bks_correct.
  rewrite <- assoc_l_ktree, <- assoc_r_ktree.
  reflexivity.
Qed.
*)
Admitted.

End Correctness.
