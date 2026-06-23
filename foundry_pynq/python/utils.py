"""Utility helpers for the Foundry PYNQ systolic-array benchmark."""

from __future__ import print_function

import numpy as np

try:
    from pynq import allocate
except ImportError:
    allocate = None


CONTROL_OFFSET = 0x00
STATUS_OFFSET = 0x04
CYCLE_COUNT_LO_OFFSET = 0x08
CYCLE_COUNT_HI_OFFSET = 0x0C
MATRIX_SIZE_OFFSET = 0x10


def _find_ip(overlay):
    """Return the MMIO-capable systolic_top IP object from a PYNQ overlay."""
    preferred_names = (
        "systolic_top_0",
        "foundry_systolic_top_0",
        "systolic_array_0",
    )
    for name in preferred_names:
        if hasattr(overlay, name):
            return getattr(overlay, name)
    for name in overlay.ip_dict:
        if "systolic" in name.lower():
            return getattr(overlay, name)
    raise RuntimeError("Could not find systolic_top IP in overlay.ip_dict")


def _find_dma(overlay):
    """Return the AXI DMA IP object from a PYNQ overlay."""
    preferred_names = ("axi_dma_0", "dma", "axi_dma")
    for name in preferred_names:
        if hasattr(overlay, name):
            return getattr(overlay, name)
    for name in overlay.ip_dict:
        if "dma" in name.lower():
            return getattr(overlay, name)
    raise RuntimeError("Could not find AXI DMA IP in overlay.ip_dict")


def read_register(overlay, offset):
    """Read a 32-bit register from the systolic accelerator AXI-Lite space."""
    ip = _find_ip(overlay)
    return int(ip.read(offset)) & 0xFFFFFFFF


def write_register(overlay, offset, value):
    """Write a 32-bit register in the systolic accelerator AXI-Lite space."""
    ip = _find_ip(overlay)
    ip.write(offset, int(value) & 0xFFFFFFFF)


def read_cycle_count(overlay):
    """Read the 64-bit hardware cycle counter as an integer."""
    lo = read_register(overlay, CYCLE_COUNT_LO_OFFSET)
    hi = read_register(overlay, CYCLE_COUNT_HI_OFFSET)
    return (hi << 32) | lo


def allocate_buffers(N):
    """Allocate physically contiguous PYNQ DMA buffers for NxN INT8 matrices."""
    if allocate is None:
        raise RuntimeError("pynq.allocate is only available on the PYNQ board")
    input_buffer_a = allocate(shape=(N, N), dtype=np.int8)
    input_buffer_b = allocate(shape=(N, N), dtype=np.int8)
    output_buffer = allocate(shape=(N, N), dtype=np.int32)
    return input_buffer_a, input_buffer_b, output_buffer


def int8_to_dma_format(matrix):
    """Convert an INT8 matrix into the row-major format consumed by the DMA."""
    arr = np.asarray(matrix, dtype=np.int8)
    if arr.ndim != 2 or arr.shape[0] != arr.shape[1]:
        raise ValueError("matrix must be square and two-dimensional")
    return np.ascontiguousarray(arr)


def dma_format_to_int32(raw_output, N):
    """Convert the DMA result buffer into an NxN INT32 numpy matrix."""
    arr = np.asarray(raw_output, dtype=np.int32)
    if arr.size < N * N:
        raise ValueError("output buffer is smaller than expected result matrix")
    return np.array(arr.reshape((N, N)), dtype=np.int32)


def get_dma(overlay):
    """Return the DMA object used by benchmark.py and inference_demo.py."""
    return _find_dma(overlay)
