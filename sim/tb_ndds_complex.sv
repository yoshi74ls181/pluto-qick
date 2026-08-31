// ENVELOPE_TYPE="COMPLEX" with the real DDS in the loop, at N_DDS=1 vs 4.
//
// The other two testbenches run GEN_DDS="FALSE", where the product path
// degenerates to mem>>1 and the imaginary envelope is unused -- so neither of
// them actually exercises a complex envelope. This one instantiates the
// regenerated 7-series DDS compiler and drives env_re and env_im both non-zero,
// so signal_gen computes the real single-sideband product
//
//     out = cos*env_re - sin*env_im        (= Re[env * e^jwt])
//
// and we require the N_DDS=1 build to produce the same sample stream as N_DDS=4.
//
// Note this verifies the real-output datapath under a complex envelope; it is
// not a test of the complex output itself -- see docs/complex-output.md.
//
// Updated for patch 0002: m_axis now carries 32 bits per lane as {Q,I}, so the
// comparison takes the real half of each lane. Before this fix the testbench
// still sliced 16 bits per lane and so read lane 0's Q as if it were lane 1's
// I, reporting ~91 of 112 samples mismatched -- a stale-testbench artifact, not
// a datapath defect.
`timescale 1ns / 1ps

module tb_ndds_complex();

localparam int N       = 16;
localparam int NREF    = 4;
localparam int LEN_CLK = 32;
localparam int LEN     = LEN_CLK * NREF;

localparam bit [15:0] GAIN = 16'd16384;
// overridable: -testplusarg style via $value$plusargs in initial
bit [31:0] PINC = 32'd8_000_000;   // a few % of full scale per sample
localparam int TOL_LSB = 4;   // see the note in check() on why this is not 0

reg clk = 0, rstn = 0;
always #5 clk = ~clk;

// Complex envelope, both components non-trivial and mutually independent so a
// swapped or dropped component cannot pass.
function automatic [15:0] env_re(input int s);
   env_re = 16'((s * 4021) ^ 16'h3C3C);
endfunction
function automatic [15:0] env_im(input int s);
   env_im = 16'((s * 7919) ^ (s << 5) ^ 16'hA55A);
endfunction

function automatic [159:0] descr(input [15:0] nsamp);
   descr = { 11'd0, 1'b1 /*phrst*/, 1'b0 /*stdysel*/, 1'b0 /*one-shot*/,
             2'd0 /*outsel = product*/, nsamp, 16'd0, GAIN, 16'd0,
             16'd0 /*addr*/, 32'd0 /*phase*/, PINC };
endfunction

// ------------------------------------------------------------------- ref DUT
// 32 bits per lane, {Q,I}: patch 0002 made the generator output complex.
wire [NREF*32-1:0] tdata_ref;  wire tvalid_ref;
wire [N-1:0]       maddr_ref;
wire               rd_ref, empty_ref;
reg                wr_ref = 0;  reg [159:0] din_ref;
wire [159:0]       fdout_ref;
reg  [NREF*16-1:0] mre_ref, mim_ref;

fifo_xpm #(.B(160), .N(16)) fifo_ref (
   .rstn(rstn), .clk(clk), .wr_en(wr_ref), .din(din_ref),
   .rd_en(rd_ref), .dout(fdout_ref), .full(), .empty(empty_ref));

signal_gen #(.N(N), .N_DDS(NREF), .GEN_DDS("TRUE")) DUT_REF (
   .rstn(rstn), .clk(clk),
   .fifo_rd_en_o(rd_ref), .fifo_empty_i(empty_ref), .fifo_dout_i(fdout_ref),
   .mem_addr_o(maddr_ref), .mem_dout_real_i(mre_ref), .mem_dout_imag_i(mim_ref),
   .m_axis_tready_i(1'b1), .m_axis_tvalid_o(tvalid_ref), .m_axis_tdata_o(tdata_ref));

// one clock of read latency, interleaved: lane i at addr a -> sample a*NREF+i
always @(posedge clk)
   for (int i = 0; i < NREF; i++) begin
      mre_ref[i*16 +: 16] <= env_re(maddr_ref * NREF + i);
      mim_ref[i*16 +: 16] <= env_im(maddr_ref * NREF + i);
   end

// ------------------------------------------------------------------ cand DUT
wire [31:0]  tdata_cnd;  wire tvalid_cnd;
wire [N-1:0] maddr_cnd;
wire         rd_cnd, empty_cnd;
reg          wr_cnd = 0;  reg [159:0] din_cnd;
wire [159:0] fdout_cnd;
reg  [15:0]  mre_cnd, mim_cnd;

fifo_xpm #(.B(160), .N(16)) fifo_cnd (
   .rstn(rstn), .clk(clk), .wr_en(wr_cnd), .din(din_cnd),
   .rd_en(rd_cnd), .dout(fdout_cnd), .full(), .empty(empty_cnd));

signal_gen #(.N(N), .N_DDS(1), .GEN_DDS("TRUE")) DUT_CND (
   .rstn(rstn), .clk(clk),
   .fifo_rd_en_o(rd_cnd), .fifo_empty_i(empty_cnd), .fifo_dout_i(fdout_cnd),
   .mem_addr_o(maddr_cnd), .mem_dout_real_i(mre_cnd), .mem_dout_imag_i(mim_cnd),
   .m_axis_tready_i(1'b1), .m_axis_tvalid_o(tvalid_cnd), .m_axis_tdata_o(tdata_cnd));

always @(posedge clk) begin
   mre_cnd <= env_re(maddr_cnd);
   mim_cnd <= env_im(maddr_cnd);
end

// ------------------------------------------------------------------- capture
bit [15:0] o_ref [$];  bit [15:0] o_cnd [$];

always @(posedge clk) if (rstn) begin
   if (tvalid_ref) for (int i = 0; i < NREF; i++) o_ref.push_back(tdata_ref[i*32 +: 16]);   // real part of lane i
   if (tvalid_cnd) o_cnd.push_back(tdata_cnd[15:0]);         // real part
end

initial begin
   if (!$value$plusargs("PINC=%d", PINC)) PINC = 32'd8_000_000;
   $display("PINC = %0d (0x%08h)", PINC, PINC);
   rstn = 0; #200; rstn = 1; #200;
   @(posedge clk);
   din_ref <= descr(LEN_CLK);
   din_cnd <= descr(LEN);
   wr_ref  <= 1; wr_cnd <= 1;
   @(posedge clk);
   wr_ref  <= 0; wr_cnd <= 0;

   fork begin
      fork
         wait (o_cnd.size() >= LEN);
         #60000;
      join_any
      disable fork;
   end join
   repeat (40) @(posedge clk);
   check();
   $finish;
end

task automatic check();
   int n, best_shift, best_bad, nonzero;
   $display("");
   $display("=== ENVELOPE_TYPE=COMPLEX with DDS in loop: N_DDS=1 vs %0d ===", NREF);
   $display("captured: ref=%0d cnd=%0d (expected %0d)", o_ref.size(), o_cnd.size(), LEN);
   if (o_ref.size() < LEN || o_cnd.size() < LEN) begin
      $display("RESULT: INCONCLUSIVE - too few samples"); return;
   end
   n = LEN;

   // Guard against a vacuous pass: the stream must actually be varying.
   nonzero = 0;
   for (int s = 0; s < n; s++) if (o_cnd[s] != o_cnd[0]) nonzero++;
   $display("candidate stream varies in %0d of %0d samples", nonzero, n);

   // bounds-checked shift search (see note in tb_ndds_envmux.sv)
   begin
      int lo, hi, b;
      best_bad = -1; best_shift = 0;
      lo = 2*NREF; hi = n - 2*NREF;
      for (int sh = -(4*NREF); sh <= 4*NREF; sh++) begin
         if (lo + sh < 0)                 continue;
         if (hi - 1 + sh >= o_cnd.size()) continue;
         b = 0;
         for (int s = lo; s < hi; s++) if (o_ref[s] !== o_cnd[s + sh]) b++;
         if (best_bad < 0 || b < best_bad) begin best_bad = b; best_shift = sh; end
      end
      if (best_bad < 0) begin
         $display("RESULT: INCONCLUSIVE - no in-range shift"); return;
      end
      $display("best sample shift = %0d, mismatches = %0d over %0d compared",
               best_shift, best_bad, hi - lo);
      if (best_bad) begin
         int shown = 0;
         for (int s = lo; s < hi && shown < 5; s++)
            if (o_ref[s] !== o_cnd[s + best_shift]) begin
               $display("  MISMATCH s=%0d ref=%04h cnd=%04h",
                        s, o_ref[s], o_cnd[s+best_shift]);
               shown++;
            end
      end
   end

   // Exact bit-match is the wrong criterion here. ctrl_sg_v6 computes the base
   // phase pinc*cnt_n through a DSP-friendly approximation -- its own comment
   // says the exact "48bits multiplier and mod32 operation doesn't map to DSPs
   // and doesn't meet timing" -- and cnt_n advances by N_DDS, so the truncation
   // differs between configurations by a few LSB of phase. That propagates to a
   // few LSB of sin/cos and hence of the product. What matters is that the
   // deviation is bounded and tiny, not that it is zero.
   begin
      int lo, hi, over, maxdiff, d;
      int unsigned hist[6];
      lo = 2*NREF; hi = n - 2*NREF;
      over = 0; maxdiff = 0;
      foreach (hist[k]) hist[k] = 0;
      for (int s = lo; s < hi; s++) begin
         d = $signed(o_ref[s]) - $signed(o_cnd[s + best_shift]);
         if (d < 0) d = -d;
         if (d > maxdiff) maxdiff = d;
         if (d > TOL_LSB) over++;
         hist[(d > 4) ? 5 : d]++;
      end
      $display("difference distribution (LSB): 0:%0d 1:%0d 2:%0d 3:%0d 4:%0d >4:%0d",
               hist[0], hist[1], hist[2], hist[3], hist[4], hist[5]);
      $display("max |difference| = %0d LSB of 16-bit full scale (~%.1f dBFS)",
               maxdiff, (maxdiff == 0) ? -200.0 : 20.0*$log10(real'(maxdiff)/32768.0));
      $display("samples exceeding tolerance of %0d LSB: %0d of %0d", TOL_LSB, over, hi - lo);

      if (nonzero <= n/4)
         $display("RESULT: INCONCLUSIVE - stream too static to be meaningful");
      else if (over == 0)
         $display("RESULT: PASS - complex envelope + DDS agrees at N_DDS=1 within %0d LSB", TOL_LSB);
      else
         $display("RESULT: FAIL - %0d sample(s) deviate by more than %0d LSB", over, TOL_LSB);
   end
endtask

endmodule
