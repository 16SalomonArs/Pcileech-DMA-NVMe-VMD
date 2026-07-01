PCILeech NVMe Disk Firmware Build
=================
Notes for generating and building the maintained NVMe board profiles. For the feature list and host requirements, see [README](README.md).

Building:
=================
1) Install Xilinx Vivado WebPACK 2023.2 or newer.
2) Open Vivado Tcl Shell command prompt.
3) Change into the cloned or unpacked source directory. Use forward slashes in the path when running from Tcl.
4) Run the board-specific generate script, for example `source vivado_generate_project_captain_75T.tcl -notrace`.
5) Run the matching board-specific build script, for example `source vivado_build_captain_75T.tcl -notrace`.
6) The build script copies the `.bin` output and writes board-specific utilization and timing reports in the repository root.

Build time depends heavily on the machine and Vivado version. If Vivado fails in a long path, move the tree to a short path such as `C:\Temp\Pcileech-DMA-NVMe-VMD` and run the scripts again.

Maintained project entrypoints are CaptainDMA 75T, CaptainDMA 100T, and ZDMA 100T only. Older Enigma/Immortal generation scripts were removed so the default 100T profile cannot be selected by accident.

Board status:

| Board | Status |
| --- | --- |
| CaptainDMA 75T | Build verified with Vivado 2023.2 |
| CaptainDMA 100T | Build verified with Vivado 2023.2 |
| ZDMA 100T | Incomplete; pending timing and bitstream refresh fixes |

The default PCIe profile is Samsung 980 PRO style: `144D:A80A`, subsystem `144D:A801`, class code `010802`, revision `02`. For device ID and BAR changes, use the notes below.

Host VMD placement:
=================
The endpoint is an NVMe device, not an Intel VMD controller. Intel VMD ownership is selected by the host BIOS for a specific root port or port group. If Windows loads the board as a working NVMe controller while VMD is enabled, but outside the VMD controller tree, the board is not under the VMD-remapped port path. If Windows lists it as a SCSI or other storage controller with no NVMe driver, the active bitstream was built with the wrong PCIe IP class code. Keep the endpoint class as `010802`; use a VMD-mapped slot or adapter path for VMD ownership.

Customizing PCIe device type, vendor ID and product ID:
=================
Many device type / vendor / product combinations can stop a host from booting or make the PCIe bus unstable. If that happens, power down and use a different profile.

Changing VID/DID alone does not make a board blend in. PCIe capabilities, BAR layout, MSI/MSI-X behavior, and the NVMe register path must stay consistent with the selected profile.

* Generate the initial project as outlined in points 1-4 above.
* Open the generated project in Vivado.
* The maintained board profiles keep the PCIe identity in the board XCI files and the NVMe profile header. Do not remove and recreate `pcie_7x_0` from the Vivado GUI; doing that resets the PCIe core back to a stock Artix-7 endpoint.
* BAR0 is a 1 MiB memory BAR. The NVMe register block, MSI-X table at `0x3000`, and PBA at `0x3800` are decoded in the low BAR range. BAR1-BAR5 are intentionally disabled in the shipped profiles.
* If you change VID/DID/class/BAR settings, keep the XCI files, generated PCIe wrapper, and `src/nvme_board_profile.svh` in sync before building.


#### Device Serial Number (DSN):

The device serial number can be changed in `src/pcileech_pcie_cfg_a7.sv`:
```verilog
rw[127:64]  <= 64'h0000000101000A35;    // cfg_dsn
```


#### Configuration Space:

The shadow configuration space is enabled by default in `src/pcileech_fifo.sv`. The maintained configuration-space images live in the active board directory: `ip_captaindma_75t`, `ip_captaindma_100t`, or `ip_zdma_100t`. The Xilinx PCIe core still owns part of configuration space and may override some user values.

The expected setting is:
```verilog
rw[203]     <= 1'b0;                        //       CFGTLP ZERO DATA (0 = CUSTOM CONFIGURATION SPACE ENABLED)
```

PCILeech itself does not read back the shadow config image. On Linux, check the host-visible config space with `lspci`. With the default `144D:A80A` profile:

Linux lspci command line: `lspci -d 144d:a80a -xxxx`.



#### BAR PIO Memory Regions:

Custom BAR PIO regions can be added if a different profile needs them.

By default there is one BAR, BAR0, configured as a 1 MiB memory window. The implemented NVMe register/MSI-X area lives in the low `0x4000` bytes of that BAR. The larger BAR size is intentional because current Vivado PCIe 7x releases no longer accept the old small BAR setting in the GUI.

For custom BAR logic, edit `src/pcileech_tlps128_bar_controller.sv`.
