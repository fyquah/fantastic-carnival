open Base
open Hardcaml
open Signal

module Config : sig
  type t =
    { depth : int
    ; ground_multiplier : Ground_multiplier.Config.t
    }

  val latency : t -> int
end

module Input : sig
  type t =
    | Multiply of (Signal.t * Signal.t)
    | Square of Signal.t
end

val create : scope:Scope.t -> clock:t -> enable:t -> config:Config.t -> Input.t -> t

module With_interface_multiply (M : sig
  val bits : int
end) : sig
  val bits : int

  module I : sig
    type 'a t =
      { clock : 'a
      ; enable : 'a
      ; x : 'a
      ; y : 'a
      ; in_valid : 'a
      }
    [@@deriving sexp_of, hardcaml]
  end

  module O : sig
    type 'a t =
      { z : 'a
      ; out_valid : 'a
      }
    [@@deriving sexp_of, hardcaml]
  end

  val create : config:Config.t -> Scope.t -> Signal.t I.t -> Signal.t O.t
end
