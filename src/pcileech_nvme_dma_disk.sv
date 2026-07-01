// Pcileech BAR0 NVMe disk function.
// Implements an NVMe namespace directly in the Pcileech FPGA TLP path.
// Host queue entries and payloads are moved with PCIe DMA TLPs.

`ifndef _pcileech_header_svh_
`include "pcileech_header.svh"
`endif

`include "nvme_board_profile.svh"

module pcileech_bar_impl_nvme_disk(
    input               rst,
    input               clk,
    input [15:0]        pcie_id,
    input               msix_enable,
    input               msix_function_mask,
    IfAXIS128.sink_lite tlps_in,
    IfAXIS128.source    tlps_dma_out,
    output bit          nvme_irq_req,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    localparam [31:0] NVME_CAP_LO = 32'h2001003f; // MQES=63, CQR=1, TO=0x20
    localparam [31:0] NVME_CAP_HI = 32'h00000020; // CSS.NVM supported, DSTRD=0
    localparam [31:0] NVME_VS     = 32'h00010400; // NVMe 1.4

    localparam [63:0]  PROFILE_LBAS   = 64'h0000000074706db0; // Samsung 980 PRO 1TB: 1,953,525,168 LBAs.
    localparam [127:0] PROFILE_BYTES  = 128'h0000000000000000000000e8e0db6000;
    localparam integer BACKING_SLOT_BITS = `NVME_BACKING_SLOT_BITS;
    localparam integer BACKING_INDEX_BITS = BACKING_SLOT_BITS + 7;
    localparam integer BACKING_LBAS   = 1 << BACKING_SLOT_BITS; // Volatile FPGA BRAM cache slots.
    localparam integer BACKING_DWORDS = 1 << BACKING_INDEX_BITS;
    localparam integer PRP_LIST_BITS = `NVME_PRP_LIST_BITS;
    localparam integer PRP_LIST_ENTRIES = 1 << PRP_LIST_BITS;
    localparam [7:0]   BACKING_SLOT_BITS_U8 = BACKING_SLOT_BITS;
    localparam [7:0]   PRP_LIST_BITS_U8 = PRP_LIST_BITS;
    localparam [BACKING_INDEX_BITS:0] BACKING_SLOT_COUNT = BACKING_LBAS;
    localparam [BACKING_INDEX_BITS:0] BACKING_COUNT = BACKING_DWORDS;
    localparam [BACKING_INDEX_BITS:0] BACKING_ONE = {{BACKING_INDEX_BITS{1'b0}}, 1'b1};
    localparam [63:0]  DISK_LBAS      = PROFILE_LBAS;
    localparam [7:0]   PROFILE_MDTS   = `NVME_MDTS;
    localparam [19:0]  MAX_XFER_DW    = `NVME_MAX_XFER_DW;
    localparam [19:0]  DMA_TIMEOUT_CLKS = `NVME_DMA_TIMEOUT_CLKS;
    localparam [63:0]  NVME_CLK_HZ    = `NVME_CLK_HZ;
    localparam [63:0]  NVME_SECOND_TICKS = `NVME_CLK_HZ;
    localparam [63:0]  NVME_HOUR_TICKS = `NVME_CLK_HZ * 64'd3600;
    localparam [7:0]   DMA_OUTSTANDING_LIMIT = 8'd1;
    localparam [7:0]   DMA_DWORDS_PER_TLP = 8'd1;
    localparam [7:0]   IO_QUEUE_LIMIT = 8'd1;
    localparam [7:0]   AER_PENDING_LIMIT = 8'd1;
    localparam [7:0]   DMA_TAG        = `NVME_DMA_TAG;
    localparam [13:0]  MSIX_TABLE_OFF = `NVME_MSIX_TABLE_OFFSET;
    localparam [13:0]  MSIX_PBA_OFF   = `NVME_MSIX_PBA_OFFSET;
    localparam [15:0]  NVME_RDY_DELAY_CLKS = 16'd4096;

    localparam [14:0] NVME_SC_SUCCESS       = 15'h0000;
    localparam [14:0] NVME_SC_INVALID_OPC   = 15'h0001;
    localparam [14:0] NVME_SC_INVALID_FIELD = 15'h0002;
    localparam [14:0] NVME_SC_DATA_XFER_ERR = 15'h0004;
    localparam [14:0] NVME_SC_INVALID_NS    = 15'h000b;
    localparam [14:0] NVME_SC_CMD_SEQ_ERR   = 15'h000c;
    localparam [14:0] NVME_SC_PRP_OFFSET_INVALID = 15'h0013;
    localparam [14:0] NVME_SC_LBA_RANGE     = 15'h0080;
    localparam [14:0] NVME_SC_CQ_INVALID    = 15'h0100;
    localparam [14:0] NVME_SC_INVALID_QID   = 15'h0101;
    localparam [14:0] NVME_SC_MAX_Q_SIZE    = 15'h0102;
    localparam [14:0] NVME_SC_QID_CONFLICT  = 15'h0103;
    localparam [14:0] NVME_SC_AER_LIMIT     = 15'h0105;
    localparam [14:0] NVME_SC_QUEUE_NOT_CREATED = 15'h0107;
    localparam [14:0] NVME_SC_INVALID_IRQ_VECTOR = 15'h0108;
    localparam [14:0] NVME_SC_INVALID_LOG_PAGE = 15'h0109;
    localparam [14:0] NVME_SC_INVALID_FORMAT = 15'h010a;

    localparam [7:0] ST_IDLE           = 8'd0;
    localparam [7:0] ST_FETCH_REQ      = 8'd1;
    localparam [7:0] ST_FETCH_WAIT     = 8'd2;
    localparam [7:0] ST_PROCESS        = 8'd3;
    localparam [7:0] ST_HOST_WRITE_REQ = 8'd4;
    localparam [7:0] ST_HOST_WRITE_WAIT= 8'd5;
    localparam [7:0] ST_HOST_READ_REQ  = 8'd6;
    localparam [7:0] ST_HOST_READ_WAIT = 8'd7;
    localparam [7:0] ST_CQE_REQ        = 8'd8;
    localparam [7:0] ST_CQE_WAIT       = 8'd9;
    localparam [7:0] ST_FORMAT_CLEAR   = 8'd10;
    localparam [7:0] ST_ZERO_CLEAR     = 8'd11;
    localparam [7:0] ST_DISK_READ      = 8'd12;
    localparam [7:0] ST_PRP_LIST_REQ   = 8'd13;
    localparam [7:0] ST_PRP_LIST_WAIT  = 8'd14;
    localparam [7:0] ST_IRQ_REQ        = 8'd15;
    localparam [7:0] ST_IRQ_WAIT       = 8'd16;
    localparam [7:0] ST_DSM_FETCH_REQ  = 8'd17;
    localparam [7:0] ST_DSM_FETCH_WAIT = 8'd18;
    localparam [7:0] ST_DSM_INVALIDATE = 8'd19;
    localparam [7:0] ST_HOST_WRITE_ADDR= 8'd20;
    localparam [7:0] ST_HOST_READ_ADDR = 8'd21;
    localparam [7:0] ST_DSM_FETCH_ADDR = 8'd22;
    localparam [7:0] ST_DSM_VALIDATE_0 = 8'd23;
    localparam [7:0] ST_DSM_VALIDATE_1 = 8'd24;
    localparam [7:0] ST_DSM_VALIDATE_2 = 8'd25;

    localparam [3:0] PAYLOAD_ZERO       = 4'd0;
    localparam [3:0] PAYLOAD_IDENT_CTL  = 4'd1;
    localparam [3:0] PAYLOAD_IDENT_NS   = 4'd2;
    localparam [3:0] PAYLOAD_IDENT_LST  = 4'd3;
    localparam [3:0] PAYLOAD_DISK       = 4'd4;
    localparam [3:0] PAYLOAD_SMART_LOG  = 4'd5;
    localparam [3:0] PAYLOAD_ERROR_LOG  = 4'd6;
    localparam [3:0] PAYLOAD_LOG_PAGES  = 4'd7;
`ifdef NVME_ENABLE_VENDOR_LOG
    localparam [3:0] PAYLOAD_VENDOR_LOG = 4'd8;
`endif
    localparam [3:0] PAYLOAD_FW_SLOT_LOG = 4'd9;
    localparam [7:0] LOG_PAGE_SUPPORTED = 8'h00;
    localparam [7:0] LOG_PAGE_ERROR     = 8'h01;
    localparam [7:0] LOG_PAGE_SMART     = 8'h02;
    localparam [7:0] LOG_PAGE_FW_SLOT   = 8'h03;
`ifdef NVME_ENABLE_VENDOR_LOG
    localparam [7:0] LOG_PAGE_VENDOR_C0 = 8'hc0;
    localparam [7:0] LOG_PAGE_VENDOR_C0_DW = 8'h30;
`endif
    localparam [31:0] AER_RESULT_ERROR_LOG   = 32'h00010000;
    localparam [31:0] AER_RESULT_SMART_TEMP  = 32'h00020101;
    localparam [31:0] AER_RESULT_SMART_MEDIA = 32'h00020201;

    (* ram_style = "block" *) reg [31:0] block_store [0:BACKING_DWORDS-1];
    bit        block_valid [0:BACKING_LBAS-1];
    bit [63:0] block_tag   [0:BACKING_LBAS-1];
    bit [31:0] cmd_dw [0:15];

    bit [31:0] intms;
    bit [31:0] cc;
    bit [31:0] csts;
    bit [31:0] aqa;
    bit [31:0] feat_arbitration;
    bit [31:0] feat_power_mgmt;
    bit [31:0] feat_temp_threshold;
    bit [31:0] feat_write_cache;
    bit [31:0] feat_irq_coalescing;
    bit [31:0] feat_irq_vector_cfg;
    bit [31:0] feat_async_event_cfg;
    bit [31:0] asq_lo;
    bit [31:0] asq_hi;
    bit [31:0] acq_lo;
    bit [31:0] acq_hi;

    bit [15:0] admin_sq_head;
    bit [15:0] admin_sq_tail;
    bit [15:0] admin_cq_tail;
    bit [15:0] admin_cq_head_db;
    bit        admin_cq_phase;

    bit [63:0] io_sq_base;
    bit [63:0] io_cq_base;
    bit [15:0] io_sq_size;
    bit [15:0] io_cq_size;
    bit [15:0] io_sq_head;
    bit [15:0] io_sq_tail;
    bit [15:0] io_cq_tail;
    bit [15:0] io_cq_head_db;
    bit        io_cq_phase;
    bit        io_enabled;
    bit        io_sq_ready;
    bit        io_cq_ready;
    bit        io_cq_irq_enabled;
    bit        io_cq_irq_vector;

    bit [7:0]  state;
    bit        current_qid;
    bit [15:0] fetch_idx;
    bit [63:0] fetch_base;

    bit [63:0] xfer_prp1;
    bit [63:0] xfer_prp2;
    bit [19:0] xfer_idx;
    bit [19:0] xfer_total_dw;
    bit [7:0]  xfer_after_prp_state;
    bit [3:0]  xfer_payload;
    bit [31:0] disk_rd_data;
    bit        prp_list_active;
    bit [PRP_LIST_BITS-1:0] prp_fetch_idx;
    bit [PRP_LIST_BITS-1:0] prp_fetch_last;
    bit        prp_fetch_dw;
    bit [63:0] prp_list [0:PRP_LIST_ENTRIES-1];
    bit [31:0] cqe_result;
    bit [14:0] cqe_status;
    bit [15:0] cqe_cid;
    bit        cqe_qid;
    bit [15:0] cqe_sq_head;
    bit [1:0]  cqe_idx;
    bit [BACKING_INDEX_BITS:0] clear_idx;
    bit [BACKING_INDEX_BITS:0] clear_total_dw;
    bit [63:0] msix_addr [0:1];
    bit [31:0] msix_data [0:1];
    bit [31:0] msix_vector_ctrl [0:1];
    bit [31:0] msix_pba;
    bit        irq_vector;
    bit [7:0]  thermal_load;
    bit [19:0] thermal_timer;
    bit [63:0] second_timer;
    bit [63:0] hour_timer;
    bit [31:0] power_on_hours;
    bit [31:0] power_cycle_count;
    bit        controller_seen_enable;
    bit [31:0] warning_temp_time;
    bit [31:0] critical_temp_time;
    bit [5:0]  warning_temp_seconds;
    bit [5:0]  critical_temp_seconds;
    bit [63:0] stat_data_units_read;
    bit [63:0] stat_data_units_written;
    bit [63:0] stat_host_read_cmds;
    bit [63:0] stat_host_write_cmds;
    bit [63:0] stat_flush_cmds;
    bit [63:0] stat_dataset_cmds;
    bit [63:0] stat_write_zero_cmds;
    bit [63:0] stat_format_cmds;
    bit [63:0] stat_cmds_completed;
    bit [63:0] stat_dma_mrd_tlps;
    bit [63:0] stat_dma_mwr_tlps;
    bit [63:0] stat_prp_list_fetches;
    bit [63:0] stat_queue_resets;
    bit [63:0] stat_shutdowns;
    bit [63:0] stat_unsafe_shutdowns;
    bit [63:0] stat_backend_evictions;
    bit [63:0] stat_timeout_errors;
    bit [63:0] stat_cpl_errors;
    bit [63:0] stat_transport_errors;
    bit [31:0] stat_media_errors;
    bit [31:0] stat_invalid_cmds;
    bit [31:0] stat_error_log_entries;
    bit [63:0] stat_last_error_lba;
    bit [15:0] stat_last_error_cid;
    bit [14:0] stat_last_error_status;
    bit [7:0]  stat_last_error_opcode;
    bit        stat_last_error_qid;
    bit [31:0] err_count_ring [0:7];
    bit [15:0] err_cid_ring [0:7];
    bit        err_qid_ring [0:7];
    bit [31:0] err_nsid_ring [0:7];
    bit [63:0] err_lba_ring [0:7];
    bit [14:0] err_status_ring [0:7];
    bit [7:0]  err_opcode_ring [0:7];
    bit [15:0] err_param_ring [0:7];
    bit [7:0]  dsm_range_idx;
    bit [7:0]  dsm_range_last;
    bit [1:0]  dsm_dw_idx;
    bit [31:0] dsm_dw0;
    bit [31:0] dsm_dw1;
    bit [31:0] dsm_dw2;
    bit [63:0] dsm_lba;
    bit [63:0] dsm_lba_limit;
    bit [63:0] dsm_disk_remaining;
    bit [31:0] dsm_range_blocks;
    bit        dsm_range_empty;
    bit        dsm_lba_in_range;
    bit        dsm_range_ok_stage;
    bit [19:0] wait_timer;
    bit [19:0] cq_full_timer;
    bit        aer_pending;
    bit        aer_event_pending;
    bit        temp_event_latched;
    bit [15:0] temp_sample;
    bit [15:0] aer_cid;
    bit [15:0] aer_sq_head;
    bit [31:0] aer_result;
    bit        ctrl_enable_pending;
    bit [15:0] ctrl_enable_timer;
    wire [15:0] xadc_temp_k;
    wire        xadc_temp_valid;

    bit [87:0] rd_req_ctx_1;
    bit [31:0] rd_req_data_1;
    bit        rd_req_valid_1;

    bit        tx_valid;
    bit [127:0] tx_data;
    bit [3:0] tx_keepdw;
    bit        tx_last;
    bit        tx_second_pending;
    bit [127:0] tx_second_data;
    bit [3:0] tx_second_keepdw;
    bit        tx_second_last;
    bit        tx_done;
    bit [63:0] dma_addr_stage;
    bit [31:0] dma_data_stage;

    bit        cpl_valid;
    bit        cpl_error;
    bit [31:0] cpl_data;
    bit        cpl_expected;
    bit [7:0]  cpl_expected_tag;
    bit [11:0] cpl_expected_byte_count;
    bit [6:0]  cpl_expected_lower_addr;

    integer init_i;
    integer init_lba;
    integer init_err;
    initial begin
        for (init_i = 0; init_i < BACKING_DWORDS; init_i = init_i + 1) begin
            block_store[init_i] = 32'h00000000;
        end
        for (init_lba = 0; init_lba < BACKING_LBAS; init_lba = init_lba + 1) begin
            block_valid[init_lba] = 1'b0;
            block_tag[init_lba] = 64'h0000000000000000;
        end
        for (init_err = 0; init_err < 8; init_err = init_err + 1) begin
            err_count_ring[init_err] = 32'h00000000;
            err_cid_ring[init_err] = 16'h0000;
            err_qid_ring[init_err] = 1'b0;
            err_nsid_ring[init_err] = 32'h00000000;
            err_lba_ring[init_err] = 64'h0000000000000000;
            err_status_ring[init_err] = NVME_SC_SUCCESS;
            err_opcode_ring[init_err] = 8'h00;
            err_param_ring[init_err] = 16'h0000;
        end
    end

    pcileech_xadc_temperature i_pcileech_xadc_temperature(
        .clk        ( clk             ),
        .rst        ( rst             ),
        .temp_k     ( xadc_temp_k     ),
        .temp_valid ( xadc_temp_valid )
    );

    assign tlps_dma_out.tdata    = tx_data;
    assign tlps_dma_out.tkeepdw  = tx_keepdw;
    assign tlps_dma_out.tlast    = tx_last;
    assign tlps_dma_out.tvalid   = tx_valid;
    assign tlps_dma_out.tuser    = {7'h00, tx_last, 1'b1};
    assign tlps_dma_out.has_data = tx_valid;

    wire        wr_bar0_active_range = (wr_addr[19:0] < `NVME_BAR0_ACTIVE_LIMIT);
    wire        rd_bar0_active_range = (rd_req_addr[19:0] < `NVME_BAR0_ACTIVE_LIMIT);
    wire [13:0] wr_off = wr_addr[13:0];
    wire [13:0] rd_off = rd_req_addr[13:0];
    wire        wr_is_msix_table = wr_bar0_active_range && (wr_off[13:5] == MSIX_TABLE_OFF[13:5]);
    wire        wr_is_msix_pba   = wr_bar0_active_range && (wr_off[13:2] == MSIX_PBA_OFF[13:2]);
    wire        wr_msix_vec      = wr_off[4];

    wire [15:0] admin_sq_size = {4'h0, aqa[11:0]} + 16'd1;
    wire [15:0] admin_cq_size = {4'h0, aqa[27:16]} + 16'd1;

    wire [7:0]  cmd_opcode = cmd_dw[0][7:0];
    wire [15:0] cmd_cid    = cmd_dw[0][31:16];
    wire [31:0] cmd_nsid   = cmd_dw[1];
    wire [63:0] cmd_prp1   = {cmd_dw[7], cmd_dw[6]};
    wire [63:0] cmd_prp2   = {cmd_dw[9], cmd_dw[8]};
    wire [63:0] cmd_slba   = {cmd_dw[11], cmd_dw[10]};
    wire [15:0] cmd_nlb    = cmd_dw[12][15:0];
    wire [31:0] cmd_io_dw32 = ({16'h0000, cmd_nlb} + 32'd1) << 7;
    wire [19:0] cmd_io_dw   = cmd_io_dw32[19:0];
    wire        cmd_nsid_is_one = (cmd_nsid == 32'd1);
    wire [14:0] cmd_lba_status = cmd_nsid_is_one ? NVME_SC_LBA_RANGE : NVME_SC_INVALID_NS;
    wire        cmd_lba_ok;

    function automatic [15:0] q_next;
        input [15:0] val;
        input [15:0] size;
        begin
            q_next = ((val + 16'd1) >= size) ? 16'd0 : (val + 16'd1);
        end
    endfunction

    function automatic lba_range_ok;
        input [31:0] nsid;
        input [63:0] slba;
        input [31:0] block_count;
        begin
            lba_range_ok = (nsid == 32'd1) &&
                           (block_count != 32'h00000000) &&
                           (slba < DISK_LBAS) &&
                           (block_count <= (DISK_LBAS - slba));
        end
    endfunction

    assign cmd_lba_ok = lba_range_ok(cmd_nsid, cmd_slba, {16'h0000, cmd_nlb} + 32'd1) &&
                        (cmd_io_dw32 <= {12'h000, MAX_XFER_DW});

    function automatic [BACKING_SLOT_BITS-1:0] backing_slot;
        input [63:0] lba;
        reg [11:0] mix;
        begin
            mix = lba[11:0] ^ lba[23:12] ^ lba[35:24] ^ lba[47:36] ^ lba[59:48] ^ {8'h00, lba[63:60]};
            backing_slot = mix[BACKING_SLOT_BITS-1:0];
        end
    endfunction

    wire [15:0] admin_sq_head_next = q_next(admin_sq_head, admin_sq_size);
    wire [15:0] io_sq_head_next    = q_next(io_sq_head, io_sq_size);
    wire        admin_cq_full      = (admin_cq_size > 16'd1) &&
                                     (q_next(admin_cq_tail, admin_cq_size) == admin_cq_head_db);
    wire        io_cq_full         = (io_cq_size > 16'd1) &&
                                     (q_next(io_cq_tail, io_cq_size) == io_cq_head_db);
    wire        cqe_irq_vector     = cqe_qid ? io_cq_irq_vector : 1'b0;
    wire        cqe_irq_enabled    = cqe_qid ? io_cq_irq_enabled : 1'b1;

    function automatic [31:0] merge_be;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0]  byte_en;
        begin
            merge_be = old_value;
            if (byte_en[0]) merge_be[7:0]   = new_value[7:0];
            if (byte_en[1]) merge_be[15:8]  = new_value[15:8];
            if (byte_en[2]) merge_be[23:16] = new_value[23:16];
            if (byte_en[3]) merge_be[31:24] = new_value[31:24];
        end
    endfunction

    wire [31:0] cc_next = merge_be(cc, wr_data, wr_be);
    wire        cc_en_effective = (wr_valid && wr_bar0_active_range && (wr_off[13:2] == 12'h005)) ? cc_next[0] : cc[0];
    wire [63:0] asq_addr = {asq_hi, asq_lo};
    wire [63:0] acq_addr = {acq_hi, acq_lo};
    wire        admin_queue_config_ok = (admin_sq_size >= 16'd2) &&
                                        (admin_sq_size <= 16'd64) &&
                                        (admin_cq_size >= 16'd2) &&
                                        (admin_cq_size <= 16'd64) &&
                                        (asq_addr != 64'h0000000000000000) &&
                                        (acq_addr != 64'h0000000000000000) &&
                                        (asq_addr[11:0] == 12'h000) &&
                                        (acq_addr[11:0] == 12'h000);
    wire        cc_enable_cfg_ok = admin_queue_config_ok &&
                                   (cc_next[6:4] == 3'b000) &&
                                   (cc_next[10:7] == 4'h0) &&
                                   (cc_next[13:11] == 3'b000) &&
                                   (cc_next[19:16] == 4'h6) &&
                                   (cc_next[23:20] == 4'h4);
    wire        controller_ready = cc[0] && csts[0] && !ctrl_enable_pending;

    function automatic [31:0] tlp_to_le;
        input [31:0] value;
        begin
            tlp_to_le = {value[7:0], value[15:8], value[23:16], value[31:24]};
        end
    endfunction

    function automatic [31:0] le_to_tlp;
        input [31:0] value;
        begin
            le_to_tlp = {value[7:0], value[15:8], value[23:16], value[31:24]};
        end
    endfunction

    function automatic [15:0] bs16;
        input [15:0] value;
        begin
            bs16 = {value[7:0], value[15:8]};
        end
    endfunction

    function automatic [31:0] ascii4;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        input [7:0] d;
        begin
            ascii4 = {d, c, b, a};
        end
    endfunction

    function automatic [31:0] prp_first_span;
        input [63:0] prp1;
        begin
            prp_first_span = 32'd4096 - {20'h0, prp1[11:0]};
        end
    endfunction

    function automatic prp_needs_list;
        input [63:0] prp1;
        input [19:0] total_dw;
        reg [31:0] total_bytes;
        begin
            total_bytes = {10'h0, total_dw, 2'b00};
            prp_needs_list = (total_bytes > (prp_first_span(prp1) + 32'd4096));
        end
    endfunction

    function automatic prp_list_too_many;
        input [63:0] prp1;
        input [19:0] total_dw;
        reg [31:0] total_bytes;
        reg [31:0] rem_bytes;
        reg [8:0] entries;
        begin
            total_bytes = {10'h0, total_dw, 2'b00};
            rem_bytes = total_bytes - prp_first_span(prp1);
            entries = (rem_bytes[11:0] == 12'h000) ? rem_bytes[20:12] : (rem_bytes[20:12] + 9'd1);
            prp_list_too_many = prp_needs_list(prp1, total_dw) && (entries > PRP_LIST_ENTRIES);
        end
    endfunction

    function automatic prp_invalid;
        input [63:0] prp1;
        input [63:0] prp2;
        input [19:0] total_dw;
        reg [31:0] total_bytes;
        begin
            total_bytes = {10'h0, total_dw, 2'b00};
            prp_invalid = (total_dw == 20'd0) ||
                          (total_dw > MAX_XFER_DW) ||
                          (prp1 == 64'h0000000000000000) ||
                          (prp1[1:0] != 2'b00) ||
                          ((total_bytes > prp_first_span(prp1)) && (prp2 == 64'h0000000000000000)) ||
                          ((total_bytes > prp_first_span(prp1)) && (prp2[11:0] != 12'h000)) ||
                          prp_list_too_many(prp1, total_dw);
        end
    endfunction

    function automatic prp_list_entry_invalid;
        input [63:0] entry;
        begin
            prp_list_entry_invalid = (entry == 64'h0000000000000000) || (entry[11:0] != 12'h000);
        end
    endfunction

    function automatic [7:0] prp_list_last;
        input [63:0] prp1;
        input [19:0] total_dw;
        reg [31:0] total_bytes;
        reg [31:0] rem_bytes;
        reg [8:0] entries;
        begin
            total_bytes = {10'h0, total_dw, 2'b00};
            rem_bytes = total_bytes - prp_first_span(prp1);
            entries = (rem_bytes[11:0] == 12'h000) ? rem_bytes[20:12] : (rem_bytes[20:12] + 9'd1);
            prp_list_last = (entries == 9'd0) ? 8'd0 :
                            (entries > PRP_LIST_ENTRIES) ? 8'hff :
                            (entries[7:0] - 8'd1);
        end
    endfunction

    function automatic [63:0] prp_addr;
        input [63:0] prp1;
        input [63:0] prp2;
        input [19:0] dw_index;
        reg [31:0] byte_off;
        reg [31:0] first_span;
        reg [31:0] rem_off;
        reg [PRP_LIST_BITS-1:0] list_idx;
        begin
            byte_off   = {10'h0, dw_index, 2'b00};
            first_span = prp_first_span(prp1);
            rem_off    = byte_off - first_span;
            list_idx   = rem_off[12 + PRP_LIST_BITS - 1:12];
            if (byte_off < first_span)
                prp_addr = prp1 + byte_off;
            else if (prp_list_active)
                prp_addr = prp_list[list_idx] + {52'h0, rem_off[11:0]};
            else
                prp_addr = prp2 + rem_off;
        end
    endfunction

    function automatic [19:0] admin_log_dw_count;
        input [31:0] cdw10;
        input [31:0] cdw11;
        reg [31:0] n_dw;
        begin
            n_dw = {cdw11[15:0], cdw10[31:16]} + 32'd1;
            admin_log_dw_count = (n_dw > 32'd1024) ? 20'd1024 : n_dw[19:0];
        end
    endfunction

    function automatic [15:0] error_param_location;
        input [14:0] status;
        begin
            case (status)
                NVME_SC_INVALID_OPC:          error_param_location = 16'h0000;
                NVME_SC_INVALID_FIELD:        error_param_location = 16'h0028;
                NVME_SC_INVALID_NS:           error_param_location = 16'h0004;
                NVME_SC_CMD_SEQ_ERR:          error_param_location = 16'h0028;
                NVME_SC_LBA_RANGE:            error_param_location = 16'h0028;
                NVME_SC_PRP_OFFSET_INVALID:   error_param_location = 16'h0018;
                NVME_SC_CQ_INVALID:           error_param_location = 16'h002c;
                NVME_SC_INVALID_QID:          error_param_location = 16'h0028;
                NVME_SC_MAX_Q_SIZE:           error_param_location = 16'h002a;
                NVME_SC_QID_CONFLICT:         error_param_location = 16'h0028;
                NVME_SC_QUEUE_NOT_CREATED:    error_param_location = 16'h0028;
                NVME_SC_INVALID_IRQ_VECTOR:   error_param_location = 16'h002c;
                NVME_SC_INVALID_LOG_PAGE:     error_param_location = 16'h0028;
                NVME_SC_INVALID_FORMAT:       error_param_location = 16'h0028;
                default:                      error_param_location = 16'h0000;
            endcase
        end
    endfunction

    function automatic [31:0] identify_ctrl_word;
        input [9:0] idx;
        begin
            case (idx)
                10'd0:   identify_ctrl_word = {`NVME_PCI_SUBSYS_VENDOR_ID, `NVME_PCI_VENDOR_ID};
                10'd1:   identify_ctrl_word = `NVME_CTRL_SERIAL_DW0;
                10'd2:   identify_ctrl_word = `NVME_CTRL_SERIAL_DW1;
                10'd3:   identify_ctrl_word = `NVME_CTRL_SERIAL_DW2;
                10'd4:   identify_ctrl_word = `NVME_CTRL_SERIAL_DW3;
                10'd5:   identify_ctrl_word = `NVME_CTRL_SERIAL_DW4;
                10'd6:   identify_ctrl_word = `NVME_CTRL_MODEL_DW0;
                10'd7:   identify_ctrl_word = `NVME_CTRL_MODEL_DW1;
                10'd8:   identify_ctrl_word = `NVME_CTRL_MODEL_DW2;
                10'd9:   identify_ctrl_word = `NVME_CTRL_MODEL_DW3;
                10'd10:  identify_ctrl_word = `NVME_CTRL_MODEL_DW4;
                10'd11:  identify_ctrl_word = `NVME_CTRL_MODEL_DW5;
                10'd12:  identify_ctrl_word = `NVME_CTRL_MODEL_DW6;
                10'd13:  identify_ctrl_word = `NVME_CTRL_MODEL_DW7;
                10'd14:  identify_ctrl_word = `NVME_CTRL_MODEL_DW8;
                10'd15:  identify_ctrl_word = `NVME_CTRL_MODEL_DW9;
                10'd16:  identify_ctrl_word = `NVME_CTRL_FW_DW0;
                10'd17:  identify_ctrl_word = `NVME_CTRL_FW_DW1;
                10'd18:  identify_ctrl_word = `NVME_IEEE_OUI_DWORD;
                10'd19:  identify_ctrl_word = {16'h0001, PROFILE_MDTS, 8'h00}; // MDTS, CNTLID=1
                10'd64:  identify_ctrl_word = 32'h00000002; // OACS: Format NVM, AERL=0 = one pending AER.
                10'd65:  identify_ctrl_word = 32'h00070100; // ELPE=7 entries, LPA bit0 set, one power state.
                10'd66:  identify_ctrl_word = {`NVME_WARNING_TEMP_K, 16'h0000};
                10'd67:  identify_ctrl_word = {16'h0000, `NVME_CRITICAL_TEMP_K};
                10'd70:  identify_ctrl_word = PROFILE_BYTES[31:0];   // TNVMCAP low
                10'd71:  identify_ctrl_word = PROFILE_BYTES[63:32];
                10'd72:  identify_ctrl_word = PROFILE_BYTES[95:64];
                10'd73:  identify_ctrl_word = PROFILE_BYTES[127:96];  // TNVMCAP high
                10'd74:  identify_ctrl_word = PROFILE_BYTES[31:0];   // UNVMCAP low
                10'd75:  identify_ctrl_word = PROFILE_BYTES[63:32];
                10'd76:  identify_ctrl_word = PROFILE_BYTES[95:64];
                10'd77:  identify_ctrl_word = PROFILE_BYTES[127:96];  // UNVMCAP high
                10'd128: identify_ctrl_word = 32'h00004466; // SQES=64B, CQES=16B
                10'd129: identify_ctrl_word = 32'd1;        // one namespace
                10'd130: identify_ctrl_word = 32'h0000000c; // Dataset Management and Write Zeroes.
                10'd132: identify_ctrl_word = 32'h00000001; // volatile write cache present
                10'd512: identify_ctrl_word = 32'h00000320; // PSD0: 8.00 W active state.
                10'd513: identify_ctrl_word = 32'h00000000;
                10'd514: identify_ctrl_word = 32'h00000000;
                10'd515: identify_ctrl_word = 32'h00000000;
                10'd516: identify_ctrl_word = 32'h00000000;
                10'd517: identify_ctrl_word = 32'h00000000;
                10'd518: identify_ctrl_word = 32'h00000000;
                10'd519: identify_ctrl_word = 32'h00000000;
                default: identify_ctrl_word = 32'h00000000;
            endcase
        end
    endfunction

    function automatic [31:0] identify_ns_word;
        input [9:0] idx;
        begin
            case (idx)
                10'd0:   identify_ns_word = DISK_LBAS[31:0]; // NSZE low
                10'd1:   identify_ns_word = DISK_LBAS[63:32];
                10'd2:   identify_ns_word = DISK_LBAS[31:0]; // NCAP low
                10'd3:   identify_ns_word = DISK_LBAS[63:32];
                10'd4:   identify_ns_word = DISK_LBAS[31:0]; // NUSE low
                10'd5:   identify_ns_word = DISK_LBAS[63:32];
                10'd6:   identify_ns_word = 32'h00000000;   // one LBA format, no metadata.
                10'd7:   identify_ns_word = 32'h00000000;   // no PI/DPS/RESCAP features.
                10'd32:  identify_ns_word = 32'h00090000;   // LBAF0: 512-byte LBAs
                default: identify_ns_word = 32'h00000000;
            endcase
        end
    endfunction

    function automatic [31:0] cqe_word;
        input [1:0] idx;
        begin
            case (idx)
                2'd0: cqe_word = cqe_result;
                2'd1: cqe_word = 32'h00000000;
                2'd2: cqe_word = {15'h0000, cqe_qid, cqe_sq_head};
                2'd3: cqe_word = {cqe_status, (cqe_qid ? io_cq_phase : admin_cq_phase), cqe_cid};
            endcase
        end
    endfunction

    function automatic [31:0] payload_word;
        input [3:0] payload;
        input [19:0] idx;
        begin
            case (payload)
                PAYLOAD_IDENT_CTL: payload_word = identify_ctrl_word(idx[9:0]);
                PAYLOAD_IDENT_NS:  payload_word = identify_ns_word(idx[9:0]);
                PAYLOAD_IDENT_LST: payload_word = (idx == 20'd0) ? 32'd1 : 32'h00000000;
                PAYLOAD_SMART_LOG: payload_word = smart_log_word(idx[7:0]);
                PAYLOAD_ERROR_LOG: payload_word = error_log_word(idx[7:0]);
                PAYLOAD_LOG_PAGES: payload_word = supported_log_word(idx[7:0]);
`ifdef NVME_ENABLE_VENDOR_LOG
                PAYLOAD_VENDOR_LOG: payload_word = vendor_log_word(idx[7:0]);
`endif
                PAYLOAD_FW_SLOT_LOG: payload_word = firmware_slot_log_word(idx[7:0]);
                PAYLOAD_DISK:      payload_word = disk_rd_data;
                default:           payload_word = 32'h00000000;
            endcase
        end
    endfunction

    function automatic [BACKING_INDEX_BITS-1:0] backing_index;
        input [63:0] lba;
        input [6:0]  word_off;
        begin
            backing_index = {backing_slot(lba), word_off};
        end
    endfunction

    function automatic [63:0] xfer_lba_offset;
        input [19:0] idx;
        begin
            xfer_lba_offset = {51'h0, idx[19:7]};
        end
    endfunction

    function automatic [63:0] backing_lba_offset;
        input [BACKING_INDEX_BITS:0] idx;
        begin
            backing_lba_offset = {{(70-BACKING_INDEX_BITS){1'b0}}, idx[BACKING_INDEX_BITS:7]};
        end
    endfunction

    wire [63:0] backing_read_lba = cmd_slba + xfer_lba_offset(xfer_idx);
    wire [6:0]  backing_read_word_off = xfer_idx[6:0];
    wire [BACKING_SLOT_BITS-1:0] backing_read_slot = backing_slot(backing_read_lba);
    wire [BACKING_INDEX_BITS-1:0] backing_read_index = backing_index(backing_read_lba, backing_read_word_off);

    wire [63:0] backing_store_lba = cmd_slba + xfer_lba_offset(xfer_idx);
    wire [6:0]  backing_store_word_off = xfer_idx[6:0];
    wire [BACKING_SLOT_BITS-1:0] backing_store_slot = backing_slot(backing_store_lba);
    wire [BACKING_INDEX_BITS-1:0] backing_store_index = backing_index(backing_store_lba, backing_store_word_off);

    wire [63:0] backing_zero_lba = cmd_slba + backing_lba_offset(clear_idx);
    wire [6:0]  backing_zero_word_off = clear_idx[6:0];
    wire [BACKING_SLOT_BITS-1:0] backing_zero_slot = backing_slot(backing_zero_lba);
    wire [BACKING_INDEX_BITS-1:0] backing_zero_index = backing_index(backing_zero_lba, backing_zero_word_off);

    wire backing_store_fire  = (state == ST_HOST_READ_WAIT) && cpl_valid;
    wire backing_format_fire = (state == ST_FORMAT_CLEAR);
    wire backing_zero_fire   = (state == ST_ZERO_CLEAR);
    wire backing_wr_en       = backing_store_fire || backing_format_fire || backing_zero_fire;
    wire [BACKING_INDEX_BITS-1:0] backing_wr_addr =
        backing_store_fire ? backing_store_index :
        backing_zero_fire  ? backing_zero_index :
                             clear_idx[BACKING_INDEX_BITS-1:0];
    wire [31:0] backing_wr_data = backing_store_fire ? cpl_data : 32'h00000000;

    always @ (posedge clk) begin
        if (rst) begin
            disk_rd_data <= 32'h00000000;
        end
        else begin
            if (state == ST_DISK_READ) begin
                if (block_valid[backing_read_slot] && (block_tag[backing_read_slot] == backing_read_lba))
                    disk_rd_data <= block_store[backing_read_index];
                else
                    disk_rd_data <= 32'h00000000;
            end
            if (backing_wr_en)
                block_store[backing_wr_addr] <= backing_wr_data;
        end
    end

    task automatic prepare_prp_transfer;
        input [63:0] prp1;
        input [63:0] prp2;
        input [19:0] total_dw;
        input [7:0] next_state;
        reg [7:0] last_entry;
        begin
            xfer_after_prp_state <= next_state;
            if (prp_invalid(prp1, prp2, total_dw)) begin
                cqe_status <= NVME_SC_PRP_OFFSET_INVALID;
                record_error(NVME_SC_PRP_OFFSET_INVALID, 1'b0);
                state <= ST_CQE_REQ;
            end
            else if (prp_needs_list(prp1, total_dw)) begin
                last_entry = prp_list_last(prp1, total_dw);
                prp_list_active <= 1'b1;
                prp_fetch_idx   <= {PRP_LIST_BITS{1'b0}};
                prp_fetch_last  <= last_entry[PRP_LIST_BITS-1:0];
                prp_fetch_dw    <= 1'b0;
                state           <= ST_PRP_LIST_REQ;
            end
            else begin
                prp_list_active <= 1'b0;
                prp_fetch_last  <= {PRP_LIST_BITS{1'b0}};
                state           <= next_state;
            end
        end
    endtask

    task automatic record_error;
        input [14:0] status;
        input        media_error;
        reg [2:0] ring_slot;
        begin
            ring_slot = stat_error_log_entries[2:0];
            stat_error_log_entries <= stat_error_log_entries + 32'd1;
            stat_last_error_status <= status;
            stat_last_error_opcode <= cmd_opcode;
            stat_last_error_cid    <= cmd_cid;
            stat_last_error_qid    <= current_qid;
            stat_last_error_lba    <= cmd_slba;
            err_count_ring[ring_slot] <= stat_error_log_entries + 32'd1;
            err_cid_ring[ring_slot] <= cmd_cid;
            err_qid_ring[ring_slot] <= current_qid;
            err_nsid_ring[ring_slot] <= cmd_nsid;
            err_lba_ring[ring_slot] <= cmd_slba;
            err_status_ring[ring_slot] <= status;
            err_opcode_ring[ring_slot] <= cmd_opcode;
            err_param_ring[ring_slot] <= error_param_location(status);
            if (aer_pending) begin
                if (media_error && feat_async_event_cfg[1]) begin
                    aer_event_pending <= 1'b1;
                    aer_result <= AER_RESULT_SMART_MEDIA;
                end
                else if (feat_async_event_cfg[0]) begin
                    aer_event_pending <= 1'b1;
                    aer_result <= AER_RESULT_ERROR_LOG;
                end
            end
            if (status == NVME_SC_DATA_XFER_ERR)
                stat_transport_errors <= stat_transport_errors + 64'd1;
            else if (media_error)
                stat_media_errors <= stat_media_errors + 32'd1;
            else
                stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
        end
    endtask

    function automatic [15:0] composite_temperature;
        begin
            composite_temperature = xadc_temp_valid ?
                                    (xadc_temp_k + {11'h000, thermal_load[7:3]}) :
                                    (16'd303 + {10'h000, thermal_load[7:2]});
        end
    endfunction

    function automatic [15:0] warning_temperature_threshold;
        begin
            warning_temperature_threshold = (feat_temp_threshold[15:0] == 16'h0000) ?
                                            16'd343 :
                                            feat_temp_threshold[15:0];
        end
    endfunction

    function automatic [15:0] critical_temperature_threshold;
        begin
            critical_temperature_threshold = 16'd358;
        end
    endfunction

    function automatic [7:0] critical_warning_byte;
        input [15:0] temp_k;
        begin
            critical_warning_byte = 8'h00;
            if (temp_k >= warning_temperature_threshold())
                critical_warning_byte[1] = 1'b1;
            if (stat_media_errors != 32'h00000000)
                critical_warning_byte[2] = 1'b1;
        end
    endfunction

    function automatic [31:0] smart_log_word;
        input [7:0] idx;
        reg [15:0] temp_k;
        begin
            temp_k = composite_temperature();
            case (idx)
                8'd0:  smart_log_word = {`NVME_SMART_SPARE, temp_k, critical_warning_byte(temp_k)};
                8'd1:  smart_log_word = {16'h0000, `NVME_SMART_PERCENT_USED, `NVME_SMART_SPARE_THRESH};
                8'd8:  smart_log_word = stat_data_units_read[31:0];
                8'd9:  smart_log_word = stat_data_units_read[63:32];
                8'd10: smart_log_word = 32'h00000000;
                8'd11: smart_log_word = 32'h00000000;
                8'd12: smart_log_word = stat_data_units_written[31:0];
                8'd13: smart_log_word = stat_data_units_written[63:32];
                8'd14: smart_log_word = 32'h00000000;
                8'd15: smart_log_word = 32'h00000000;
                8'd16: smart_log_word = stat_host_read_cmds[31:0];
                8'd17: smart_log_word = stat_host_read_cmds[63:32];
                8'd18: smart_log_word = 32'h00000000;
                8'd19: smart_log_word = 32'h00000000;
                8'd20: smart_log_word = stat_host_write_cmds[31:0];
                8'd21: smart_log_word = stat_host_write_cmds[63:32];
                8'd22: smart_log_word = 32'h00000000;
                8'd23: smart_log_word = 32'h00000000;
                8'd24: smart_log_word = 32'h00000000;
                8'd25: smart_log_word = 32'h00000000;
                8'd26: smart_log_word = 32'h00000000;
                8'd27: smart_log_word = 32'h00000000;
                8'd28: smart_log_word = power_cycle_count;
                8'd29: smart_log_word = 32'h00000000;
                8'd30: smart_log_word = 32'h00000000;
                8'd31: smart_log_word = 32'h00000000;
                8'd32: smart_log_word = power_on_hours;
                8'd33: smart_log_word = 32'h00000000;
                8'd34: smart_log_word = 32'h00000000;
                8'd35: smart_log_word = 32'h00000000;
                8'd36: smart_log_word = stat_unsafe_shutdowns[31:0];
                8'd37: smart_log_word = stat_unsafe_shutdowns[63:32];
                8'd38: smart_log_word = 32'h00000000;
                8'd39: smart_log_word = 32'h00000000;
                8'd40: smart_log_word = stat_media_errors;
                8'd41: smart_log_word = 32'h00000000;
                8'd42: smart_log_word = 32'h00000000;
                8'd43: smart_log_word = 32'h00000000;
                8'd44: smart_log_word = stat_error_log_entries;
                8'd45: smart_log_word = 32'h00000000;
                8'd46: smart_log_word = 32'h00000000;
                8'd47: smart_log_word = 32'h00000000;
                8'd48: smart_log_word = warning_temp_time;
                8'd49: smart_log_word = critical_temp_time;
                8'd50: smart_log_word = {temp_k, temp_k};
                8'd51: smart_log_word = {16'h0000, temp_k};
                8'd52: smart_log_word = 32'h00000000;
                8'd53: smart_log_word = 32'h00000000;
                8'd54: smart_log_word = 32'h00000000;
                8'd55: smart_log_word = 32'h00000000;
                8'd56: smart_log_word = 32'h00000000;
                default: smart_log_word = 32'h00000000;
            endcase
        end
    endfunction

    function automatic [31:0] error_log_word;
        input [7:0] idx;
        reg [2:0] entry;
        reg [2:0] ring_slot;
        reg [3:0] field;
        begin
            entry = idx[6:4];
            field = idx[3:0];
            ring_slot = stat_error_log_entries[2:0] - entry - 3'd1;
            if ((idx[7] == 1'b1) ||
                ((stat_error_log_entries < 32'd8) && ({29'h00000000, entry} >= stat_error_log_entries))) begin
                error_log_word = 32'h00000000;
            end
            else begin
                case (field)
                    4'd0: error_log_word = err_count_ring[ring_slot];
                    4'd1: error_log_word = 32'h00000000;
                    4'd2: error_log_word = {err_cid_ring[ring_slot], 15'h0000, err_qid_ring[ring_slot]};
                    4'd3: error_log_word = {err_param_ring[ring_slot], err_status_ring[ring_slot], 1'b0};
                    4'd4: error_log_word = err_lba_ring[ring_slot][31:0];
                    4'd5: error_log_word = err_lba_ring[ring_slot][63:32];
                    4'd6: error_log_word = err_nsid_ring[ring_slot];
                    4'd7: error_log_word = {9'h000, err_status_ring[ring_slot], err_opcode_ring[ring_slot]};
                    default: error_log_word = 32'h00000000;
                endcase
            end
        end
    endfunction

    function automatic [31:0] supported_log_word;
        input [7:0] idx;
        begin
            case (idx)
                8'h00: supported_log_word = 32'h01010101;
