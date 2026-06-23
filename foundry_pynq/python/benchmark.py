"""Benchmark Foundry's 16x16 INT8 systolic array against ARM numpy matmul."""

from __future__ import print_function

import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np

try:
    from pynq import Overlay
except ImportError:
    Overlay = None

from utils import (
    CONTROL_OFFSET,
    STATUS_OFFSET,
    allocate_buffers,
    dma_format_to_int32,
    get_dma,
    int8_to_dma_format,
    read_cycle_count,
    read_register,
    write_register,
)


def load_accelerator(bitfile_path):
    """Load the FPGA bitstream and return the PYNQ Overlay object."""
    if Overlay is None:
        raise RuntimeError("pynq.Overlay is only available on the PYNQ board")
    overlay = Overlay(bitfile_path)
    overlay.download()
    print("Accelerator loaded successfully")
    return overlay


def prepare_matrices(N=16):
    """Generate random INT8 matrices and allocate contiguous DMA buffers."""
    rng = np.random.default_rng()
    A = rng.integers(-8, 8, size=(N, N), dtype=np.int8)
    B = rng.integers(-8, 8, size=(N, N), dtype=np.int8)
    input_buffer_a, input_buffer_b, output_buffer = allocate_buffers(N)
    return A, B, input_buffer_a, input_buffer_b, output_buffer


def run_fpga_inference(overlay, A, B, buffers):
    """Run one FPGA matrix multiply and return the INT32 result and cycles."""
    input_buffer_a, input_buffer_b, output_buffer = buffers
    dma = get_dma(overlay)
    dma_b = getattr(overlay, "axi_dma_b_0", None)
    if dma_b is None:
        raise RuntimeError("Overlay must provide a second DMA send channel for matrix B")

    np.copyto(input_buffer_a, int8_to_dma_format(A))
    np.copyto(input_buffer_b, int8_to_dma_format(B))
    output_buffer[:] = 0

    input_buffer_a.flush()
    input_buffer_b.flush()
    output_buffer.flush()

    write_register(overlay, CONTROL_OFFSET, 0x2)
    write_register(overlay, CONTROL_OFFSET, 0x1)

    dma.recvchannel.transfer(output_buffer)
    dma.sendchannel.transfer(input_buffer_a)
    dma_b.sendchannel.transfer(input_buffer_b)
    dma.sendchannel.wait()
    dma_b.sendchannel.wait()

    while (read_register(overlay, STATUS_OFFSET) & 0x1) == 0:
        pass

    dma.recvchannel.wait()
    output_buffer.invalidate()
    result = dma_format_to_int32(output_buffer, A.shape[0])
    cycle_count = read_cycle_count(overlay)
    return result, cycle_count


def run_arm_baseline(A, B, n_runs=1000):
    """Run numpy INT32 matmul repeatedly on ARM and return timing statistics."""
    latencies = []
    A32 = A.astype(np.int32)
    B32 = B.astype(np.int32)
    for _ in range(n_runs):
        t0 = time.perf_counter()
        _ = A32 @ B32
        t1 = time.perf_counter()
        latencies.append((t1 - t0) * 1000.0)
    mean_ms = float(np.mean(latencies))
    std_ms = float(np.std(latencies))
    throughput = 1000.0 / mean_ms if mean_ms > 0.0 else 0.0
    return {"mean_ms": mean_ms, "std_ms": std_ms, "throughput": throughput}


def benchmark_fpga(overlay, A, B, buffers, n_runs=100):
    """Run the FPGA accelerator repeatedly and return wall-clock/cycle stats."""
    wall_ms = []
    cycles = []
    last_result = None
    for _ in range(n_runs):
        t0 = time.perf_counter()
        last_result, cycle_count = run_fpga_inference(overlay, A, B, buffers)
        t1 = time.perf_counter()
        wall_ms.append((t1 - t0) * 1000.0)
        cycles.append(cycle_count)
    mean_ms = float(np.mean(wall_ms))
    std_ms = float(np.std(wall_ms))
    throughput = 1000.0 / mean_ms if mean_ms > 0.0 else 0.0
    return {
        "mean_ms": mean_ms,
        "std_ms": std_ms,
        "throughput": throughput,
        "mean_cycles": float(np.mean(cycles)),
        "cycles": [int(c) for c in cycles],
        "last_result": last_result,
    }


def verify_correctness(result_hw, A, B):
    """Compare the FPGA result against INT32 numpy matmul."""
    expected = A.astype(np.int32) @ B.astype(np.int32)
    diff = result_hw.astype(np.int32) - expected
    max_abs_error = int(np.max(np.abs(diff)))
    return bool(np.array_equal(result_hw, expected)), max_abs_error


