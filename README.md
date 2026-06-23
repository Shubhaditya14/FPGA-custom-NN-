# Foundry PYNQ Systolic Array Accelerator

## Section 1: PROJECT OVERVIEW

Foundry is an FPGA transformer inference accelerator project. This repository slice implements a 16x16 signed INT8 matrix multiply accelerator in Verilog, wraps it with AXI interfaces for PYNQ-Z2, and provides Python benchmarking code for comparing FPGA fabric execution against the ARM Cortex-A9 on the same Zynq-7020 chip.

The exact target hardware is the Digilent PYNQ-Z2 board with a Xilinx Zynq-7020 SoC. The Zynq-7020 contains dual ARM Cortex-A9 processors in the processing system and programmable FPGA fabric in the programmable logic. This project measures the same 16x16 INT8 matrix multiply workload on both sides: numpy INT32 matmul on ARM and a systolic INT8 multiply/INT32 accumulate array in FPGA fabric.

This matters because transformer inference is dominated by matrix multiplies in projections, attention, and MLP layers. A systolic array keeps many multiply-accumulate operations active at once and is the basic hardware pattern behind many neural-network accelerators.

## Section 2: ARCHITECTURE

The systolic array is a 16x16 grid of processing elements. Each PE receives one signed 8-bit A value from its left neighbor, one signed 8-bit B value from its top neighbor, multiplies them as INT8 x INT8, sign-extends the INT16 product, and accumulates into a signed INT32 register. A values flow rightward. B values flow downward. Once the wavefront is full, many PEs perform useful MACs every cycle, which is why the design is faster than running the operations sequentially.

Input skewing is the alignment step that makes the right A[k] and B[k] meet at each PE in the same cycle. For a 3x3 array, row 0 of A is delayed by 0 cycles, row 1 by 1 cycle, and row 2 by 2 cycles. Column 0 of B is delayed by 0 cycles, column 1 by 1 cycle, and column 2 by 2 cycles.

3x3 example:

```text
Cycle 0: A[0][0], B[0][0] enter.
Cycle 1: A[0][1], A[1][0], B[0][1], B[1][0] enter.
Cycle 2: A[0][2], A[1][1], A[2][0], B[0][2], B[1][1], B[2][0] enter.
Cycle 3: A[1][2], A[2][1], B[1][2], B[2][1] enter.
Cycle 4: A[2][2], B[2][2] enter.
```

AXI-Lite is used for control and status registers because register reads and writes are small, low-bandwidth transactions. AXI-Stream is used for matrix data because it supports high-throughput streaming with valid/ready backpressure. The RTL has two 128-bit stream inputs, one for A and one for B, and one 128-bit stream output for C.

The hardware cycle counter is the ground-truth latency counter. Python wall-clock timing includes software overhead, DMA setup, cache maintenance, and polling. The cycle counter measures the accelerator transaction from start until done inside hardware.

The top-level state machine is `IDLE -> LOADING -> COMPUTING -> DONE`. In `IDLE`, the accelerator waits for CONTROL bit 0. In `LOADING`, it accepts 16 stream beats for A and 16 stream beats for B. In `COMPUTING`, it runs the input skew and systolic array. In `DONE`, it asserts status done and streams out 64 result beats.

## Section 3: FILE STRUCTURE

`rtl/pe.v`: One signed INT8 multiply, signed INT32 accumulate processing element with registered A/B/valid outputs and accumulator clear.

`rtl/systolic_array_core.v`: 16x16 generated PE grid with rightward A flow, downward B flow, row-valid propagation, and flattened 256x32-bit result bus.

`rtl/input_skew.v`: Cycle-accurate row and column skewing module using shift-register chains so A row i is delayed by i cycles and B column j is delayed by j cycles.

`rtl/systolic_top.v`: AXI-Lite and AXI-Stream top-level wrapper with register map, load/compute/done state machine, cycle counter, and result stream.

`tb/tb_systolic_top.v`: RTL testbench that performs AXI-Lite and AXI-Stream transactions, checks all 256 outputs for a known matrix product, prints cycle count, and reports PASS/FAIL.

`constraints/pynq_z2.xdc`: PYNQ-Z2 clock and timing constraints for standalone synthesis and timing reference.

`python/utils.py`: Register access, cycle-counter access, DMA discovery, DMA buffer allocation, and matrix format conversion helpers.

