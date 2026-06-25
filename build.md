PCILeech NVMe Disk Firmware Build
=================
This readme details some customizations that are possible to perform prior to building/flashing the FPGA. For general information please check out the general [README](README.md).

Building:
=================
1) Install Xilinx Vivado WebPACK 2023.2 or later.
2) Open Vivado Tcl Shell command prompt.
3) cd into the cloned or unpacked code directory (forward slash instead of backslash in path).
4) Run the board-specific generate script, for example `source vivado_generate_project_captain_75T.tcl -notrace`.
5) Run the matching board-specific build script, for example `source vivado_build_captain_75T.tcl -notrace`.
6) The build script copies the `.bin` output and writes board-specific utilization and timing reports in the repository root.

Building the project may take a very long time (~1 hour). Sometimes the build will fail if the directory path is too long. If build fails try re-run it while pcileech-fpga is placed in C:\Temp or any other place with short directory path.

Maintained project entrypoints are CaptainDMA 75T, CaptainDMA 100T, and ZDMA 100T only. Older Enigma/Immortal generation scripts were removed so the default 100T profile cannot be selected by accident.

The PCIe device is configured as a Samsung 980 PRO NVMe disk profile by default: `144D:A80A`, subsystem `144D:A801`, class code `010802`, revision `02`. For instructions on how to change the device ID and other advanced build properties, check the section below.

Customizing PCIe device type, vendor ID and product ID:
=================
Please note that many combinations of device types, vendor IDs and product IDs will make computers not boot, hang and otherwise perform badly when the PCIe device is connected. If that happens please try another combination of values.

Please also note that changing the device and vendor ID is not in itself sufficient to make the device "undetectable" by software looking for malicious DMA devices. There are, more settings that are or aren't, directly modifiable in the PCIe configuration wizard that will alter the device PCIe configuration space.

* Please first generate the initial project as outlined in points 1-4 above.
* Open the generated project in Vivado.
* The maintained board profiles keep the PCIe identity in the board XCI files and the NVMe profile header. Do not remove and recreate `pcie_7x_0` from the Vivado GUI; doing that resets the PCIe core back to a stock Artix-7 endpoint.
* BAR0 is a 1 MiB memory BAR. The NVMe register block, MSI-X table at `0x3000`, and PBA at `0x3800` are decoded in the low BAR range. BAR1-BAR5 are intentionally disabled in the shipped profiles.
* If you change VID/DID/class/BAR settings, keep the XCI files, generated PCIe wrapper, and `src/nvme_board_profile.svh` in sync before building.


#### Device Serial Number (DSN):

It may also be a good idea to modify the device serial number (DSN) by editing the line below in the file: `src/pcileech_pcie_cfg_a7.sv`
```verilog
rw[127:64]  <= 64'h0000000101000A35;    // cfg_dsn
```


#### Configuration Space:

It's possible to partly change the PCIe configuration space of the device. This is achieved by altering the value below from `1'b1` to `1'b0` in the file `src/pcileech_fifo.sv` (please see below). The maintained configuration-space images live in the active board directory: `ip_captaindma_75t`, `ip_captaindma_100t`, or `ip_zdma_100t`. Please note that the Xilinx PCIe core will in-part override user-configured values.

in `src/pcileech_fifo.sv` change:
```verilog
rw[203]     <= 1'b1;                        //       CFGTLP ZERO DATA
```
into:
```verilog
rw[203]     <= 1'b0;                        //       CFGTLP ZERO DATA (0 = CUSTOM CONFIGURATION SPACE ENABLED)
```

It's not currently possible to read the custom configuration space from within PCILeech, but on a Linux system it's possible to view it using the `lspci` command. The command line, if the vendor/device ID is the default `144D:A80A`, is:

Linux lspci command line: `lspci -d 144d:a80a -xxxx`.



#### BAR PIO Memory Regions:

It's possible to implement a custom BAR PIO memory region, commonly used by devices. Properly implemented BAR PIO memory regions may allow for more complete device emulation.

By default there is one BAR, BAR0, configured as a 1 MiB memory window. The implemented NVMe register/MSI-X area lives in the low `0x4000` bytes of that BAR. The larger BAR size is intentional because current Vivado PCIe 7x releases no longer accept the old small BAR setting in the GUI.

Secondly, edit the file: `pcileech_tlps128_bar_controller.sv` and follow the instructions in the file to implement custom BAR PIO memory regions.
