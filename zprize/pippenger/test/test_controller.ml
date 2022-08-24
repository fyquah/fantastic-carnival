open! Core
open Hardcaml
open Hardcaml_waveterm
module Config = Pippenger.Config.Zprize
module Controller = Pippenger.Controller.Make (Config)
module Sim = Cyclesim.With_interface (Controller.I) (Controller.O)

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
  inputs.scalar_valid := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.scalar_valid := Bits.gnd;
  for _ = 0 to 10 do
    Cyclesim.cycle sim
  done;
  Waveform.print ~display_width:100 ~display_height:35 ~wave_width:1 waves;
  [%expect{|
    ┌Signals───────────┐┌Waves─────────────────────────────────────────────────────────────────────────┐
    │clock             ││┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─│
    │                  ││  └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ └─┘ │
    │clear             ││────┐                                                                         │
    │                  ││    └───────────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │affine_point      ││ 000000000000000000000000000000000000000000000000000000.                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │scalar0           ││ 0000                                                                         │
    │                  ││────────────────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │scalar1           ││ 0000                                                                         │
    │                  ││────────────────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │scalar2           ││ 0000                                                                         │
    │                  ││────────────────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │scalar3           ││ 0000                                                                         │
    │                  ││────────────────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │scalar4           ││ 0000                                                                         │
    │                  ││────────────────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │scalar5           ││ 0000                                                                         │
    │                  ││────────────────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    │scalar6           ││ 0000                                                                         │
    │                  ││────────────────────────────────────────────────────────                      │
    │scalar_valid      ││        ┌───┐                                                                 │
    │                  ││────────┘   └───────────────────────────────────────────                      │
    │start             ││    ┌───┐                                                                     │
    │                  ││────┘   └───────────────────────────────────────────────                      │
    │                  ││────────────────────────────────────────────────────────                      │
    └──────────────────┘└──────────────────────────────────────────────────────────────────────────────┘ |}]
;;
