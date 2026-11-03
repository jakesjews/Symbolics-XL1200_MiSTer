//============================================================================
//  Symbolics XL1200 for MiSTer: the Ivory processor and the XL1200's boards
//  (Merlin-II and the I/O board), booting the FEP from the machine's disks.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS   = 0;

localparam NT = 2;   // SCSI disks 0 and 1

`include "build_id.v"
localparam CONF_STR = {
	"XL1200;;",
	"-;",
	"S0,DD IMGVHD,SCSI disk 0;",
	"S1,DD IMGVHD,SCSI disk 1;",
	"-;",
	"O[2],Aspect ratio,Original,Full Screen;",
	"O[5:3],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"O[6],Clock,28 years back,Today;",
	"O[12],Display,Console,Color;",
`ifdef XL_DEBUG
	"O[7],Debug line,Off,On;",
`endif
	"O[10:8],Network,eth0,Off,eth1,macvlan,tap0;",
	"-;",
	"I,Processor halted,Memory port stalled;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire  [64:0] rtc;

wire  [NT-1:0] img_mounted;
wire           img_readonly;
wire    [63:0] img_size;
wire    [31:0] sd_lba[NT];
wire     [5:0] sd_blk_cnt[NT];
wire  [NT-1:0] sd_rd, sd_wr, sd_ack;
wire    [13:0] sd_buff_addr;
wire     [7:0] sd_buff_dout;
wire     [7:0] sd_buff_din[NT];
wire           sd_buff_wr;

reg        info_req = 0;      // an OSD message, below
reg  [7:0] info = 0;

wire [21:0]  gamma_bus;     // the OSD's gamma tables, to gamma_fast
hps_io #(.CONF_STR(CONF_STR), .VDNUM(NT), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.RTC(rtc),

	.info_req(info_req),
	.info(info)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_vid;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),    // 50 MHz: processor and boards
	.outclk_1(clk_vid)     // 80 MHz: the console's dot clock
);

// Power-up: DDR3 is cleared once after the core loads; the reset button
// restarts the machine without touching memory.
reg  [7:0] por = 0;
wire       power_on = ~&por;
always @(posedge clk_sys) if (power_on) por <= por + 1'd1;

// Mounting a disk while the boot PROM has halted for want of one starts the
// machine again, as pressing reset after connecting the disk would.
wire halted;
reg  reset;
reg  mount_reset;
always @(posedge clk_sys) begin
	mount_reset <= |img_mounted && halted;
	reset <= RESET | status[0] | buttons[1] | power_on | mount_reset;
end
reg ddr_reset;   // RESET alone, for the DDR3 port (xl_machine)
always @(posedge clk_sys) ddr_reset <= RESET;

// A message on the screen when the machine stops, through the framework's
// info strings (the I line of CONF_STR): 1 when the processor halts once a
// disk is there (a real XL1200's FEP announces a halt on the console; the
// boot PROM's halt for want of a disk is not news), 2 when the DDR3 port
// has held a command for 168 ms (a wedged port stops everything).
reg        halted_q = 0, disk_seen = 0, ddr_stalled = 0;
reg [22:0] ddr_wait = 0;
always @(posedge clk_sys) begin
	halted_q <= halted;
	if (|img_mounted) disk_seen <= 1;
	if (!(DDRAM_BUSY && (DDRAM_RD || DDRAM_WE))) ddr_wait <= 0;
	else if (!(&ddr_wait)) ddr_wait <= ddr_wait + 1'd1;
	ddr_stalled <= &ddr_wait;
	info_req <= 0;
	if (halted && !halted_q && disk_seen) begin info_req <= 1; info <= 8'd1; end
	else if (&ddr_wait && !ddr_stalled) begin info_req <= 1; info <= 8'd2; end
end

///////////////////////   CONSOLE   //////////////////////////////

wire       key_strobe, key_down;
wire [6:0] key_code;
xl_keyboard keyboard
(
	.clk(clk_sys),
	.ps2_key(ps2_key),
	.key_strobe(key_strobe),
	.key_down(key_down),
	.key_code(key_code)
);

// PS/2 mouse: status byte {.., Y sign, X sign, 1, M, R, L}, X, Y (up positive)
reg        mouse_strobe;
reg        mouse_seen;
reg  [2:0] mouse_buttons;
reg  signed [9:0] mouse_dx, mouse_dy;
always @(posedge clk_sys) begin
	mouse_strobe <= 0;
	mouse_seen <= ps2_mouse[24];
	if (ps2_mouse[24] != mouse_seen) begin
		mouse_strobe  <= 1;
		mouse_buttons <= {ps2_mouse[0], ps2_mouse[2], ps2_mouse[1]};
		mouse_dx <= {{2{ps2_mouse[4]}}, ps2_mouse[15:8]};
		mouse_dy <= -{{2{ps2_mouse[5]}}, ps2_mouse[23:16]};
	end
end

///////////////////////   MACHINE   //////////////////////////////

wire [28:0] ddr_addr;
wire  [7:0] ddr_burstcnt;
wire        ddr_rd, ddr_we, ddr_dout_ready, ddr_busy;
wire [63:0] ddr_din, ddr_dout;
wire  [7:0] ddr_be;

wire white, hs, vs, hblank, vblank;
wire [23:0] rgb;
wire        video_on;          // the board's video enable; unused since Display lost Auto
wire run_light, disk_light;

xl_machine #(.NT(NT), .CLK_HZ(50_000_000), .PROM_FILE("rtl/xl/boot_prom.mem")) machine
(
	.clk(clk_sys),
	.clk_vid(clk_vid),
	.power_on(power_on),
	.reset(reset),
	.fw_reset(ddr_reset),

	.ddr_addr(ddr_addr),
	.ddr_burstcnt(ddr_burstcnt),
	.ddr_rd(ddr_rd),
	.ddr_we(ddr_we),
	.ddr_din(ddr_din),
	.ddr_be(ddr_be),
	.ddr_dout(ddr_dout),
	.ddr_dout_ready(ddr_dout_ready),
	.ddr_busy(ddr_busy),

	.key_strobe(key_strobe),
	.key_down(key_down),
	.key_code(key_code),
	.mouse_strobe(mouse_strobe),
	.mouse_buttons(mouse_buttons),
	.mouse_dx(mouse_dx),
	.mouse_dy(mouse_dy),
	.rtc(rtc),
	.rtc_back28(~status[6]),
	.net_ena(status[10:8] != 3'd1),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.white(white),
	.hs(hs),
	.vs(vs),
	.hblank(hblank),
	.vblank(vblank),
	.rgb(rgb),
	.video_on(video_on),

	.run_light(run_light),
	.disk_light(disk_light),
	.halted(halted),
	.halt_reason(),
	.retire(),
	.insn_count(),
	.debug(debug_on),
	.dbg(dbg)
);

// The debug line is a debug build's (XL_DEBUG in the qsf). With it on, the
// same words go out on the UART (/dev/ttyS1 on the MiSTer, 115200 8N1) twice
// a second.
wire [31:0] dbg[8];
`ifdef XL_DEBUG
wire debug_on = status[7];
xl_debug_uart #(.CLK_HZ(50_000_000)) debug_uart
(
	.clk(clk_sys),
	.enable(status[7]),
	.words(dbg),
	.txd(UART_TXD)
);
`else
wire debug_on = 1'b0;
assign UART_TXD = 1'b1;
`endif

