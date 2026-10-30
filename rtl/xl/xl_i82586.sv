// Intel 82586 Ethernet coprocessor with no network attached; follows
// emu/i82586.cpp (which describes what Genera needs) operation for operation.
//
// The chip sees the I/O board's buffer memory as bytes: its address bits 16:0,
// low byte of each word first, so it reaches buffer words 0-0x7FFF in 16-bit
// halves (m_hi selects bits 31:16).  Its pins come from the latch at
// 0x44016000: bit 7 releases RESET, a falling edge on bit 6 is channel
// attention, bit 5 releases loopback.  Channel attention runs the init
// handshake (SCP -> ISCP -> SCB) after a reset, otherwise the SCB command:
// acknowledgements, receive unit (goes ready, never receives) and command
// unit (every command completes OK; TDR reports the link OK, DUMP writes
// zeros).  busy is set while it works.
module xl_i82586 (
  input  logic        clk,
  input  logic        reset,
  input  logic        pins_we,
  input  logic [7:0]  pins,
  output logic        busy,
  output logic        irq,

  output logic        m_req,
  output logic        m_we,
  output logic [14:0] m_word,
  output logic        m_hi,
  output logic [15:0] m_wdata,
  input  logic        m_ack,
  input  logic [31:0] m_rdata
);

  localparam logic [3:0] CX = 4'h8, CNA = 4'h2;   // SCB status <15:12>
  localparam logic [2:0] CU_IDLE = 3'd0, CU_SUSPENDED = 3'd1, CU_ACTIVE = 3'd2;
  localparam logic [2:0] RU_IDLE = 3'd0, RU_SUSPENDED = 3'd1, RU_READY = 3'd4;

  typedef enum logic [4:0] {
    E_IDLE, E_MEM,
    E_INIT1, E_INIT2, E_INIT3, E_INIT4, E_INIT5, E_INIT6, E_INIT7,
    E_CA1, E_CA2, E_CU0, E_CU1, E_CU2, E_CU3, E_DUMP1, E_DUMP2, E_CU4, E_CU5, E_CU6,
    E_STATUS, E_DONE
  } estate_t;
  estate_t     st, ret;

  logic        in_reset, ca, need_init;
  logic [3:0]  stat;
  logic [2:0]  cus, rus;
  logic [15:0] cbl, cmd, c, v, lo;
  logic [23:0] iscp, scb_base, scb, cb, d;
  logic [7:0]  di;
  logic [12:0] n;

  assign irq = !in_reset && stat != 4'd0;
  assign busy = st != E_IDLE;

  task automatic rd16(input logic [23:0] b, input estate_t r);
    m_req <= 1'b1; m_we <= 1'b0; m_word <= b[16:2]; m_hi <= b[1];
    ret <= r; st <= E_MEM;
  endtask
  task automatic wr16(input logic [23:0] b, input logic [15:0] w, input estate_t r);
    m_req <= 1'b1; m_we <= 1'b1; m_word <= b[16:2]; m_hi <= b[1]; m_wdata <= w;
    ret <= r; st <= E_MEM;
  endtask

  always_ff @(posedge clk) begin
    if (reset) begin
      st <= E_IDLE;
      m_req <= 1'b0;
      in_reset <= 1'b1;
      need_init <= 1'b1;
      ca <= 1'b0;
      stat <= '0; cus <= CU_IDLE; rus <= RU_IDLE;
      cbl <= 16'hFFFF;
    end else begin
      // I82586::control
      if (pins_we) begin
        ca <= pins[6];
        if (!pins[7]) begin
          in_reset <= 1'b1;
          need_init <= 1'b1;
          stat <= '0; cus <= CU_IDLE; rus <= RU_IDLE;
        end else begin
          in_reset <= 1'b0;
          if (ca && !pins[6] && st == E_IDLE) st <= need_init ? E_INIT1 : E_CA1;
        end
      end

      case (st)
        E_MEM: if (m_ack) begin
          m_req <= 1'b0;
          v <= m_hi ? m_rdata[31:16] : m_rdata[15:0];
          st <= ret;
        end

        // ---- after RESET: SCP (ISCP address at 0xFFFFFC) -> ISCP -> SCB
        E_INIT1: rd16(24'hFFFFFC, E_INIT2);
        E_INIT2: begin lo <= v; rd16(24'hFFFFFE, E_INIT3); end
        E_INIT3: begin
          iscp <= {v[7:0], lo};
          rd16({v[7:0], lo} + 24'd4, E_INIT4);
        end
        E_INIT4: begin lo <= v; rd16(iscp + 24'd6, E_INIT5); end
        E_INIT5: begin scb_base <= {v[7:0], lo}; rd16(iscp + 24'd2, E_INIT6); end
        E_INIT6: begin scb <= scb_base + {8'd0, v}; rd16(iscp, E_INIT7); end
        E_INIT7: begin
          wr16(iscp, v & 16'hFF00, E_STATUS);   // clear the busy byte
          need_init <= 1'b0;
          stat <= CX | CNA;
          cus <= CU_IDLE;
          rus <= RU_IDLE;
        end

        // ---- channel attention: the SCB command word
        E_CA1: rd16(scb + 24'd2, E_CA2);
        E_CA2: begin
          cmd <= v;
          stat <= stat & ~v[15:12];
          n <= '0;
          if (v[7]) begin             // software reset: set up again at the next CA
            need_init <= 1'b1;
            stat <= '0; cus <= CU_IDLE; rus <= RU_IDLE;
            wr16(scb + 24'd2, 16'd0, E_DONE);
          end else begin
            case (v[6:4])
              3'd1: rus <= RU_READY;
              3'd2: if (rus == RU_SUSPENDED) rus <= RU_READY;
              3'd3: if (rus == RU_READY) rus <= RU_SUSPENDED;
              3'd4: rus <= RU_IDLE;
              default: ;
            endcase
            wr16(scb + 24'd2, 16'd0, E_CU0);
          end
        end
        E_CU0:
          case (cmd[10:8])
            3'd1: rd16(scb + 24'd4, E_CU1);   // start: the command list
            3'd2: begin if (cus == CU_SUSPENDED) cus <= CU_ACTIVE; st <= E_CU2; end
            3'd3: begin if (cus == CU_ACTIVE) begin cus <= CU_SUSPENDED; stat <= stat | CNA; end st <= E_CU2; end
            3'd4: begin if (cus != CU_IDLE) begin cus <= CU_IDLE; stat <= stat | CNA; end st <= E_CU2; end
            default: st <= E_CU2;
          endcase
        E_CU1: begin cbl <= v; cus <= CU_ACTIVE; st <= E_CU2; end

        // ---- command unit: one command block a pass
        E_CU2:
          if (cus != CU_ACTIVE || n[12]) st <= E_STATUS;
          else if (cbl == 16'hFFFF) begin
            cus <= CU_IDLE;
            stat <= stat | CNA;
            st <= E_STATUS;
          end else begin
            cb <= scb_base + {8'd0, cbl};
            rd16(scb_base + {8'd0, cbl} + 24'd2, E_CU3);
          end
        E_CU3: begin
          c <= v;
          case (v[2:0])
            3'd5: wr16(cb + 24'd6, 16'h87FF, E_CU4);   // TDR: link OK, no reflection
            3'd6: rd16(cb + 24'd6, E_DUMP1);           // DUMP: zeros
            default: wr16(cb, 16'hA000, E_CU5);        // C, OK
          endcase
        end
        E_DUMP1: begin d <= scb_base + {8'd0, v}; di <= '0; st <= E_DUMP2; end
        E_DUMP2:
          if (di == 8'd170) st <= E_CU4;
          else begin
            di <= di + 8'd2;
            wr16(d + {16'd0, di}, 16'd0, E_DUMP2);
          end
        E_CU4: wr16(cb, 16'hA000, E_CU5);
        E_CU5: begin
          if (c[13]) stat <= stat | CX;
          rd16(cb + 24'd4, E_CU6);
        end
        E_CU6: begin
          if (c[15]) begin cus <= CU_IDLE; stat <= stat | CNA; end
          else if (c[14]) begin cus <= CU_SUSPENDED; stat <= stat | CNA; end
          cbl <= v;
          n <= n + 13'd1;
          st <= E_CU2;
        end

        E_STATUS: wr16(scb, {stat, 1'b0, cus, 1'b0, rus, 4'd0}, E_DONE);
        E_DONE: st <= E_IDLE;
        default: ;
      endcase
    end
  end

endmodule
