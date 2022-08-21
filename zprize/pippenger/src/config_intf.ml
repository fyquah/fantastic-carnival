module type S = sig
  val window_size_bits : int
  val num_windows : int
  val affine_point_bits : int
  val pipeline_depth : int
  val log_num_scalars : int
  val log_stall_fifo_depth : int
end

module type Config = sig
  module type S = S
end
