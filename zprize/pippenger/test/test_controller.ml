open! Core
open Hardcaml
open Hardcaml_waveterm

module Config = struct
  let window_size_bits = 8
  let num_windows = 4
  let affine_point_bits = 16
  let pipeline_depth = 8
  let log_stall_fifo_depth = 2
end

module Controller = Pippenger.Controller.Make (Config)
module Sim = Cyclesim.With_interface (Controller.I) (Controller.O)
module I_rules = Display_rules.With_interface (Controller.I)
module O_rules = Display_rules.With_interface (Controller.O)

let ( <-. ) a b = a := Bits.of_int ~width:(Bits.width !a) b
let scalars = [| [| 1; 2; 3; 4 |]; [| 5; 2; 1; 3 |]; [| 1; 3; 3; 5 |] |]

let%expect_test "" =
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Controller.create (Scope.create ~flatten_design:true ()))
  in
  let waves, sim = Waveform.create sim in
  let inputs = Cyclesim.inputs sim in
  inputs.clear := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.clear := Bits.gnd;
  inputs.start := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.start := Bits.gnd;
  for i = 0 to 2 do
    inputs.scalar_valid := Bits.vdd;
    for window = 0 to Config.num_windows - 1 do
      inputs.scalar.(window) <-. scalars.(i).(window);
      Cyclesim.cycle sim;
      Cyclesim.cycle sim
    done;
    inputs.scalar_valid := Bits.gnd
  done;
  Waveform.print
    ~display_width:130
    ~display_height:60
    ~wave_width:1
    ~start_cycle:0
    ~display_rules:
      (List.concat
         [ I_rules.default ()
         ; O_rules.default ()
         ; [ Display_rule.port_name_is "STATE" ~wave_format:(Index Controller.State.names)
           ; Display_rule.default
           ]
         ])
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │clock             ││┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ │
    │                  ││  └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─│
    │clear             ││────┐                                                                                                       │
    │                  ││    └───────────────────────────────────────────────────────────────────────────────────────────────────    │
    │start             ││    ┌───┐                                                                                                   │
    │                  ││────┘   └───────────────────────────────────────────────────────────────────────────────────────────────    │
    │                  ││────────┬───────────────────────────────┬───────────────────────────────┬───────────────────────────────    │
    │scalar0           ││ 00     │01                             │05                             │01                                 │
    │                  ││────────┴───────────────────────────────┴───────────────────────────────┴───────────────────────────────    │
    │                  ││────────────────┬───────────────────────────────────────────────────────────────┬───────────────────────    │
    │scalar1           ││ 00             │02                                                             │03                         │
    │                  ││────────────────┴───────────────────────────────────────────────────────────────┴───────────────────────    │
    │                  ││────────────────────────┬───────────────────────────────┬───────────────────────────────┬───────────────    │
    │scalar2           ││ 00                     │03                             │01                             │03                 │
    │                  ││────────────────────────┴───────────────────────────────┴───────────────────────────────┴───────────────    │
    │                  ││────────────────────────────────┬───────────────────────────────┬───────────────────────────────┬───────    │
    │scalar3           ││ 00                             │04                             │03                             │05         │
    │                  ││────────────────────────────────┴───────────────────────────────┴───────────────────────────────┴───────    │
    │scalar_valid      ││        ┌───────────────────────────────────────────────────────────────────────────────────────────────    │
    │                  ││────────┘                                                                                                   │
    │last_scalar       ││                                                                                                            │
    │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────    │
    │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────    │
    │affine_point      ││ 0000                                                                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────    │
    │done_             ││────────┐                                                                                                   │
    │                  ││        └───────────────────────────────────────────────────────────────────────────────────────────────    │
    │scalar_read       ││                                    ┌───┐                           ┌───┐                           ┌───    │
    │                  ││────────────────────────────────────┘   └───────────────────────────┘   └───────────────────────────┘       │
    │                  ││────────────────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────    │
    │window            ││ 0              │1      │2      │3      │0      │1      │2      │3      │0      │1      │2      │3          │
    │                  ││────────────────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────    │
    │                  ││────────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────────────┬───────    │
    │bucket            ││ 00     │01     │02     │03     │04     │05     │02     │01     │03     │01     │03             │05         │
    │                  ││────────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────────────┴───────    │
    │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────    │
    │adder_affine_point││ 0000                                                                                                       │
    │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────    │
    │bubble            ││                                                    ┌───┐                   ┌───┐           ┌───┐           │
    │                  ││────────────────────────────────────────────────────┘   └───────────────────┘   └───────────┘   └───────    │
    │execute           ││            ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───    │
    │                  ││────────────┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘       │
    │                  ││────────┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───    │
    │STATE             ││ -      │M  │Es │Ws │Es │Ws │Es │Ws │Es │M  │Es │Ws │Es │Ws │Es │Ws │Es │M  │Es │Ws │Es │Ws │Es │Ws │Es     │
    │                  ││────────┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───    │
    │                  ││────────────────┬───────────────────────────────┬───────────────────────────────┬───────────────────────    │
    │bpipes$bp_0$scl$0 ││ 00             │01                             │05                             │00                         │
    │                  ││────────────────┴───────────────────────────────┴───────────────────────────────┴───────────────────────    │
    │                  ││────────────────────────────────────────────────┬───────────────────────────────┬───────────────────────    │
    │bpipes$bp_0$scl$1 ││ 00                                             │01                             │05                         │
    │                  ││────────────────────────────────────────────────┴───────────────────────────────┴───────────────────────    │
    │                  ││────────────────────────┬───────────────────────────────┬───────────────────────────────┬───────────────    │
    │bpipes$bp_1$scl$0 ││ 00                     │02                             │00                             │03                 │
    │                  ││────────────────────────┴───────────────────────────────┴───────────────────────────────┴───────────────    │
    │                  ││────────────────────────────────────────────────────────┬───────────────────────────────┬───────────────    │
    │bpipes$bp_1$scl$1 ││ 00                                                     │02                             │00                 │
    │                  ││────────────────────────────────────────────────────────┴───────────────────────────────┴───────────────    │
    │                  ││────────────────────────────────┬───────────────────────────────┬───────────────────────────────┬───────    │
    └──────────────────┘└────────────────────────────────────────────────────────────────────────────────────────────────────────────┘ |}]
;;