`python/benchmark.py`: End-to-end benchmark script that loads the bitstream, prepares matrices, runs ARM numpy baseline, runs FPGA inference, verifies correctness, prints a table, and saves JSON results.

`python/inference_demo.py`: Transformer-style demo that runs Q, K, V, attention, and MLP-like matrix multiplies and prints per-layer cycle counts.

`vivado_setup.tcl`: Vivado project creation script for xc7z020clg400-1 that adds RTL/testbench files, packages the accelerator as local IP, and creates a Zynq PS + DMA block design.

`README.md`: This guide.

## Section 4: SETUP FROM SCRATCH

1. Install Vivado 2022.1 or later from AMD/Xilinx: https://www.xilinx.com/support/download.html. Include Zynq-7000 device support during installation.

2. Clone this repo on your laptop:

```bash
git clone <repo-url>
cd <repo>/foundry_pynq
```

3. Create the Vivado project:

```bash
vivado -mode batch -source vivado_setup.tcl
```

4. Run synthesis and implementation from Tcl:

```tcl
open_project vivado_project/foundry_pynq.xpr
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

In the GUI, open `vivado_project/foundry_pynq.xpr`, select `Run Synthesis`, then `Run Implementation`, then `Generate Bitstream`.

5. Export the bitstream:

```bash
cp vivado_project/foundry_pynq.runs/impl_1/foundry_system_wrapper.bit systolic_array.bit
cp vivado_project/foundry_pynq.gen/sources_1/bd/foundry_system/hw_handoff/foundry_system.hwh systolic_array.hwh
```

PYNQ needs both the `.bit` and matching `.hwh` file in the same directory.

6. Copy files to the PYNQ board:

```bash
scp systolic_array.bit systolic_array.hwh python/*.py xilinx@192.168.2.99:/home/xilinx/foundry_pynq/
```

7. Connect to the PYNQ board. Default USB Ethernet IP is commonly `192.168.2.99`; default username/password are `xilinx`/`xilinx`.

```bash
ssh xilinx@192.168.2.99
```

8. Install dependencies on PYNQ:

```bash
python3 -m pip install --user pynq numpy
```

Most PYNQ images already include both packages.

9. Run the benchmark on the PYNQ board:

```bash
cd /home/xilinx/foundry_pynq
python3 benchmark.py --bitfile systolic_array.bit --runs 100
```

The normal PYNQ `Overlay` API runs on the board. To start it from a laptop without manually opening SSH, use one command:

```bash
python3 python/benchmark.py --bitfile systolic_array.bit --runs 100
```

If `pynq` is not installed locally, `benchmark.py` falls back to SSH orchestration: it copies the bitstream, `.hwh`, and Python files to `xilinx@192.168.2.99:/home/xilinx/foundry_pynq`, then runs the benchmark on the ARM Cortex-A9 and streams the output back to your terminal. Use `--remote-host`, `--remote-user`, or `--remote-dir` if your board differs.

10. Expected successful output:

```text
Accelerator loaded successfully

| Metric                  | ARM Cortex-A9  | FPGA Fabric    |
|-------------------------|----------------|----------------|
| Mean latency (ms)       |           0.08 |           0.35 |
| Std dev (ms)            |           0.01 |           0.04 |
| Throughput (matmul/s)   |          12500 |           2857 |
| Hardware cycles         | N/A            |             67 |
| Cycle-based latency(ms) | N/A            |     0.00 @ 100MHz |
| Speedup                 |          1.00x |        119.40x |
| Result correct          | baseline       |            YES |
| Max absolute error      |              0 |              0 |
```

Exact numbers depend on clocking, DMA integration, CPU load, and PYNQ image version.

## Section 5: UNDERSTANDING THE OUTPUT

`Mean latency (ms)` for ARM is the average numpy INT32 matmul time on the Cortex-A9. `Mean latency (ms)` for FPGA is Python wall-clock time around the FPGA call, including DMA setup and polling.

`Std dev (ms)` shows run-to-run variation. High FPGA standard deviation usually means Linux scheduling, DMA contention, or cache maintenance overhead is dominating.

`Throughput (matmul/s)` is `1000 / mean_latency_ms`.

`Hardware cycles` is the count reported by the RTL cycle counter. It starts when the start register is written and stops when done asserts.

`Cycle-based latency(ms)` converts hardware cycles to time using the fabric clock. At 100 MHz, one cycle is 10 ns, so 100 cycles is 0.001 ms.

FPGA wall-clock time might be slower than ARM for a tiny 16x16 matrix because DMA setup overhead can exceed compute time. Cycle-based latency is the fair comparison for the accelerator core because it removes Python and DMA software overhead.

`Speedup` is ARM mean latency divided by FPGA cycle-based latency. Good hardware speedup with poor wall-clock speedup means the core is fast but the host/data-movement path needs batching.

## Section 6: COMMON ERRORS AND FIXES

`Bitstream not found`: Make sure `systolic_array.bit` exists in the current directory or pass an absolute path to `--bitfile`.

`HWH metadata not found`: Copy `systolic_array.hwh` next to `systolic_array.bit`. PYNQ uses the `.hwh` to discover IP names and register maps.

`DMA timeout`: Confirm both DMA engines are present in the Vivado block design and named consistently with `axi_dma_a_0` and `axi_dma_b_0`, or update `python/utils.py`.

`AXI handshake not completing`: Check that stream `tready` is high in `LOADING`, that both A and B streams send 16 beats, and that `s_axi_aresetn` is connected to a valid active-low reset.

`Wrong matrix dimensions`: This design is hardcoded for 16x16. Use `prepare_matrices(16)` and do not pass arbitrary N until the RTL parameters are changed.

`Cycle count reads zero`: Make sure CONTROL bit 0 is written after reset, the status done bit becomes 1, and the AXI-Lite address map in PYNQ matches the generated Vivado address map.

`Result verification fails`: Check signedness first. Inputs must be `np.int8`, expected output must be `np.int32`, and Verilog PE multiplication must remain signed.

`SSH connection refused`: Confirm the board is powered, the PYNQ image booted, Ethernet/USB networking is connected, and the board responds to `ping 192.168.2.99`.

`Vivado synthesis errors`: Run `update_compile_order`, confirm `pe.v` is included before the generated core during compilation, and use Verilog mode rather than SystemVerilog-only syntax.

`PYNQ cannot find the accelerator IP`: Open the `.hwh` file and check the instance name. Add that name to `_find_ip()` in `python/utils.py`.

## Section 7: HOW TO MODIFY

To change array size from 16x16 to 32x32, replace hardcoded `16` dimensions in `pe` grid generation, flattened bus widths, input skew delays, load counters, result stream beat count, and Python matrix allocation. The output stream becomes 1024 INT32 values, or 256 beats at 128 bits per beat.

To change data width from INT8 to INT4, change PE input widths from 8 to 4, product width from 16 to 8, DMA packing from 16 values per 128-bit beat to 32 values per beat, and Python packing/unpacking helpers. Keep INT32 accumulation unless you have a proven narrower accumulator bound.

To add a new layer type such as softmax, do not place it inside this matrix multiply datapath first. Add a separate RTL IP or a Python post-processing stage, benchmark it independently, then decide whether it needs hardware acceleration.

To connect real transformer weights from a Python simulator, quantize weights to signed INT8, tile larger matrices into 16x16 blocks, call the accelerator per tile, and accumulate partial sums in INT32. Make sure quantization scales are stored so outputs can be dequantized or passed to the next quantized layer.

## Section 8: BENCHMARK INTERPRETATION GUIDE

For a 16x16 INT8 matmul, a healthy core-only compute wavefront should be roughly 46 useful MAC cycles plus several control/load/drain cycles. With this wrapper, expected hardware cycle count is usually around 60 to 100 cycles depending on how the DMA streams are scheduled.

Good cycle-based speedup is usually 20x or higher for this tiny workload. A speedup below 5x suggests the array is not receiving a correct wavefront, the clock is much lower than expected, or the cycle counter includes too much software-controlled idle time. A result below 1x means something is wrong for cycle-based comparison.

Read the cycle breakdown as: load cycles receive A and B, compute cycles fill and drain the systolic wavefront, and output cycles are normally outside the done counter unless you modify the state machine. Wall-clock timing includes all of those plus Python and DMA overhead.

Red flags include hardware cycles equal to zero, done never asserting, max absolute error nonzero, all-zero result matrices, cycle counts changing wildly between runs, FPGA wall-clock latency above several milliseconds for one 16x16 multiply, or a missing second DMA send channel for matrix B.
