#include <assert.h>

#include "driver.h"

namespace argpos {
  const uint64_t GMEM_INPUT = 3;
  const uint64_t GMEM_INTERMEDIATE = 4;
  const uint64_t GMEM_OUTPUT = 5;
  const uint64_t ROW_SIZE = 6;
  const uint64_t PHASE = 7;
};  // argpos

std::ostream& operator<<(std::ostream &os, CoreType core_type)
{
  switch (core_type) {
  case CoreType::REVERSE:
    return os << "REVERSE";

  case CoreType::NTT_2_12:
    return os << "NTT_2_12";

  case CoreType::NTT_2_18:
    return os << "NTT_2_18";

  case CoreType::NTT_2_24:
    return os << "NTT_2_24";
  }

  assert(false);
}


class LogTimeTaken {
private:
  const char *descr;
  std::chrono::time_point<std::chrono::steady_clock> start;

public:
  LogTimeTaken(const char *descr)
    : descr(descr), start(std::chrono::steady_clock::now()) {}

  ~LogTimeTaken() {
    auto end = std::chrono::steady_clock::now();
    std::chrono::duration<double> elapsed_seconds = end - start;
    std::cout << "[" << descr << "] " << elapsed_seconds.count() << "s\n";
  }
};


NttFpgaDriverArg::NttFpgaDriverArg(CoreType core_type, uint64_t log_row_size)
  : core_type(core_type), log_row_size(log_row_size)
{
}

uint64_t NttFpgaDriverArg::row_size() {
  return 1ull << log_row_size; 
}

uint64_t NttFpgaDriverArg::num_elements() {
  return row_size() * row_size();
}

NttFpgaDriverArg NttFpgaDriverArg::create_reverse(uint64_t log_row_size)
{
  return NttFpgaDriverArg(CoreType::REVERSE, log_row_size);
}

NttFpgaDriverArg NttFpgaDriverArg::create_ntt_2_24()
{
  return NttFpgaDriverArg(CoreType::NTT_2_24, 12);
}

NttFpgaDriverArg NttFpgaDriverArg::create_ntt_2_18()
{
  return NttFpgaDriverArg(CoreType::NTT_2_18, 9);
}

NttFpgaDriverArg NttFpgaDriverArg::create_ntt_2_12()
{
  return NttFpgaDriverArg(CoreType::NTT_2_12, 6);
}

NttFpgaDriver::NttFpgaDriver(NttFpgaDriverArg driver_arg) : 
    core_type(driver_arg.core_type),
    log_row_size(driver_arg.log_row_size),
	  row_size(1 << driver_arg.log_row_size),
	  matrix_size(row_size * row_size),
    loaded_xclbin(false),
    m_max_num_buffers_in_flight(8),
    last_enqueued_buffer(nullptr)
{
  // We only have at most 2 events pending at a time
  tmp_events_to_wait_for.resize(2);
}


template<typename F>
static auto
bench(const char *descr, F f) {
  LogTimeTaken log_time_taken(descr);
  return f();
}

NttFpgaBuffer* NttFpgaDriver::request_buffer()
{
  for (auto & p : user_buffers) {
    if (!p.in_use) {
      p.in_use = true;
      return &p;
    }
  }

  return nullptr;
}

void NttFpgaDriver::free_buffer(NttFpgaBuffer *buffer)
{
  if (!buffer->in_use) {
    std::string error_message;
    error_message
        .append("Cannot free a buffer that has already been freed (or not in use)! ");
    throw std::runtime_error(error_message);
  }
  /* TODO(fyquah): Check no outstanding events? */
  buffer->in_use = false;
}

void NttFpgaDriver::enqueue_transfer_data_to_fpga(NttFpgaBuffer *buffer)
{
  tmp_events_to_wait_for.clear();
  // The following doesn't help:
  //
  // if (last_enqueued_buffer != nullptr) {
  //   tmp_events_to_wait_for.push_back(last_enqueued_buffer->ev_transfer_data_to_fpga);
  // }

  OCL_CHECK(err, err = q.enqueueMigrateMemObjects(
        {buffer->cl_buffer_input},
        0 /* 0 means from host*/,
        &tmp_events_to_wait_for,
        &buffer->ev_transfer_data_to_fpga));
}

void NttFpgaDriver::enqueue_transfer_data_from_fpga(NttFpgaBuffer *buffer)
{
  tmp_events_to_wait_for.clear();
  tmp_events_to_wait_for.push_back(buffer->ev_phase2_work);

  OCL_CHECK(err, err = q.enqueueMigrateMemObjects(
        {buffer->cl_buffer_output},
        CL_MIGRATE_MEM_OBJECT_HOST,
        &tmp_events_to_wait_for,
        &buffer->ev_transfer_data_from_fpga
        ));
}

