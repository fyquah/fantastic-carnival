open! Base
open! Hardcaml

module Core (Config : Config.S) = struct
  open Signal
  open Config

  let pipeline_depth_per_window = (pipeline_depth + num_windows - 1) / num_windows

  module I = struct
    type 'a t =
      { clock : 'a
      ; clear : 'a
      ; scalar_in : 'a [@bits window_size_bits]
      ; shift : 'a
      ; scalar_match : 'a [@bits window_size_bits]
      }
    [@@deriving sexp_of, hardcaml]
  end

  module O = struct
    type 'a t = { is_in_pipeline : 'a } [@@deriving sexp_of, hardcaml]
  end

  let create _scope (i : _ I.t) =
    let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
    let rec build_pipe n d pipe =
      if n = pipeline_depth_per_window
      then pipe
      else (
        let d = reg spec ~enable:i.shift d in
        build_pipe (n + 1) d (d :: pipe))
    in
    let stored = build_pipe 0 i.scalar_in [] in
    { O.is_in_pipeline =
        List.map stored ~f:(fun d -> d ==: i.scalar_match)
        |> tree ~arity:6 ~f:(reduce ~f:( |: ))
    }
  ;;

  let hierarchy ~window scope =
    let module Hier = Hierarchy.In_scope (I) (O) in
    Hier.hierarchical ~name:"bpipe" ~instance:("bp_" ^ Int.to_string window) ~scope create
  ;;
end

module Make (Config : Config.S) = struct
  open Signal
  open Config

  let log_num_windows = Int.ceil_log2 num_windows

  module I = struct
    type 'a t =
      { clock : 'a
      ; clear : 'a
      ; window : 'a [@bits log_num_windows]
      ; scalar_in : 'a array [@bits window_size_bits] [@length num_windows]
      ; stalled_scalar : 'a [@bits window_size_bits]
      ; process_stalled : 'a
      ; shift : 'a
      }
    [@@deriving sexp_of, hardcaml]
  end

  module O = struct
    type 'a t = { is_in_pipeline : 'a list [@length num_windows] }
    [@@deriving sexp_of, hardcaml]
  end

  module Core = Core (Config)

  let create scope (i : _ I.t) =
    let c =
      List.init num_windows ~f:(fun window_index ->
          Core.hierarchy
            ~window:window_index
            scope
            { Core.I.clock = i.clock
            ; clear = i.clear
            ; scalar_in =
                mux2 i.process_stalled (zero window_size_bits) i.scalar_in.(window_index)
            ; shift = i.window ==:. window_index &: i.shift
            ; scalar_match =
                mux2 i.process_stalled i.stalled_scalar i.scalar_in.(window_index)
            })
    in
    { O.is_in_pipeline = List.map c ~f:(fun c -> c.is_in_pipeline) }
  ;;

  let hierarchy scope =
    let module Hier = Hierarchy.In_scope (I) (O) in
    Hier.hierarchical ~name:"bpipes" ~scope create
  ;;
end
