`timescale 1ns/1ps
//
// axis_readout_v2's down_conversion at N_DDS=1, checking the INPUT_TYPE="COMPLEX"
// path added for the AD9361 front end.
//
// Two instances share one control word, so both see an identical DDS phase.
//
//   Phase A  equivalence: drive COMPLEX with Q=0. The complex product
//            I*cos - Q*sin / I*sin + Q*cos then reduces exactly to the REAL
//            path's cos*x / sin*x, so the outputs must match bit for bit.
//            This is what proves the edit did not disturb upstream behaviour.
//
//   Phase B  single sideband: drive COMPLEX with a true complex tone. Mixing
//            two complex exponentials yields one tone, so |out| is flat. The
//            REAL instance fed only the real part produces cos(w_in t)*e^{jw_lo t}
//            = two tones, whose sum beats between 0 and full scale. Envelope
//            ripple therefore separates the two behaviours cleanly.
//
module tb_readout_complex;

localparam real FS   = 122.88e6;
localparam real TCK  = 1e9/FS/2.0;      // half period, ns

// LO: phase increment for the readout DDS (32-bit accumulator).
localparam [31:0] PINC = 32'd60000000;
// Input tone, as a fraction of fs.
localparam real   FIN_FRAC = 0.031;

reg clk = 0, rstn = 0;
always #TCK clk = ~clk;

// {mode, outsel[1:0], nsamp[15:0], phase[31:0], freq[31:0]}
// outsel 0 selects the mixer product; nsamp large so no reload occurs mid-run.
wire [82:0] cfg = {1'b0, 2'b00, 16'hffff, 32'd0, PINC};

reg  [15:0] din_real;
reg  [31:0] din_cplx;
wire [31:0] dout_real, dout_cplx;

down_conversion #(.N_DDS(1), .INPUT_TYPE("REAL")) dut_r (
    .rstn(rstn), .clk(clk),
    .s_axis_tready_o(), .s_axis_tvalid_i(1'b1), .s_axis_tdata_i(din_real),
    .m_axis_tready_i(1'b1), .m_axis_tvalid_o(), .m_axis_tdata_o(dout_real),
    .fifo_rd_en_o(), .fifo_empty_i(1'b0), .fifo_dout_i(cfg));

down_conversion #(.N_DDS(1), .INPUT_TYPE("COMPLEX")) dut_c (
    .rstn(rstn), .clk(clk),
    .s_axis_tready_o(), .s_axis_tvalid_i(1'b1), .s_axis_tdata_i(din_cplx),
    .m_axis_tready_i(1'b1), .m_axis_tvalid_o(), .m_axis_tdata_o(dout_cplx),
    .fifo_rd_en_o(), .fifo_empty_i(1'b0), .fifo_dout_i(cfg));

// Signed views of the {Q,I} outputs.
function real sre(input [31:0] d); begin sre = $itor($signed(d[15:0]));  end endfunction
function real sim_(input [31:0] d); begin sim_ = $itor($signed(d[31:16])); end endfunction

integer n, mism;
real    amp, ph, i_val, q_val;
// 16-bit holders: concatenating $rtoi() results directly builds a 64-bit value,
// and assigning that to a 32-bit reg silently keeps only the low half (dropping Q).
reg signed [15:0] iv, qv;
real    mag, mag_min_c, mag_max_c, mag_min_r, mag_max_r;
real    ripple_c, ripple_r;

localparam real A = 30000.0;   // |I+jQ| = A; product magnitude is also A, so
                               // the 33-bit sum never saturates for A < 32767

initial begin
    din_real = 0; din_cplx = 0;
    repeat (20) @(posedge clk);
    rstn = 1;
    repeat (60) @(posedge clk);      // let the DDS pipeline (latency 10) fill

    /////////////////////////////////////////////////////////////////////
    // Phase A: Q = 0, expect bit-exact agreement
    /////////////////////////////////////////////////////////////////////
    mism = 0;
    for (n = 0; n < 2000; n = n + 1) begin
        ph    = 2.0*3.14159265358979*FIN_FRAC*n;
        i_val = A*$cos(ph);
        iv = $rtoi(i_val);
        din_real = iv;
        din_cplx = {16'sd0, iv};
        @(posedge clk);
        if (n > 20 && dout_real !== dout_cplx) begin
            if (mism < 5)
                $display("  MISMATCH n=%0d real=%08x cplx=%08x", n, dout_real, dout_cplx);
            mism = mism + 1;
        end
    end
    $display("");
    $display("Phase A  complex path with Q=0 vs real path");
    $display("  compared %0d samples, mismatches = %0d", 2000-21, mism);
    if (mism == 0) $display("  PASS  the complex product reduces exactly to the real one");
    else           $display("  FAIL");

    /////////////////////////////////////////////////////////////////////
    // Phase B: true complex tone -> flat envelope; real input -> beating
    /////////////////////////////////////////////////////////////////////
    mag_min_c =  1e30; mag_max_c = -1e30;
    mag_min_r =  1e30; mag_max_r = -1e30;
    for (n = 0; n < 4000; n = n + 1) begin
        ph    = 2.0*3.14159265358979*FIN_FRAC*n;
        i_val = A*$cos(ph);
        q_val = A*$sin(ph);
        iv = $rtoi(i_val);
        qv = $rtoi(q_val);
        din_real = iv;
        din_cplx = {qv, iv};
        @(posedge clk);
        if (n > 200) begin
            mag = $sqrt(sre(dout_cplx)*sre(dout_cplx) + sim_(dout_cplx)*sim_(dout_cplx));
            if (mag < mag_min_c) mag_min_c = mag;
            if (mag > mag_max_c) mag_max_c = mag;
            mag = $sqrt(sre(dout_real)*sre(dout_real) + sim_(dout_real)*sim_(dout_real));
            if (mag < mag_min_r) mag_min_r = mag;
            if (mag > mag_max_r) mag_max_r = mag;
        end
    end
    ripple_c = 100.0*(mag_max_c-mag_min_c)/mag_max_c;
    ripple_r = 100.0*(mag_max_r-mag_min_r)/mag_max_r;
    $display("");
    $display("Phase B  envelope of the down-converted output");
    $display("  COMPLEX in : |out| in [%0.1f, %0.1f]  ripple %0.2f %%", mag_min_c, mag_max_c, ripple_c);
    $display("  REAL    in : |out| in [%0.1f, %0.1f]  ripple %0.2f %%", mag_min_r, mag_max_r, ripple_r);
    if (ripple_c < 5.0 && ripple_r > 50.0)
        $display("  PASS  complex input gives a single sideband; real input beats as expected");
    else
        $display("  FAIL  ripple_c=%0.2f (want <5) ripple_r=%0.2f (want >50)", ripple_c, ripple_r);

    $display("");
    $finish;
end

endmodule
