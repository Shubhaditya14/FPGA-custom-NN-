"""Transformer-style inference demo using the Foundry systolic accelerator."""

from __future__ import print_function

import argparse

import numpy as np

from benchmark import load_accelerator, prepare_matrices, run_fpga_inference


def run_layer(overlay, name, activation, weight, buffers):
    """Run one simulated transformer layer matrix multiply on the FPGA."""
    result, cycles = run_fpga_inference(overlay, activation, weight, buffers)
    print("%-18s cycles: %d" % (name, cycles))
    return result.astype(np.int8), int(cycles)


def run_demo(bitfile_path, clock_mhz=100.0):
    """Run QKV, attention, and MLP style matrix multiplies and print totals."""
    overlay = load_accelerator(bitfile_path)
    activation, _, input_a, input_b, output = prepare_matrices(16)
    buffers = (input_a, input_b, output)
    rng = np.random.default_rng()

    layers = [
        ("Q projection", rng.integers(-4, 4, size=(16, 16), dtype=np.int8)),
        ("K projection", rng.integers(-4, 4, size=(16, 16), dtype=np.int8)),
        ("V projection", rng.integers(-4, 4, size=(16, 16), dtype=np.int8)),
        ("Attention score", rng.integers(-4, 4, size=(16, 16), dtype=np.int8)),
        ("MLP up", rng.integers(-4, 4, size=(16, 16), dtype=np.int8)),
        ("MLP down", rng.integers(-4, 4, size=(16, 16), dtype=np.int8)),
    ]

    total_cycles = 0
    per_layer = []
    x = activation
    for name, weight in layers:
        x, cycles = run_layer(overlay, name, x, weight, buffers)
        total_cycles += cycles
        per_layer.append((name, cycles))

    bottleneck_name, bottleneck_cycles = max(per_layer, key=lambda item: item[1])
    latency_ms = float(total_cycles) / (float(clock_mhz) * 1000.0)
    print("")
    print("Total inference cycles: %d" % total_cycles)
    print("Estimated latency: %.3f ms @ %.1f MHz" % (latency_ms, clock_mhz))
    print("Bottleneck layer: %s (%d cycles)" % (bottleneck_name, bottleneck_cycles))


def main():
    """Parse arguments and run the transformer-style inference demo."""
    parser = argparse.ArgumentParser(description="Foundry transformer-style inference demo")
    parser.add_argument("--bitfile", required=True, help="Path to systolic_array.bit")
    parser.add_argument("--clock-mhz", type=float, default=100.0, help="FPGA fabric clock frequency")
    args = parser.parse_args()
    run_demo(args.bitfile, args.clock_mhz)


if __name__ == "__main__":
    main()
