# Pcileech-DMA-NVMe-VMD

## Implemented

- Handles the normal NVMe driver path: controller enable/disable, admin queue setup, I/O queue setup, doorbells, and reset cleanup.
- Keeps written sectors in a volatile FPGA-side cache, so read-after-write works until the FPGA is reset or power-cycled.
- Handles small I/O, larger transfers, 4K page crossings, PRP1/PRP2, and PRP list transfers.
- Keeps PCIe identity, Identify Controller, and Identify Namespace fields aligned with the shipped Samsung-style profile.
- Reports SMART / Health data with temperature, read/write counters, command counters, error counters, and unsafe shutdown count.
- Uses FPGA XADC temperature input with a light workload-based offset.
- Implements Error Log, Supported Log Pages, Firmware Slot Info, and vendor log page `C0h`.
- Implements Flush, Format, Write Zeroes, and DSM/TRIM for normal OS and tool testing.
- Supports MSI and MSI-X interrupts, including table, PBA, function mask, and vector mask behavior.
- Backing storage is volatile FPGA cache, not persistent NAND.

## Requirements

- Intel CPU, 11th generation or newer, in the host where the DMA card is installed.
- Intel VMD (Virtual RAID on CPU) enabled in BIOS.
- Matching Intel RST/VMD drivers installed on Windows.
- A clean Windows install may be required for correct driver initialization and device recognition.
