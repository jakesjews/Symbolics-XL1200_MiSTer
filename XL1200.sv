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
	"O[7],Debug line,Off,On;",
	"-;",
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
wire         forced_scandoubler;

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

hps_io #(.CONF_STR(CONF_STR), .VDNUM(NT), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

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
	.RTC(rtc)
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
wire run_light, disk_light;

xl_machine #(.NT(NT), .CLK_MHZ(50), .PROM_FILE("rtl/xl/boot_prom.mem")) machine
(
	.clk(clk_sys),
	.clk_vid(clk_vid),
	.power_on(power_on),
	.reset(reset),

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

	.run_light(run_light),
	.disk_light(disk_light),
	.halted(halted),
	.halt_reason(),
	.retire(),
	.insn_count(),
	.debug(status[7]),
	.dbg(dbg)
);

// With the debug line on, the same words go out on the UART (/dev/ttyS1 on
// the MiSTer, 115200 8N1) twice a second.
wire [31:0] dbg[8];
xl_debug_uart debug_uart
(
	.clk(clk_sys),
	.enable(status[7]),
	.words(dbg),
	.txd(UART_TXD)
);

assign LED_USER = run_light;
assign LED_DISK = {1'b1, disk_light};

// DDR3: a burst cut short by a reset (e.g. when another core loads) would
// wedge the HPS port; the terminator finishes it.
assign DDRAM_CLK = clk_sys;
reg ddr_reset;
always @(posedge clk_sys) ddr_reset <= RESET;
f2sdram_safe_terminator #(.DATA_WIDTH(64), .BURSTCOUNT_WIDTH(8)) ddr_terminator
(
	.clk(clk_sys),
	.rst_req_sync(ddr_reset),

	.waitrequest_master(DDRAM_BUSY),
	.burstcount_master(DDRAM_BURSTCNT),
	.address_master(DDRAM_ADDR),
	.readdata_master(DDRAM_DOUT),
	.readdatavalid_master(DDRAM_DOUT_READY),
	.read_master(DDRAM_RD),
	.writedata_master(DDRAM_DIN),
	.byteenable_master(DDRAM_BE),
	.write_master(DDRAM_WE),

	.waitrequest_slave(ddr_busy),
	.burstcount_slave(ddr_burstcnt),
	.address_slave(ddr_addr),
	.readdata_slave(ddr_dout),
	.readdatavalid_slave(ddr_dout_ready),
	.read_slave(ddr_rd),
	.writedata_slave(ddr_din),
	.byteenable_slave(ddr_be),
	.write_slave(ddr_we)
);

///////////////////////   VIDEO   ////////////////////////////////

// The console monitor: 1152 x 880, black on white, 80 MHz dot clock
// (54.35 kHz, 60.45 Hz) as the FEP programs the SCN2674.
wire [7:0] grey = {8{white}};
wire       vga_de;

assign CLK_VIDEO = clk_vid;
assign VGA_SL = 0;

// No gamma: gamma_corr samples on the rising edge of ce_pix, which needs a
// video clock four times the pixel rate, and the dot clock is the pixel rate.
video_mixer #(.LINE_LENGTH(1152), .HALF_DEPTH(1), .GAMMA(0)) video_mixer
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.ce_pix(1'b1),

	.scandoubler(forced_scandoubler),
	.hq2x(1'b0),
	.gamma_bus(),

	.R(grey[7:4]),
	.G(grey[7:4]),
	.B(grey[7:4]),

	.HSync(hs),
	.VSync(vs),
	.HBlank(hblank),
	.VBlank(vblank),

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