void NttFpgaDriver::enqueue_phase1_work(NttFpgaBuffer *buffer)
{
  tmp_events_to_wait_for.clear();
  tmp_events_to_wait_for.push_back(buffer->ev_transfer_data_to_fpga);
  if (last_enqueued_buffer != nullptr) {
    tmp_events_to_wait_for.push_back(last_enqueued_buffer->ev_phase2_work);
  }

  OCL_CHECK(err, err = krnl_controller.setArg(argpos::PHASE, (uint8_t) 0b01));
  // The reverse core uses the C++ HLS ap_ctrl_handshake mechanism, hence it needs to be
  // explicitly enqueued. The NTT core operates solely based on axi streams without any
  // control signals., so we don't need to enqueue it.
  if (core_type == CoreType::REVERSE) {
    OCL_CHECK(err, err = q.enqueueTask(krnl_ntt));
  }
  OCL_CHECK(err, err = q.enqueueTask(krnl_controller, &tmp_events_to_wait_for, &buffer->ev_phase1_work));
}

void NttFpgaDriver::enqueue_phase2_work(NttFpgaBuffer *buffer)
{
  tmp_events_to_wait_for.clear();
  tmp_events_to_wait_for.push_back(buffer->ev_phase1_work);

  OCL_CHECK(err, err = krnl_controller.setArg(argpos::PHASE, (uint8_t) 0b10));
  // See comment in "Doing phase 1 work"
  if (core_type == CoreType::REVERSE) {
    OCL_CHECK(err, err = q.enqueueTask(krnl_ntt));
  }
  OCL_CHECK(err, err = q.enqueueTask(krnl_controller, &tmp_events_to_wait_for, &buffer->ev_phase2_work));
  last_enqueued_buffer = buffer;
}

void NttFpgaDriver::set_args(NttFpgaBuffer *buffer)
{
  // Set the controller arguments
  OCL_CHECK(err, err = krnl_controller.setArg(argpos::GMEM_INPUT, buffer->cl_buffer_input));
  OCL_CHECK(err, err = krnl_controller.setArg(argpos::GMEM_INTERMEDIATE, buffer->cl_buffer_intermediate));
  OCL_CHECK(err, err = krnl_controller.setArg(argpos::GMEM_OUTPUT, buffer->cl_buffer_output));
  OCL_CHECK(err, err = krnl_controller.setArg(argpos::ROW_SIZE, (uint16_t) row_size));

  // Set the reverse arguments
  if (core_type == CoreType::REVERSE) {
    OCL_CHECK(err, err = krnl_ntt.setArg(2, (uint16_t) row_size));
  }
}

void NttFpgaDriver::wait_for_result(NttFpgaBuffer *buffer)
{
  OCL_CHECK(err, err = buffer->ev_transfer_data_from_fpga.wait());
}

void NttFpgaDriver::enqueue_evaluation_async(NttFpgaBuffer *buffer)
{
  set_args(buffer);
  enqueue_transfer_data_to_fpga(buffer);
  enqueue_phase1_work(buffer);
  enqueue_phase2_work(buffer);
  enqueue_transfer_data_from_fpga(buffer);
}

void NttFpgaDriver::simple_evaluate_slow_with_profilling(uint64_t *out, const uint64_t *in, uint64_t data_length) {
  if (data_length > matrix_size) {
    std::string error_message;
    error_message
        .append("Data length exceeds supported size of driver. data_length = ")
        .append(std::to_string(data_length))
        .append(", driver log_row_size = ")
        .append(std::to_string(log_row_size));
    throw std::runtime_error(error_message);
  }

  auto *buffer = request_buffer();

  bench("Evaluate NTT", [&]() {
    bench("Copy to internal page-aligned buffer", [&](){
        memcpy(buffer->input_data()              , in, sizeof(uint64_t) * data_length);
        memset(buffer->input_data() + data_length, 0 , sizeof(uint64_t) * (matrix_size - data_length));
    });

    bench("Copying input points to device", [&]() {
        set_args(buffer);
        enqueue_transfer_data_to_fpga(buffer);
        OCL_CHECK(err, err = buffer->ev_transfer_data_to_fpga.wait());
    });

    bench("Doing NTT (phase1 + twiddling + phase2)", [&]() {
        enqueue_phase1_work(buffer);
        enqueue_phase2_work(buffer);
        OCL_CHECK(err, err = buffer->ev_phase2_work.wait());
    });

    bench("Copying final result to host", [&]() {
        enqueue_transfer_data_from_fpga(buffer);
        OCL_CHECK(err, err = buffer->ev_transfer_data_from_fpga.wait());
    });

    bench("Copy from internal page-aligned buffer", [&]() {
      memcpy(out, buffer->output_data(), sizeof(uint64_t) * data_length);
    });
  });

  free_buffer(buffer);
}

