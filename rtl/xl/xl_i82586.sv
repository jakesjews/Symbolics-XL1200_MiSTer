// Intel 82586 Ethernet coprocessor on the XL1200 I/O board, with the wire
// behind it (xl_eth_hps: frames to and from Main_MiSTer's bridge).  The
// control structures in the board's buffer memory are as Genera's driver
// (network/82586-ethernet-driver.lisp) and the Intel reference manual lay
// them out; emu/i82586.cpp, the model without a network, describes what
// Genera needs of the chip.
//
// The chip sees the I/O board's buffer memory as bytes: its address bits
// 16:0, low byte of each word first, so it reaches buffer words 0-0x7FFF in
// 16-bit halves (m_hi selects bits 31:16, m_be the bytes of the half).  Its
// pins come from the latch at 0x44016000: bit 7 releases RESET, a falling
// edge on bit 6 is channel attention, bit 5 releases loopback.  Channel
// attention runs the init handshake (SCP -> ISCP -> SCB) after a reset,
// otherwise the SCB command: acknowledgements, the receive unit (start takes
// the RFA offset; frames then land in the RFD and RBD chains as they come
// from the wire) and the command unit, which runs the command list: IA-setup
// and configure are taken in (station address; AL-LOC, loopback,
// promiscuous, broadcast disable), MC-setup opens the multicast filter,
// transmit pushes the TBD chain to the wire (with the destination, source
// and length from the block first when AL-LOC is 0) and completes when the
// wire has taken the frame, TDR reports the link OK, DUMP writes zeros, NOP
// and DIAGNOSE complete.  The SCB status word is written when a command is
// accepted (the CU then shows active: Genera starts the CU only when it
// reads idle) and again, with INT (irq), after every pass and every
// received frame.  A transmit whose frame the wire hasn't taken yet waits
// in E_IDLE (txw), so channel attentions and received frames are served
// meanwhile (manual 2.7.1; Genera gives up on a CA after about 2 ms, and the
// wire can be busy for up to its 50 ms TXWAIT); a CU command then is taken
// for the block in progress (suspend, abort) or, CU start, not at all
// (Genera never issues one while the CU shows active).
//
// A received frame goes to the RFD at the RFA, into the RBD chain the RFD
// names if it is the first frame since RU start, otherwise the next free
// RBD (manual 2.5.2: the CPU puts the free buffer list in the first RFD
// only; Genera never rewrites the other RFDs' RBD offsets, so after a lap
// they still hold the buffers of the previous one), buffer by
// buffer: each gets its actual count, F, and EOF with the frame's last byte;
// the RFD gets the first RBD's offset, C and OK, and the frame's address
// and length fields when AL-LOC is 0.  The FCS Main appends is not stored.
// An RFD with EL ends the frame area (RU no resources, RNR), one with S
// suspends it; an RBD with EL before the frame's end truncates it (no
// resources, the RFD without OK).  Receive buffers are taken to start and
// end on even bytes (Genera's are 192 bytes, word-aligned).  With the RU not
// ready, a frame offered is dropped (RSCERRS doesn't count it).  busy is set
// while the chip works, a transmit waiting included (lockstep holds the
// processor meanwhile).
module xl_i82586 (
  input  logic        clk,
  input  logic        reset,
  input  logic        pins_we,
  input  logic [7:0]  pins,
  output logic        busy,
  output logic        irq,

  // buffer memory: 16-bit cycles
  output logic        m_req,
  output logic        m_we,
  output logic [14:0] m_word,
  output logic        m_hi,
  output logic [1:0]  m_be,
  output logic [15:0] m_wdata,
  input  logic        m_ack,
  input  logic [31:0] m_rdata,

  // the wire (xl_eth_hps): frames 16 bits at a time, the earlier byte in [15:8]
  output logic        tx_push,
  output logic        tx_stp,
  output logic [1:0]  tx_be,
  output logic [15:0] tx_d,
  output logic        tx_enp,
  output logic [11:0] tx_len,
  output logic        tx_crcgen,
  output logic        tx_clr,
  input  logic        tx_busy,
  output logic        rx_pop,
  output logic        rx_clr,
  input  logic [15:0] rx_d,
  input  logic        rx_deof,
  input  logic        rx_fifordy,
  input  logic [11:0] rx_len,
  output logic        rx_lpbk,
  output logic        rx_prom,
  output logic [47:0] rx_padr,
  output logic [63:0] rx_ladrf
);

  localparam logic [3:0] CX = 4'h8, FR = 4'h4, CNA = 4'h2, RNR = 4'h1;   // SCB status <15:12>
  localparam logic [2:0] CU_IDLE = 3'd0, CU_SUSPENDED = 3'd1, CU_ACTIVE = 3'd2;
  localparam logic [2:0] RU_IDLE = 3'd0, RU_SUSPENDED = 3'd1, RU_NO_RESOURCES = 3'd2, RU_READY = 3'd4;
  localparam logic [15:0] NONE = 16'hFFFF;

  typedef enum logic [6:0] {
    E_IDLE, E_ADDR, E_MEM,
    E_INIT1, E_INIT2, E_INIT3, E_INIT4, E_INIT5, E_INIT6, E_INIT7,
    E_CA1, E_CA2, E_RUS, E_CU0, E_CU1, E_CU2, E_CU3, E_DUMP1, E_DUMP2, E_CU4, E_CU5, E_CU6,
    E_IA1, E_IA2, E_IA3, E_CF1, E_CF2, E_MC1,
    E_TX0, E_TXA1, E_TXA2, E_TXA3, E_TXA4, E_TXP, E_TBD0, E_TBD1, E_TBD2, E_TBD3, E_TBD4,
    E_TXD0, E_TXD1, E_TXW0, E_TXW,
    E_RX0, E_RX1, E_RX2, E_RXA1, E_RXA2, E_RXA3, E_RBD0, E_RBD1, E_RBD2, E_RBD3, E_RBD4,
    E_RXD0, E_RXD1, E_RXD2, E_RBDW, E_RBDW2, E_RXDRAIN, E_RXDRAIN2, E_RFD1, E_RFD2, E_RFD3,
    E_ACC, E_STATUS, E_DONE
  } estate_t;
  estate_t     st, ret;

  logic        in_reset, ca, ca_pend, need_init;
  logic        txw;                   // a transmit waits for the wire (in E_IDLE)
  logic        rx_first;              // the next frame takes the RFD's RBD offset
  logic [3:0]  stat;
  logic [2:0]  cus, rus;
  logic [15:0] cbl, cmd, c, v, lo;
  logic [16:0] iscp, scb_base, scb, cb, d;   // the chip only addresses the 128 KB buffer
  logic [7:0]  di;
  logic [12:0] n;

  // taken from the commands
  logic [47:0] ia;                    // [7:0] the first byte on the wire
  logic        cfg_alloc, cfg_prom, cfg_bcdis, cfg_lpbk, mc_any;

  // receive unit
  logic [15:0] rfa, cur_rbd, first_rbd, rfd_cmd, rfd_link, rbd_next;
  logic [16:0] rfd, rbd, pos;         // byte addresses
  logic [13:0] rbd_size, act;
  logic        rbd_el, rsc;           // the frame ran out of buffers
  logic [11:0] left;                  // frame bytes still to store (FCS excluded)
  logic [15:0] w;                     // a popped word
  logic [2:0]  pi;                    // a word of the frame's address fields

  // transmit
  logic [15:0] tbd, tbd_next;
  logic [16:0] tb;                    // the TBD's address
  logic [13:0] tcount;
  logic        teof, tenp, first;
  logic [23:0] tpos, tend;
  logic [15:0] pre [7];               // AL-LOC 0: destination, source, length, as memory words
  logic [11:0] tlen;
  logic [1:0]  wait2;

  assign irq = !in_reset && stat != 4'd0;
  assign busy = st != E_IDLE || txw;
  assign rx_padr = ia;
  assign rx_prom = cfg_prom;
  assign rx_lpbk = cfg_lpbk;
  assign rx_ladrf = mc_any ? '1 : '0;
  assign tx_crcgen = 1'b1;
  assign tx_len = tlen;
  assign tx_enp = tenp;

  // Every descriptor access goes through one address adder: the tasks latch
  // a base and an offset, E_ADDR forms the address, E_MEM waits for the
  // buffer memory. (One adder a call site made the chip three times its size.)
  logic [16:0] ab;
  logic [15:0] ao;
  logic [1:0]  ak;                    // 0 read, 1 write a word, 2 write a byte
  wire  [16:0] sum = ab + {1'b0, ao};
  task automatic rd16(input logic [16:0] b, input logic [15:0] o, input estate_t r);
    ab <= b; ao <= o; ak <= 2'd0; ret <= r; st <= E_ADDR;
  endtask
  task automatic wr16(input logic [16:0] b, input logic [15:0] o, input logic [15:0] x, input estate_t r);
    ab <= b; ao <= o; ak <= 2'd1; m_wdata <= x; ret <= r; st <= E_ADDR;
  endtask
  task automatic wr8(input logic [16:0] b, input logic [15:0] o, input logic [7:0] x, input estate_t r);
    ab <= b; ao <= o; ak <= 2'd2; m_wdata <= {x, x}; ret <= r; st <= E_ADDR;
  endtask

  always_ff @(posedge clk) begin
    tx_push <= 1'b0; tx_stp <= 1'b0; tx_clr <= 1'b0;
    rx_pop <= 1'b0; rx_clr <= 1'b0;
    if (reset) begin
      st <= E_IDLE;
      m_req <= 1'b0;
      in_reset <= 1'b1;
      need_init <= 1'b1;
      ca <= 1'b0; ca_pend <= 1'b0;
      txw <= 1'b0; rx_first <= 1'b0;
      stat <= '0; cus <= CU_IDLE; rus <= RU_IDLE;
      cbl <= NONE;
      ia <= '0;
      {cfg_alloc, cfg_prom, cfg_bcdis, cfg_lpbk, mc_any} <= '0;
      rfa <= NONE; cur_rbd <= NONE;
      tenp <= 1'b0; tlen <= '0;
    end else begin
      // I82586::control
      if (pins_we) begin
        ca <= pins[6];
        if (!pins[7]) begin
          in_reset <= 1'b1;
          need_init <= 1'b1;
          ca_pend <= 1'b0;
          stat <= '0; cus <= CU_IDLE; rus <= RU_IDLE;
          {cfg_alloc, cfg_prom, cfg_bcdis, cfg_lpbk, mc_any} <= '0;
          tx_clr <= 1'b1; rx_clr <= 1'b1;
          tenp <= 1'b0; tlen <= '0;
          txw <= 1'b0;
          if (st != E_IDLE) begin st <= E_IDLE; m_req <= 1'b0; end
        end else begin
          in_reset <= 1'b0;
          if (ca && !pins[6]) ca_pend <= 1'b1;
        end
      end

      case (st)
        E_IDLE:
          if (ca_pend && !in_reset) begin
            ca_pend <= 1'b0;
            st <= need_init ? E_INIT1 : E_CA1;
          end else if (rx_fifordy) begin
            if (rus == RU_READY && !in_reset) begin
              rfd <= scb_base + {1'b0, rfa};
              left <= rx_len >= 12'd4 ? rx_len - 12'd4 : 12'd0;
              rsc <= 1'b0;
              rd16(scb_base, rfa + 16'd2, E_RX0);
            end else rx_clr <= 1'b1;
          end else if (txw && !tx_busy) begin       // the wire has the frame: C, OK
            txw <= 1'b0;
            wr16(cb, 16'd0, 16'hA000, E_CU5);
          end

        E_ADDR: begin
          m_req <= 1'b1; m_we <= ak != 2'd0;
          m_word <= sum[16:2]; m_hi <= sum[1];
          m_be <= ak == 2'd2 ? (sum[0] ? 2'b10 : 2'b01) : 2'b11;
          st <= E_MEM;
        end
        E_MEM: if (m_ack) begin
          m_req <= 1'b0;
          v <= m_hi ? m_rdata[31:16] : m_rdata[15:0];
          st <= ret;
        end

        // ---- after RESET: SCP (ISCP address at 0xFFFFFC) -> ISCP -> SCB
        E_INIT1: rd16(17'h1FFFC, 16'd0, E_INIT2);
        E_INIT2: begin lo <= v; rd16(17'h1FFFE, 16'd0, E_INIT3); end
        E_INIT3: begin
          iscp <= {v[0], lo};
          rd16({v[0], lo}, 16'd4, E_INIT4);
        end
        E_INIT4: begin lo <= v; rd16(iscp, 16'd6, E_INIT5); end
        E_INIT5: begin scb_base <= {v[0], lo}; rd16(iscp, 16'd2, E_INIT6); end
        E_INIT6: begin scb <= scb_base + {1'b0, v}; rd16(iscp, 16'd0, E_INIT7); end
        E_INIT7: begin
          wr16(iscp, 16'd0, v & 16'hFF00, E_STATUS);   // clear the busy byte
          need_init <= 1'b0;
          stat <= CX | CNA;
          cus <= CU_IDLE;
          rus <= RU_IDLE;
          rfa <= NONE; cur_rbd <= NONE;
        end

        // ---- channel attention: the SCB command word
        E_CA1: rd16(scb, 16'd2, E_CA2);
        E_CA2: begin
          cmd <= v;
          stat <= stat & ~v[15:12];
          n <= '0;
          if (v[7]) begin             // software reset: set up again at the next CA
            need_init <= 1'b1;
            stat <= '0; cus <= CU_IDLE; rus <= RU_IDLE;
            if (txw) begin txw <= 1'b0; tx_clr <= 1'b1; end
            wr16(scb, 16'd2, 16'd0, E_DONE);
          end else begin
            case (v[6:4])
              3'd1: rd16(scb, 16'd6, E_RUS);           // start: the RFA offset
              3'd2: begin if (rus == RU_SUSPENDED) rus <= RU_READY; wr16(scb, 16'd2, 16'd0, E_CU0); end
              3'd3: begin if (rus == RU_READY) rus <= RU_SUSPENDED; wr16(scb, 16'd2, 16'd0, E_CU0); end
              3'd4: begin rus <= RU_IDLE; wr16(scb, 16'd2, 16'd0, E_CU0); end
              default: wr16(scb, 16'd2, 16'd0, E_CU0);
            endcase
          end
        end
        E_RUS: begin
          rfa <= v; cur_rbd <= NONE; rus <= RU_READY; rx_first <= 1'b1;
          wr16(scb, 16'd2, 16'd0, E_CU0);
        end
        E_CU0:
          case (cmd[10:8])
            3'd1: if (txw) st <= E_ACC; else rd16(scb, 16'd4, E_CU1);   // start: the command list
            3'd2: begin if (cus == CU_SUSPENDED) cus <= CU_ACTIVE; st <= E_ACC; end
            3'd3: begin if (cus == CU_ACTIVE) begin cus <= CU_SUSPENDED; stat <= stat | CNA; end st <= E_ACC; end
            3'd4: begin if (cus != CU_IDLE) begin cus <= CU_IDLE; stat <= stat | CNA; end st <= E_ACC; end
            default: st <= E_ACC;
          endcase
        E_CU1: begin cbl <= v; cus <= CU_ACTIVE; st <= E_ACC; end
        E_ACC: wr16(scb, 16'd0, {stat, 1'b0, cus, 1'b0, rus, 4'd0}, E_CU2);   // the command taken: CU and RU state

        // ---- command unit: one command block a pass
        E_CU2:
          if (cus != CU_ACTIVE || n[12] || txw) st <= E_STATUS;
          else if (cbl == NONE) begin
            cus <= CU_IDLE;
            stat <= stat | CNA;
            st <= E_STATUS;
          end else begin
            cb <= scb_base + {1'b0, cbl};
            rd16(scb_base, cbl + 16'd2, E_CU3);
          end
        E_CU3: begin
          c <= v;
          case (v[2:0])
            3'd1: rd16(cb, 16'd6, E_IA1);               // IA setup
            3'd2: rd16(cb, 16'd8, E_CF1);               // configure
            3'd3: rd16(cb, 16'd6, E_MC1);               // MC setup
            3'd4: begin tlen <= '0; tenp <= 1'b0; first <= 1'b1; rd16(cb, 16'd6, E_TX0); end
            3'd5: wr16(cb, 16'd6, 16'h87FF, E_CU4);     // TDR: link OK, no reflection
            3'd6: rd16(cb, 16'd6, E_DUMP1);             // DUMP: zeros
            default: wr16(cb, 16'd0, 16'hA000, E_CU5);          // NOP, DIAGNOSE: C, OK
          endcase
        end
        E_IA1: begin ia[15:0] <= v; rd16(cb, 16'd8, E_IA2); end
        E_IA2: begin ia[31:16] <= v; rd16(cb, 16'd10, E_IA3); end
        E_IA3: begin ia[47:32] <= v; wr16(cb, 16'd0, 16'hA000, E_CU5); end
        E_CF1: begin                                     // byte 9: AL-LOC, loopback
          cfg_alloc <= v[11];
          cfg_lpbk <= v[14] | v[15];
          rd16(cb, 16'd14, E_CF2);
        end
        E_CF2: begin                                     // byte 14: PRM, BC-DIS
          cfg_prom <= v[0];
          cfg_bcdis <= v[1];
          wr16(cb, 16'd0, 16'hA000, E_CU5);
        end
        E_MC1: begin mc_any <= v[13:0] >= 14'd6; wr16(cb, 16'd0, 16'hA000, E_CU5); end
        E_DUMP1: begin d <= scb_base + {1'b0, v}; di <= '0; st <= E_DUMP2; end
        E_DUMP2:
          if (di == 8'd170) st <= E_CU4;
          else begin
            di <= di + 8'd2;
            wr16(d, {8'd0, di}, 16'd0, E_DUMP2);
          end
        E_CU4: wr16(cb, 16'd0, 16'hA000, E_CU5);
        E_CU5: begin
          if (c[13]) stat <= stat | CX;
          rd16(cb, 16'd4, E_CU6);
        end
        E_CU6: begin
          if (c[15]) begin cus <= CU_IDLE; stat <= stat | CNA; end
          else if (c[14]) begin cus <= CU_SUSPENDED; stat <= stat | CNA; end
          cbl <= v;
          n <= n + 13'd1;
          st <= E_CU2;
        end

        // ---- transmit: the block's TBD chain to the wire
        E_TX0: begin
          tbd <= v;
          if (cfg_alloc) st <= E_TBD0;
          else rd16(cb, 16'd8, E_TXA1);
        end
        E_TXA1: begin pre[0] <= v; rd16(cb, 16'd10, E_TXA2); end
        E_TXA2: begin pre[1] <= v; rd16(cb, 16'd12, E_TXA3); end
        E_TXA3: begin pre[2] <= v; rd16(cb, 16'd14, E_TXA4); end
        E_TXA4: begin
          pre[3] <= ia[15:0]; pre[4] <= ia[31:16]; pre[5] <= ia[47:32]; pre[6] <= v;
          pi <= '0; tlen <= 12'd14;
          st <= E_TXP;
        end
        E_TXP:                                            // the 14 header bytes
          if (!tx_busy || !first) begin
            tx_push <= 1'b1; tx_stp <= first; first <= 1'b0;
            tx_be <= 2'b11; tx_d <= {pre[pi][7:0], pre[pi][15:8]};
            pi <= pi + 3'd1;
            if (pi == 3'd6) st <= E_TBD0;
          end
        E_TBD0:
          if (tbd == NONE) begin tenp <= 1'b1; st <= E_TXW0; end   // no (more) buffers
          else begin tb <= scb_base + {1'b0, tbd}; rd16(scb_base, tbd, E_TBD1); end
        E_TBD1: begin tcount <= v[13:0]; teof <= v[15]; rd16(tb, 16'd2, E_TBD2); end
        E_TBD2: begin tbd_next <= v; rd16(tb, 16'd4, E_TBD3); end
        E_TBD3: begin lo <= v; rd16(tb, 16'd6, E_TBD4); end
        E_TBD4: begin
          tpos <= {v[7:0], lo};
          tend <= {v[7:0], lo} + {10'd0, tcount};
          tlen <= tlen + tcount[11:0];
          tenp <= teof;
          st <= E_TXD0;
        end
        E_TXD0:
          if (tpos >= tend) begin
            if (teof) st <= E_TXW0;
            else begin tbd <= tbd_next; st <= E_TBD0; end
          end else if (!tx_busy || !first) rd16({tpos[16:1], 1'b0}, 16'd0, E_TXD1);
        E_TXD1: begin                                     // bytes e (v[7:0]) and e+1 (v[15:8]) of the word at e
          tx_push <= 1'b1; tx_stp <= first; first <= 1'b0;
          tx_d <= {v[7:0], v[15:8]};
          tx_be <= {~tpos[0], {tpos[23:1], 1'b1} < tend};
          tpos <= {tpos[23:1], 1'b0} + 24'd2;
          st <= E_TXD0;
        end
        E_TXW0: begin                                     // let tx_busy rise after the last push
          wait2 <= 2'd2;
          st <= E_TXW;
        end
        E_TXW:
          if (wait2 != 2'd0) wait2 <= wait2 - 2'd1;
          else if (tlen == 12'd0) begin tx_clr <= 1'b1; wr16(cb, 16'd0, 16'hA000, E_CU5); end
          else if (!tx_busy) wr16(cb, 16'd0, 16'hA000, E_CU5); // the wire has it: C, OK
          else begin txw <= 1'b1; st <= E_IDLE; end            // wait in E_IDLE, serving CAs

        // ---- receive: a frame from the wire into the RFD and its RBDs
        E_RX0: begin rfd_cmd <= v; rd16(rfd, 16'd4, E_RX1); end
        E_RX1: begin rfd_link <= v; rd16(rfd, 16'd6, E_RX2); end
        E_RX2: begin : rx2
          logic [15:0] nb;
          nb = rx_first && v != NONE ? v : cur_rbd;
          rx_first <= 1'b0;
          first_rbd <= nb;
          cur_rbd <= nb;
          if (nb == NONE) begin                           // no buffers at all
            rus <= RU_NO_RESOURCES; stat <= stat | RNR;
            rx_clr <= 1'b1;
            st <= E_STATUS;
          end else begin
            rbd <= scb_base + {1'b0, nb};
            pi <= '0;
            st <= cfg_alloc ? E_RBD0 : E_RXA1;
          end
        end
        E_RXA1:                                           // AL-LOC 0: destination, source, length into the RFD
          if (rx_fifordy) begin w <= rx_d; rx_pop <= 1'b1; st <= E_RXA2; end
          else begin rsc <= 1'b1; st <= E_RFD1; end
        E_RXA2: begin
          left <= left >= 12'd2 ? left - 12'd2 : 12'd0;
          wr16(rfd, {12'd0, pi, 1'b0} + 16'd8, {w[7:0], w[15:8]}, E_RXA3);
        end
        E_RXA3: begin
          pi <= pi + 3'd1;
          st <= pi == 3'd6 ? E_RBD0 : E_RXA1;
        end
        E_RBD0: rd16(rbd, 16'd2, E_RBD1);
        E_RBD1: begin rbd_next <= v; rd16(rbd, 16'd4, E_RBD2); end
        E_RBD2: begin lo <= v; rd16(rbd, 16'd6, E_RBD3); end
        E_RBD3: begin pos <= {v[0], lo}; rd16(rbd, 16'd8, E_RBD4); end
        E_RBD4: begin rbd_size <= v[13:0]; rbd_el <= v[15]; act <= '0; st <= E_RXD0; end
        E_RXD0:
          if (left == 12'd0 || act >= rbd_size) st <= E_RBDW;
          else if (rx_fifordy) begin w <= rx_d; rx_pop <= 1'b1; st <= E_RXD1; end
          else begin rsc <= 1'b1; st <= E_RBDW; end      // the offer was withdrawn
        E_RXD1:
          if (left >= 12'd2 && rbd_size - act >= 14'd2) begin
            wr16(pos, 16'd0, {w[7:0], w[15:8]}, E_RXD2);
            pos <= pos + 17'd2; act <= act + 14'd2; left <= left - 12'd2;
          end else begin
            wr8(pos, 16'd0, w[15:8], E_RXD2);
            pos <= pos + 17'd1; act <= act + 14'd1; left <= left - 12'd1;
          end
        E_RXD2: st <= E_RXD0;
        E_RBDW: wr16(rbd, 16'd0, {left == 12'd0 && !rsc, 1'b1, act}, E_RBDW2);   // EOF, F, actual count
        E_RBDW2:
          if (left == 12'd0 || rsc) begin
            cur_rbd <= rbd_el ? NONE : rbd_next;
            st <= E_RXDRAIN;
          end else if (rbd_el) begin                      // out of buffers inside the frame
            cur_rbd <= NONE; rsc <= 1'b1;
            rus <= RU_NO_RESOURCES; stat <= stat | RNR;
            st <= E_RXDRAIN;
          end else begin
            cur_rbd <= rbd_next;
            rbd <= scb_base + {1'b0, rbd_next};
            st <= E_RBD0;
          end
        E_RXDRAIN:                                        // the FCS, and the rest of a truncated frame
          if (!rx_fifordy) st <= E_RFD1;
          else begin rx_pop <= 1'b1; st <= E_RXDRAIN2; end
        E_RXDRAIN2: st <= E_RXDRAIN;
        E_RFD1: wr16(rfd, 16'd6, first_rbd, E_RFD2);
        E_RFD2: wr16(rfd, 16'd0, rsc ? 16'h8200 : 16'hA000, E_RFD3);   // C; OK, or no resources
        E_RFD3: begin
          if (rfd_cmd[15]) begin rus <= RU_NO_RESOURCES; stat <= stat | FR | RNR; end
          else if (rfd_cmd[14]) begin rus <= RU_SUSPENDED; stat <= stat | FR | RNR; end
          else stat <= stat | FR;
          rfa <= rfd_link;
          st <= E_STATUS;
        end

        E_STATUS: wr16(scb, 16'd0, {stat, 1'b0, cus, 1'b0, rus, 4'd0}, E_DONE);
        E_DONE: st <= E_IDLE;
        default: st <= E_IDLE;
      endcase
    end
  end

endmodule
