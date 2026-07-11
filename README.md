# Pcileech-DMA-NVMe-VMD

## Implemented

- Board status: CaptainDMA 75T and CaptainDMA 100T are the maintained targets. ZDMA 100T is still pending update and validation.
- Handles the normal NVMe driver path: controller enable/disable, admin queue setup, I/O queue setup, doorbells, and reset cleanup.
- Keeps written sectors in a volatile FPGA-side cache, so read-after-write works until the FPGA is reset or power-cycled.
- Handles small I/O, larger transfers, 4K page crossings, PRP1/PRP2, and PRP list transfers.
- Keeps PCIe identity, Identify Controller, and Identify Namespace fields aligned with the shipped Samsung-style profile.
- Reports SMART / Health data with temperature, read/write counters, command counters, error counters, and unsafe shutdown count.
- Uses FPGA XADC temperature input with a light workload-based offset.
- Implements Error Log, Supported Log Pages, and Firmware Slot Info.
- Implements Flush, Format, Write Zeroes, and DSM/TRIM for normal OS and tool testing.
- Supports MSI and MSI-X interrupts, including table, PBA, function mask, and vector mask behavior.
- Backing storage is volatile FPGA cache, not persistent NAND.

## Requirements

- Intel CPU, 11th generation or newer, in the host where the DMA card is installed.
- Intel VMD (Virtual RAID on CPU) enabled in BIOS for the physical PCIe port or M.2 adapter path used by the DMA card.
- Matching Intel RST/VMD drivers installed on Windows.
- A clean Windows install may be required for correct driver initialization and device recognition.

## VMD port selection

- Map the physical PCIe port or M.2 adapter path that contains the DMA board. VMD ownership is selected by the host root port, not by changing the endpoint class.
- Keep the Windows boot NVMe drive in the same VMD or native mode that was used when Windows was installed. Moving the boot drive between those modes can cause `INACCESSIBLE_BOOT_DEVICE` because its storage-controller path changes.
- Do not toggle an unknown root-port mapping to find the DMA board. Use the motherboard slot map or compare the PCI bus/device/function path with the board removed and installed.
- If Windows stops booting after a mapping change, restore the previous boot-drive mapping before changing firmware or reinstalling drivers.
