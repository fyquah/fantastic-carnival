open! Base
open! Hardcaml
open! Signal
open! Reg_with_enable

module Stage0 = struct
  type 'a t =
    { x : 'a
    ; y : 'a
    ; valid : 'a
    }
  [@@deriving sexp_of, hardcaml]
end

module Stage1 = struct
  type 'a t =
    { xy : 'a
    ; valid : 'a
    }
  [@@deriving sexp_of, hardcaml]

  let create ~scope ~multiplier_config ~clock ~enable { Stage0.x; y; valid } =
    let latency = Karatsuba_ofman_mult.Config.latency multiplier_config in
    { xy =
        Karatsuba_ofman_mult.hierarchical
          ~scope
          ~clock
          ~enable
          ~config:multiplier_config
          x
          (`Signal y)
    ; valid = Signal.pipeline (Reg_spec.create ~clock ()) ~enable ~n:latency valid
    }
  ;;
end

(* Computes m = [(xy mod r) * p' mod r], where P'P = -1 mod r and r is a power
 * of two.
 *)
module Stage2 = struct
  type 'a t =
    { m : 'a
    ; xy : 'a
    ; valid : 'a
    }
  [@@deriving sexp_of, hardcaml]

  let create
      ~scope
      ~multiplier_config
      ~(logr : int)
      ~p'
      ~clock
      ~enable
      { Stage1.xy; valid }
    =
    let spec = Reg_spec.create ~clock () in
    let m =
      Karatsuba_ofman_mult.hierarchical
        ~scope
        ~clock
        ~enable
        ~config:multiplier_config
        (sel_bottom xy logr)
        (`Constant p')
      |> Fn.flip sel_bottom logr
    in
    let latency = Karatsuba_ofman_mult.Config.latency multiplier_config in
    { m
    ; xy = pipeline spec ~n:latency ~enable xy
    ; valid = pipeline (Reg_spec.create ~clock ()) ~enable ~n:latency valid
    }
  ;;
end

module Stage3 = struct
  type 'a t =
    { mp : 'a
    ; xy : 'a
    ; valid : 'a
    }
  [@@deriving sexp_of, hardcaml]

  let create ~scope ~multiplier_config ~p ~clock ~enable { Stage2.m; xy; valid } =
    let spec = Reg_spec.create ~clock () in
    let mp =
      Karatsuba_ofman_mult.hierarchical
        ~scope
        ~clock
        ~enable
        ~config:multiplier_config
        m
        (`Constant p)
    in
    let latency = Karatsuba_ofman_mult.Config.latency multiplier_config in
    { mp
    ; xy = pipeline spec ~enable ~n:latency xy
    ; valid = pipeline (Reg_spec.create ~clock ()) ~enable ~n:latency valid
    }
  ;;
end

module Stage4 = struct
  type 'a t =
    { t : 'a
    ; valid : 'a
    }
  [@@deriving sexp_of, hardcaml]

  let create ~scope ~depth ~logr ~clock ~enable { Stage3.mp; xy; valid } =
    assert (Signal.width mp = Signal.width xy);
    let t =
      let { Adder_subtractor_pipe.Single_op_output.result; carry = _ } =
        { lhs = gnd @: xy; rhs_list = [ { op = `Add; term = gnd @: mp } ] }
        |> Adder_subtractor_pipe.hierarchical
             ~name:"adder_pipe_378"
             ~stages:depth
             ~scope
             ~enable
             ~clock
        |> List.last_exn
      in
      result
      |> Fn.flip (Scope.naming scope) "stage4$xy_plus_mp"
      |> Fn.flip drop_bottom logr
    in
    let latency = Modulo_adder_pipe.latency ~stages:depth in
    { t; valid = pipeline (Reg_spec.create ~clock ()) ~enable ~n:latency valid }
  ;;
end