`ifdef NVME_ENABLE_VENDOR_LOG
                LOG_PAGE_VENDOR_C0_DW: supported_log_word = 32'h00000001;
`endif
                default: supported_log_word = 32'h00000000;
            endcase
        end
    endfunction

    function automatic [31:0] firmware_slot_log_word;
        input [7:0] idx;
        begin
            case (idx)
                8'd0: firmware_slot_log_word = 32'h00000001; // AFI: active slot 1.
                8'd2: firmware_slot_log_word = `NVME_CTRL_FW_DW0;
                8'd3: firmware_slot_log_word = `NVME_CTRL_FW_DW1;
                default: firmware_slot_log_word = 32'h00000000;
            endcase
        end
    endfunction

`ifdef NVME_ENABLE_VENDOR_LOG
    function automatic [31:0] vendor_log_word;
        input [7:0] idx;
        begin
            case (idx)
                8'd0:  vendor_log_word = ascii4("N","V","M","D");
                8'd1:  vendor_log_word = 32'h00000002;
                8'd2:  vendor_log_word = BACKING_LBAS;
                8'd3:  vendor_log_word = {PRP_LIST_BITS_U8, PROFILE_MDTS, 8'h00, BACKING_SLOT_BITS_U8};
                8'd4:  vendor_log_word = {12'h000, MAX_XFER_DW};
                8'd5:  vendor_log_word = {12'h000, DMA_TIMEOUT_CLKS};
                8'd6:  vendor_log_word = NVME_CLK_HZ[31:0];
                8'd7:  vendor_log_word = NVME_CLK_HZ[63:32];
                8'd34: vendor_log_word = {16'h0000, DMA_DWORDS_PER_TLP, DMA_OUTSTANDING_LIMIT};
                8'd35: vendor_log_word = stat_unsafe_shutdowns[31:0];
                8'd36: vendor_log_word = stat_unsafe_shutdowns[63:32];
                8'd37: vendor_log_word = stat_transport_errors[31:0];
                8'd38: vendor_log_word = stat_transport_errors[63:32];
                8'd39: vendor_log_word = {24'h000000, AER_PENDING_LIMIT};
                8'd40: vendor_log_word = {30'd0, aer_event_pending, aer_pending};
                8'd41: vendor_log_word = {30'd0, io_cq_irq_enabled, io_cq_irq_vector};
                8'd42: vendor_log_word = {24'h000000, IO_QUEUE_LIMIT};
                8'd43: vendor_log_word = {24'h000000, feat_async_event_cfg[7:0]};
                8'd44: vendor_log_word = power_cycle_count;
                8'd45: vendor_log_word = {31'd0, feat_write_cache[0]};
                8'd8:  vendor_log_word = stat_dma_mrd_tlps[31:0];
                8'd9:  vendor_log_word = stat_dma_mrd_tlps[63:32];
                8'd10: vendor_log_word = stat_dma_mwr_tlps[31:0];
                8'd11: vendor_log_word = stat_dma_mwr_tlps[63:32];
                8'd12: vendor_log_word = stat_prp_list_fetches[31:0];
                8'd13: vendor_log_word = stat_prp_list_fetches[63:32];
                8'd14: vendor_log_word = stat_queue_resets[31:0];
                8'd15: vendor_log_word = stat_queue_resets[63:32];
                8'd16: vendor_log_word = stat_shutdowns[31:0];
                8'd17: vendor_log_word = stat_shutdowns[63:32];
                8'd18: vendor_log_word = stat_flush_cmds[31:0];
                8'd19: vendor_log_word = stat_flush_cmds[63:32];
                8'd20: vendor_log_word = stat_dataset_cmds[31:0];
                8'd21: vendor_log_word = stat_dataset_cmds[63:32];
                8'd22: vendor_log_word = stat_write_zero_cmds[31:0];
                8'd23: vendor_log_word = stat_write_zero_cmds[63:32];
                8'd24: vendor_log_word = stat_format_cmds[31:0];
                8'd25: vendor_log_word = stat_format_cmds[63:32];
                8'd26: vendor_log_word = stat_backend_evictions[31:0];
                8'd27: vendor_log_word = stat_backend_evictions[63:32];
                8'd28: vendor_log_word = stat_timeout_errors[31:0];
                8'd29: vendor_log_word = stat_timeout_errors[63:32];
                8'd30: vendor_log_word = stat_cpl_errors[31:0];
                8'd31: vendor_log_word = stat_cpl_errors[63:32];
                8'd32: vendor_log_word = stat_invalid_cmds;
                8'd33: vendor_log_word = stat_media_errors;
                default: vendor_log_word = 32'h00000000;
            endcase
        end
    endfunction
`endif

    function automatic [31:0] msix_table_word;
        input       vec;
        input [1:0] dw;
        begin
            case (dw)
                2'd0: msix_table_word = msix_addr[vec][31:0];
                2'd1: msix_table_word = msix_addr[vec][63:32];
                2'd2: msix_table_word = msix_data[vec];
                2'd3: msix_table_word = msix_vector_ctrl[vec];
            endcase
        end
    endfunction

    function automatic [31:0] nvme_reg_read;
        input [13:0] off;
        begin
            if ((off[13:5] == MSIX_TABLE_OFF[13:5])) begin
                nvme_reg_read = msix_table_word(off[4], off[3:2]);
            end
            else if (off[13:2] == MSIX_PBA_OFF[13:2]) begin
                nvme_reg_read = msix_pba;
            end
            else begin
            case (off[13:2])
                12'h000: nvme_reg_read = NVME_CAP_LO;
                12'h001: nvme_reg_read = NVME_CAP_HI;
                12'h002: nvme_reg_read = NVME_VS;
                12'h003: nvme_reg_read = intms;
                12'h004: nvme_reg_read = 32'h00000000;
                12'h005: nvme_reg_read = cc;
                12'h006: nvme_reg_read = 32'h00000000;
                12'h007: nvme_reg_read = csts;
                12'h008: nvme_reg_read = 32'h00000000;
                12'h009: nvme_reg_read = aqa;
                12'h00a: nvme_reg_read = asq_lo;
                12'h00b: nvme_reg_read = asq_hi;
                12'h00c: nvme_reg_read = acq_lo;
                12'h00d: nvme_reg_read = acq_hi;
                12'h00e: nvme_reg_read = 32'h00000000;
                12'h00f: nvme_reg_read = 32'h00000000;
                default: begin
                    if (off[13:12] != 2'b00) begin
                        case (off[11:2])
                            10'h000: nvme_reg_read = {16'h0000, admin_sq_tail};
                            10'h001: nvme_reg_read = {16'h0000, admin_cq_head_db};
                            10'h002: nvme_reg_read = {16'h0000, io_sq_tail};
                            10'h003: nvme_reg_read = {16'h0000, io_cq_head_db};
                            default: nvme_reg_read = 32'h00000000;
                        endcase
                    end
                    else begin
                        nvme_reg_read = 32'h00000000;
                    end
                end
            endcase
            end
        end
    endfunction

    task automatic start_mrd1;
        input [63:0] addr;
        input [7:0]  tag;
        begin
            stat_dma_mrd_tlps <= stat_dma_mrd_tlps + 64'd1;
            cpl_expected <= 1'b1;
            cpl_expected_tag <= tag;
            cpl_expected_byte_count <= 12'd4;
            cpl_expected_lower_addr <= addr[6:0];
            tx_second_pending <= 1'b0;
            tx_valid          <= 1'b1;
            tx_last           <= 1'b1;
            if (addr[63:32] == 32'h00000000) begin
                tx_keepdw <= 4'b0111;
                tx_data   <= {
                    32'h00000000,
                    {addr[31:2], 2'b00},
                    {bs16(pcie_id), tag, 4'hf, 4'hf},
                    {22'b0000000000000000000000, 10'd1}
                };
            end
            else begin
                tx_keepdw <= 4'b1111;
                tx_data   <= {
                    {addr[31:2], 2'b00},
                    addr[63:32],
                    {bs16(pcie_id), tag, 4'hf, 4'hf},
                    {22'b0010000000000000000000, 10'd1}
                };
            end
        end
    endtask

    task automatic start_mwr1;
        input [63:0] addr;
        input [31:0] data;
        begin
            stat_dma_mwr_tlps <= stat_dma_mwr_tlps + 64'd1;
            tx_valid <= 1'b1;
            if (addr[63:32] == 32'h00000000) begin
                tx_keepdw         <= 4'b1111;
                tx_last           <= 1'b1;
                tx_second_pending <= 1'b0;
                tx_data           <= {
                    le_to_tlp(data),
                    {addr[31:2], 2'b00},
                    {bs16(pcie_id), 8'h00, 4'hf, 4'hf},
                    {22'b0100000000000000000000, 10'd1}
                };
            end
            else begin
                tx_keepdw         <= 4'b1111;
                tx_last           <= 1'b0;
                tx_second_pending <= 1'b1;
                tx_data           <= {
                    {addr[31:2], 2'b00},
                    addr[63:32],
                    {bs16(pcie_id), 8'h00, 4'hf, 4'hf},
                    {22'b0110000000000000000000, 10'd1}
                };
                tx_second_keepdw  <= 4'b0001;
                tx_second_last    <= 1'b1;
                tx_second_data    <= {96'h000000000000000000000000, le_to_tlp(data)};
            end
        end
    endtask

    always @ (posedge clk) begin
        if (rst) begin
            cpl_valid <= 1'b0;
            cpl_error <= 1'b0;
            cpl_data  <= 32'h00000000;
        end
        else begin
            cpl_valid <= 1'b0;
            cpl_error <= 1'b0;
            if (tlps_in.tvalid && tlps_in.tuser[0] && (tlps_in.tdata[31:25] == 7'b0100101) &&
                (tlps_in.tdata[79:72] == DMA_TAG) && tlps_in.tkeepdw[3]) begin
                if (cpl_expected &&
                    (tlps_in.tdata[79:72] == cpl_expected_tag) &&
                    (tlps_in.tdata[47:45] == 3'b000) &&
                    (tlps_in.tdata[43:32] == cpl_expected_byte_count) &&
                    (tlps_in.tdata[70:64] == cpl_expected_lower_addr)) begin
                    cpl_valid <= 1'b1;
                    cpl_data  <= tlp_to_le(tlps_in.tdata[127:96]);
                end
                else begin
                    cpl_error <= 1'b1;
                end
            end
        end
    end

    always @ (posedge clk) begin
        if (rst) begin
            intms              <= 32'h00000000;
            cc                 <= 32'h00000000;
            csts               <= 32'h00000000;
            aqa                <= 32'h00000000;
            feat_arbitration   <= 32'h00000000;
            feat_power_mgmt    <= 32'h00000000;
            feat_temp_threshold<= 32'h00000157;
            feat_write_cache   <= 32'h00000001;
            feat_irq_coalescing<= 32'h00000000;
            feat_irq_vector_cfg<= 32'h00000000;
            feat_async_event_cfg <= 32'h00000000;
            asq_lo             <= 32'h00000000;
            asq_hi             <= 32'h00000000;
            acq_lo             <= 32'h00000000;
            acq_hi             <= 32'h00000000;
            admin_sq_head      <= 16'h0000;
            admin_sq_tail      <= 16'h0000;
            admin_cq_tail      <= 16'h0000;
            admin_cq_head_db   <= 16'h0000;
            admin_cq_phase     <= 1'b1;
            io_sq_base         <= 64'h0000000000000000;
            io_cq_base         <= 64'h0000000000000000;
            io_sq_size         <= 16'd1;
            io_cq_size         <= 16'd1;
            io_sq_head         <= 16'h0000;
            io_sq_tail         <= 16'h0000;
            io_cq_tail         <= 16'h0000;
            io_cq_head_db      <= 16'h0000;
            io_cq_phase        <= 1'b1;
            io_enabled         <= 1'b0;
            io_sq_ready        <= 1'b0;
            io_cq_ready        <= 1'b0;
            io_cq_irq_enabled  <= 1'b0;
            io_cq_irq_vector   <= 1'b0;
            state              <= ST_IDLE;
            current_qid        <= 1'b0;
            fetch_idx          <= 16'h0000;
            fetch_base         <= 64'h0000000000000000;
            xfer_idx           <= 20'h00000;
            xfer_total_dw      <= 20'h00000;
            xfer_after_prp_state <= ST_IDLE;
            xfer_payload       <= PAYLOAD_ZERO;
            prp_list_active    <= 1'b0;
            prp_fetch_idx      <= {PRP_LIST_BITS{1'b0}};
            prp_fetch_last     <= {PRP_LIST_BITS{1'b0}};
            prp_fetch_dw       <= 1'b0;
            cqe_result         <= 32'h00000000;
            cqe_status         <= NVME_SC_SUCCESS;
            cqe_cid            <= 16'h0000;
            cqe_qid            <= 1'b0;
            cqe_sq_head        <= 16'h0000;
            cqe_idx            <= 2'h0;
            clear_idx          <= {BACKING_INDEX_BITS+1{1'b0}};
            clear_total_dw     <= {BACKING_INDEX_BITS+1{1'b0}};
            msix_addr[0]       <= 64'h0000000000000000;
            msix_addr[1]       <= 64'h0000000000000000;
            msix_data[0]       <= 32'h00000000;
            msix_data[1]       <= 32'h00000000;
            msix_vector_ctrl[0]<= 32'h00000001;
            msix_vector_ctrl[1]<= 32'h00000001;
            msix_pba           <= 32'h00000000;
            irq_vector         <= 1'b0;
            thermal_load       <= 8'h00;
            thermal_timer      <= 20'h00000;
            second_timer       <= 64'h0000000000000000;
            hour_timer         <= 64'h0000000000000000;
            power_on_hours     <= `NVME_SMART_INIT_POH;
            power_cycle_count  <= `NVME_SMART_INIT_POWER_CYCLES;
            controller_seen_enable <= 1'b0;
            warning_temp_time  <= 32'h00000000;
            critical_temp_time <= 32'h00000000;
            warning_temp_seconds <= 6'd0;
            critical_temp_seconds <= 6'd0;
            stat_data_units_read <= 64'h0000000000000000;
            stat_data_units_written <= 64'h0000000000000000;
            stat_host_read_cmds <= 64'h0000000000000000;
            stat_host_write_cmds <= 64'h0000000000000000;
            stat_flush_cmds    <= 64'h0000000000000000;
            stat_dataset_cmds  <= 64'h0000000000000000;
            stat_write_zero_cmds <= 64'h0000000000000000;
            stat_format_cmds   <= 64'h0000000000000000;
            stat_cmds_completed <= 64'h0000000000000000;
            stat_dma_mrd_tlps  <= 64'h0000000000000000;
            stat_dma_mwr_tlps  <= 64'h0000000000000000;
            stat_prp_list_fetches <= 64'h0000000000000000;
            stat_queue_resets  <= 64'h0000000000000000;
            stat_shutdowns     <= 64'h0000000000000000;
            stat_unsafe_shutdowns <= `NVME_SMART_INIT_UNSAFE_SHUTDOWNS;
            stat_backend_evictions <= 64'h0000000000000000;
            stat_timeout_errors <= 64'h0000000000000000;
            stat_cpl_errors    <= 64'h0000000000000000;
            stat_transport_errors <= 64'h0000000000000000;
            stat_media_errors  <= 32'h00000000;
            stat_invalid_cmds  <= 32'h00000000;
            stat_error_log_entries <= 32'h00000000;
            stat_last_error_lba <= 64'h0000000000000000;
            stat_last_error_cid <= 16'h0000;
            stat_last_error_status <= NVME_SC_SUCCESS;
            stat_last_error_opcode <= 8'h00;
            stat_last_error_qid <= 1'b0;
            dsm_range_idx     <= 8'h00;
            dsm_range_last    <= 8'h00;
            dsm_dw_idx        <= 2'h0;
            dsm_dw0           <= 32'h00000000;
            dsm_dw1           <= 32'h00000000;
            dsm_dw2           <= 32'h00000000;
            dsm_lba           <= 64'h0000000000000000;
            dsm_lba_limit     <= 64'h0000000000000000;
            dsm_disk_remaining <= 64'h0000000000000000;
            dsm_range_blocks  <= 32'h00000000;
            dsm_range_empty   <= 1'b0;
            dsm_lba_in_range  <= 1'b0;
            dsm_range_ok_stage <= 1'b0;
            wait_timer        <= 20'h00000;
            cq_full_timer     <= 20'h00000;
            aer_pending       <= 1'b0;
            aer_event_pending <= 1'b0;
            temp_event_latched<= 1'b0;
            temp_sample       <= 16'h0000;
            aer_cid           <= 16'h0000;
            aer_sq_head       <= 16'h0000;
            aer_result        <= 32'h00000000;
            ctrl_enable_pending <= 1'b0;
            ctrl_enable_timer <= 16'd0;
            rd_req_ctx_1       <= 88'h0;
            rd_req_data_1      <= 32'h00000000;
            rd_req_valid_1     <= 1'b0;
            rd_rsp_ctx         <= 88'h0;
            rd_rsp_data        <= 32'h00000000;
            rd_rsp_valid       <= 1'b0;
            tx_valid           <= 1'b0;
            tx_keepdw          <= 4'h0;
            tx_last            <= 1'b0;
            tx_data            <= 128'h0;
            tx_second_pending  <= 1'b0;
            tx_second_keepdw   <= 4'h0;
            tx_second_last     <= 1'b0;
            tx_second_data     <= 128'h0;
            tx_done            <= 1'b0;
            dma_addr_stage     <= 64'h0000000000000000;
            dma_data_stage     <= 32'h00000000;
            cpl_expected       <= 1'b0;
            cpl_expected_tag   <= 8'h00;
            cpl_expected_byte_count <= 12'h000;
            cpl_expected_lower_addr <= 7'h00;
            nvme_irq_req       <= 1'b0;
            for (init_err = 0; init_err < 8; init_err = init_err + 1) begin
                err_count_ring[init_err] <= 32'h00000000;
                err_cid_ring[init_err] <= 16'h0000;
                err_qid_ring[init_err] <= 1'b0;
                err_nsid_ring[init_err] <= 32'h00000000;
                err_lba_ring[init_err] <= 64'h0000000000000000;
                err_status_ring[init_err] <= NVME_SC_SUCCESS;
                err_opcode_ring[init_err] <= 8'h00;
                err_param_ring[init_err] <= 16'h0000;
            end
        end
        else begin
            tx_done      <= 1'b0;
            nvme_irq_req <= 1'b0;
            temp_sample <= composite_temperature();

            if (ctrl_enable_pending) begin
                if (ctrl_enable_timer >= NVME_RDY_DELAY_CLKS) begin
                    ctrl_enable_pending <= 1'b0;
                    ctrl_enable_timer <= 16'd0;
                    if (cc[0]) begin
                        csts[0] <= 1'b1;
                        csts[1] <= 1'b0;
                    end
                end
                else begin
                    ctrl_enable_timer <= ctrl_enable_timer + 16'd1;
                end
            end

            thermal_timer <= thermal_timer + 20'd1;
            if (thermal_timer == 20'hfffff && thermal_load != 8'h00)
                thermal_load <= thermal_load - 8'd1;

            if (second_timer >= (NVME_SECOND_TICKS - 64'd1)) begin
                second_timer <= 64'h0000000000000000;
                if (composite_temperature() >= warning_temperature_threshold()) begin
                    if (warning_temp_seconds == 6'd59) begin
                        warning_temp_seconds <= 6'd0;
                        if (warning_temp_time != 32'hffffffff)
                            warning_temp_time <= warning_temp_time + 32'd1;
                    end
                    else begin
                        warning_temp_seconds <= warning_temp_seconds + 6'd1;
                    end
                    if (aer_pending && feat_async_event_cfg[1] && !temp_event_latched) begin
                        aer_event_pending <= 1'b1;
                        aer_result <= AER_RESULT_SMART_TEMP;
                    end
                    temp_event_latched <= 1'b1;
                end
                else begin
                    warning_temp_seconds <= 6'd0;
                    temp_event_latched <= 1'b0;
                end

                if (composite_temperature() >= critical_temperature_threshold()) begin
                    if (critical_temp_seconds == 6'd59) begin
                        critical_temp_seconds <= 6'd0;
                        if (critical_temp_time != 32'hffffffff)
                            critical_temp_time <= critical_temp_time + 32'd1;
                    end
                    else begin
                        critical_temp_seconds <= critical_temp_seconds + 6'd1;
                    end
                end
                else begin
                    critical_temp_seconds <= 6'd0;
                end
            end
            else begin
                second_timer <= second_timer + 64'd1;
            end

            if (hour_timer >= (NVME_HOUR_TICKS - 64'd1)) begin
                hour_timer <= 64'h0000000000000000;
                if (power_on_hours != 32'hffffffff)
                    power_on_hours <= power_on_hours + 32'd1;
            end
            else begin
                hour_timer <= hour_timer + 64'd1;
            end

            if (tx_valid && tlps_dma_out.tready) begin
                if (tx_second_pending) begin
                    tx_data           <= tx_second_data;
                    tx_keepdw         <= tx_second_keepdw;
                    tx_last           <= tx_second_last;
                    tx_second_pending <= 1'b0;
                end
                else begin
                    tx_valid <= 1'b0;
                    tx_done  <= 1'b1;
                end
            end

            if (wr_valid && wr_is_msix_table) begin
                case (wr_off[3:2])
                    2'd0: msix_addr[wr_msix_vec][31:0]  <= merge_be(msix_addr[wr_msix_vec][31:0],  wr_data, wr_be);
                    2'd1: msix_addr[wr_msix_vec][63:32] <= merge_be(msix_addr[wr_msix_vec][63:32], wr_data, wr_be);
                    2'd2: msix_data[wr_msix_vec]        <= merge_be(msix_data[wr_msix_vec],        wr_data, wr_be);
                    2'd3: msix_vector_ctrl[wr_msix_vec] <= merge_be(msix_vector_ctrl[wr_msix_vec], wr_data, wr_be) & 32'h00000001;
                endcase
            end
            else if (wr_valid && wr_is_msix_pba) begin
                msix_pba <= msix_pba;
            end
            else if (wr_valid && wr_bar0_active_range) begin
                case (wr_off[13:2])
                    12'h003: intms <= intms | wr_data;
                    12'h004: intms <= intms & ~wr_data;
                    12'h005: begin
                        cc <= cc_next;
                        if (cc_next[0]) begin
                            if (!cc[0] && !cc_enable_cfg_ok) begin
                                csts[0] <= 1'b0;
                                csts[1] <= 1'b1;
                                ctrl_enable_pending <= 1'b0;
                                ctrl_enable_timer <= 16'd0;
                                state <= ST_IDLE;
                                stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                            end
                            else if (!cc[0]) begin
                                if (controller_seen_enable && (power_cycle_count != 32'hffffffff))
                                    power_cycle_count <= power_cycle_count + 32'd1;
                                controller_seen_enable <= 1'b1;
                                csts[0] <= 1'b0;
                                csts[3:1] <= 3'b000;
                                ctrl_enable_pending <= 1'b1;
                                ctrl_enable_timer <= 16'd0;
                            end
                            else if (cc_next[15:14] != 2'b00) begin
                                csts[3:2] <= 2'b10;
                                if (cc[15:14] == 2'b00)
                                    stat_shutdowns <= stat_shutdowns + 64'd1;
                            end
                            else begin
                                csts[3:2] <= 2'b00;
                            end
                        end
                        else begin
                            csts[0] <= 1'b0;
                            csts[1] <= 1'b0;
                            csts[3:2] <= 2'b00;
                            ctrl_enable_pending <= 1'b0;
                            ctrl_enable_timer <= 16'd0;
                            if (cc[0] && (cc[15:14] == 2'b00))
                                stat_unsafe_shutdowns <= stat_unsafe_shutdowns + 64'd1;
                            state <= ST_IDLE;
                            admin_sq_head <= 16'd0;
                            admin_sq_tail <= 16'd0;
                            admin_cq_tail <= 16'd0;
                            admin_cq_head_db <= 16'd0;
                            admin_cq_phase <= 1'b1;
                            io_sq_base <= 64'h0000000000000000;
                            io_cq_base <= 64'h0000000000000000;
                            io_sq_size <= 16'd1;
                            io_cq_size <= 16'd1;
                            io_sq_head <= 16'd0;
                            io_sq_tail <= 16'd0;
                            io_cq_tail <= 16'd0;
                            io_cq_head_db <= 16'd0;
                            io_cq_phase <= 1'b1;
                            io_enabled <= 1'b0;
                            io_sq_ready <= 1'b0;
                            io_cq_ready <= 1'b0;
                            io_cq_irq_enabled <= 1'b0;
                            io_cq_irq_vector <= 1'b0;
                            prp_list_active <= 1'b0;
                            cpl_expected <= 1'b0;
                            tx_valid <= 1'b0;
                            tx_second_pending <= 1'b0;
                            aer_pending <= 1'b0;
                            aer_event_pending <= 1'b0;
                            wait_timer <= 20'h00000;
                            cq_full_timer <= 20'h00000;
                            stat_queue_resets <= stat_queue_resets + 64'd1;
                        end
                    end
                    12'h009: begin
                        if (!cc[0])
                            aqa <= merge_be(aqa, wr_data, wr_be);
                        else
                            stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                    end
                    12'h00a: begin
                        if (!cc[0])
                            asq_lo <= merge_be(asq_lo, wr_data, wr_be);
                        else
                            stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                    end
                    12'h00b: begin
                        if (!cc[0])
                            asq_hi <= merge_be(asq_hi, wr_data, wr_be);
                        else
                            stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                    end
                    12'h00c: begin
                        if (!cc[0])
                            acq_lo <= merge_be(acq_lo, wr_data, wr_be);
                        else
                            stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                    end
                    12'h00d: begin
                        if (!cc[0])
                            acq_hi <= merge_be(acq_hi, wr_data, wr_be);
                        else
                            stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                    end
                    default: begin
                        if (wr_off[13:12] != 2'b00) begin
                            case (wr_off[11:2])
                                10'h000: begin
                                    if (wr_data[15:0] < admin_sq_size)
                                        admin_sq_tail <= wr_data[15:0];
                                    else
                                        stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                                end
                                10'h001: begin
                                    if (wr_data[15:0] < admin_cq_size) begin
                                        admin_cq_head_db <= wr_data[15:0];
                                        msix_pba[0]      <= 1'b0;
                                    end
                                    else begin
                                        stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                                    end
                                end
                                10'h002: begin
                                    if (io_sq_ready && (wr_data[15:0] < io_sq_size))
                                        io_sq_tail <= wr_data[15:0];
                                    else
                                        stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                                end
                                10'h003: begin
                                    if (io_cq_ready && (wr_data[15:0] < io_cq_size)) begin
                                        io_cq_head_db <= wr_data[15:0];
                                        msix_pba[io_cq_irq_vector] <= 1'b0;
                                    end
                                    else begin
                                        stat_invalid_cmds <= stat_invalid_cmds + 32'd1;
                                    end
                                end
                            endcase
                        end
                    end
                endcase
            end

            rd_req_ctx_1   <= rd_req_ctx;
            rd_req_data_1  <= rd_bar0_active_range ? nvme_reg_read(rd_off) : 32'h00000000;
            rd_req_valid_1 <= rd_req_valid;
            rd_rsp_ctx     <= rd_req_ctx_1;
            rd_rsp_data    <= rd_req_data_1;
            rd_rsp_valid   <= rd_req_valid_1;

            if (!cc_en_effective || !controller_ready) begin
                state <= ST_IDLE;
            end
            else begin
            case (state)
                ST_IDLE: begin
                    if (msix_enable && !msix_function_mask &&
                        msix_pba[0] && !msix_vector_ctrl[0][0] &&
                        (msix_addr[0] != 64'h0000000000000000)) begin
                        irq_vector <= 1'b0;
                        state <= ST_IRQ_REQ;
                    end
                    else if (msix_enable && !msix_function_mask &&
                             msix_pba[1] && !msix_vector_ctrl[1][0] &&
                             (msix_addr[1] != 64'h0000000000000000)) begin
                        irq_vector <= 1'b1;
                        state <= ST_IRQ_REQ;
                    end
                    else if (aer_pending && aer_event_pending) begin
                        cqe_result  <= aer_result;
                        cqe_status  <= NVME_SC_SUCCESS;
                        cqe_cid     <= aer_cid;
                        cqe_qid     <= 1'b0;
                        cqe_sq_head <= aer_sq_head;
                        cqe_idx     <= 2'd0;
                        aer_pending <= 1'b0;
                        aer_event_pending <= 1'b0;
                        state <= ST_CQE_REQ;
                    end
                    else if (admin_sq_head != admin_sq_tail) begin
                        current_qid <= 1'b0;
                        fetch_base  <= {asq_hi, asq_lo} + ({48'h0, admin_sq_head} << 6);
                        fetch_idx   <= 16'd0;
                        state       <= ST_FETCH_REQ;
                    end
                    else if (io_enabled && io_sq_ready && io_cq_ready && (io_sq_head != io_sq_tail)) begin
                        current_qid <= 1'b1;
                        fetch_base  <= io_sq_base + ({48'h0, io_sq_head} << 6);
                        fetch_idx   <= 16'd0;
                        state       <= ST_FETCH_REQ;
                    end
                end

                ST_FETCH_REQ: begin
                    if (!tx_valid) begin
                        start_mrd1(fetch_base + ({48'h0, fetch_idx} << 2), DMA_TAG);
                        wait_timer <= 20'h00000;
                        state <= ST_FETCH_WAIT;
                    end
                end

                ST_FETCH_WAIT: begin
                    if (cpl_error) begin
                        cpl_expected <= 1'b0;
                        cqe_result <= 32'h00000000;
                        cqe_status <= NVME_SC_DATA_XFER_ERR;
                        cqe_cid <= (fetch_idx == 16'd0) ? 16'h0000 : cmd_cid;
                        cqe_qid <= current_qid;
                        cqe_sq_head <= current_qid ? io_sq_head_next : admin_sq_head_next;
                        cqe_idx <= 2'd0;
                        if (current_qid)
                            io_sq_head <= io_sq_head_next;
                        else
                            admin_sq_head <= admin_sq_head_next;
                        stat_cpl_errors <= stat_cpl_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_CQE_REQ;
                    end
                    else if (cpl_valid) begin
                        cpl_expected <= 1'b0;
                        cmd_dw[fetch_idx[3:0]] <= cpl_data;
                        if (fetch_idx == 16'd15) begin
                            state <= ST_PROCESS;
                        end
                        else begin
                            fetch_idx <= fetch_idx + 16'd1;
                            state <= ST_FETCH_REQ;
                        end
                    end
                    else if (wait_timer >= DMA_TIMEOUT_CLKS) begin
                        cpl_expected <= 1'b0;
                        cqe_result <= 32'h00000000;
                        cqe_status <= NVME_SC_DATA_XFER_ERR;
                        cqe_cid <= (fetch_idx == 16'd0) ? 16'h0000 : cmd_cid;
                        cqe_qid <= current_qid;
                        cqe_sq_head <= current_qid ? io_sq_head_next : admin_sq_head_next;
                        cqe_idx <= 2'd0;
                        if (current_qid)
                            io_sq_head <= io_sq_head_next;
                        else
                            admin_sq_head <= admin_sq_head_next;
                        stat_timeout_errors <= stat_timeout_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_CQE_REQ;
                    end
                    else begin
                        wait_timer <= wait_timer + 20'd1;
                    end
                end

                ST_PROCESS: begin
                    cqe_result  <= 32'h00000000;
                    cqe_status  <= NVME_SC_SUCCESS;
                    cqe_cid     <= cmd_cid;
                    cqe_qid     <= current_qid;
                    cqe_idx     <= 2'd0;

                    if (!current_qid) begin
                        admin_sq_head <= admin_sq_head_next;
                        cqe_sq_head   <= admin_sq_head_next;
                        case (cmd_opcode)
                            8'h01: begin
                                if (cmd_dw[10][15:0] != 16'd1) begin
                                    cqe_status <= NVME_SC_INVALID_QID;
                                    record_error(NVME_SC_INVALID_QID, 1'b0);
                                end
                                else if ((cmd_dw[10][31:16] == 16'h0000) ||
                                         (cmd_dw[10][31:16] > 16'd63)) begin
                                    cqe_status <= NVME_SC_MAX_Q_SIZE;
                                    record_error(NVME_SC_MAX_Q_SIZE, 1'b0);
                                end
                                else if (!io_cq_ready || (cmd_dw[11][31:16] != 16'd1)) begin
                                    cqe_status <= NVME_SC_CQ_INVALID;
                                    record_error(NVME_SC_CQ_INVALID, 1'b0);
                                end
                                else if (io_sq_ready) begin
                                    cqe_status <= NVME_SC_QID_CONFLICT;
                                    record_error(NVME_SC_QID_CONFLICT, 1'b0);
                                end
                                else if ((!cmd_dw[11][0]) ||
                                         (cmd_dw[11][2:1] != 2'b00) ||
                                         (cmd_dw[11][15:3] != 13'd0) ||
                                         (cmd_prp1[11:0] != 12'h000)) begin
                                    cqe_status <= NVME_SC_INVALID_FIELD;
                                    record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                end
                                else begin
                                    io_sq_base   <= cmd_prp1;
                                    io_sq_size   <= cmd_dw[10][31:16] + 16'd1;
                                    io_sq_head   <= 16'd0;
                                    io_sq_tail   <= 16'd0;
                                    io_cq_tail   <= 16'd0;
                                    io_sq_ready  <= 1'b1;
                                    io_enabled   <= io_cq_ready;
                                end
                                state        <= ST_CQE_REQ;
                            end
                            8'h05: begin
                                if (cmd_dw[10][15:0] != 16'd1) begin
                                    cqe_status <= NVME_SC_INVALID_QID;
                                    record_error(NVME_SC_INVALID_QID, 1'b0);
                                end
                                else if ((cmd_dw[10][31:16] == 16'h0000) ||
                                         (cmd_dw[10][31:16] > 16'd63)) begin
                                    cqe_status <= NVME_SC_MAX_Q_SIZE;
                                    record_error(NVME_SC_MAX_Q_SIZE, 1'b0);
                                end
                                else if (cmd_dw[11][31:16] > 16'd1) begin
                                    cqe_status <= NVME_SC_INVALID_IRQ_VECTOR;
                                    record_error(NVME_SC_INVALID_IRQ_VECTOR, 1'b0);
                                end
                                else if (io_cq_ready) begin
                                    cqe_status <= NVME_SC_QID_CONFLICT;
                                    record_error(NVME_SC_QID_CONFLICT, 1'b0);
                                end
                                else if ((!cmd_dw[11][0]) ||
                                         (cmd_dw[11][15:2] != 14'd0) ||
                                         (cmd_prp1[11:0] != 12'h000)) begin
                                    cqe_status <= NVME_SC_INVALID_FIELD;
                                    record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                end
                                else begin
                                    io_cq_base   <= cmd_prp1;
                                    io_cq_size   <= cmd_dw[10][31:16] + 16'd1;
                                    io_cq_tail   <= 16'd0;
                                    io_cq_head_db<= 16'd0;
                                    io_cq_phase  <= 1'b1;
                                    io_cq_ready  <= 1'b1;
                                    io_cq_irq_enabled <= cmd_dw[11][1];
                                    io_cq_irq_vector  <= cmd_dw[11][16];
                                    io_enabled   <= io_sq_ready;
                                end
                                state        <= ST_CQE_REQ;
                            end
                            8'h06: begin
                                if (((cmd_dw[10][7:0] == 8'h00) && (cmd_nsid != 32'd1)) ||
                                    (cmd_dw[10][7:0] > 8'h02)) begin
                                    cqe_status <= NVME_SC_INVALID_FIELD;
                                    record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                    state <= ST_CQE_REQ;
                                end
                                else begin
                                    xfer_prp1    <= cmd_prp1;
                                    xfer_prp2    <= cmd_prp2;
                                    xfer_idx     <= 20'd0;
                                    xfer_total_dw<= 20'd1024;
                                    case (cmd_dw[10][7:0])
                                        8'h00: xfer_payload <= PAYLOAD_IDENT_NS;
                                        8'h01: xfer_payload <= PAYLOAD_IDENT_CTL;
                                        8'h02: xfer_payload <= PAYLOAD_IDENT_LST;
                                    endcase
                                    prepare_prp_transfer(cmd_prp1, cmd_prp2, 20'd1024, ST_HOST_WRITE_REQ);
                                end
                            end
                            8'h02: begin
                                xfer_prp1     <= cmd_prp1;
                                xfer_prp2     <= cmd_prp2;
                                xfer_idx      <= 20'd0;
                                xfer_total_dw <= admin_log_dw_count(cmd_dw[10], cmd_dw[11]);
                                case (cmd_dw[10][7:0])
                                    LOG_PAGE_SUPPORTED: begin
                                        xfer_payload <= PAYLOAD_LOG_PAGES;
                                        prepare_prp_transfer(cmd_prp1, cmd_prp2, admin_log_dw_count(cmd_dw[10], cmd_dw[11]), ST_HOST_WRITE_REQ);
                                    end
                                    LOG_PAGE_ERROR: begin
                                        xfer_payload <= PAYLOAD_ERROR_LOG;
                                        prepare_prp_transfer(cmd_prp1, cmd_prp2, admin_log_dw_count(cmd_dw[10], cmd_dw[11]), ST_HOST_WRITE_REQ);
                                    end
                                    LOG_PAGE_SMART: begin
                                        if ((cmd_nsid == 32'd1) || (cmd_nsid == 32'hffffffff)) begin
                                            xfer_payload <= PAYLOAD_SMART_LOG;
                                            prepare_prp_transfer(cmd_prp1, cmd_prp2, admin_log_dw_count(cmd_dw[10], cmd_dw[11]), ST_HOST_WRITE_REQ);
                                        end
                                        else begin
                                            cqe_status <= NVME_SC_INVALID_NS;
                                            record_error(NVME_SC_INVALID_NS, 1'b0);
                                            state <= ST_CQE_REQ;
                                        end
                                    end
                                    LOG_PAGE_FW_SLOT: begin
                                        xfer_payload <= PAYLOAD_FW_SLOT_LOG;
                                        prepare_prp_transfer(cmd_prp1, cmd_prp2, admin_log_dw_count(cmd_dw[10], cmd_dw[11]), ST_HOST_WRITE_REQ);
                                    end
`ifdef NVME_ENABLE_VENDOR_LOG
                                    LOG_PAGE_VENDOR_C0: begin
                                        xfer_payload <= PAYLOAD_VENDOR_LOG;
                                        prepare_prp_transfer(cmd_prp1, cmd_prp2, admin_log_dw_count(cmd_dw[10], cmd_dw[11]), ST_HOST_WRITE_REQ);
                                    end
`endif
                                    default: begin
                                        cqe_status <= NVME_SC_INVALID_LOG_PAGE;
                                        record_error(NVME_SC_INVALID_LOG_PAGE, 1'b0);
                                        state <= ST_CQE_REQ;
                                    end
                                endcase
                            end
                            8'h09: begin
                                case (cmd_dw[10][7:0])
                                    8'h01: feat_arbitration    <= cmd_dw[11];
                                    8'h02: begin
                                        if (((cmd_dw[11] & 32'hffffff00) != 32'h00000000) ||
                                            (cmd_dw[11][4:0] > `NVME_POWER_STATE_MAX)) begin
                                            cqe_status <= NVME_SC_INVALID_FIELD;
                                            record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                        end
                                        else begin
                                            feat_power_mgmt <= cmd_dw[11] & 32'h000000ff;
                                        end
                                    end
                                    8'h04: begin
                                        if ((cmd_dw[11][31:16] != 16'h0000) ||
                                            (cmd_dw[11][15:0] < 16'd250) ||
                                            (cmd_dw[11][15:0] > 16'd430)) begin
                                            cqe_status <= NVME_SC_INVALID_FIELD;
                                            record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                        end
                                        else begin
                                            feat_temp_threshold <= {16'h0000, cmd_dw[11][15:0]};
                                        end
                                    end
                                    8'h06: begin
                                        if ((cmd_dw[11] & 32'hfffffffe) != 32'h00000000) begin
                                            cqe_status <= NVME_SC_INVALID_FIELD;
                                            record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                        end
                                        else begin
                                            feat_write_cache <= cmd_dw[11] & 32'h00000001;
                                        end
                                    end
                                    8'h07: cqe_result          <= 32'h00000000;
                                    8'h08: begin
                                        if (cmd_dw[11] != 32'h00000000) begin
                                            cqe_status <= NVME_SC_INVALID_FIELD;
                                            record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                        end
                                    end
                                    8'h09: begin
                                        if (((cmd_dw[11] & 32'hffff0000) != 32'h00000000) ||
                                            (cmd_dw[11][15:0] > 16'd1)) begin
                                            cqe_status <= NVME_SC_INVALID_FIELD;
                                            record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                        end
                                        else begin
                                            feat_irq_vector_cfg <= cmd_dw[11];
                                        end
                                    end
                                    8'h0b: begin
                                        if ((cmd_dw[11] & 32'hfffffffc) != 32'h00000000) begin
                                            cqe_status <= NVME_SC_INVALID_FIELD;
                                            record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                        end
                                        else begin
                                            feat_async_event_cfg <= cmd_dw[11] & 32'h00000003;
                                        end
                                    end
                                    default: begin
                                        cqe_status <= NVME_SC_INVALID_FIELD;
                                        record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                    end
                                endcase
                                state <= ST_CQE_REQ;
                            end
                            8'h08: begin
                                if (cmd_dw[10][15:0] > 16'd1) begin
                                    cqe_status <= NVME_SC_INVALID_QID;
                                    record_error(NVME_SC_INVALID_QID, 1'b0);
                                end
                                else if ((cmd_dw[11] != 32'h00000000) ||
                                         (cmd_dw[12] != 32'h00000000) ||
                                         (cmd_dw[13] != 32'h00000000) ||
                                         (cmd_dw[14] != 32'h00000000) ||
                                         (cmd_dw[15] != 32'h00000000)) begin
                                    cqe_status <= NVME_SC_INVALID_FIELD;
                                    record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                end
                                else begin
                                    cqe_result <= 32'h00000001;
                                end
                                state <= ST_CQE_REQ;
                            end
                            8'h0a: begin
                                case (cmd_dw[10][7:0])
                                    8'h01: cqe_result <= feat_arbitration;
                                    8'h02: cqe_result <= feat_power_mgmt;
                                    8'h04: cqe_result <= feat_temp_threshold;
                                    8'h06: cqe_result <= feat_write_cache;
                                    8'h07: cqe_result <= 32'h00000000;
                                    8'h08: cqe_result <= feat_irq_coalescing;
                                    8'h09: cqe_result <= feat_irq_vector_cfg;
                                    8'h0a: cqe_result <= 32'h00000000;
                                    8'h0b: cqe_result <= feat_async_event_cfg;
                                    default: begin
                                        cqe_result <= 32'h00000000;
                                        cqe_status <= NVME_SC_INVALID_FIELD;
                                        record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                    end
                                endcase
                                state <= ST_CQE_REQ;
                            end
                            8'h80: begin
                                if ((cmd_nsid != 32'd1) ||
                                    (cmd_dw[10][3:0] != 4'h0) ||
                                    (cmd_dw[10][8:5] != 4'h0) ||
                                    (cmd_dw[10][31:9] != 23'h000000) ||
                                    (cmd_dw[11] != 32'h00000000) ||
                                    (cmd_dw[12] != 32'h00000000) ||
                                    (cmd_dw[13] != 32'h00000000) ||
                                    (cmd_dw[14] != 32'h00000000) ||
                                    (cmd_dw[15] != 32'h00000000)) begin
                                    cqe_status <= NVME_SC_INVALID_FORMAT;
                                    record_error(NVME_SC_INVALID_FORMAT, 1'b0);
                                    state <= ST_CQE_REQ;
                                end
                                else begin
                                    stat_format_cmds <= stat_format_cmds + 64'd1;
                                    clear_idx      <= {BACKING_INDEX_BITS+1{1'b0}};
                                    clear_total_dw <= BACKING_COUNT;
                                    state          <= ST_FORMAT_CLEAR;
                                end
                            end
                            8'h0c: begin
                                if (aer_pending) begin
                                    cqe_status <= NVME_SC_AER_LIMIT;
                                    record_error(NVME_SC_AER_LIMIT, 1'b0);
                                    state <= ST_CQE_REQ;
                                end
                                else begin
                                    aer_pending <= 1'b1;
                                    aer_cid <= cmd_cid;
                                    aer_sq_head <= admin_sq_head_next;
                                    if (feat_async_event_cfg[1] &&
                                        (composite_temperature() >= warning_temperature_threshold())) begin
                                        aer_result <= AER_RESULT_SMART_TEMP;
                                        aer_event_pending <= 1'b1;
                                    end
                                    else if (feat_async_event_cfg[1] &&
                                             (stat_media_errors != 32'h00000000)) begin
                                        aer_result <= AER_RESULT_SMART_MEDIA;
                                        aer_event_pending <= 1'b1;
                                    end
                                    else if (feat_async_event_cfg[0] &&
                                             (stat_error_log_entries != 32'h00000000)) begin
                                        aer_result <= AER_RESULT_ERROR_LOG;
                                        aer_event_pending <= 1'b1;
                                    end
                                    else begin
                                        aer_result <= AER_RESULT_ERROR_LOG;
                                        aer_event_pending <= 1'b0;
                                    end
                                    state <= ST_IDLE;
                                end
                            end
                            8'h00: begin
                                if (cmd_dw[10][15:0] != 16'd1) begin
                                    cqe_status <= NVME_SC_INVALID_QID;
                                    record_error(NVME_SC_INVALID_QID, 1'b0);
                                end
                                else if (!io_sq_ready) begin
                                    cqe_status <= NVME_SC_QUEUE_NOT_CREATED;
                                    record_error(NVME_SC_QUEUE_NOT_CREATED, 1'b0);
                                end
                                else begin
                                    io_sq_base <= 64'h0000000000000000;
                                    io_sq_size <= 16'd1;
                                    io_sq_head <= 16'd0;
                                    io_sq_tail <= 16'd0;
                                    io_cq_tail <= 16'd0;
                                    io_sq_ready <= 1'b0;
                                    io_enabled <= 1'b0;
                                    stat_queue_resets <= stat_queue_resets + 64'd1;
                                end
                                state <= ST_CQE_REQ;
                            end
                            8'h04: begin
                                if (cmd_dw[10][15:0] != 16'd1) begin
                                    cqe_status <= NVME_SC_INVALID_QID;
                                    record_error(NVME_SC_INVALID_QID, 1'b0);
                                end
                                else if (!io_cq_ready) begin
                                    cqe_status <= NVME_SC_QUEUE_NOT_CREATED;
                                    record_error(NVME_SC_QUEUE_NOT_CREATED, 1'b0);
                                end
                                else if (io_sq_ready) begin
                                    cqe_status <= NVME_SC_CMD_SEQ_ERR;
                                    record_error(NVME_SC_CMD_SEQ_ERR, 1'b0);
                                end
                                else begin
                                    io_cq_base  <= 64'h0000000000000000;
                                    io_cq_size  <= 16'd1;
                                    io_cq_tail  <= 16'd0;
                                    io_cq_head_db <= 16'd0;
                                    io_cq_phase <= 1'b1;
                                    io_cq_ready <= 1'b0;
                                    io_cq_irq_enabled <= 1'b0;
                                    io_cq_irq_vector <= 1'b0;
                                    io_enabled  <= 1'b0;
                                    stat_queue_resets <= stat_queue_resets + 64'd1;
                                end
                                state <= ST_CQE_REQ;
                            end
                            default: begin
                                cqe_status <= NVME_SC_INVALID_OPC;
                                record_error(NVME_SC_INVALID_OPC, 1'b0);
                                state      <= ST_CQE_REQ;
                            end
                        endcase
                    end
                    else begin
                        io_sq_head <= io_sq_head_next;
                        cqe_sq_head <= io_sq_head_next;
                        case (cmd_opcode)
                            8'h00: begin
                                if (((cmd_nsid == 32'd1) || (cmd_nsid == 32'hffffffff)) &&
                                    (cmd_dw[10] == 32'h00000000) &&
                                    (cmd_dw[11] == 32'h00000000) &&
                                    (cmd_dw[12] == 32'h00000000) &&
                                    (cmd_dw[13] == 32'h00000000) &&
                                    (cmd_dw[14] == 32'h00000000) &&
                                    (cmd_dw[15] == 32'h00000000)) begin
                                    stat_flush_cmds <= stat_flush_cmds + 64'd1;
                                    if (thermal_load < 8'hf0)
                                        thermal_load <= thermal_load + 8'd1;
                                end
                                else begin
                                    cqe_status <= (cmd_nsid == 32'd1) || (cmd_nsid == 32'hffffffff) ?
                                                  NVME_SC_INVALID_FIELD :
                                                  NVME_SC_INVALID_NS;
                                    record_error(
                                        ((cmd_nsid == 32'd1) || (cmd_nsid == 32'hffffffff)) ?
                                        NVME_SC_INVALID_FIELD :
                                        NVME_SC_INVALID_NS,
                                        1'b0
                                    );
                                end
                                state <= ST_CQE_REQ;
                            end
                            8'h01: begin
                                if (cmd_lba_ok) begin
                                    stat_host_write_cmds <= stat_host_write_cmds + 64'd1;
                                    stat_data_units_written <= stat_data_units_written + 64'd1;
                                    if (thermal_load < 8'he0)
                                        thermal_load <= thermal_load + 8'd2;
                                    xfer_prp1     <= cmd_prp1;
                                    xfer_prp2     <= cmd_prp2;
                                    xfer_idx      <= 20'd0;
                                    xfer_total_dw <= cmd_io_dw;
                                    prepare_prp_transfer(cmd_prp1, cmd_prp2, cmd_io_dw, ST_HOST_READ_REQ);
                                end
                                else begin
                                    cqe_status <= cmd_lba_status;
                                    record_error(cmd_lba_status, 1'b0);
                                    state      <= ST_CQE_REQ;
                                end
                            end
                            8'h02: begin
                                if (cmd_lba_ok) begin
                                    stat_host_read_cmds <= stat_host_read_cmds + 64'd1;
                                    stat_data_units_read <= stat_data_units_read + 64'd1;
                                    if (thermal_load < 8'he0)
                                        thermal_load <= thermal_load + 8'd2;
                                    xfer_prp1     <= cmd_prp1;
                                    xfer_prp2     <= cmd_prp2;
                                    xfer_idx      <= 20'd0;
                                    xfer_total_dw <= cmd_io_dw;
                                    xfer_payload  <= PAYLOAD_DISK;
                                    prepare_prp_transfer(cmd_prp1, cmd_prp2, cmd_io_dw, ST_DISK_READ);
                                end
                                else begin
                                    cqe_status <= cmd_lba_status;
                                    record_error(cmd_lba_status, 1'b0);
                                    state      <= ST_CQE_REQ;
                                end
                            end
                            8'h08: begin
                                if ((cmd_dw[12][31:16] != 16'h0000) ||
                                    (cmd_dw[13] != 32'h00000000) ||
                                    (cmd_dw[14] != 32'h00000000) ||
                                    (cmd_dw[15] != 32'h00000000)) begin
                                    cqe_status <= NVME_SC_INVALID_FIELD;
                                    record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                    state <= ST_CQE_REQ;
                                end
                                else if (cmd_lba_ok) begin
                                    stat_write_zero_cmds <= stat_write_zero_cmds + 64'd1;
                                    if (thermal_load < 8'he0)
                                        thermal_load <= thermal_load + 8'd2;
                                    clear_idx      <= {BACKING_INDEX_BITS+1{1'b0}};
                                    clear_total_dw <= cmd_io_dw[BACKING_INDEX_BITS:0];
                                    state          <= ST_ZERO_CLEAR;
                                end
                                else begin
                                    cqe_status <= cmd_lba_status;
                                    record_error(cmd_lba_status, 1'b0);
                                    state      <= ST_CQE_REQ;
                                end
                            end
                            8'h09: begin
                                if (cmd_nsid == 32'd1) begin
                                    stat_dataset_cmds <= stat_dataset_cmds + 64'd1;
                                    if (((cmd_dw[11] & 32'hfffffffb) != 32'h00000000) ||
                                        (cmd_dw[10][31:8] != 24'h000000)) begin
                                        cqe_status <= NVME_SC_INVALID_FIELD;
                                        record_error(NVME_SC_INVALID_FIELD, 1'b0);
                                        state <= ST_CQE_REQ;
                                    end
                                    else if (cmd_dw[11][2]) begin
                                        xfer_prp1       <= cmd_prp1;
                                        xfer_prp2       <= cmd_prp2;
                                        prp_list_active <= 1'b0;
                                        dsm_range_idx   <= 8'h00;
                                        dsm_range_last  <= cmd_dw[10][7:0];
                                        dsm_dw_idx      <= 2'h0;
                                        prepare_prp_transfer(
                                            cmd_prp1,
                                            cmd_prp2,
                                            (({12'h000, cmd_dw[10][7:0]} + 20'd1) << 2),
                                            ST_DSM_FETCH_REQ
                                        );
                                    end
                                    else begin
                                        state <= ST_CQE_REQ;
                                    end
                                end
                                else begin
                                    cqe_status <= NVME_SC_INVALID_NS;
                                    record_error(NVME_SC_INVALID_NS, 1'b0);
                                    state      <= ST_CQE_REQ;
                                end
                            end
                            default: begin
                                cqe_status <= NVME_SC_INVALID_OPC;
                                record_error(NVME_SC_INVALID_OPC, 1'b0);
                                state      <= ST_CQE_REQ;
                            end
                        endcase
                    end
                end

                ST_PRP_LIST_REQ: begin
                    if (!tx_valid) begin
                        start_mrd1(cmd_prp2 + ({{(63-PRP_LIST_BITS){1'b0}}, prp_fetch_idx, prp_fetch_dw} << 2), DMA_TAG);
                        wait_timer <= 20'h00000;
                        state <= ST_PRP_LIST_WAIT;
                    end
                end

                ST_PRP_LIST_WAIT: begin
                    if (cpl_error) begin
                        cpl_expected <= 1'b0;
                        cqe_status <= NVME_SC_DATA_XFER_ERR;
                        stat_cpl_errors <= stat_cpl_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_CQE_REQ;
                    end
                    else if (cpl_valid) begin
                        cpl_expected <= 1'b0;
                        if (!prp_fetch_dw) begin
                            prp_list[prp_fetch_idx][31:0] <= cpl_data;
                            prp_fetch_dw <= 1'b1;
                            state <= ST_PRP_LIST_REQ;
                        end
                        else begin
                            prp_list[prp_fetch_idx][63:32] <= cpl_data;
                            prp_fetch_dw <= 1'b0;
                            stat_prp_list_fetches <= stat_prp_list_fetches + 64'd1;
                            if (prp_list_entry_invalid({cpl_data, prp_list[prp_fetch_idx][31:0]})) begin
                                cqe_status <= NVME_SC_PRP_OFFSET_INVALID;
                                record_error(NVME_SC_PRP_OFFSET_INVALID, 1'b0);
                                state <= ST_CQE_REQ;
                            end
                            else if (prp_fetch_idx == prp_fetch_last) begin
                                state <= xfer_after_prp_state;
                            end
                            else begin
                                prp_fetch_idx <= prp_fetch_idx + {{(PRP_LIST_BITS-1){1'b0}}, 1'b1};
                                state <= ST_PRP_LIST_REQ;
                            end
                        end
                    end
                    else if (wait_timer >= DMA_TIMEOUT_CLKS) begin
                        cpl_expected <= 1'b0;
                        cqe_status <= NVME_SC_DATA_XFER_ERR;
                        stat_timeout_errors <= stat_timeout_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_CQE_REQ;
                    end
                    else begin
                        wait_timer <= wait_timer + 20'd1;
                    end
                end

                ST_HOST_WRITE_REQ: begin
                    if (!tx_valid) begin
                        dma_addr_stage <= prp_addr(xfer_prp1, xfer_prp2, xfer_idx);
                        dma_data_stage <= payload_word(xfer_payload, xfer_idx);
                        state <= ST_HOST_WRITE_ADDR;
                    end
                end

                ST_HOST_WRITE_ADDR: begin
                    if (!tx_valid) begin
                        start_mwr1(dma_addr_stage, dma_data_stage);
                        wait_timer <= 20'h00000;
                        state <= ST_HOST_WRITE_WAIT;
                    end
                end

                ST_HOST_WRITE_WAIT: begin
                    if (tx_done) begin
                        if ((xfer_idx + 20'd1) >= xfer_total_dw) begin
                            state <= ST_CQE_REQ;
                        end
                        else begin
                            xfer_idx <= xfer_idx + 20'd1;
                            state <= (xfer_payload == PAYLOAD_DISK) ? ST_DISK_READ : ST_HOST_WRITE_REQ;
                        end
                    end
                    else if (wait_timer >= DMA_TIMEOUT_CLKS) begin
                        cqe_status <= NVME_SC_DATA_XFER_ERR;
                        stat_timeout_errors <= stat_timeout_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_CQE_REQ;
                    end
                    else begin
                        wait_timer <= wait_timer + 20'd1;
                    end
                end

                ST_DISK_READ: begin
                    state <= ST_HOST_WRITE_REQ;
                end

                ST_HOST_READ_REQ: begin
                    if (!tx_valid) begin
                        dma_addr_stage <= prp_addr(xfer_prp1, xfer_prp2, xfer_idx);
                        state <= ST_HOST_READ_ADDR;
                    end
                end

                ST_HOST_READ_ADDR: begin
                    if (!tx_valid) begin
                        start_mrd1(dma_addr_stage, DMA_TAG);
                        wait_timer <= 20'h00000;
                        state <= ST_HOST_READ_WAIT;
                    end
                end

                ST_HOST_READ_WAIT: begin
                    if (cpl_error) begin
                        cpl_expected <= 1'b0;
                        cqe_status <= NVME_SC_DATA_XFER_ERR;
                        stat_cpl_errors <= stat_cpl_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_CQE_REQ;
                    end
                    else if (cpl_valid) begin
                        cpl_expected <= 1'b0;
                        if ((backing_store_word_off == 7'h00) &&
                            block_valid[backing_store_slot] &&
                            (block_tag[backing_store_slot] != backing_store_lba)) begin
                            stat_backend_evictions <= stat_backend_evictions + 64'd1;
                        end
                        block_valid[backing_store_slot] <= 1'b1;
                        block_tag[backing_store_slot] <= backing_store_lba;
                        if ((xfer_idx + 20'd1) >= xfer_total_dw) begin
                            state <= ST_CQE_REQ;
                        end
                        else begin
                            xfer_idx <= xfer_idx + 20'd1;
                            state <= ST_HOST_READ_REQ;
                        end
                    end
                    else if (wait_timer >= DMA_TIMEOUT_CLKS) begin
                        cpl_expected <= 1'b0;
                        cqe_status <= NVME_SC_DATA_XFER_ERR;
                        stat_timeout_errors <= stat_timeout_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_CQE_REQ;
                    end
                    else begin
                        wait_timer <= wait_timer + 20'd1;
                    end
                end

                ST_FORMAT_CLEAR: begin
                    if (clear_idx[6:0] == 7'h00) begin
                        block_valid[clear_idx[BACKING_INDEX_BITS-1:7]] <= 1'b0;
                        block_tag[clear_idx[BACKING_INDEX_BITS-1:7]] <= 64'h0000000000000000;
                    end
                    if ((clear_idx + BACKING_ONE) >= clear_total_dw) begin
                        state <= ST_CQE_REQ;
                    end
                    else begin
                        clear_idx <= clear_idx + BACKING_ONE;
                    end
                end

                ST_ZERO_CLEAR: begin
                    if ((backing_zero_word_off == 7'h00) &&
                        block_valid[backing_zero_slot] &&
                        (block_tag[backing_zero_slot] != backing_zero_lba)) begin
                        stat_backend_evictions <= stat_backend_evictions + 64'd1;
                    end
                    block_valid[backing_zero_slot] <= 1'b1;
                    block_tag[backing_zero_slot] <= backing_zero_lba;
                    if ((clear_idx + BACKING_ONE) >= clear_total_dw) begin
                        state <= ST_CQE_REQ;
                    end
                    else begin
                        clear_idx <= clear_idx + BACKING_ONE;
                    end
                end

                ST_DSM_FETCH_REQ: begin
                    if (!tx_valid) begin
                        dma_addr_stage <= prp_addr(xfer_prp1, xfer_prp2, {10'h000, dsm_range_idx, dsm_dw_idx});
                        state <= ST_DSM_FETCH_ADDR;
                    end
                end

                ST_DSM_FETCH_ADDR: begin
                    if (!tx_valid) begin
                        start_mrd1(dma_addr_stage, DMA_TAG);
                        wait_timer <= 20'h00000;
                        state <= ST_DSM_FETCH_WAIT;
                    end
                end

                ST_DSM_FETCH_WAIT: begin
                    if (cpl_error) begin
                        cpl_expected <= 1'b0;
                        cqe_status <= NVME_SC_DATA_XFER_ERR;
                        stat_cpl_errors <= stat_cpl_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_CQE_REQ;
                    end
                    else if (cpl_valid) begin
                        cpl_expected <= 1'b0;
                        case (dsm_dw_idx)
                            2'd0: begin
                                dsm_dw0    <= cpl_data;
                                dsm_dw_idx <= 2'd1;
                                state      <= ST_DSM_FETCH_REQ;
                            end
                            2'd1: begin
                                dsm_dw1    <= cpl_data;
                                dsm_dw_idx <= 2'd2;
                                state      <= ST_DSM_FETCH_REQ;
                            end
                            2'd2: begin
                                dsm_dw2    <= cpl_data;
                                dsm_dw_idx <= 2'd3;
                                state      <= ST_DSM_FETCH_REQ;
                            end
                            default: begin
                                dsm_lba          <= {cpl_data, dsm_dw2};
                                dsm_range_blocks <= dsm_dw1;
                                dsm_range_empty  <= (dsm_dw1 == 32'h00000000);
                                state            <= ST_DSM_VALIDATE_0;
                            end
                        endcase
                    end
                    else if (wait_timer >= DMA_TIMEOUT_CLKS) begin
                        cpl_expected <= 1'b0;
                        cqe_status <= NVME_SC_DATA_XFER_ERR;
                        stat_timeout_errors <= stat_timeout_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_CQE_REQ;
                    end
                    else begin
                        wait_timer <= wait_timer + 20'd1;
                    end
                end

                ST_DSM_VALIDATE_0: begin
                    dsm_lba_in_range   <= (dsm_lba < DISK_LBAS);
                    dsm_disk_remaining <= DISK_LBAS - dsm_lba;
                    dsm_lba_limit      <= dsm_lba + {32'h00000000, dsm_range_blocks};
                    state              <= ST_DSM_VALIDATE_1;
                end

                ST_DSM_VALIDATE_1: begin
                    dsm_range_ok_stage <= dsm_lba_in_range && (dsm_range_blocks <= dsm_disk_remaining[31:0]);
                    state              <= ST_DSM_VALIDATE_2;
                end

                ST_DSM_VALIDATE_2: begin
                    if (dsm_range_empty) begin
                        if (dsm_range_idx == dsm_range_last) begin
                            state <= ST_CQE_REQ;
                        end
                        else begin
                            dsm_range_idx <= dsm_range_idx + 8'd1;
                            dsm_dw_idx    <= 2'd0;
                            state         <= ST_DSM_FETCH_REQ;
                        end
                    end
                    else if (dsm_range_ok_stage) begin
                        clear_idx <= {BACKING_INDEX_BITS+1{1'b0}};
                        state     <= ST_DSM_INVALIDATE;
                    end
                    else begin
                        cqe_status <= NVME_SC_LBA_RANGE;
                        record_error(NVME_SC_LBA_RANGE, 1'b0);
                        stat_last_error_lba <= dsm_lba;
                        state      <= ST_CQE_REQ;
                    end
                end

                ST_DSM_INVALIDATE: begin
                    if (block_valid[clear_idx[BACKING_SLOT_BITS-1:0]] &&
                        (block_tag[clear_idx[BACKING_SLOT_BITS-1:0]] >= dsm_lba) &&
                        (block_tag[clear_idx[BACKING_SLOT_BITS-1:0]] < dsm_lba_limit)) begin
                        block_valid[clear_idx[BACKING_SLOT_BITS-1:0]] <= 1'b0;
                        block_tag[clear_idx[BACKING_SLOT_BITS-1:0]]   <= 64'h0000000000000000;
                    end
                    if ((clear_idx + BACKING_ONE) >= BACKING_SLOT_COUNT) begin
                        if (dsm_range_idx == dsm_range_last) begin
                            state <= ST_CQE_REQ;
                        end
                        else begin
                            dsm_range_idx <= dsm_range_idx + 8'd1;
                            dsm_dw_idx    <= 2'd0;
                            state         <= ST_DSM_FETCH_REQ;
                        end
                    end
                    else begin
                        clear_idx <= clear_idx + BACKING_ONE;
                    end
                end

                ST_CQE_REQ: begin
                    if ((cqe_qid && io_cq_full) || (!cqe_qid && admin_cq_full)) begin
                        if (cq_full_timer >= DMA_TIMEOUT_CLKS) begin
                            cq_full_timer <= 20'h00000;
                            stat_timeout_errors <= stat_timeout_errors + 64'd1;
                            record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                            state <= ST_IDLE;
                        end
                        else begin
                            cq_full_timer <= cq_full_timer + 20'd1;
                            state <= ST_CQE_REQ;
                        end
                    end
                    else if (!tx_valid) begin
                        cq_full_timer <= 20'h00000;
                        start_mwr1(
                            (cqe_qid ? io_cq_base : {acq_hi, acq_lo}) +
                            ({48'h0, (cqe_qid ? io_cq_tail : admin_cq_tail)} << 4) +
                            ({62'h0, cqe_idx} << 2),
                            cqe_word(cqe_idx)
                        );
                        wait_timer <= 20'h00000;
                        state <= ST_CQE_WAIT;
                    end
                end

                ST_CQE_WAIT: begin
                    if (tx_done) begin
                        if (cqe_idx == 2'd3) begin
                            stat_cmds_completed <= stat_cmds_completed + 64'd1;
                            if (cqe_qid) begin
                                if ((io_cq_tail + 16'd1) >= io_cq_size) begin
                                    io_cq_tail  <= 16'd0;
                                    io_cq_phase <= ~io_cq_phase;
                                end
                                else begin
                                    io_cq_tail <= io_cq_tail + 16'd1;
                                end
                            end
                            else begin
                                if ((admin_cq_tail + 16'd1) >= admin_cq_size) begin
                                    admin_cq_tail  <= 16'd0;
                                    admin_cq_phase <= ~admin_cq_phase;
                                end
                                else begin
                                    admin_cq_tail <= admin_cq_tail + 16'd1;
                                end
                            end
                            irq_vector <= cqe_irq_vector;
                            if (cqe_irq_enabled && !intms[cqe_irq_vector]) begin
                                if (msix_enable) begin
                                    msix_pba[cqe_irq_vector] <= 1'b1;
                                    if (!msix_function_mask &&
                                        !msix_vector_ctrl[cqe_irq_vector][0] &&
                                        (msix_addr[cqe_irq_vector] != 64'h0000000000000000)) begin
                                        state <= ST_IRQ_REQ;
                                    end
                                    else begin
                                        state <= ST_IDLE;
                                    end
                                end
                                else begin
                                    nvme_irq_req <= 1'b1;
                                    state <= ST_IDLE;
                                end
                            end
                            else begin
                                state <= ST_IDLE;
                            end
                        end
                        else begin
                            cqe_idx <= cqe_idx + 2'd1;
                            state <= ST_CQE_REQ;
                        end
                    end
                    else if (wait_timer >= DMA_TIMEOUT_CLKS) begin
                        stat_timeout_errors <= stat_timeout_errors + 64'd1;
                        record_error(NVME_SC_DATA_XFER_ERR, 1'b0);
                        state <= ST_IDLE;
                    end
                    else begin
                        wait_timer <= wait_timer + 20'd1;
                    end
                end

                ST_IRQ_REQ: begin
                    if (!tx_valid) begin
                        start_mwr1(msix_addr[irq_vector], msix_data[irq_vector]);
                        wait_timer <= 20'h00000;
                        state <= ST_IRQ_WAIT;
                    end
                end

                ST_IRQ_WAIT: begin
                    if (tx_done) begin
                        msix_pba[irq_vector] <= 1'b0;
                        state <= ST_IDLE;
                    end
                    else if (wait_timer >= DMA_TIMEOUT_CLKS) begin
                        stat_timeout_errors <= stat_timeout_errors + 64'd1;
                        msix_pba[irq_vector] <= 1'b1;
                        state <= ST_IDLE;
                    end
                    else begin
                        wait_timer <= wait_timer + 20'd1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
            end
        end
    end

endmodule


module pcileech_xadc_temperature(
    input             clk,
    input             rst,
    output bit [15:0] temp_k,
    output bit        temp_valid
);

    wire [15:0] xadc_do;
    wire        xadc_drdy;
    wire        xadc_eoc;
    wire        xadc_busy;
    wire [4:0]  xadc_channel;
    wire [7:0]  xadc_alarm;
    wire        xadc_eos;
    wire        xadc_jtagbusy;
    wire        xadc_jtaglocked;
    wire        xadc_jtagmodified;
    wire [4:0]  xadc_muxaddr;
    wire        xadc_ot;

    function automatic [15:0] xadc_raw_to_kelvin;
        input [11:0] raw;
        reg [27:0] scaled;
        begin
            scaled = raw * 16'd504;
            xadc_raw_to_kelvin = scaled[27:12];
        end
    endfunction

    always @ (posedge clk) begin
        if (rst) begin
            temp_k     <= 16'd303;
            temp_valid <= 1'b0;
        end
        else if (xadc_drdy) begin
            temp_k     <= xadc_raw_to_kelvin(xadc_do[15:4]);
            temp_valid <= 1'b1;
        end
    end

    XADC #(
        .INIT_40(16'h9000),
        .INIT_41(16'h2ef0),
        .INIT_42(16'h0400),
        .INIT_48(16'h0100),
        .INIT_49(16'h0000),
        .INIT_4A(16'h0000),
        .INIT_4B(16'h0000),
        .INIT_4C(16'h0000),
        .INIT_4D(16'h0000),
        .INIT_4E(16'h0000),
        .INIT_4F(16'h0000),
        .SIM_DEVICE("7SERIES")
    ) i_xadc (
        .CONVST       ( 1'b0          ),
        .CONVSTCLK    ( 1'b0          ),
        .DADDR        ( 7'h00         ),
        .DCLK         ( clk           ),
        .DEN          ( xadc_eoc      ),
        .DI           ( 16'h0000      ),
        .DWE          ( 1'b0          ),
        .RESET        ( rst           ),
        .VAUXN        ( 16'h0000      ),
        .VAUXP        ( 16'h0000      ),
        .ALM          ( xadc_alarm    ),
        .BUSY         ( xadc_busy     ),
        .CHANNEL      ( xadc_channel  ),
        .DO           ( xadc_do       ),
        .DRDY         ( xadc_drdy     ),
        .EOC          ( xadc_eoc      ),
        .EOS          ( xadc_eos      ),
        .JTAGBUSY     ( xadc_jtagbusy ),
        .JTAGLOCKED   ( xadc_jtaglocked ),
        .JTAGMODIFIED ( xadc_jtagmodified ),
        .MUXADDR      ( xadc_muxaddr  ),
        .OT           ( xadc_ot       ),
        .VN           ( 1'b0          ),
        .VP           ( 1'b0          )
    );

endmodule