void NttFpgaDriver::simple_evaluate(uint64_t *out, const uint64_t *in, uint64_t data_length) {
  auto *buffer = request_buffer();

  memcpy(buffer->input_data()              , in, sizeof(uint64_t) * data_length);
  memset(buffer->input_data() + data_length, 0 , sizeof(uint64_t) * (matrix_size - data_length));

  enqueue_evaluation_async(buffer);
  wait_for_result(buffer);

  memcpy(out, buffer->output_data(), sizeof(uint64_t) * data_length);

  free_buffer(buffer);
}

void NttFpgaDriver::load_xclbin(const std::string& binaryFile)
{
  if (loaded_xclbin) {
    std::string error_message("Cannot call NttFpgaDriver::load_xclbin multiple times!");
    throw std::runtime_error(error_message);
  }

  loaded_xclbin = true;

  // OPENCL HOST CODE AREA START
  // Create Program and Kernel
  auto devices = xcl::get_xil_devices();
  auto device = devices[0];

  // read_binary_file() is a utility API which will load the binaryFile
  // and will return the pointer to file buffer.
  auto fileBuf = xcl::read_binary_file(binaryFile);
  cl::Program::Binaries bins{{fileBuf.data(), fileBuf.size()}};
  bool valid_device = false;
  for (size_t i = 0; i < devices.size(); i++) {
      auto device = devices[i];
      // Creating Context and Command Queue for selected Device
      OCL_CHECK(err, context = cl::Context(device, nullptr, nullptr, nullptr, &err));
      OCL_CHECK(err, q = cl::CommandQueue(context, device, CL_QUEUE_OUT_OF_ORDER_EXEC_MODE_ENABLE | CL_QUEUE_PROFILING_ENABLE, &err));

      std::cout << "Trying to program device[" << i << "]: " << device.getInfo<CL_DEVICE_NAME>() << std::endl;
      cl::Program program(context, {device}, bins, nullptr, &err);
      if (err != CL_SUCCESS) {
          std::cout << "Failed to program device[" << i << "] with xclbin file!\n";
      } else {
          std::cout << "Device[" << i << "]: program successful!" << std::endl;
          if (core_type == CoreType::REVERSE) {
            OCL_CHECK(err, krnl_ntt = cl::Kernel(program, "krnl_ntt", &err));
          }
          OCL_CHECK(err, krnl_controller = cl::Kernel(program, "krnl_controller", &err));
          valid_device = true;
          break; // we break because we found a valid device
      }
  }
  if (!valid_device) {
      std::cout << "Failed to program any device found, exit!\n";
      exit(EXIT_FAILURE);
  }

  // Allocate user Buffers
  // TODO(fyquah): Is the awkward p jumping around actually useful?

  user_buffers.resize(max_num_buffers_in_flight());
  uint64_t p = 0;
  for (uint64_t i = 0; i < max_num_buffers_in_flight(); i++) {
    auto &user_buffer = user_buffers[i];
    (void) p;
    size_t vector_size_bytes = sizeof(uint64_t) * matrix_size;

    user_buffer.in_use = false;

    user_buffer.host_buffer_input = vec64(matrix_size);
    user_buffer.host_buffer_output = vec64(matrix_size);

    /* CL_MEM_HOST_WRITE_ONLY is important! See notes about write-combining buffer in
       https://man.opencl.org/clCreateBuffer.html . This flag alone yield around a 1.6x
       improvement in throughput, and some improvement in latency.
    */
    OCL_CHECK(err, user_buffer.cl_buffer_input = cl::Buffer(
                            context,
                            CL_MEM_USE_HOST_PTR | CL_MEM_READ_ONLY | CL_MEM_HOST_WRITE_ONLY,
                            vector_size_bytes,
                            user_buffer.host_buffer_input.data(),
                            &err)
                    );
    OCL_CHECK(err, user_buffer.cl_buffer_intermediate = cl::Buffer(
                            context,
                            CL_MEM_READ_WRITE | CL_MEM_HOST_NO_ACCESS,
                            vector_size_bytes,
                            nullptr,  /* nullptr because the host never access this */
                            &err)
                    );
    OCL_CHECK(err, user_buffer.cl_buffer_output = cl::Buffer(
                            context,
                            CL_MEM_USE_HOST_PTR | CL_MEM_WRITE_ONLY | CL_MEM_HOST_READ_ONLY,
                            vector_size_bytes,
                            user_buffer.host_buffer_output.data(),
                            &err));

    p += 4;
    if (p >= max_num_buffers_in_flight()) {
      p = p % 4;
      p += 1;
    }
  }
}