module Stage5 = struct
  type 'a t =
    { result : 'a
    ; valid : 'a
    }
  [@@deriving sexp_of, hardcaml, fields]

  let create ~scope ~depth ~p ~clock ~enable { Stage4.t; valid } =
    let width = width t in
    (* At this point, [0 <= t < 2p]. This step puts [result] backs into
     * the modulo range by computing [mux2 (t <: p) t (t -: p)]. The following
     * circuits implements this in a pipelined fashion.
     *)
    let latency = depth in
    let pipe = pipeline (Reg_spec.create ~clock ()) ~enable ~n:latency in
    let { Adder_subtractor_pipe.Single_op_output.result = subtractor_result
        ; carry = borrow
        }
      =
      { lhs = t; rhs_list = [ { op = `Sub; term = of_z ~width p } ] }
      |> Adder_subtractor_pipe.hierarchical
           ~name:"subtract_by_p_pipe_378"
           ~stages:depth
           ~scope
           ~enable
           ~clock
      |> List.last_exn
    in
    { result = lsbs (mux2 borrow (pipe t) subtractor_result); valid = pipe valid }
  ;;
end

module Config = struct
  type t =
    { multiplier_config : Karatsuba_ofman_mult.Config.t
    ; adder_depth : int
    ; subtractor_depth : int
    }

  let latency ({ multiplier_config; adder_depth; subtractor_depth } : t) =
    (3 * Karatsuba_ofman_mult.Config.latency multiplier_config)
    + adder_depth
    + subtractor_depth
  ;;
end

let create
    ~(config : Config.t)
    ~scope
    ~clock
    ~enable
    ~(p : Z.t)
    ~valid
    (x : Signal.t)
    (y : Signal.t)
  =
  assert (Signal.width x = Signal.width y);
  let logr = Signal.width x in
  let r = Z.(one lsl logr) in
  let p' =
    (* We want to find p' such that pp' = −1 mod r
     *
     * First we find
     * ar + bp = 1 using euclidean extended algorithm
     * <-> -ar - bp = -1
     * -> -bp = -1 mod r
     *
     * if b is negative, we're done, if it's not, we can do a little trick:
     *
     * -bp = (-b+r)p mod r
     *
     *)
    let { Extended_euclidean.coef_x = _; coef_y; gcd } =
      Extended_euclidean.extended_euclidean ~x:r ~y:p
    in
    assert (Z.equal gcd Z.one);
    let p' = Z.neg coef_y in
    if Z.lt p' Z.zero then Z.(p' + r) else p'
  in
  let ( -- ) = Scope.naming scope in
  assert (Z.(equal (p * p' mod r) (r - one)));
  { x; y; valid }
  |> Stage1.create ~scope ~multiplier_config:config.multiplier_config ~clock ~enable
  |> Stage1.map2 Stage1.port_names ~f:(fun port_name x -> x -- ("stage1$" ^ port_name))
  |> Stage2.create
       ~scope
       ~multiplier_config:config.multiplier_config
       ~logr
       ~p'
       ~clock
       ~enable
  |> Stage2.map2 Stage2.port_names ~f:(fun port_name x -> x -- ("stage2$" ^ port_name))
  |> Stage3.create ~scope ~multiplier_config:config.multiplier_config ~p ~clock ~enable
  |> Stage3.map2 Stage3.port_names ~f:(fun port_name x -> x -- ("stage3$" ^ port_name))
  |> Stage4.create ~scope ~depth:config.adder_depth ~logr ~clock ~enable
  |> Stage4.map2 Stage4.port_names ~f:(fun port_name x -> x -- ("stage4$" ^ port_name))
  |> Stage5.create ~scope ~depth:config.subtractor_depth ~p ~clock ~enable
  |> Stage5.map2 Stage5.port_names ~f:(fun port_name x -> x -- ("stage5$" ^ port_name))
;;

module With_interface (M : sig
  val bits : int
end) =
struct
  module Config = Config
  include M

  module I = struct
    type 'a t =
      { clock : 'a
      ; enable : 'a
      ; x : 'a [@bits bits]
      ; y : 'a [@bits bits]
      ; valid : 'a [@rtlprefix "in_"]
      }
    [@@deriving sexp_of, hardcaml]
  end

  module O = struct
    type 'a t =
      { z : 'a [@bits bits]
      ; valid : 'a [@rtlprefix "out_"]
      }
    [@@deriving sexp_of, hardcaml]
  end

  let create ~(config : Config.t) ~p scope { I.clock; enable; x; y; valid } =
    let { Stage5.result; valid } = create ~valid ~scope ~config ~clock ~enable ~p x y in
    { O.z = result; valid }
  ;;
end
