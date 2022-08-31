open Base
open Hardcaml
open Signal

module Config = struct
  type t =
    | Verilog_multiply of { latency : int }
    | Hybrid_dsp_and_luts of { latency : int }
    | Specialized_43_bit_multiply
  [@@deriving sexp_of]

  let latency = function
    | Verilog_multiply { latency } -> latency
    | Hybrid_dsp_and_luts { latency } -> latency
    | Specialized_43_bit_multiply -> 5
  ;;
end

let long_multiplication_with_addition
    (type a)
    (module Comb : Comb.S with type t = a)
    ~pivot
    big
  =
  let open Comb in
  let output_width = width pivot + width big in
  let addition_terms =
    List.filter_mapi (bits_lsb pivot) ~f:(fun i b ->
        let term = mux2 b (concat_msb_e [ big; zero i ]) (zero (i + width big)) in
        if is_vdd (term ==:. 0) then None else Some term)
  in
  match addition_terms with
  | [] -> zero output_width
  | _ ->
    addition_terms
    |> Signal.tree ~arity:2 ~f:(reduce ~f:Uop.( +: ))
    |> Fn.flip uresize output_width
;;

let hybrid_dsp_and_luts_umul a b =
  assert (Signal.width a = Signal.width b);
  let w = Signal.width a in
  if w <= 17
  then a *: b
  else (
    let smaller = a *: b.:[16, 0] in
    let bigger =
      long_multiplication_with_addition (module Signal) ~pivot:(drop_bottom b 17) a
    in
    let result = uresize (bigger @: zero 17) (2 * w) +: uresize smaller (2 * w) in
    assert (width result = width a + width b);
    result)
;;

let specialized_43_bit_multiply
    (type a)
    (module Comb : Comb.S with type t = a)
    ~pipe
    (x : a)
    (y : a)
  =
  let open Comb in
  assert (width x = width y);
  assert (width x <= 43);
  let pipe2 ~n = uresize (pipe ~n x) 43, uresize (pipe ~n y) 43 in
  let p1 = x.:[25, 0] *: y.:[16, 0] in
  let p2 =
    let x, y = pipe2 ~n:1 in
    x.:[16, 0] *: y.:[42, 17]
  in
  let p3 =
    let x, y = pipe2 ~n:2 in
    x.:[42, 26] *: y.:[25, 0]
  in
  let p4 =
    let x, y = pipe2 ~n:3 in
    long_multiplication_with_addition (module Comb) ~pivot:x.:[25, 17] y.:[25, 17]
  in
  let p5 =
    let x, y = pipe2 ~n:4 in
    x.:[42, 17] *: y.:[42, 26]
  in
  assert (width p1 = 26 + 17);
  assert (width p2 = 26 + 17);
  assert (width p3 = 26 + 17);
  assert (width p4 = 18);
  assert (width p5 = 26 + 17);
  let a1 = pipe ~n:1 p1 in
  let a2 = pipe ~n:1 Uop.(p2 +: drop_bottom a1 17) in
  let a3 = pipe ~n:1 Uop.(p3 +: drop_bottom a2 9) in
  let a4 = pipe ~n:1 Uop.(p4 +: drop_bottom a3 8) in
  let a5 = pipe ~n:1 (p5 +: uresize (drop_bottom a4 9) 43) in
  let result =
    concat_msb
      [ a5
      ; pipe ~n:1 (sel_bottom a4 9)
      ; pipe ~n:2 (sel_bottom a3 8)
      ; pipe ~n:3 (sel_bottom a2 9)
      ; pipe ~n:4 (sel_bottom a1 17)
      ]
  in
  assert (width result = 43 * 2);
  uresize result (width x + width y)
;;

let create ~clock ~enable ~config a b =
  let spec = Reg_spec.create ~clock () in
  let pipeline ~n x = if Signal.is_const x then x else pipeline ~n spec ~enable x in
  match config with
  | Config.Verilog_multiply { latency } -> pipeline ~n:latency (a *: b)
  | Config.Hybrid_dsp_and_luts { latency } ->
    (* TODO(fyquah): either annotate this with backwards retiming, or
     * balance the register stages better.
     *)
    pipeline ~n:latency (hybrid_dsp_and_luts_umul a b)
  | Config.Specialized_43_bit_multiply ->
    let pipe ~n x = pipeline ~n x in
    specialized_43_bit_multiply (module Signal) ~pipe a b
;;

module For_testing = struct
  let long_multiplication_with_addition = long_multiplication_with_addition
  let specialized_43_bit_multiply = specialized_43_bit_multiply ~pipe:(fun ~n:_ x -> x)
end
