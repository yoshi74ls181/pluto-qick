`timescale 1ns/1ps
//
// The TX command path: a tProc v2 waveform descriptor through sg_translator into
// axis_signal_gen_v6 at N_DDS=1, which is the link the loopback depends on and
// the one nothing had checked.
//
// tProc v2 descriptor, 168 bits (from qick_sg_translator/src/sg_translator.v):
//
//   [167:152] conf   ([4] phrst, [3] stdysel, [2] mode, [1:0] outsel)
//   [151:120] nsamp
//   [119: 88] gain
//   [ 87: 64] addr
//   [ 63: 32] phase
//   [ 31:  0] freq
//
// sg_translator is combinational rewiring only, which is why it costs zero LUTs
// in the implemented design -- worth asserting rather than assuming, since a
// silently mis-mapped field would produce a pulse with the wrong frequency or
// length and look like an analog problem on hardware.
//
// Phase 2 uses outsel=1 (DDS only) so no envelope has to be loaded into the
// generator's memory: the point here is the command path, not the envelope.
//
module tb_sg_chain;

localparam real FS  = 30.72e6;
localparam real TCK = 1e9/FS/2.0;
localparam real PI  = 3.14159265358979;

reg clk = 0, rstn = 0;
always #TCK clk = ~clk;

reg  [167:0] desc  = 0;
reg          dvalid = 0;
wire [159:0] gen_tdata;
wire         gen_tvalid, gen_tready;

sg_translator #(.OUT_TYPE(0)) sgt (
    .aresetn(rstn), .aclk(clk),
    .s_axis_tdata(desc), .s_axis_tvalid(dvalid), .s_axis_tready(),
    .m_gen_v6_axis_tdata(gen_tdata), .m_gen_v6_axis_tvalid(gen_tvalid),
    .m_gen_v6_axis_tready(gen_tready));

wire [31:0] m_tdata;
wire        m_tvalid;

axis_signal_gen_v6 #(.N(12), .N_DDS(1), .ENVELOPE_TYPE("COMPLEX"), .GEN_DDS("TRUE")) sg (
    .s_axi_aclk(clk), .s_axi_aresetn(rstn),
    .s_axi_awaddr(6'd0), .s_axi_awprot(3'd0), .s_axi_awvalid(1'b0), .s_axi_awready(),
    .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0), .s_axi_wvalid(1'b0), .s_axi_wready(),
    .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(1'b0),
    .s_axi_araddr(6'd0), .s_axi_arprot(3'd0), .s_axi_arvalid(1'b0), .s_axi_arready(),
    .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b0),
    .aresetn(rstn), .aclk(clk),
    .s0_axis_aclk(clk), .s0_axis_aresetn(rstn),
    .s0_axis_tdata(32'd0), .s0_axis_tvalid(1'b0), .s0_axis_tready(),
    .s1_axis_tdata(gen_tdata), .s1_axis_tvalid(gen_tvalid), .s1_axis_tready(gen_tready),
    .m_axis_tready(1'b1), .m_axis_tvalid(m_tvalid), .m_axis_tdata(m_tdata));

integer errs = 0, n, nz, nint;
real    mag, mmin, mmax;

task chk(input [8*40-1:0] what, input integer got, input integer want);
begin
    if (got !== want) begin
        $display("  FAIL %0s: got %0d want %0d", what, got, want);
        errs = errs + 1;
    end
end
endtask

reg [31:0] f_want, p_want;
reg [15:0] g_want, ns_want, a_want;
reg [1:0]  os_want;

initial begin
    repeat (8) @(posedge clk);
    rstn = 1;
    repeat (8) @(posedge clk);

    $display("");
    $display("Phase 1  descriptor field mapping through sg_translator");
    for (n = 0; n < 200; n = n + 1) begin
        f_want  = $random;  p_want = $random;
        g_want  = $random;  ns_want = $random;  a_want = $random;
        os_want = n[1:0];
        desc = {11'd0, 1'b0, 1'b0, n[2], os_want,   // conf[15:0]
                {16'd0, ns_want},                   // nsamp  [151:120]
                {16'd0, g_want},                    // gain   [119: 88]
                {8'd0,  a_want},                    // addr   [ 87: 64]
                p_want,                             // phase  [ 63: 32]
                f_want};                            // freq   [ 31:  0]
        #1;
        chk("freq",   gen_tdata[31:0],     f_want);
        chk("phase",  gen_tdata[63:32],    p_want);
        chk("addr",   gen_tdata[79:64],    a_want);
        chk("gain",   gen_tdata[111:96],   g_want);
        chk("nsamp",  gen_tdata[143:128],  ns_want);
        chk("outsel", gen_tdata[145:144],  os_want);
        chk("mode",   gen_tdata[146],      n[2]);
        chk("pad_hi", gen_tdata[159:149],  0);
        @(posedge clk);
    end
    $display("  200 random descriptors, errors = %0d", errs);
    if (errs == 0) $display("  PASS  every field lands where the generator expects it");

    $display("");
    $display("Phase 2  a DDS-only pulse actually comes out");
    // outsel=1 (dds), mode=0 (one-shot), nsamp in generator clocks
    desc = {11'd0, 1'b0, 1'b0, 1'b0, 2'b01,
            {16'd0, 16'd64},              // nsamp = 64
            {16'd0, 16'h7fff},            // gain  = max
            {8'd0,  16'd0},               // addr
            32'd0,                        // phase
            32'd200000000};               // freq: ~1.43 MHz at fs/2^32
    @(posedge clk); dvalid = 1; @(posedge clk); dvalid = 0;

    // Count the whole pulse for length, but measure the envelope only on its
    // interior: the generator's DDS has latency 10, so the leading samples come
    // out before the phase pipeline has filled and are not representative.
    nz = 0; mmin = 1e30; mmax = -1e30; nint = 0;
    for (n = 0; n < 400; n = n + 1) begin
        @(posedge clk);
        if (m_tvalid) begin
            mag = $sqrt($itor($signed(m_tdata[15:0]))*$itor($signed(m_tdata[15:0]))
                      + $itor($signed(m_tdata[31:16]))*$itor($signed(m_tdata[31:16])));
            if (mag > 100.0) begin
                nz = nz + 1;
                if (nz > 16 && nz <= 56) begin   // interior only
                    nint = nint + 1;
                    if (mag < mmin) mmin = mag;
                    if (mag > mmax) mmax = mag;
                end
                if (nz <= 3 || (nz > 14 && nz <= 17))
                    $display("    sample %0d: I=%0d Q=%0d |out|=%0.0f", nz,
                             $signed(m_tdata[15:0]), $signed(m_tdata[31:16]), mag);
            end
        end
    end
    $display("  samples with |out| > 100 : %0d  (nsamp commanded = 64)", nz);
    if (nint > 0)
        $display("  interior (%0d samples): |out| range [%0.0f, %0.0f], ripple %0.2f %%",
                 nint, mmin, mmax, 100.0*(mmax-mmin)/mmax);
    if (nz >= 32) $display("  PASS  the descriptor produced a pulse");
    else begin $display("  FAIL  no pulse emerged"); errs = errs + 1; end

    $display("");
    $display(errs == 0 ? "ALL PASS" : "FAILURES");
    $display("");
    $finish;
end

endmodule