assign LED_USER = run_light;
assign LED_DISK = {1'b1, disk_light};

// DDR3: the machine's port (xl_machine: MiSTer's safe terminator, and no new
// command while RESET is up).
assign DDRAM_CLK = clk_sys;
assign DDRAM_ADDR = ddr_addr;
assign DDRAM_BURSTCNT = ddr_burstcnt;
assign DDRAM_RD = ddr_rd;
assign DDRAM_WE = ddr_we;
assign DDRAM_DIN = ddr_din;
assign DDRAM_BE = ddr_be;
assign ddr_dout = DDRAM_DOUT;
assign ddr_dout_ready = DDRAM_DOUT_READY;
assign ddr_busy = DDRAM_BUSY;

///////////////////////   VIDEO   ////////////////////////////////

// The console monitor: 1152 x 880, black on white, 80 MHz dot clock
// (54.35 kHz, 60.45 Hz) as the FEP programs the SCN2674.  The color
// board's screen runs on the same raster; Display picks which one shows and
// Pause switches to the other until Display is next changed. (Bit 11 was an
// Auto choice that followed Genera's video enable; a saved Auto reads as
// Console, a saved Console or Color as before.)  Pause comes from hps_io as
// one press event, E0 77, with no release.
reg        display_flip = 0;
reg        display_opt_q;
reg        pause_toggle_q;
always @(posedge clk_sys) begin
	pause_toggle_q <= ps2_key[10];
	display_opt_q  <= status[12];
	if (status[12] != display_opt_q) display_flip <= 0;
	else if (ps2_key[10] != pause_toggle_q && ps2_key[9:0] == 10'h377) display_flip <= ~display_flip;
end
reg  [1:0]  show_color_s;
wire        show_color = show_color_s[1];
always @(posedge clk_vid) show_color_s <= {show_color_s[0], status[12] ^ display_flip};
wire [23:0] pix = show_color ? rgb : {24{white}};
wire        vga_de;

assign CLK_VIDEO = clk_vid;
assign VGA_SL = 0;

// Gamma from the OSD through the framework's gamma_fast (three tables, one
// lookup a pixel), since the video clock is the pixel clock; the mixer's own
// gamma_corr reads its one table four times a pixel and would need a video
// clock four times the dot clock. Two pixels of latency, the syncs and
// blanking delayed with the pixels.
wire [23:0] pix_g;
wire        hs_g, vs_g, hblank_g, vblank_g;
gamma_fast gamma
(
	.clk_vid(CLK_VIDEO),
	.ce_pix(1'b1),
	.gamma_bus(gamma_bus),
	.HSync(hs), .VSync(vs), .HBlank(hblank), .VBlank(vblank), .DE(1'b0),
	.RGB_in(pix),
	.HSync_out(hs_g), .VSync_out(vs_g), .HBlank_out(hblank_g), .VBlank_out(vblank_g), .DE_out(),
	.RGB_out(pix_g)
);

video_mixer #(.LINE_LENGTH(1152), .HALF_DEPTH(0), .GAMMA(0)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(1'b1),

	// No scandoubler: the console's raster is 1152x880 progressive at 54.35 kHz
	// lines, and doubling it (MiSTer.ini's forced_scandoubler) would make 109 kHz
	// that no display takes. The constant removes the doubler and its Hq2x filter.
	.scandoubler(1'b0),
	.hq2x(1'b0),
	.gamma_bus(),

	.R(pix_g[23:16]),
	.G(pix_g[15:8]),
	.B(pix_g[7:0]),

	.HSync(hs_g),
	.VSync(vs_g),
	.HBlank(hblank_g),
	.VBlank(vblank_g),

	.HDMI_FREEZE(1'b0),
	.freeze_sync(),

	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_VS(VGA_VS),
	.VGA_HS(VGA_HS),
	.VGA_DE(vga_de)
);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de),
	.ARX(status[2] ? 12'd0 : 12'd1152),
	.ARY(status[2] ? 12'd0 : 12'd880),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[5:3])
);

endmodule
