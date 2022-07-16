(** Slow models for eliptic curve operations. *)

open Snarks_r_fun

val point_double
  :  montgomery:bool
  -> p:Z.t
  -> Z.t Point.Jacobian.t
  -> Z.t Point.Jacobian.t

val mixed_add
  :  montgomery:bool
  -> p:Z.t
  -> Z.t Point.Affine.t
  -> Z.t Point.Jacobian.t
  -> Z.t Point.Jacobian.t
