(** Computes [z' = x' * y' mod p], where p is a prime, where x', y' and z'
    are x, y and z in montgomery space.
*)

open! Hardcaml

module Config : sig
  type t =
    { m0_config : Karatsuba_ofman_mult.Config.t
    ; m1_config : Half_width_multiplier.Config.t
    ; m2_config : Karatsuba_ofman_mult.Config.t
    ; adder_depth : int
    ; subtractor_depth : int
    }

  val latency : t -> int
end

module With_interface (M : sig
  val bits : int
end) : sig
  module Config = Config

  val bits : int

  module I : sig
    type 'a t =
      { clock : 'a
      ; enable : 'a
      ; x : 'a
      ; y : 'a
      ; valid : 'a
      }
    [@@deriving sexp_of, hardcaml]
  end

  module O : sig
    type 'a t =
      { z : 'a
      ; valid : 'a
      }
    [@@deriving sexp_of, hardcaml]
  end

  val create : config:Config.t -> p:Z.t -> Scope.t -> Signal.t I.t -> Signal.t O.t
end
