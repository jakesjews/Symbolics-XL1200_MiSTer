// Western Digital WD33C93 SCSI controller (initiator) with direct-access disk
// targets on MiSTer disk images, as on the Merlin I/O board.  Follows
// emu/scsi.cpp: the commands the FEP uses, statuses queued behind the one in
// the status register, data moved through the board's DMA byte port.
//
// Images are raw SCSI2SD card dumps: each 1280-byte block in three 512-byte
// sectors (block n at byte n*1536).  Blocks pass through a 16 KB staging
// buffer between the image and the DMA port, a window of up to WIN blocks
// (30 sectors) a request to MiSTer's main program instead of one block a
// round trip; a window read stays valid and serves later reads that fall in
// it (Genera's paging and Load World read sequentially), so ten single-block
// reads in a row cost one round trip.
//
// A register access takes effect in the cycle it is accepted and is
// acknowledged in the next.  With SYNC_IO a write of the command register is
// acknowledged only when the command has finished, so the processor sees
// commands complete instantly, as in the reference model (lockstep
// simulation); otherwise the command runs while the processor polls the
// auxiliary status register (busy, then INT).
module xl_scsi #(
  parameter int NT = 2,          // targets 0..NT-1 (MiSTer images 0..NT-1), at most 7
  parameter bit SYNC_IO = 1'b0
) (
  input  logic        clk,
  input  logic        reset,       // machine reset
  input  logic        mr,          // pulse: the board released the chip's reset pin

  // registers
  input  logic        reg_req,
  input  logic        reg_we,
  input  logic [4:0]  reg_addr,
  input  logic [7:0]  reg_wdata,
  output logic        reg_ack,
  output logic [7:0]  reg_rdata,

  // DMA byte port (buffer memory at the board's DMA address)
  output logic        dma_req,
  output logic        dma_we,
  output logic [7:0]  dma_wdata,
  input  logic        dma_ack,
  input  logic [7:0]  dma_rdata,

  // MiSTer disk images (hps_io)
  input  logic [NT-1:0] img_mounted,
  input  logic          img_readonly,
  input  logic [63:0]   img_size,
  output logic [31:0]   sd_lba [NT],
  output logic [5:0]    sd_blk_cnt [NT],
  output logic [NT-1:0] sd_rd,
  output logic [NT-1:0] sd_wr,
  input  logic [NT-1:0] sd_ack,
  input  logic [13:0]   sd_buff_addr,
  input  logic [7:0]    sd_buff_dout,
  output logic [7:0]    sd_buff_din [NT],
  input  logic          sd_buff_wr,

  output logic          busy,       // a command is running (disk light)
  output logic          irq,        // INT: ASR bit 7
  output logic [31:0]   dbg,        // targets present, engine state, ASR, opcode
  output logic [31:0]   dbg_blocks  // target 0's block count
);

  localparam logic [4:0] R_OWN_ID = 5'h00, R_CONTROL = 5'h01, R_CDB1 = 5'h03, R_TARGET_LUN = 5'h0F,
    R_COMMAND_PHASE = 5'h10, R_COUNT_HI = 5'h12, R_COUNT_MID = 5'h13, R_COUNT_LO = 5'h14,
    R_DEST_ID = 5'h15, R_SCSI_STATUS = 5'h17, R_COMMAND = 5'h18, R_ASR = 5'h1F;
  localparam int BLOCK = 1280;
  // INQUIRY data: direct access, removable no, SCSI-1 CCS
  localparam logic [36*8-1:0] INQUIRY = {8'h00, 8'h00, 8'h01, 8'h01, 8'd31, 8'h00, 8'h00, 8'h00,
                                         "SYMBOLIC", "XL1200 DISK     ", "0001"};

  // ---------------------------------------------------------------- targets
  // (by SCSI ID; IDs from NT up are never present)
  logic [7:0]    present = '0;
  logic [7:0]    readonly;
  logic [31:0]   blocks [8];
  logic [3:0]    sense_key [8];
  logic [7:0]    asc [8];

  // ---------------------------------------------------------------- staging buffer
  localparam int WIN = 10;         // blocks a window: 30 sectors, 15 KB of the 16 KB
  localparam int SECT = 1536;      // a block's three sectors
  logic [7:0]  stg [16384];
  logic [13:0] stg_a;
  logic        stg_we;
  logic [7:0]  stg_wd, stg_q;
  logic        sd_xfer;       // the image transfer owns the buffer
  wire  [13:0] stg_addr = sd_xfer ? sd_buff_addr : stg_a;
  always_ff @(posedge clk) begin
    if (sd_xfer ? sd_buff_wr : stg_we) stg[stg_addr] <= sd_xfer ? sd_buff_dout : stg_wd;
    stg_q <= stg[stg_addr];
  end
  always_comb for (int i = 0; i < NT; i++) sd_buff_din[i] = stg_q;

  // ---------------------------------------------------------------- registers
  logic [7:0] regs [32];
  logic [7:0] asr;
  logic [7:0] pend [4];
  logic [2:0] npend;
  logic [2:0] own_id;

  // ---------------------------------------------------------------- command engine
  typedef enum logic [3:0] {
    C_IDLE, C_SELECT, C_RESP, C_RD_SD, C_RD_SD_W, C_RD_DMA, C_WR_DMA, C_WR_PAD,
    C_WR_SD, C_WR_SD_W, C_DONE
  } cstate_t;
  cstate_t cs;

  logic [2:0]  tid;
  logic [7:0]  op;
  logic [31:0] lba, nblk, bi;    // first block, block count, block index
  logic [3:0]  bk;               // the block's place in the window
  logic [31:0] win_lba;          // the window's first block
  logic [3:0]  win_n;            // blocks in it
  logic [3:0]  req_n;            // blocks asked for
  logic        win_valid;        // a read window the next read may be served from
  logic [2:0]  win_tid;
  wire  [13:0] bk_base = {bk, 10'd0} + {1'b0, bk, 9'd0};   // bk * SECT
  logic [23:0] cnt;              // the transfer count register while running
  logic [31:0] wr_left;          // data-out bytes still to take
  logic [10:0] bp;               // byte position in the response or block
  logic [10:0] resp_len;
  logic [7:0]  status;
  logic        wr_disk;          // data-out bytes go to the image
  logic        bp_ok;            // stg_q holds block byte bp
  logic        mr_pending;

  // Byte i of the response of a non-transfer command (emu/scsi.cpp).
  function automatic logic [7:0] resp_byte(input logic [7:0] c, input logic [10:0] i,
                                           input logic [31:0] nb, input logic [3:0] key,
                                           input logic [7:0] code);
    logic [7:0] b;
    logic [23:0] nb24;
    logic [31:0] last;
    b = 8'h00;
    nb24 = (nb > 32'hFFFFFF) ? 24'hFFFFFF : nb[23:0];
    last = nb - 32'd1;
    case (c)
      8'h03: case (i)   // REQUEST SENSE
        11'd0: b = 8'h70; 11'd2: b = {4'd0, key}; 11'd7: b = 8'd10; 11'd12: b = code;
        default: b = 8'h00;
      endcase
      8'h12: b = (i < 11'd36) ? INQUIRY[(35 - i[5:0]) * 8 +: 8] : 8'h00;
      8'h1A: case (i)   // MODE SENSE(6): header and one block descriptor
        11'd0: b = 8'd11; 11'd3: b = 8'd8;
        11'd5: b = nb24[23:16]; 11'd6: b = nb24[15:8]; 11'd7: b = nb24[7:0];
        11'd10: b = 8'(BLOCK >> 8); 11'd11: b = 8'(BLOCK);
        default: b = 8'h00;
      endcase
      8'h25: case (i)   // READ CAPACITY
        11'd0: b = last[31:24]; 11'd1: b = last[23:16]; 11'd2: b = last[15:8]; 11'd3: b = last[7:0];
        11'd6: b = 8'(BLOCK >> 8); 11'd7: b = 8'(BLOCK);
        default: b = 8'h00;
      endcase
      default: b = 8'h00;
    endcase
    return b;
  endfunction

  // Its length, given the allocation length byte.
  function automatic logic [10:0] resp_length(input logic [7:0] c, input logic [7:0] alloc);
    logic [10:0] n, max;
    n = {3'd0, alloc};
    max = 11'd0;
    case (c)
      8'h03: begin max = 11'd18; if (alloc == 8'd0) n = 11'd4; end
      8'h12: max = 11'd36;
      8'h1A: max = 11'd12;
      8'h25: begin max = 11'd8; n = 11'd8; end
      default: n = 11'd0;
    endcase
    return (n < max) ? n : max;
  endfunction

  // ---------------------------------------------------------------- image requests
  always_comb begin
    for (int i = 0; i < NT; i++) begin
      sd_lba[i] = win_lba * 32'd3;
      sd_blk_cnt[i] = 6'({2'd0, req_n} * 6'd3 - 6'd1);   // three sectors a block
      sd_rd[i] = cs == C_RD_SD && tid == 3'(i);
      sd_wr[i] = cs == C_WR_SD && tid == 3'(i);
    end
  end
  wire [7:0] ack8 = 8'(sd_ack);
  assign sd_xfer = cs == C_RD_SD || cs == C_RD_SD_W || cs == C_WR_SD || cs == C_WR_SD_W;

  // ---------------------------------------------------------------- DMA
  always_comb begin
    dma_req = 1'b0; dma_we = 1'b0; dma_wdata = stg_q;
    stg_a = bk_base + 14'(bp); stg_we = 1'b0; stg_wd = dma_rdata;
    case (cs)
      C_RESP: begin
        dma_req = bp != resp_len && cnt != 24'd0;
        dma_we = 1'b1;
        dma_wdata = resp_byte(op, bp, blocks[tid], sense_key[tid], asc[tid]);
      end
      C_RD_DMA: begin dma_req = bp_ok; dma_we = 1'b1; end
      C_WR_DMA: begin dma_req = 1'b1; stg_we = dma_ack; end
      C_WR_PAD: begin stg_we = 1'b1; stg_wd = 8'h00; end
      default: ;
    endcase
  end

  assign busy = cs != C_IDLE;
  assign dbg = {present, 4'd0, cs, asr, op};
  assign irq = asr[7];
  assign dbg_blocks = blocks[0];

  // ---------------------------------------------------------------- state
  logic reg_done;
  wire  cmd_write = reg_req && reg_we && reg_addr == R_COMMAND;
  wire  reg_hold = SYNC_IO && cmd_write && cs != C_IDLE;   // command still running
  assign reg_ack = reg_req && reg_done && !reg_hold;

  logic [7:0] a, st17, push_v, push2_v;
  logic [2:0] n;
  logic [7:0] q [4];
  logic       push, push2, start;

  always_ff @(posedge clk) begin
    if (reset) begin
      for (int i = 0; i < 32; i++) regs[i] <= 8'h00;
      asr <= 8'h00;
      npend <= '0;
      own_id <= 3'd7;
      cs <= C_IDLE;
      reg_done <= 1'b0;
      mr_pending <= 1'b0;
      bp_ok <= 1'b0;
      win_valid <= 1'b0;
      for (int i = 0; i < 8; i++) begin sense_key[i] <= 4'd0; asc[i] <= 8'h00; end
    end else begin
      // Statuses and register reads are applied in order within the cycle.
      a = asr; n = npend; q = pend; st17 = regs[R_SCSI_STATUS];
      push = 1'b0; push_v = 8'h00; push2 = 1'b0; push2_v = 8'h00; start = 1'b0;

      if (|img_mounted) win_valid <= 1'b0;   // a new image: the window is stale

      // ---- register access
      if (reg_ack) reg_done <= 1'b0;
      else if (reg_req && !reg_done && !reg_hold) begin
        reg_done <= 1'b1;
        if (reg_we) begin
          if (reg_addr == R_COMMAND) begin
            regs[R_COMMAND] <= reg_wdata;
            case (reg_wdata[6:0])
              7'h00: begin   // reset (advanced features would answer 0x01: WD33C93A)
                own_id <= regs[R_OWN_ID][2:0];
                push = 1'b1; push_v = 8'h00;
              end
              7'h01: begin push = 1'b1; push_v = 8'h22; end   // abort
              7'h08, 7'h09: start = 1'b1;                     // select-and-transfer
              default: begin a = a | 8'h40; push = 1'b1; push_v = 8'h40; end
            endcase
          end else regs[reg_addr] <= reg_wdata;
        end else begin
          reg_rdata <= (reg_addr == R_ASR) ? a : regs[reg_addr];
          if (reg_addr == R_SCSI_STATUS) begin   // clears INT, presents the next status
            a = a & ~8'h80;
            if (n != 3'd0) begin
              st17 = q[0];
              q[0] = q[1]; q[1] = q[2]; q[2] = q[3];
              n = n - 3'd1;
              a = a | 8'h80;
            end
          end
        end
      end

      // ---- command engine
      bp_ok <= 1'b0;
      case (cs)
        C_IDLE: if (start) begin
          tid <= regs[R_DEST_ID][2:0];
          op <= regs[R_CDB1];
          cnt <= {regs[R_COUNT_HI], regs[R_COUNT_MID], regs[R_COUNT_LO]};
          a = a | 8'h30;          // busy, command in progress
          cs <= C_SELECT;
        end

        C_SELECT: begin
          logic [31:0] l, nb;
          logic rw6;
          rw6 = op == 8'h08 || op == 8'h0A;
          l = rw6 ? {11'd0, regs[R_CDB1 + 5'd1][4:0], regs[R_CDB1 + 5'd2], regs[R_CDB1 + 5'd3]}
                  : {regs[R_CDB1 + 5'd2], regs[R_CDB1 + 5'd3], regs[R_CDB1 + 5'd4], regs[R_CDB1 + 5'd5]};
          nb = rw6 ? ((regs[R_CDB1 + 5'd4] == 8'd0) ? 32'd256 : {24'd0, regs[R_CDB1 + 5'd4]})
                   : {16'd0, regs[R_CDB1 + 5'd7], regs[R_CDB1 + 5'd8]};
          lba <= l;
          nblk <= nb;
          bp <= '0;
          bi <= '0;
          bk <= '0;
          status <= 8'd0;
          if (tid == own_id || !present[tid]) begin
            regs[R_COMMAND_PHASE] <= 8'h00;
            push = 1'b1; push_v = 8'h42;   // timeout during selection
            cs <= C_IDLE;
          end else case (op)
            8'h00: begin sense_key[tid] <= 4'd0; cs <= C_DONE; end          // TEST UNIT READY
            8'h03, 8'h12, 8'h1A, 8'h25: begin                              // responses
              resp_len <= resp_length(op, regs[R_CDB1 + 5'd4]);
              cs <= C_RESP;
            end
            8'h01, 8'h0B, 8'h15, 8'h1B, 8'h1E, 8'h2B, 8'h2F, 8'h35: cs <= C_DONE;
            8'h08, 8'h28, 8'h0A, 8'h2A:
              if ({1'b0, l} + {1'b0, nb} > {1'b0, blocks[tid]}) begin     // LBA out of range
                sense_key[tid] <= 4'd5; asc[tid] <= 8'h21; status <= 8'd2;
                cs <= C_DONE;
              end else if (op == 8'h08 || op == 8'h28) begin
                if (cnt == 24'd0) cs <= C_DONE;
                else if (win_valid && win_tid == tid && l >= win_lba && l < win_lba + 32'(win_n)) begin
                  bk <= 4'(l - win_lba);        // in the window already read
                  cs <= C_RD_DMA;
                end else begin
                  win_valid <= 1'b0;
                  win_lba <= l;
                  req_n <= (blocks[tid] - l < 32'(WIN)) ? 4'(blocks[tid] - l) : 4'(WIN);
                  cs <= C_RD_SD;
                end
              end else begin
                // The image is written only if the count covers every block.
                wr_left <= ({8'd0, cnt} < nb * BLOCK) ? {8'd0, cnt} : nb * BLOCK;
                wr_disk <= !readonly[tid] && {8'd0, cnt} >= nb * BLOCK;
                win_valid <= 1'b0;              // the window may hold what is rewritten
                win_lba <= l;                   // the write group's first block
                cs <= (cnt == 24'd0) ? C_DONE : C_WR_DMA;
              end
            default: begin sense_key[tid] <= 4'd5; asc[tid] <= 8'h20; status <= 8'd2; cs <= C_DONE; end
          endcase
        end

        C_RESP:
          if (!dma_req) begin
            if (op == 8'h03) begin sense_key[tid] <= 4'd0; asc[tid] <= 8'h00; end
            cs <= C_DONE;
          end else if (dma_ack) begin
            bp <= bp + 11'd1;
            cnt <= cnt - 24'd1;
          end

        C_RD_SD: if (ack8[tid]) cs <= C_RD_SD_W;
        C_RD_SD_W: if (!ack8[tid]) begin
          win_valid <= 1'b1;
          win_n <= req_n;
          win_tid <= tid;
          bk <= 4'(lba + bi - win_lba);
          bp <= '0;
          cs <= C_RD_DMA;
        end
        // The block's byte bp reaches stg_q a cycle after bp is set.
        C_RD_DMA:
          if (dma_ack) begin
            cnt <= cnt - 24'd1;
            bp <= bp + 11'd1;
            if (cnt == 24'd1) cs <= C_DONE;
            else if (bp == 11'(BLOCK - 1)) begin
              bi <= bi + 32'd1;
              bp <= '0;
              if (bi + 32'd1 == nblk) cs <= C_DONE;
              else if (bk + 4'd1 == win_n) begin    // the next window
                win_valid <= 1'b0;
                win_lba <= lba + bi + 32'd1;
                req_n <= (blocks[tid] - (lba + bi + 32'd1) < 32'(WIN)) ? 4'(blocks[tid] - (lba + bi + 32'd1)) : 4'(WIN);
                cs <= C_RD_SD;
              end else bk <= bk + 4'd1;
            end
          end else bp_ok <= 1'b1;

        C_WR_DMA: if (dma_ack) begin
          cnt <= cnt - 24'd1;
          wr_left <= wr_left - 32'd1;
          bp <= (bp == 11'(BLOCK - 1)) ? 11'(BLOCK) : bp + 11'd1;
          if (wr_left == 32'd1 && !wr_disk) cs <= C_DONE;
          else if (bp == 11'(BLOCK - 1)) begin
            if (wr_disk) cs <= C_WR_PAD;
            else bp <= '0;
          end
        end
        C_WR_PAD:   // zero the rest of the third sector; the group goes to the
                    // image when it fills the window or ends the command
          if (bp == 11'd1535) begin
            bi <= bi + 32'd1;
            if (bi + 32'd1 == nblk || bk == 4'(WIN - 1)) begin
              req_n <= bk + 4'd1;
              cs <= C_WR_SD;
            end else begin
              bk <= bk + 4'd1;
              bp <= '0;
              cs <= C_WR_DMA;
            end
          end else bp <= bp + 11'd1;
        C_WR_SD: if (ack8[tid]) cs <= C_WR_SD_W;
        C_WR_SD_W: if (!ack8[tid]) begin
          bp <= '0;
          bk <= '0;
          win_lba <= lba + bi;
          cs <= (bi == nblk) ? C_DONE : C_WR_DMA;
        end

        C_DONE: begin
          regs[R_COUNT_HI] <= cnt[23:16];
          regs[R_COUNT_MID] <= cnt[15:8];
          regs[R_COUNT_LO] <= cnt[7:0];
          regs[R_TARGET_LUN] <= status;
          regs[R_COMMAND_PHASE] <= 8'h60;
          // Command Complete (0x16); then bus free reports a disconnect unless
          // EDI (control bit 3) asks for the 0x16 to come at that point.
          push = 1'b1; push_v = 8'h16;
          if (!regs[R_CONTROL][3]) begin push2 = 1'b1; push2_v = 8'h85; end
          cs <= C_IDLE;
        end

        default: cs <= C_IDLE;
      endcase

      // ---- interrupts: a status is presented if INT is clear, else queued
      if (push) begin
        a = a & ~8'h30;
        if (a[7]) begin q[n[1:0]] = push_v; n = n + 3'd1; end
        else begin st17 = push_v; a = a | 8'h80; end
      end
      if (push2) begin
        if (a[7]) begin q[n[1:0]] = push2_v; n = n + 3'd1; end
        else begin st17 = push2_v; a = a | 8'h80; end
      end

      asr <= a;
      npend <= n;
      pend <= q;
      regs[R_SCSI_STATUS] <= st17;

      // ---- the chip's reset pin (applied between commands): registers
      // cleared, then the reset interrupt
      if ((mr || mr_pending) && cs != C_IDLE) mr_pending <= 1'b1;
      else if (mr || mr_pending) begin
        mr_pending <= 1'b0;
        for (int i = 0; i < 32; i++) regs[i] <= 8'h00;
        asr <= 8'h80;
        npend <= '0;
      end
    end
  end

  // ---------------------------------------------------------------- mounting
  // Block count of a new image: (size + 256) / 1536 = ((size + 256) / 512) / 3,
  // by restoring division.
  logic [2:0]  mnt_id;
  logic        mnt_busy = 1'b0;
  logic [31:0] mnt_rem, mnt_q, mnt_n;
  logic [5:0]  mnt_bit;

  always_ff @(posedge clk) begin
    if (|img_mounted) begin
      for (int i = 0; i < NT; i++)
        if (img_mounted[i]) begin
          mnt_id <= 3'(i);
          present[i] <= 1'b0;
          readonly[i] <= img_readonly;
        end
      mnt_n <= 32'((img_size + 64'd256) >> 9);
      mnt_rem <= '0;
      mnt_q <= '0;
      mnt_bit <= 6'd32;
      mnt_busy <= img_size >= 64'(BLOCK);
    end else if (mnt_busy) begin
      if (mnt_bit == 6'd0) begin
        blocks[mnt_id] <= mnt_q;
        present[mnt_id] <= 1'b1;
        mnt_busy <= 1'b0;
      end else begin
        logic [32:0] r;
        r = {mnt_rem, mnt_n[5'(mnt_bit - 6'd1)]};
        if (r >= 33'd3) begin
          mnt_rem <= 32'(r - 33'd3);
          mnt_q[5'(mnt_bit - 6'd1)] <= 1'b1;
        end else mnt_rem <= r[31:0];
        mnt_bit <= mnt_bit - 6'd1;
      end
    end
  end

endmodule
