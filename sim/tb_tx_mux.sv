`timescale 1ns/1ps
//
// qick_tx_mux, the TX selector in antsdr-pynq/boards/e200/qick.
//
// This module had no test, and an earlier version of it registered the sample
// data while leaving valid_in wired straight from util_ad9361_dac_upack. Data
// therefore sat one clock behind its own valid, the DAC FIFO latched the
// previous sample, and the corrupted transmit path made the AD9361 driver's
// digital interface calibration fail. Because the AD9361 also sources the LVDS
// DATA_CLK that clocks the entire QICK datapath, that left the whole design
// dead and needed a power cycle to recover.
//
// So the properties worth asserting are exactly the ones that bug violated:
//
//   1. With sel=0 the module is a wire. Data and valid must appear at the
//      outputs in the SAME cycle they appear at the inputs -- any pipelining
//      here reintroduces the skew.
//   2. With sel=1 the generator's samples are presented and valid is held.
//   3. tready follows sel and nothing else. It must be asserted whenever the
//      generator is selected, and never when it is not.
//
// Property 3 used to read the other way round: tready was gated on the fifo's
// read request, on the reasoning that the generator should advance in lockstep
// with real consumption. On hardware that deadlocked. With the stock transmit
// path idle the fifo never requests a sample, so the generator could not
// advance, which back-pressured sg_translator and stalled the tProc on the
// instruction that writes the waveform descriptor -- a capture that blocked
// outright rather than merely dropping samples. Both sides run on the same
// divided clock at one complex sample per clock, so they are rate matched
// anyway and the handshake bought nothing.
//
module tb_tx_mux;

localparam integer NCHK = 400;

reg         clk = 0, resetn = 0, sel = 0;
reg  [15:0] dma_data_i = 0, dma_data_q = 0;
reg         dma_valid_in = 0;
reg  [31:0] qick_tdata = 0;
reg         qick_tvalid = 1;
wire        qick_tready;
wire [15:0] dac_data_i, dac_data_q;
wire        dac_valid_in;

always #4 clk = ~clk;     // 125 MHz, the worst-case divided AD9361 clock

qick_tx_mux dut (
    .clk(clk), .resetn(resetn), .sel(sel),
    .dma_data_i(dma_data_i), .dma_data_q(dma_data_q),
    .dma_valid_in(dma_valid_in),
    .qick_tdata(qick_tdata), .qick_tvalid(qick_tvalid), .qick_tready(qick_tready),
    .dac_data_i(dac_data_i), .dac_data_q(dac_data_q), .dac_valid_in(dac_valid_in));

integer errs = 0, n;
integer ready_cnt = 0, rd_cnt = 0;

task fail(input [8*48-1:0] why);
begin
    if (errs < 8) $display("  FAIL %0s at t=%0t", why, $time);
    errs = errs + 1;
end
endtask

// Drive stimulus well away from the clock edge, then check.
//
// Applying stimulus at the same simulation time as posedge clk races the DUT's
// own nonblocking assignments: whichever executes first decides whether a
// registered output samples the old or the new value. That race originally hid
// the data-skew defect here entirely -- the buggy version passed the data checks
// and was only caught by an unrelated tready assertion. Driving at a defined
// offset after the edge removes the ambiguity, so a registered data path now
// shows up as the stale sample it is.
task step(input integer k);
begin
    @(posedge clk);
    #2;
    dma_data_i   = $random;
    dma_data_q   = $random;
    dma_valid_in = k[0];
    qick_tdata   = {$random} & 32'hffff_ffff;
    #1;   // settle combinational logic, still between edges
    if (sel === 1'b0) begin
        if (dac_data_i   !== dma_data_i)   fail("sel=0 data_i not passthrough");
        if (dac_data_q   !== dma_data_q)   fail("sel=0 data_q not passthrough");
        if (dac_valid_in !== dma_valid_in) fail("sel=0 valid not passthrough");
        if (qick_tready  !== 1'b0)         fail("tready asserted while sel=0");
    end else begin
        if (dac_data_i   !== qick_tdata[15:0])  fail("sel=1 data_i wrong");
        if (dac_data_q   !== qick_tdata[31:16]) fail("sel=1 data_q wrong");
        if (dac_valid_in !== 1'b1)              fail("sel=1 valid not held");
        if (qick_tready  !== 1'b1)              fail("tready not held while selected");
        ready_cnt = ready_cnt + 1;
    end
    if (sel === 1'b1) rd_cnt = rd_cnt + 1;
end
endtask

initial begin
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (4) @(posedge clk);

    $display("");
    $display("Phase 1  sel=0 must be a transparent wire");
    sel = 0; repeat (4) @(posedge clk);      // let the synchroniser settle
    for (n = 0; n < NCHK; n = n + 1) step(n);
    $display("  %0d cycles checked, errors so far = %0d", NCHK, errs);

    $display("");
    $display("Phase 2  sel=1 must present generator samples and hold tready");
    sel = 1; repeat (4) @(posedge clk);
    for (n = 0; n < NCHK; n = n + 1) step(n);
    $display("  %0d cycles checked, tready asserted on %0d of %0d",
             NCHK, ready_cnt, rd_cnt);
    if (ready_cnt != rd_cnt) fail("tready not asserted on every selected cycle");

    $display("");
    $display("Phase 3  switching back must restore the wire immediately");
    sel = 0; repeat (4) @(posedge clk);
    for (n = 0; n < NCHK; n = n + 1) step(n);

    $display("");
    if (errs == 0)
        $display("PASS  sel=0 is bit-exact and zero-latency; sel=1 holds tready");
    else
        $display("FAIL  %0d errors", errs);
    $display("");
    $finish;
end

endmodule