def print_results(arm_stats, fpga_stats, cycle_count, correct, max_error, clock_mhz=100):
    """Print a comparison table for ARM and FPGA benchmark results."""
    cycle_latency_ms = float(cycle_count) / (float(clock_mhz) * 1000.0)
    speedup = arm_stats["mean_ms"] / cycle_latency_ms if cycle_latency_ms > 0.0 else 0.0
    print("")
    print("| Metric                  | ARM Cortex-A9  | FPGA Fabric    |")
    print("|-------------------------|----------------|----------------|")
    print("| Mean latency (ms)       | %14.2f | %14.2f |" % (arm_stats["mean_ms"], fpga_stats["mean_ms"]))
    print("| Std dev (ms)            | %14.2f | %14.2f |" % (arm_stats["std_ms"], fpga_stats["std_ms"]))
    print("| Throughput (matmul/s)   | %14.0f | %14.0f |" % (arm_stats["throughput"], fpga_stats["throughput"]))
    print("| Hardware cycles         | N/A            | %14d |" % int(cycle_count))
    print("| Cycle-based latency(ms) | N/A            | %8.2f @ %dMHz |" % (cycle_latency_ms, clock_mhz))
    print("| Speedup                 |          1.00x | %13.2fx |" % speedup)
    print("| Result correct          | baseline       | %14s |" % ("YES" if correct else "NO"))
    print("| Max absolute error      |              0 | %14d |" % int(max_error))


def run_remote_benchmark(args):
    """Run this benchmark on a networked PYNQ board through ssh/scp."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    bitfile = os.path.abspath(args.bitfile)
    hwh_file = os.path.splitext(bitfile)[0] + ".hwh"
    target = "%s@%s" % (args.remote_user, args.remote_host)
    remote_dir = args.remote_dir.rstrip("/")
    remote_bitfile = os.path.join(remote_dir, os.path.basename(bitfile))

    files = [
        bitfile,
        os.path.join(script_dir, "benchmark.py"),
        os.path.join(script_dir, "utils.py"),
        os.path.join(script_dir, "inference_demo.py"),
    ]
    if os.path.exists(hwh_file):
        files.append(hwh_file)

    ssh_mkdir = ["ssh", target, "mkdir -p %s/results" % remote_dir]
    scp_cmd = ["scp"] + files + ["%s:%s/" % (target, remote_dir)]
    remote_cmd = [
        "ssh",
        target,
        "cd %s && python3 benchmark.py --bitfile %s --runs %d --arm-runs %d --clock-mhz %.6f --no-remote"
        % (remote_dir, remote_bitfile, args.runs, args.arm_runs, args.clock_mhz),
    ]

    print("pynq is not installed locally; running benchmark on %s over SSH" % target)
    subprocess.check_call(ssh_mkdir)
    subprocess.check_call(scp_cmd)
    return subprocess.call(remote_cmd)


def main():
    """Parse command-line arguments and run the full benchmark pipeline."""
    parser = argparse.ArgumentParser(description="Benchmark Foundry systolic array on PYNQ-Z2")
    parser.add_argument("--bitfile", required=True, help="Path to systolic_array.bit")
    parser.add_argument("--runs", type=int, default=100, help="Number of FPGA benchmark runs")
    parser.add_argument("--arm-runs", type=int, default=1000, help="Number of ARM baseline runs")
    parser.add_argument("--clock-mhz", type=float, default=100.0, help="FPGA fabric clock frequency")
    parser.add_argument("--remote-host", default="192.168.2.99", help="PYNQ board IP for laptop-launched remote mode")
    parser.add_argument("--remote-user", default="xilinx", help="PYNQ SSH username for laptop-launched remote mode")
    parser.add_argument("--remote-dir", default="/home/xilinx/foundry_pynq", help="Remote working directory on the PYNQ board")
    parser.add_argument("--no-remote", action="store_true", help="Disable laptop fallback and require local PYNQ APIs")
    args = parser.parse_args()

    if Overlay is None and not args.no_remote:
        sys.exit(run_remote_benchmark(args))

    overlay = load_accelerator(args.bitfile)
    A, B, input_a, input_b, output = prepare_matrices(16)
    buffers = (input_a, input_b, output)

    arm_stats = run_arm_baseline(A, B, args.arm_runs)
    fpga_stats = benchmark_fpga(overlay, A, B, buffers, args.runs)
    correct, max_error = verify_correctness(fpga_stats["last_result"], A, B)
    cycle_count = int(round(fpga_stats["mean_cycles"]))

    print_results(arm_stats, fpga_stats, cycle_count, correct, max_error, args.clock_mhz)

    os.makedirs("results", exist_ok=True)
    payload = {
        "arm": arm_stats,
        "fpga": {k: v for k, v in fpga_stats.items() if k != "last_result"},
        "correct": correct,
        "max_absolute_error": max_error,
        "clock_mhz": args.clock_mhz,
    }
    with open("results/benchmark_results.json", "w") as f:
        json.dump(payload, f, indent=2)


if __name__ == "__main__":
    main()
