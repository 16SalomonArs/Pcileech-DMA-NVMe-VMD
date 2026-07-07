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
`define NVME_DMA_TAG              8'h75
`define NVME_CTRL_SERIAL_DW0      ascii4("S","6","P","Y")
`define NVME_CTRL_SERIAL_DW1      ascii4("N","J","0","T")
`define NVME_CTRL_SERIAL_DW2      ascii4("1","2","3","4")
`define NVME_CTRL_SERIAL_DW3      ascii4("5","6","X"," ")
`define NVME_CTRL_SERIAL_DW4      ascii4(" "," "," "," ")
`define NVME_CTRL_MODEL_DW0       ascii4("S","a","m","s")
`define NVME_CTRL_MODEL_DW1       ascii4("u","n","g"," ")
`define NVME_CTRL_MODEL_DW2       ascii4("S","S","D"," ")
`define NVME_CTRL_MODEL_DW3       ascii4("9","8","0"," ")
`define NVME_CTRL_MODEL_DW4       ascii4("P","R","O"," ")
`define NVME_CTRL_MODEL_DW5       ascii4(" "," "," "," ")
`define NVME_CTRL_MODEL_DW6       ascii4(" "," "," "," ")
`define NVME_CTRL_MODEL_DW7       ascii4(" "," "," "," ")
`define NVME_CTRL_MODEL_DW8       ascii4(" "," "," "," ")
`define NVME_CTRL_MODEL_DW9       ascii4(" "," "," "," ")
`define NVME_CTRL_FW_DW0          ascii4("5","B","2","Q")
`define NVME_CTRL_FW_DW1          ascii4("G","X","A","7")
`define NVME_SMART_INIT_POH       32'd41
`define NVME_SMART_INIT_POWER_CYCLES 32'd17
`define NVME_SMART_INIT_UNSAFE_SHUTDOWNS 64'd0
`define NVME_SMART_SPARE          8'd100
`define NVME_SMART_SPARE_THRESH   8'd10
`define NVME_SMART_PERCENT_USED   8'd0
`define NVME_WARNING_TEMP_K       16'd343
`define NVME_CRITICAL_TEMP_K      16'd358
`define NVME_POWER_STATE_MAX      5'd0

`ifdef NVME_PROFILE_75T
    `define NVME_PROFILE_NAME        "CaptainDMA 75T"
    `define NVME_BACKING_SLOT_BITS  1
    `define NVME_PRP_LIST_BITS      2
    `define NVME_MDTS               8'd2
    `define NVME_MAX_XFER_DW        20'd4096
    `define NVME_DMA_TIMEOUT_CLKS   20'd262143
    `define NVME_CLK_HZ             64'd125000000
`elsif NVME_PROFILE_ZDMA_100T
    `define NVME_PROFILE_NAME        "ZDMA 100T x4"
    `define NVME_BACKING_SLOT_BITS  7
    `define NVME_PRP_LIST_BITS      6
    `define NVME_MDTS               8'd5
    `define NVME_MAX_XFER_DW        20'd32768
    `define NVME_DMA_TIMEOUT_CLKS   20'd524287
    `define NVME_CLK_HZ             64'd125000000
`elsif NVME_PROFILE_100T
    `define NVME_PROFILE_NAME        "CaptainDMA 100T"
    `define NVME_BACKING_SLOT_BITS  7
    `define NVME_PRP_LIST_BITS      6
    `define NVME_MDTS               8'd5
    `define NVME_MAX_XFER_DW        20'd32768
    `define NVME_DMA_TIMEOUT_CLKS   20'd524287
    `define NVME_CLK_HZ             64'd125000000
`else
    `define NVME_PROFILE_NAME        "CaptainDMA 100T"
    `define NVME_BACKING_SLOT_BITS  7
    `define NVME_PRP_LIST_BITS      6
    `define NVME_MDTS               8'd5
    `define NVME_MAX_XFER_DW        20'd32768
    `define NVME_DMA_TIMEOUT_CLKS   20'd524287
    `define NVME_CLK_HZ             64'd125000000
`endif

`endif
