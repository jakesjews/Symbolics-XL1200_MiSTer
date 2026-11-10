// Western Digital WD33C93 SCSI controller (initiator) with direct-access disk
// targets and a CD-ROM drive on MiSTer images, as on the Merlin I/O board.
// Follows emu/scsi.cpp: the commands the FEP and Genera use, statuses queued
// behind the one in the status register, data moved through the board's DMA
// byte port.
//
// Disk images are raw SCSI2SD card dumps: each 1280-byte block in three
// 512-byte sectors (block n at byte n*1536).  Blocks pass through a 16 KB
// staging buffer between the image and the DMA port, a window of up to WIN
// blocks (30 sectors) a request to MiSTer's main program instead of one block
// a round trip; a window read stays valid and serves later reads that fall in
// it (Genera's paging and Load World read sequentially), so ten single-block
// reads in a row cost one round trip.
//
// Target CD is a CD-ROM drive on an ISO image: 2048-byte blocks, four sectors
// each, eight to a window.  The drive answers with or without a disc (NOT
// READY without one), reports a new disc or a reset once as UNIT ATTENTION
// and refuses writes.
//
// A Select-and-Transfer whose transfer count runs out while the target still
// has data ends with an unexpected information phase (status 0x48 data out,
// 0x49 data in) and Command Phase 0x46, the target left connected; issued
// again with Command Phase 0x45 it goes on with the data (data sheet 7.6.1).
// Genera reads a CD-ROM 64 KB at a time through its 32 KB buffer this way.
//
// A register access takes effect in the cycle it is accepted and is
// acknowledged in the next.  With SYNC_IO a write of the command register is
// acknowledged only when the command has finished, so the processor sees
// commands complete instantly, as in the reference model (lockstep
// simulation); otherwise the command runs while the processor polls the
// auxiliary status register (busy, then INT) or goes on until the interrupt.
module xl_scsi #(
  parameter int NT = 3,          // targets 0..NT-1 (MiSTer images 0..NT-1), at most 7
  parameter int CD = 2,          // the target that is a CD-ROM drive (NT or more: none)
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
  localparam logic [7:0] CD_MASK = (CD < NT) ? 8'(1 << CD) : 8'h00;
  localparam int CDI = (CD < NT) ? CD : 0;
  localparam int TW = (NT > 1) ? $clog2(NT) : 1;
  // INQUIRY data: direct access, removable no, SCSI-1 CCS
  localparam logic [36*8-1:0] INQUIRY = {8'h00, 8'h00, 8'h01, 8'h01, 8'd31, 8'h00, 8'h00, 8'h00,
                                         "SYMBOLIC", "XL1200 DISK     ", "0001"};

  // ---------------------------------------------------------------- targets
  // (by SCSI ID; IDs from NT up are never present)
  logic [7:0]    present = '0;     // an image is mounted (the CD-ROM drive: a disc is in)
  logic [NT-1:0] readonly;
  logic [31:0]   blocks [NT];
  logic [3:0]    sense_key [NT];
  logic [7:0]    asc [NT];
  logic          cd_attn;          // the CD-ROM drive has a UNIT ATTENTION to report:
  logic          cd_attn_reset;    //   a reset (0x29), else a new disc (0x28)

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
    C_IDLE, C_SELECT, C_RANGE, C_RESP, C_RD_SD, C_RD_SD_W, C_RD_DMA, C_WR_DMA, C_WR_PAD,
    C_WR_SD, C_WR_SD_W, C_DONE, C_PAUSE
  } cstate_t;
  cstate_t cs;
  cstate_t ret;                  // C_PAUSE: the data state the count ran out in
  wire active = cs != C_IDLE && cs != C_PAUSE;   // a command is running

  logic [2:0]  tid;
  logic [7:0]  op;
  logic [31:0] lba;              // the block moving
  logic [16:0] nleft;            // blocks still to move, with it
  logic [3:0]  bk;               // the block's place in the window
  logic [31:0] win_lba;          // the window's first block
  logic [3:0]  win_n;            // blocks in it
  logic        win_valid;        // a read window the next read may be served from
  logic [2:0]  win_tid;
  wire  [TW-1:0] ti = tid[TW-1:0];                        // its place in the targets' arrays
  wire         cd = CD_MASK[tid];                         // the target is the CD-ROM drive
  wire  [13:0] bk_base = cd ? {bk[2:0], 11'd0} : {bk, 10'd0} + {1'b0, bk, 9'd0};   // bk * 2048 or bk * SECT
  wire  [10:0] blk_last = cd ? 11'd2047 : 11'(BLOCK - 1);  // a block's last byte
  wire  [3:0]  win_max = cd ? 4'd8 : 4'(WIN);              // blocks a window
  // Blocks from the one moving to the end of the image: the range check, and
  // the size of a window read (which starts at the block moving).
  wire  [32:0] left = {1'b0, blocks[ti]} - {1'b0, lba};
  wire  [31:0] off = lba - win_lba;                       // its place in the window read last
  wire         hit = win_valid && win_tid == tid && off[31:4] == 28'd0 && off[3:0] < win_n;
  wire         wr_sd = cs == C_WR_SD || cs == C_WR_SD_W;
  wire  [3:0]  req_n = wr_sd ? bk + 4'd1                  // blocks asked of the image
                     : (left[31:4] == 28'd0 && left[3:0] < win_max) ? left[3:0] : win_max;
  logic [23:0] cnt;              // the transfer count register while running
  logic [10:0] bp;               // byte position in the response or block
  logic [10:0] resp_len;
  logic        chk;              // the target's status: CHECK CONDITION
  logic        wr_disk;          // data-out bytes go to the image
  logic        bp_ok;            // stg_q holds block byte bp
  logic        mr_pending;

  // Byte i of the response of a non-transfer command (emu/scsi.cpp).
  function automatic logic [7:0] resp_byte(input logic [7:0] c, input logic [10:0] i,
                                           input logic [31:0] nb, input logic [3:0] key,
                                           input logic [7:0] code, input logic cdrom);
    logic [7:0] b;
    logic [23:0] nb24;
    logic [31:0] last;
    logic [15:0] bsz;
    b = 8'h00;
    bsz = cdrom ? 16'd2048 : 16'(BLOCK);
    nb24 = (nb > 32'hFFFFFF) ? 24'hFFFFFF : nb[23:0];
    last = nb - 32'd1;
    case (c)
      8'h03: case (i)   // REQUEST SENSE
        11'd0: b = 8'h70; 11'd2: b = {4'd0, key}; 11'd7: b = 8'd10; 11'd12: b = code;
        default: b = 8'h00;
      endcase
      8'h12: begin
        b = (i < 11'd36) ? INQUIRY[(35 - i[5:0]) * 8 +: 8] : 8'h00;
        if (cdrom) case (i)   // a removable CD-ROM, "XL1200 CD-ROM"
          11'd0: b = 8'h05; 11'd1: b = 8'h80;
          11'd23: b = "C"; 11'd24: b = "D"; 11'd25: b = "-"; 11'd26: b = "R"; 11'd27: b = "O"; 11'd28: b = "M";
          default: ;
        endcase
      end
      8'h1A: case (i)   // MODE SENSE(6): header and one block descriptor
        11'd0: b = 8'd11; 11'd3: b = 8'd8;
        11'd5: b = nb24[23:16]; 11'd6: b = nb24[15:8]; 11'd7: b = nb24[7:0];
        11'd10: b = bsz[15:8]; 11'd11: b = bsz[7:0];
        default: b = 8'h00;
      endcase
      8'h25: case (i)   // READ CAPACITY
        11'd0: b = last[31:24]; 11'd1: b = last[23:16]; 11'd2: b = last[15:8]; 11'd3: b = last[7:0];
        11'd6: b = bsz[15:8]; 11'd7: b = bsz[7:0];
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
      // three sectors a disk block, four a CD-ROM block
      sd_lba[i] = cd ? {win_lba[29:0], 2'b00} : win_lba * 32'd3;
      sd_blk_cnt[i] = cd ? 6'({req_n, 2'b00}) - 6'd1 : 6'({2'd0, req_n} * 6'd3 - 6'd1);
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
        dma_wdata = resp_byte(op, bp, blocks[ti], sense_key[ti], asc[ti], cd);
      end
      C_RD_DMA: begin dma_req = bp_ok && cnt != 24'd0; dma_we = 1'b1; end
      C_WR_DMA: begin dma_req = cnt != 24'd0; stg_we = dma_ack; end
      C_WR_PAD: begin stg_we = 1'b1; stg_wd = 8'h00; end
      default: ;
    endcase
  end

  assign busy = active;
  assign dbg = {present, 4'd0, cs, asr, op};
  assign irq = asr[7];
  assign dbg_blocks = blocks[0];

  // ---------------------------------------------------------------- state
  logic reg_done;
  wire  cmd_write = reg_req && reg_we && reg_addr == R_COMMAND;
  wire  reg_hold = SYNC_IO && cmd_write && active;         // command still running
  wire  cd_mount = |(8'(img_mounted) & CD_MASK);
  assign reg_ack = reg_req && reg_done && !reg_hold;

  logic [7:0] a, st17, push_v, push2_v;
  logic [2:0] n;
  logic [7:0] q [4];
  logic       push, push2, start, drop, pause;

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
      for (int i = 0; i < NT; i++) begin sense_key[i] <= 4'd0; asc[i] <= 8'h00; end
      cd_attn <= 1'b1;
      cd_attn_reset <= 1'b1;
    end else begin
      // Statuses and register reads are applied in order within the cycle.
      a = asr; n = npend; q = pend; st17 = regs[R_SCSI_STATUS];
      push = 1'b0; push_v = 8'h00; push2 = 1'b0; push2_v = 8'h00; start = 1'b0;
      drop = 1'b0; pause = 1'b0;

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
                drop = 1'b1;
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
          // busy until the interrupt; CIP (8'h10) only while the chip
          // interprets the command, which this takes at once (data sheet
          // 6.2.1 and 7.2: a running Level II command shows BSY 1, CIP 0;
          // Genera spins on CIP with interrupts off after each command)
          a = a | 8'h20;
          cs <= C_SELECT;
        end

        C_SELECT: begin
          logic rw6;
          rw6 = op == 8'h08 || op == 8'h0A;
          lba <= rw6 ? {11'd0, regs[R_CDB1 + 5'd1][4:0], regs[R_CDB1 + 5'd2], regs[R_CDB1 + 5'd3]}
                     : {regs[R_CDB1 + 5'd2], regs[R_CDB1 + 5'd3], regs[R_CDB1 + 5'd4], regs[R_CDB1 + 5'd5]};
          nleft <= rw6 ? ((regs[R_CDB1 + 5'd4] == 8'd0) ? 17'd256 : {9'd0, regs[R_CDB1 + 5'd4]})
                       : {1'b0, regs[R_CDB1 + 5'd7], regs[R_CDB1 + 5'd8]};
          bp <= '0;
          bk <= '0;
          chk <= 1'b0;
          if (tid == own_id || !(present[tid] || cd)) begin
            regs[R_COMMAND_PHASE] <= 8'h00;
            push = 1'b1; push_v = 8'h42;   // timeout during selection
            cs <= C_IDLE;
          end else if (cd && op != 8'h03 && op != 8'h12
                       && (cd_attn || !present[tid] || op == 8'h0A || op == 8'h2A)) begin
            // The CD-ROM drive, to all but INQUIRY and REQUEST SENSE: a UNIT
            // ATTENTION once, NOT READY with no disc in, a write refused
            if (cd_attn) begin
              sense_key[ti] <= 4'd6; asc[ti] <= cd_attn_reset ? 8'h29 : 8'h28;
              cd_attn <= 1'b0;
            end else if (!present[tid]) begin sense_key[ti] <= 4'd2; asc[ti] <= 8'h3A; end
            else begin sense_key[ti] <= 4'd7; asc[ti] <= 8'h27; end
            chk <= 1'b1;
            cs <= C_DONE;
          end else case (op)
            8'h00: begin sense_key[ti] <= 4'd0; cs <= C_DONE; end          // TEST UNIT READY
            8'h03, 8'h12, 8'h1A, 8'h25: begin                              // responses
              resp_len <= resp_length(op, regs[R_CDB1 + 5'd4]);
              cs <= C_RESP;
            end
            8'h01, 8'h0B, 8'h15, 8'h1B, 8'h1E, 8'h2B, 8'h2F, 8'h35: cs <= C_DONE;
            8'h08, 8'h28, 8'h0A, 8'h2A: cs <= C_RANGE;
            default: begin sense_key[ti] <= 4'd5; asc[ti] <= 8'h20; chk <= 1'b1; cs <= C_DONE; end
          endcase
        end

        // READ and WRITE, the block address and count taken
        C_RANGE:
          if (left[32] || (left[31:17] == 15'd0 && left[16:0] < nleft)) begin   // past the end
            sense_key[ti] <= 4'd5; asc[ti] <= 8'h21; chk <= 1'b1;
            cs <= C_DONE;
          end else if (nleft == 17'd0) cs <= C_DONE;                            // no blocks: no data
          else if (op == 8'h08 || op == 8'h28) begin
            if (hit) begin
              bk <= off[3:0];                   // in the window already read
              cs <= C_RD_DMA;
            end else begin
              win_valid <= 1'b0;
              win_lba <= lba;
              cs <= C_RD_SD;
            end
          end else begin
            wr_disk <= !readonly[ti];
            win_valid <= 1'b0;                  // the window may hold what is rewritten
            win_lba <= lba;                     // the write group's first block
            cs <= C_WR_DMA;
          end

        // A data state that finds the count at zero with data still to move
        // pauses (below); the count registers then read zero.
        C_RESP:
          if (bp == resp_len) begin
            if (op == 8'h03) begin sense_key[ti] <= 4'd0; asc[ti] <= 8'h00; end
            cs <= C_DONE;
          end else if (cnt == 24'd0) pause = 1'b1;
          else if (dma_ack) begin
            bp <= bp + 11'd1;
            cnt <= cnt - 24'd1;
          end

        C_RD_SD: if (ack8[tid]) cs <= C_RD_SD_W;
        C_RD_SD_W: if (!ack8[tid]) begin
          win_valid <= 1'b1;
          win_n <= req_n;
          win_tid <= tid;
          bk <= '0;                             // the window starts at the block wanted
          bp <= '0;
          cs <= C_RD_DMA;
        end
        // The block's byte bp reaches stg_q a cycle after bp is set.
        C_RD_DMA:
          if (cnt == 24'd0) pause = 1'b1;
          else if (dma_ack) begin
            cnt <= cnt - 24'd1;
            bp <= bp + 11'd1;
            if (bp == blk_last) begin
              lba <= lba + 32'd1;
              nleft <= nleft - 17'd1;
              bp <= '0;
              if (nleft == 17'd1) cs <= C_DONE;
              else if (bk + 4'd1 == win_n) begin    // the next window
                win_valid <= 1'b0;
                win_lba <= lba + 32'd1;
                cs <= C_RD_SD;
              end else bk <= bk + 4'd1;
            end
          end else bp_ok <= 1'b1;

        // (disks only: the CD-ROM drive refuses a write before its data)
        C_WR_DMA:
          if (cnt == 24'd0) pause = 1'b1;
          else if (dma_ack) begin
            cnt <= cnt - 24'd1;
            bp <= bp + 11'd1;
            if (bp == 11'(BLOCK - 1)) begin
              if (wr_disk) cs <= C_WR_PAD;
              else begin                            // a read-only image: the data is dropped
                bp <= '0;
                nleft <= nleft - 17'd1;
                if (nleft == 17'd1) cs <= C_DONE;
              end
            end
          end
        C_WR_PAD:   // zero the rest of the third sector; the group goes to the
                    // image when it fills the window or ends the command
          if (bp == 11'd1535) begin
            lba <= lba + 32'd1;
            nleft <= nleft - 17'd1;
            if (nleft == 17'd1 || bk == 4'(WIN - 1)) cs <= C_WR_SD;
            else begin
              bk <= bk + 4'd1;
              bp <= '0;
              cs <= C_WR_DMA;
            end
          end else bp <= bp + 11'd1;
        C_WR_SD: if (ack8[tid]) cs <= C_WR_SD_W;
        C_WR_SD_W: if (!ack8[tid]) begin
          bp <= '0;
          bk <= '0;
          win_lba <= lba;
          cs <= (nleft == 17'd0) ? C_DONE : C_WR_DMA;
        end

        C_DONE: begin
          regs[R_COUNT_HI] <= cnt[23:16];
          regs[R_COUNT_MID] <= cnt[15:8];
          regs[R_COUNT_LO] <= cnt[7:0];
          regs[R_TARGET_LUN] <= {6'd0, chk, 1'b0};
          regs[R_COMMAND_PHASE] <= 8'h60;
          // Command Complete (0x16); then bus free reports a disconnect unless
          // EDI (control bit 3) asks for the 0x16 to come at that point.
          push = 1'b1; push_v = 8'h16;
          if (!regs[R_CONTROL][3]) begin push2 = 1'b1; push2_v = 8'h85; end
          cs <= C_IDLE;
        end

        // Connected, the data phase waiting: a Select-and-Transfer resumes
        // at the Command Phase register, 0x45 (or 0x41) with the data; any
        // other phase expects something else than the data the target asks
        // for. A Reset command lets the target go.
        C_PAUSE:
          if (drop) cs <= C_IDLE;
          else if (start) begin
            cnt <= {regs[R_COUNT_HI], regs[R_COUNT_MID], regs[R_COUNT_LO]};
            a = a | 8'h20;
            if (regs[R_COMMAND_PHASE] == 8'h45 || regs[R_COMMAND_PHASE] == 8'h41) cs <= ret;
            else begin push = 1'b1; push_v = (ret == C_WR_DMA) ? 8'h48 : 8'h49; end
          end

        default: cs <= C_IDLE;
      endcase

      // ---- the count ran out with data to go: an unexpected information
      // phase (data out 0x48, data in 0x49), Command Phase 0x46
      if (pause) begin
        regs[R_COUNT_HI] <= 8'h00;
        regs[R_COUNT_MID] <= 8'h00;
        regs[R_COUNT_LO] <= 8'h00;
        regs[R_COMMAND_PHASE] <= 8'h46;
        push = 1'b1; push_v = (cs == C_WR_DMA) ? 8'h48 : 8'h49;
        ret <= cs;
        cs <= C_PAUSE;
      end

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
      // cleared, then the reset interrupt. The board resets the bus with it
      // (the FEP and Genera write both bits together), which lets a connected
      // target go and leaves the CD-ROM drive a UNIT ATTENTION.
      if ((mr || mr_pending) && active) mr_pending <= 1'b1;
      else if (mr || mr_pending) begin
        mr_pending <= 1'b0;
        for (int i = 0; i < 32; i++) regs[i] <= 8'h00;
        asr <= 8'h80;
        npend <= '0;
        cs <= C_IDLE;
        cd_attn <= 1'b1;
        cd_attn_reset <= 1'b1;
      end

      // ---- a disc put in (or taken out): the medium may have changed
      if (cd_mount) begin
        cd_attn <= 1'b1;
        cd_attn_reset <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------- mounting
  // Block count of a new image: (size + 256) / 1536 = ((size + 256) / 512) / 3,
  // by restoring division; a disc's is its whole 2048-byte blocks.
  logic [TW-1:0] mnt_id;
  logic        mnt_busy = 1'b0;
  logic [31:0] mnt_n;            // the dividend going out at the top, the quotient coming in below
  logic [1:0]  mnt_rem;
  logic [5:0]  mnt_bit;
  wire  [2:0]  mnt_r = {mnt_rem, mnt_n[31]};

  always_ff @(posedge clk) begin
    if (|img_mounted) begin
      for (int i = 0; i < NT; i++)
        if (img_mounted[i]) begin
          mnt_id <= TW'(i);
          present[i] <= 1'b0;
          readonly[i] <= img_readonly;
        end
      mnt_n <= 32'((img_size + 64'd256) >> 9);
      mnt_rem <= '0;
      mnt_bit <= 6'd32;
      mnt_busy <= img_size >= 64'(BLOCK) && !cd_mount;
      if (cd_mount) begin
        blocks[CDI] <= img_size[42:11];
        present[CDI] <= |img_size[63:11];
      end
    end else if (mnt_busy) begin
      if (mnt_bit == 6'd0) begin
        blocks[mnt_id] <= mnt_n;
        present[3'(mnt_id)] <= 1'b1;
        mnt_busy <= 1'b0;
      end else begin
        mnt_rem <= (mnt_r >= 3'd3) ? 2'(mnt_r - 3'd3) : mnt_r[1:0];
        mnt_n <= {mnt_n[30:0], mnt_r >= 3'd3};
        mnt_bit <= mnt_bit - 6'd1;
      end
    end
  end

endmodule
