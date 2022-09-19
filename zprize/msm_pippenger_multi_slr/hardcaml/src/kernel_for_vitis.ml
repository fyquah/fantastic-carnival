open Core
open Hardcaml
open Hardcaml_axi
open Signal

module Make (C : Config.S) = struct
  let config = C.t
  let num_cores = Array.length config.scalar_bits_by_core

  module Kernel_for_single_instance = Kernel_for_single_instance.Make (C)

  module Stream_splitter_512 =
    Stream_splitter.Make
      (Axi512.Stream)
      (struct
        let num_outputs = num_cores
      end)

  module Gather_output_stream = Gather_output_stream.Make (C)

  module I = struct
    type 'a t =
      { ap_clk : 'a
      ; ap_rst_n : 'a
      ; host_to_fpga : 'a Axi512.Stream.Source.t [@rtlprefix "host_to_fpga_"]
      ; fpga_to_host_dest : 'a Axi512.Stream.Dest.t [@rtlprefix "fpga_to_host_"]
      }
    [@@deriving sexp_of, hardcaml]
  end

  module O = struct
    type 'a t =
      { fpga_to_host : 'a Axi512.Stream.Source.t [@rtlprefix "fpga_to_host_"]
      ; host_to_fpga_dest : 'a Axi512.Stream.Dest.t [@rtlprefix "host_to_fpga_"]
      }
    [@@deriving sexp_of, hardcaml]
  end

  let axis_pipeline ~n scope (input : _ Axi512.Stream.Register.I.t) =
    let outputs =
      Array.init n ~f:(fun _ -> Axi512.Stream.Register.O.Of_signal.wires ())
    in
    for i = 0 to n - 1 do
      let up = if i = 0 then input.up else outputs.(i - 1).dn in
      let dn_dest = if i = n - 1 then input.dn_dest else outputs.(i).up_dest in
      Axi512.Stream.Register.O.Of_signal.( <== )
        outputs.(i)
        (Axi512.Stream.Register.create
           scope
           { clock = input.clock; clear = input.clear; up; dn_dest })
    done;
    { Axi512.Stream.Register.O.dn = outputs.(n - 1).dn; up_dest = outputs.(0).up_dest }
  ;;

  let create ~build_mode (scope : Scope.t) (i : _ I.t) =
    let ap_clk = i.ap_clk in
    let ap_rst_n = i.ap_rst_n in
    let clock = ap_clk in
    let clear = ~:ap_rst_n in
    let stream_splitter = Stream_splitter_512.O.Of_signal.wires () in
    let splitter_to_sub_kernels_registers =
      Array.init num_cores ~f:(fun _ -> Axi512.Stream.Register.O.Of_signal.wires ())
    in
    let sub_kernels =
      Array.init num_cores ~f:(fun _ -> Kernel_for_single_instance.O.Of_signal.wires ())
    in
    let sub_kernels_to_gatherer_registers =
      Array.init num_cores ~f:(fun _ -> Axi512.Stream.Register.O.Of_signal.wires ())
    in
    let gather_output_stream = Gather_output_stream.O.Of_signal.wires () in
    Stream_splitter_512.O.Of_signal.assign
      stream_splitter
      (Stream_splitter_512.create
         scope
         { clock
         ; clear
         ; up = i.host_to_fpga
         ; dn_dests = Array.map splitter_to_sub_kernels_registers ~f:(fun k -> k.up_dest)
         });
    Array.iteri
      splitter_to_sub_kernels_registers
      ~f:(fun core_index splitter_to_sub_kernels_register ->
      Axi512.Stream.Register.O.Of_signal.( <== )
        splitter_to_sub_kernels_register
        (axis_pipeline
           ~n:2
           scope
           { clock
           ; clear
           ; up = stream_splitter.dns.(core_index)
           ; dn_dest = sub_kernels.(core_index).host_to_fpga_dest
           }));
    Array.iteri sub_kernels ~f:(fun core_index sub_kernel ->
      Kernel_for_single_instance.O.Of_signal.assign
        sub_kernel
        (Kernel_for_single_instance.hierarchical
           ~build_mode
           ~core_index
           scope
           { ap_clk
           ; ap_rst_n
           ; host_to_fpga = splitter_to_sub_kernels_registers.(core_index).dn
           ; fpga_to_host_dest = sub_kernels_to_gatherer_registers.(core_index).up_dest
           }));
    Array.iteri
      sub_kernels_to_gatherer_registers
      ~f:(fun core_index sub_kernels_to_gatherer_register ->
      Axi512.Stream.Register.O.Of_signal.( <== )
        sub_kernels_to_gatherer_register
        (axis_pipeline
           ~n:2
           scope
           { clock
           ; clear
           ; up = sub_kernels.(core_index).fpga_to_host
           ; dn_dest = gather_output_stream.sub_fpga_to_host_dests.(core_index)
           }));
    Gather_output_stream.O.Of_signal.assign
      gather_output_stream
      (Gather_output_stream.hierarchical
         scope
         { clock
         ; clear
         ; sub_fpga_to_hosts =
             Array.map sub_kernels_to_gatherer_registers ~f:(fun k -> k.dn)
         ; fpga_to_host_dest = i.fpga_to_host_dest
         });
    { O.fpga_to_host = gather_output_stream.fpga_to_host
    ; host_to_fpga_dest = stream_splitter.up_dest
    }
  ;;

  let hierarchical ~build_mode scope i =
    let module H = Hierarchy.In_scope (I) (O) in
    H.hierarchical ~scope ~name:"kernel" (create ~build_mode) i
  ;;
end
