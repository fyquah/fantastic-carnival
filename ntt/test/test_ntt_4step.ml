open Core
module Gf = Ntts_r_fun.Gf_z
module Ntt_sw = Ntts_r_fun.Ntt_sw.Make (Gf)

let%expect_test "form 2d input matrix, transpose" =
  let input = Array.init 16 ~f:(fun i -> Gf.of_z (Z.of_int i)) in
  let matrix = Ntt_sw.matrix input 2 2 in
  print_s [%message (matrix : Gf.t array array)];
  let transpose = Ntt_sw.transpose matrix in
  print_s [%message (transpose : Gf.t array array)];
  [%expect
    {|
    (matrix ((0 1 2 3) (4 5 6 7) (8 9 10 11) (12 13 14 15)))
    (transpose ((0 4 8 12) (1 5 9 13) (2 6 10 14) (3 7 11 15))) |}]
;;

let%expect_test "inverse, 4 step" =
  let input = Array.init 16 ~f:(fun i -> Gf.of_z (Z.of_int i)) in
  let expected = Array.copy input in
  Ntt_sw.inverse_dit expected;
  print_s [%message (expected : Gf.t array)];
  let four_step = Ntt_sw.four_step input 2 in
  print_s [%message (four_step : Gf.t array)];
  [%expect
    {|
    (expected
     (120 9185100786013534200 18444501065828136953 9189603281834309625
      18444492269600899065 9185082089752463353 2260596040923128
      9189586793186428920 18446744069414584313 9257157276228155385
      18444483473373661177 9261661979662120952 2251799813685240
      9257140787580274680 2243003586447352 9261643283401050105))
    (four_step
     (120 9185100786013534200 18444501065828136953 9189603281834309625
      18444492269600899065 9185082089752463353 2260596040923128
      9189586793186428920 18446744069414584313 9257157276228155385
      18444483473373661177 9261661979662120952 2251799813685240
      9257140787580274680 2243003586447352 9261643283401050105)) |}]
;;

(* hardware *)

open Hardcaml
open Hardcaml_waveterm
module N4 = Ntts_r_fun.Ntt_4step
module Gf_bits = Ntts_r_fun.Gf_bits.Make (Bits)
module Core = Ntts_r_fun.Ntt_4step.Core
module Sim = Cyclesim.With_interface (Core.I) (Core.O)

let logn = N4.logn
let logcores = N4.logcores
let num_cores = 1 lsl logcores

let%expect_test "" =
  print_s [%message (logn : int) (logcores : int)];
  [%expect {| ((logn 5) (logcores 3)) |}];
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Core.create (Scope.create ~flatten_design:true ()))
  in
  let inputs = Cyclesim.inputs sim in
  let waves, sim = Waveform.create sim in
  let input_coefs =
    Array.init (1 lsl logcores) ~f:(fun _ ->
      Array.init (1 lsl logn) ~f:(fun _ -> Z.of_int (Random.int 100_000)))
  in
  inputs.clear := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.clear := Bits.gnd;
  Cyclesim.cycle sim;
  inputs.wr_en := Bits.ones num_cores;
  for ntt = 0 to (1 lsl logn) - 1 do
    inputs.wr_addr := Bits.of_int ~width:logn ntt;
    for core = 0 to (1 lsl logcores) - 1 do
      inputs.wr_d.(core) := Gf_bits.of_z input_coefs.(core).(ntt) |> Gf_bits.to_bits
    done;
    Cyclesim.cycle sim
  done;
  inputs.wr_en := Bits.zero num_cores;
  inputs.start := Bits.vdd;
  inputs.input_done := Bits.vdd;
  inputs.output_done := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.start := Bits.gnd;
  for _ = 0 to 1000 do
    Cyclesim.cycle sim
  done;
  Waveform.print
    ~start_cycle:60
    ~display_width:94
    ~display_height:76
    ~wave_width:(-1)
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────┐
    │clock             ││╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥╥│
    │                  ││╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨╨│
    │clear             ││                                                                        │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │input_done        ││────────────────────────────────────────────────────────────────────────│
    │                  ││                                                                        │
    │output_done       ││────────────────────────────────────────────────────────────────────────│
    │                  ││                                                                        │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │rd_addr           ││ 00                                                                     │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │rd_en             ││ 00                                                                     │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │start             ││                                                                        │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_addr           ││ 1F                                                                     │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_d0             ││ 0000000000015979                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_d1             ││ 0000000000010A6E                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_d2             ││ 0000000000012B48                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_d3             ││ 000000000000FBE1                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_d4             ││ 000000000000D52C                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_d5             ││ 000000000001321B                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_d6             ││ 00000000000078DB                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_d7             ││ 000000000001407F                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││────────────────────────────────────────────────────────────────────────│
    │wr_en             ││ 00                                                                     │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │done_             ││                                                                        │
    │                  ││────────────────────────────────────────────────────────────────────────│
    │                  ││──────────┬───────────────┬───────────────┬────────────────┬────────────│
    │rd_q0             ││ 00000000.│0000000000045A.│00000000000A80.│000000000016DE44│00000000000.│
    │                  ││──────────┴───────────────┴───────────────┴────────────────┴────────────│
    │                  ││──────────┬───────────────┬───────────────┬────────────────┬────────────│
    │rd_q1             ││ 00000000.│0000000000079B.│00000000000C5E.│00000000001907AD│00000000000.│
    │                  ││──────────┴───────────────┴───────────────┴────────────────┴────────────│
    │                  ││──────────┬───────────────┬───────────────┬────────────────┬────────────│
    │rd_q2             ││ 00000000.│000000000005A3.│000000000009DB.│000000000017CBFF│00000000000.│
    │                  ││──────────┴───────────────┴───────────────┴────────────────┴────────────│
    │                  ││──────────┬───────────────┬───────────────┬────────────────┬────────────│
    │rd_q3             ││ 00000000.│0000000000061D.│00000000000FED.│00000000001ADDCC│00000000000.│
    │                  ││──────────┴───────────────┴───────────────┴────────────────┴────────────│
    │                  ││──────────┬───────────────┬───────────────┬────────────────┬────────────│
    │rd_q4             ││ 00000000.│00000000000625.│00000000000C51.│0000000000195528│00000000000.│
    │                  ││──────────┴───────────────┴───────────────┴────────────────┴────────────│
    │                  ││──────────┬───────────────┬───────────────┬────────────────┬────────────│
    │rd_q5             ││ 00000000.│000000000004CD.│000000000009C9.│0000000000181A29│00000000000.│
    │                  ││──────────┴───────────────┴───────────────┴────────────────┴────────────│
    │                  ││──────────┬───────────────┬───────────────┬────────────────┬────────────│
    │rd_q6             ││ 00000000.│0000000000072F.│00000000000B7E.│0000000000161EEB│00000000000.│
    │                  ││──────────┴───────────────┴───────────────┴────────────────┴────────────│
    │                  ││──────────┬───────────────┬───────────────┬────────────────┬────────────│
    │rd_q7             ││ 00000000.│0000000000067C.│00000000000B44.│000000000019609D│00000000000.│
    │                  ││──────────┴───────────────┴───────────────┴────────────────┴────────────│
    │start_input       ││                                                        ┌┐              │
    │                  ││────────────────────────────────────────────────────────┘└──────────────│
    └──────────────────┘└────────────────────────────────────────────────────────────────────────┘ |}]
;;
