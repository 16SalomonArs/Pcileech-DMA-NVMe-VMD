`ifndef _nvme_board_profile_svh_
`define _nvme_board_profile_svh_

`define NVME_PCI_VENDOR_ID        16'h144d
`define NVME_PCI_DEVICE_ID        16'ha80a
`define NVME_PCI_SUBSYS_VENDOR_ID 16'h144d
`define NVME_PCI_SUBSYS_ID        16'ha801
`define NVME_PCI_REVISION_ID      8'h02
`define NVME_PCI_CLASS_CODE       24'h010802
`define NVME_MSIX_TABLE_OFFSET    14'h3000
`define NVME_MSIX_PBA_OFFSET      14'h3800
`define NVME_BAR0_SIZE_BYTES      32'h00100000
`define NVME_BAR0_ACTIVE_BYTES    32'h00004000
`define NVME_BAR0_ACTIVE_LIMIT    20'h04000
`define NVME_IEEE_OUI_DWORD       32'h00253800

`ifdef NVME_PROFILE_75T
    `define NVME_PROFILE_NAME        "CaptainDMA 75T"
    `define NVME_BACKING_SLOT_BITS  4
    `define NVME_PRP_LIST_BITS      3
    `define NVME_MDTS               8'd2
    `define NVME_MAX_XFER_DW        20'd4096
    `define NVME_DMA_TIMEOUT_CLKS   20'd262143
    `define NVME_CLK_HZ             64'd125000000
`elsif NVME_PROFILE_ZDMA_100T
    `define NVME_PROFILE_NAME        "ZDMA 100T x4"
    `define NVME_BACKING_SLOT_BITS  9
    `define NVME_PRP_LIST_BITS      6
    `define NVME_MDTS               8'd5
    `define NVME_MAX_XFER_DW        20'd32768
    `define NVME_DMA_TIMEOUT_CLKS   20'd524287
    `define NVME_CLK_HZ             64'd125000000
`elsif NVME_PROFILE_100T
    `define NVME_PROFILE_NAME        "CaptainDMA 100T"
    `define NVME_BACKING_SLOT_BITS  9
    `define NVME_PRP_LIST_BITS      6
    `define NVME_MDTS               8'd5
    `define NVME_MAX_XFER_DW        20'd32768
    `define NVME_DMA_TIMEOUT_CLKS   20'd524287
    `define NVME_CLK_HZ             64'd125000000
`else
    `define NVME_PROFILE_NAME        "CaptainDMA 100T"
    `define NVME_BACKING_SLOT_BITS  9
    `define NVME_PRP_LIST_BITS      6
    `define NVME_MDTS               8'd5
    `define NVME_MAX_XFER_DW        20'd32768
    `define NVME_DMA_TIMEOUT_CLKS   20'd524287
    `define NVME_CLK_HZ             64'd125000000
`endif

`endif
