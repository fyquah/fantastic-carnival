(* Calculates [a mod p] using barret reduction, where [p] is a compile-time
   known constant.

   Based on implementation in 
   https://github.com/ZcashFoundation/zcash-fpga/blob/c4c0ad918898084c73528ca231d025e36740d40c/ip_cores/util/src/rtl/barret_mod_pipe.sv

   Computes the following in separate pipeline stages, where
   k = Int.ceillog(p)

   {[
     let reduce ~p ~k a =
       let q = (a * m) >> k in
       let qp = q * p in
       let a_minus_qp = a - qp in
       mux2 (a_minus_qp >= p)
         (a_minus_qp - p)
         a_minus_qp
   ]}
*)

open Base
open Hardcaml
open Signal
open Reg_with_enable

module Config = struct
  type t =
    { approx_msb_multiplier_config : Approx_msb_multiplier.Config.t
    ; half_multiplier_config : Half_width_multiplier.Config.t
    ; subtracter_stages : int
    ; num_correction_steps : int
    }

  let latency (config : t) =
    (1 * Approx_msb_multiplier.Config.latency config.approx_msb_multiplier_config)
    + (1 * Half_width_multiplier.Config.latency config.half_multiplier_config)
    + config.subtracter_stages
    + (config.num_correction_steps * config.subtracter_stages)
  ;;

  let approx_msb_mult_2222 =
    let open Approx_msb_multiplier.Config in
    { levels =
        [ { k = (fun _ -> 187)
          ; for_karatsuba =
              { radix = Radix_2
              ; pre_adder_stages = 1
              ; (* [middle_adder_stages] here is irrel. *)
                middle_adder_stages = 1
              ; (* Adding up to 390 bit results *)
                post_adder_stages = 5
              }
          }
        ; { k = (fun _ -> 94)
          ; for_karatsuba =
              { radix = Radix_2
              ; pre_adder_stages = 1
              ; (* intermediate results has width of 42-50 bits. 1 stage pipeline
                   is sufficient.
                *)
                middle_adder_stages = 1
              ; post_adder_stages = 2
              }
          }
        ; { k = (fun _ -> 48)
          ; for_karatsuba =
              { radix = Radix_2
              ; pre_adder_stages = 1
              ; (* intermediate results is tiny. middle_adder_stages=1 (or even 0?)
                   is ok.
                *)
                middle_adder_stages = 1
              ; post_adder_stages = 1
              }
          }
        ; { k = (fun _ -> 24)
          ; for_karatsuba =
              { radix = Radix_2
              ; pre_adder_stages = 1
              ; (* intermediate results is tiny. middle_adder_stages=1 (or even 0?)
                     is ok.
                *)
                middle_adder_stages = 1
              ; post_adder_stages = 1
              }
          }
        ]
    ; ground_multiplier =
        Mixed
          { latency = 2
          ; lut_only_hamming_weight_threshold = Some 6
          ; hybrid_hamming_weight_threshold = None
          }
    }
  ;;

  let approx_msb_mult_332 =
    let open Approx_msb_multiplier.Config in
    { levels =
        [ { k = (fun _ -> 125)
          ; for_karatsuba =
              { radix = Radix_3
              ; pre_adder_stages = 1
              ; (* [middle_adder_stages] here is irrel. *)
                middle_adder_stages = 1
              ; (* Adding up to 390 bit results *)
                post_adder_stages = 5
              }
          }
        ; { k = (fun _ -> 42)
          ; for_karatsuba =
              { radix = Radix_3
              ; pre_adder_stages = 1
              ; (* intermediate results has width of 42-50 bits. 1 stage pipeline
                   is sufficient.
                *)
                middle_adder_stages = 1
              ; post_adder_stages = 2
              }
          }
        ; { k = (fun _ -> 20)
          ; for_karatsuba =
              { radix = Radix_2
              ; pre_adder_stages = 1
              ; (* intermediate results is tiny. middle_adder_stages=1 (or even 0?)
                   is ok.
                *)
                middle_adder_stages = 1
              ; post_adder_stages = 1
              }
          }
        ]
    ; ground_multiplier =
        Mixed
          { latency = 2
          ; lut_only_hamming_weight_threshold = Some 6
          ; hybrid_hamming_weight_threshold = None
          }
    }
  ;;

  let lsb_mult_332 =
    let open Half_width_multiplier.Config in
    { levels =
        [ { radix = Radix_3
          ; pre_adder_stages = 1
          ; (* [middle_adder_stages] here is irrel. *)
            middle_adder_stages = 1
          ; post_adder_stages = 5
          }
        ; { radix = Radix_3
          ; pre_adder_stages = 1
          ; (* intermediate results has width of 42 bits. 1 stage pipeline
                 is sufficient.
            *)
            middle_adder_stages = 1
          ; post_adder_stages = 2
          }
        ; { radix = Radix_2
          ; pre_adder_stages = 1
          ; (* intermediate results is tiny. middle_adder_stages=1 (or even 0?)
                 is ok.
            *)
            middle_adder_stages = 1
          ; post_adder_stages = 1
          }
        ]
    ; ground_multiplier =
        Mixed
          { latency = 2
          ; lut_only_hamming_weight_threshold = Some 6
          ; hybrid_hamming_weight_threshold = None
          }
    }
  ;;

  let lsb_mult_2222 =
    let open Half_width_multiplier.Config in
    { levels =
        [ { radix = Radix_2
          ; pre_adder_stages = 1
          ; (* [middle_adder_stages] here is irrel. *)
            middle_adder_stages = 1
          ; post_adder_stages = 5
          }
        ; { radix = Radix_2
          ; pre_adder_stages = 1
          ; (* intermediate results has width of 42 bits. 1 stage pipeline
                 is sufficient.
            *)
            middle_adder_stages = 1
          ; post_adder_stages = 2
          }
        ; { radix = Radix_2
          ; pre_adder_stages = 1
          ; (* intermediate results is tiny. middle_adder_stages=1 (or even 0?)
                 is ok.
            *)
            middle_adder_stages = 1
          ; post_adder_stages = 1
          }
        ; { radix = Radix_2
          ; pre_adder_stages = 1
          ; (* intermediate results is tiny. middle_adder_stages=1 (or even 0?)
                 is ok.
            *)
            middle_adder_stages = 1
          ; post_adder_stages = 1
          }
        ]
    ; ground_multiplier =
        Mixed
          { latency = 2
          ; lut_only_hamming_weight_threshold = Some 6
          ; hybrid_hamming_weight_threshold = None
          }
    }
  ;;

  let for_bls12_377 =
    let which_msb_mult = `Approx_msb_mult_2222 in
    let which_lsb_mult = `Lsb_mult_2222 in
    (* See libs/field_ops/model/approx_msb_multiplier_model.ml for the
     * rationale behind the values.
     *)
    { approx_msb_multiplier_config =
        (match which_msb_mult with
         | `Approx_msb_mult_332 -> approx_msb_mult_332
         | `Approx_msb_mult_2222 -> approx_msb_mult_2222)
    ; half_multiplier_config =
        (match which_lsb_mult with
         | `Lsb_mult_332 -> lsb_mult_332
         | `Lsb_mult_2222 -> lsb_mult_2222)
    ; subtracter_stages = 3
    ; num_correction_steps =
        (match which_msb_mult with
         | `Approx_msb_mult_332 -> 3
         | `Approx_msb_mult_2222 -> 4)
    }
  ;;
