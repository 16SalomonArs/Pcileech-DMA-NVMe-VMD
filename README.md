# Pcileech-DMA-NVMe-VMD

## Implemented

- Makes a supported PCILeech FPGA board show up as a Samsung SSD 980 PRO style NVMe drive.
- Uses a Samsung-looking PCIe/NVMe profile instead of exposing the board as a plain DMA endpoint.
- Includes build profiles for CaptainDMA 75T, CaptainDMA 100T, and ZDMA 100T.
- Supports normal NVMe driver startup: controller enable/disable, queue setup, doorbells, and reset cleanup.
- Supports host read and write commands through the DMA TLP path.
- Keeps written sectors in a volatile FPGA-side cache, so read-after-write works during the same power session.
- Handles common I/O layouts used by real systems: small reads/writes, larger transfers, page crossings, PRP1/PRP2, and PRP lists.
- Reports Identify Controller / Namespace data that matches the advertised device profile.
- Reports SMART / Health data, including temperature, read/write counters, command counters, error counters, and unsafe shutdown count.
- Uses FPGA XADC temperature data with a simple workload curve instead of a fixed fake temperature.
- Supports Error Log, Supported Log Pages, Firmware Slot Info, and vendor debug log page `C0h`.
- Supports Flush, Format, Write Zeroes, and DSM/TRIM for common OS and tool testing.
- Supports MSI and MSI-X interrupts, including table, PBA, function mask, and vector mask behavior.
- Data is not persistent after FPGA reset or power loss; this is an FPGA-backed NVMe disk profile, not NAND firmware.

## Requirements

- Intel CPU, 11th generation or newer, in the host where the DMA card is installed.
- Intel VMD (Virtual RAID on CPU) enabled in BIOS.
- Matching Intel RST/VMD drivers installed on Windows.
- A clean Windows install may be required for correct driver initialization and device recognition.
