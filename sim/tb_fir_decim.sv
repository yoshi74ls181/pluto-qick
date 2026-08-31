`timescale 1ns/1ps
//
// axis_readout_v2's down_conversion_fir at N_DDS=1 / INPUT_TYPE=COMPLEX, i.e.
// the complex mixer followed by the fir_compiler_0 that
// syn/regen_readout_fir_ndds1.tcl rebuilds at SamplePeriod 8.
//
// tb_readout_complex.sv already covers the mixer. What has never been checked is
// the regenerated filter: it is the one piece of patch 0006 that only exists as
// a generated artifact, and getting SamplePeriod wrong would silently change the
// output rate or the response. So this checks the filter's own behaviour:
//
//   1. m1_axis_tvalid asserts once every 8 aclk, i.e. decimation by 8 really
//      happened and at one sample per clock rather than eight.
//   2. A tone inside the passband survives; a tone above the new Nyquist
//      (fs/16 after decimation) is attenuated. That is what the 121-tap
//      ../fir.coe is for, and it is the part a wrong SamplePeriod would break
//      while leaving the rate looking plausible.
//
module tb_fir_decim;

localparam real FS  = 30.72e6;          // sample clock
localparam real TCK = 1e9/FS/2.0;       // half period, ns

reg clk = 0, rstn = 0;
always #TCK clk = ~clk;

// {mode, outsel[1:0], nsamp[15:0], phase[31:0], freq[31:0]}
// outsel 2 selects the raw input passthrough, so the filter is measured on its
// own without the DDS mixing the tone away from where we put it.
reg [31:0] pinc = 32'd0;
wire [82:0] cfg = {1'b0, 2'b10, 16'hffff, 32'd0, pinc};

reg  [31:0] din = 0;
wire [31:0] m0_data;
wire [31:0] m1_data;
wire        m1_valid;

down_conversion_fir #(.N_DDS(1), .INPUT_TYPE("COMPLEX")) dut (
    .rstn(rstn), .clk(clk),
    .s_axis_tready_o(), .s_axis_tvalid_i(1'b1), .s_axis_tdata_i(din),
    .m0_axis_tready_i(1'b1), .m0_axis_tvalid_o(), .m0_axis_tdata_o(m0_data),
    .m1_axis_tready_i(1'b1), .m1_axis_tvalid_o(m1_valid), .m1_axis_tdata_o(m1_data),
    .fifo_rd_en_o(), .fifo_empty_i(1'b0), .fifo_dout_i(cfg));

function real sre(input [31:0] d); begin sre = $itor($signed(d[15:0]));  end endfunction
function real sim_(input [31:0] d); begin sim_ = $itor($signed(d[31:16])); end endfunction

integer n, nvalid, gap, last_valid, worst_gap, best_gap;
real    ph, acc, mag, amp;
reg signed [15:0] iv, qv;
localparam real A = 20000.0;
localparam real PI = 3.14159265358979;

// Drive a complex tone at f/fs = frac for nclk clocks and return mean |m1|.
task measure(input real frac, input integer nclk, output real mean_mag, output integer vcount);
begin
    mean_mag = 0.0; vcount = 0;
    for (n = 0; n < nclk; n = n + 1) begin
        ph = 2.0*PI*frac*n;
        iv = $rtoi(A*$cos(ph));
        qv = $rtoi(A*$sin(ph));
        @(negedge clk);
        din = {qv, iv};
        @(posedge clk);
        if (m1_valid && n > nclk/3) begin      // skip the filter's fill time
            mean_mag = mean_mag + $sqrt(sre(m1_data)*sre(m1_data) + sim_(m1_data)*sim_(m1_data));
            vcount = vcount + 1;
        end
    end
    if (vcount > 0) mean_mag = mean_mag / vcount;
end
endtask

integer vc;
real m_dc, m_pass, m_stop;

initial begin
    repeat (10) @(posedge clk);
    rstn = 1;
    repeat (40) @(posedge clk);

    // ---- 1. decimation cadence -------------------------------------------
    nvalid = 0; last_valid = -1; worst_gap = 0; best_gap = 9999;
    for (n = 0; n < 800; n = n + 1) begin
        @(posedge clk);
        din = {16'sd0, 16'sd8000};
        if (m1_valid) begin
            if (last_valid >= 0) begin
                gap = n - last_valid;
                if (gap > worst_gap) worst_gap = gap;
                if (gap < best_gap)  best_gap = gap;
            end
            last_valid = n;
            nvalid = nvalid + 1;
        end
    end
    $display("");
    $display("Decimation cadence");
    $display("  m1_axis_tvalid asserted %0d times in 800 clocks", nvalid);
    $display("  gap between valids: min %0d, max %0d  (expect 8)", best_gap, worst_gap);
    if (best_gap == 8 && worst_gap == 8)
        $display("  PASS  one output per 8 input clocks");
    else
        $display("  FAIL  cadence is not decimate-by-8");

    // ---- 2. filter response ----------------------------------------------
    // After decimating by 8 the new Nyquist is fs/16. 1/64 of fs sits well
    // inside the passband; 3/16 of fs is above it and must be rejected.
    measure(1.0/512.0, 3000, m_dc,   vc);
    measure(1.0/64.0,  3000, m_pass, vc);
    measure(3.0/16.0,  3000, m_stop, vc);
    $display("");
    $display("Filter response (mean |m1_axis|, input amplitude %0.0f)", A);
    $display("  f = fs/512  (deep passband) : %0.1f", m_dc);
    $display("  f = fs/64   (passband)      : %0.1f", m_pass);
    $display("  f = 3fs/16  (stopband)      : %0.1f", m_stop);
    if (m_dc > 1000.0 && m_stop < m_dc/10.0)
        $display("  PASS  passband preserved, stopband rejected by %0.1f dB",
                 20.0*$log10(m_dc/(m_stop+0.001)));
    else
        $display("  FAIL  response is not a decimating low-pass");
    $display("");
    $finish;
end

endmodule