end

module With_interface (M : sig
  val bits : int
end) =
struct
  include M

  let k = 2 * bits

  module Config = Config

  module Stage0 = struct
    type 'a t =
      { a : 'a
      ; valid : 'a
      }
    [@@deriving sexp_of, hardcaml]
  end

  module Stage1 = struct
    type 'a t =
      { q : 'a
      ; a' : 'a
      ; valid : 'a
      }
    [@@deriving sexp_of, hardcaml]

    let create ~scope ~clock ~enable ~m ~(config : Config.t) { Stage0.a; valid } =
      assert (width a = bits * 2);
      let latency =
        Approx_msb_multiplier.Config.latency config.approx_msb_multiplier_config
      in
      let spec = Reg_spec.create ~clock () in
      let q =
        Approx_msb_multiplier.hierarchical
          ~scope
          ~config:config.approx_msb_multiplier_config
          ~clock
          ~enable
          (Multiply_by_constant
             (uresize (sel_top a bits) (bits + 1), Bits.of_z ~width:(bits + 1) m))
      in
      let q = q.:[(2 * bits) - 1, bits] in
      assert (width q = bits);
      { q
      ; a' =
          pipeline
            ~enable
            ~n:latency
            spec
            (sel_bottom a (bits + config.num_correction_steps))
      ; valid = pipeline ~enable ~n:latency spec valid
      }
    ;;
  end

  module Stage2 = struct
    type 'a t =
      { qp : 'a
      ; a' : 'a
      ; valid : 'a
      }
    [@@deriving sexp_of, hardcaml]

    let create ~clock ~scope ~enable ~p ~(config : Config.t) { Stage1.q; a'; valid } =
      let latency = Half_width_multiplier.Config.latency config.half_multiplier_config in
      let spec = Reg_spec.create ~clock () in
      assert (width q = bits);
      { qp =
          Half_width_multiplier.hierarchical
            ~scope
            ~clock
            ~enable
            ~config:config.half_multiplier_config
            (Multiply_by_constant
               ( uresize q (bits + config.num_correction_steps)
               , Bits.of_z ~width:(bits + config.num_correction_steps) p ))
      ; a' = pipeline ~enable ~n:latency spec a'
      ; valid = pipeline ~enable ~n:latency spec valid
      }
    ;;
  end

  module Stage3 = struct
    type 'a t =
      { a_minus_qp : 'a
      ; valid : 'a
      }
    [@@deriving sexp_of, hardcaml]

    let create ~scope ~clock ~enable ~(config : Config.t) { Stage2.qp; a'; valid } =
      let spec = Reg_spec.create ~clock () in
      let stages = config.subtracter_stages in
      let latency = Modulo_subtractor_pipe.latency ~stages in
      assert (width a' = bits + config.num_correction_steps);
      assert (width qp = bits + config.num_correction_steps);
      { a_minus_qp =
          Adder_subtractor_pipe.sub ~stages ~scope ~enable ~clock [ a'; qp ]
          |> Adder_subtractor_pipe.O.result
      ; valid = pipeline ~enable ~n:latency spec valid
      }
    ;;
  end

  module Stage4 = struct
    type 'a t =
      { a_mod_p : 'a
      ; valid : 'a
      }
    [@@deriving sexp_of, hardcaml]

    let create ~scope ~clock ~enable ~p ~(config : Config.t) { Stage3.a_minus_qp; valid } =
      assert (width a_minus_qp = bits + config.num_correction_steps);
      let spec = Reg_spec.create ~clock () in
      let stages = config.subtracter_stages in
      let correction_factors =
        List.init config.num_correction_steps ~f:(fun i -> 1 lsl i) |> List.rev
      in
      let latency =
        Modulo_subtractor_pipe.latency ~stages * List.length correction_factors
      in
      let a_mod_p =
        List.fold correction_factors ~init:a_minus_qp ~f:(fun acc i ->
          let result =
            Adder_subtractor_pipe.sub
              ~stages
              ~scope
              ~enable
              ~clock
              [ acc
              ; Signal.of_z ~width:(bits + config.num_correction_steps) Z.(of_int i * p)
              ]
          in
          let borrow = Adder_subtractor_pipe.O.carry result in
          mux2
            borrow
            (Signal.pipeline spec ~n:stages acc)
            (Adder_subtractor_pipe.O.result result))
        |> Fn.flip Signal.uresize bits
      in
      { a_mod_p; valid = pipeline ~enable ~n:latency spec valid }
    ;;
  end

  module I = struct
    type 'a t =
      { clock : 'a
      ; enable : 'a
      ; a : 'a [@bits 2 * bits]
      ; valid : 'a [@rtlprefix "in_"]
      }
    [@@deriving sexp_of, hardcaml]
  end

  module O = struct
    type 'a t =
      { a_mod_p : 'a [@bits bits]
      ; valid : 'a [@rtlprefix "out_"]
      }
    [@@deriving sexp_of, hardcaml]
  end

  let create ~config ~p scope { I.clock; enable; a; valid } =
    assert (Z.log2up p <= bits);
    let m = Z.((one lsl k) / p) in
    let { Stage4.a_mod_p; valid } =
      let ( -- ) = Scope.naming scope in
      { Stage0.a; valid }
      |> Stage1.create ~scope ~clock ~enable ~m ~config
      |> Stage1.map2 Stage1.port_names ~f:(fun n s -> s -- ("stage1$" ^ n))
      |> Stage2.create ~scope ~clock ~enable ~p ~config
      |> Stage2.map2 Stage2.port_names ~f:(fun n s -> s -- ("stage2$" ^ n))
      |> Stage3.create ~scope ~clock ~enable ~config
      |> Stage3.map2 Stage3.port_names ~f:(fun n s -> s -- ("stage3$" ^ n))
      |> Stage4.create ~scope ~clock ~enable ~p ~config
      |> Stage4.map2 Stage4.port_names ~f:(fun n s -> s -- ("stage4$" ^ n))
    in
    { O.valid; a_mod_p = uresize a_mod_p bits }
  ;;

  let hierarchical ~config ~p scope i =
    let module H = Hierarchy.In_scope (I) (O) in
    let name = [%string "barrett_reduction_%{bits#Int}"] in
    H.hierarchical ~scope ~name (create ~config ~p) i
  ;;
end

let hierarchical ~scope ~config ~p ~clock ~enable { With_valid.valid; value = a } =
  let bits = width a in
  let module M =
    With_interface (struct
      let bits = (bits + 1) / 2
    end)
  in
  let { M.O.a_mod_p; valid } =
    M.hierarchical ~config ~p scope { M.I.clock; enable; a; valid }
  in
  { With_valid.valid; value = a_mod_p }
;;
