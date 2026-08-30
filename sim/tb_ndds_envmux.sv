// Does axis_signal_gen_v6's envelope + output-mux path behave correctly at
// N_DDS=1?  Companion to tb_ndds_equiv.sv, which covers the phase path.
//
// The envelope is stored *interleaved* across N_DDS block RAMs: lane i at
// address a holds sample a*N_DDS + i, and addr_cnt advances by 1 per clock
// regardless of N_DDS. So a correct N_DDS=1 build must read the same sample
// sequence, just one per clock instead of N.
//
// Driven with GEN_DDS="FALSE" (as QICK's own tb.sv does), which replaces the DDS
// with a full-scale constant and makes the product path mem>>1. That isolates
// the envelope fetch, the source mux and the gain stage from the DDS compiler.
//
// Checked for every source-select value:
//   src=0 product (mem>>1), src=1 DDS constant, src=2 envelope, src=3 zero.
`timescale 1ns / 1ps

module tb_ndds_envmux();

localparam int N       = 16;
localparam int NREF    = 4;
localparam int LEN_CLK = 24;
localparam int LEN     = LEN_CLK * NREF;   // samples

localparam bit [15:0] GAIN = 16'd16384;

reg clk = 0, rstn = 0;
always #5 clk = ~clk;

int          outsel_now;
int          fail_total = 0;

// Envelope as a function of absolute sample index - deliberately non-monotonic
// so a lane-ordering bug cannot hide behind a ramp.
function automatic [15:0] env(input int s);
   env = 16'((s * 7919) ^ (s << 3) ^ 16'h5A5A);
endfunction

function automatic [159:0] descr(input [15:0] nsamp, input [1:0] outsel);
   descr = { 11'd0, 1'b1 /*phrst*/, 1'b0 /*stdysel*/, 1'b0 /*mode: one-shot*/,
             outsel, nsamp, 16'd0, GAIN, 16'd0, 16'd0 /*addr*/, 32'd0, 32'd12345 };
endfunction

// ------------------------------------------------------------------- ref DUT
wire [NREF*16-1:0] tdata_ref;  wire tvalid_ref;
wire [N-1:0]       maddr_ref;
wire               rd_ref, empty_ref;
reg                wr_ref = 0;  reg [159:0] din_ref;
wire [159:0]       fdout_ref;
reg  [NREF*16-1:0] mreal_ref, mimag_ref;

fifo_xpm #(.B(160), .N(16)) fifo_ref (
   .rstn(rstn), .clk(clk), .wr_en(wr_ref), .din(din_ref),
   .rd_en(rd_ref), .dout(fdout_ref), .full(), .empty(empty_ref));

signal_gen #(.N(N), .N_DDS(NREF), .GEN_DDS("FALSE")) DUT_REF (
   .rstn(rstn), .clk(clk),
   .fifo_rd_en_o(rd_ref), .fifo_empty_i(empty_ref), .fifo_dout_i(fdout_ref),
   .mem_addr_o(maddr_ref), .mem_dout_real_i(mreal_ref), .mem_dout_imag_i(mimag_ref),
   .m_axis_tready_i(1'b1), .m_axis_tvalid_o(tvalid_ref), .m_axis_tdata_o(tdata_ref));

// Memory model with one clock of read latency, as bram_dp_xpm provides.
// Lane i at address a holds sample a*NREF + i (the interleaving contract).
always @(posedge clk) begin
   for (int i = 0; i < NREF; i++) begin
      mreal_ref[i*16 +: 16] <= env(maddr_ref * NREF + i);
      mimag_ref[i*16 +: 16] <= 16'd0;
   end
end

// ------------------------------------------------------------------ cand DUT
wire [15:0]  tdata_cnd;  wire tvalid_cnd;
wire [N-1:0] maddr_cnd;
wire         rd_cnd, empty_cnd;
reg          wr_cnd = 0;  reg [159:0] din_cnd;
wire [159:0] fdout_cnd;
reg  [15:0]  mreal_cnd, mimag_cnd;

fifo_xpm #(.B(160), .N(16)) fifo_cnd (
   .rstn(rstn), .clk(clk), .wr_en(wr_cnd), .din(din_cnd),
   .rd_en(rd_cnd), .dout(fdout_cnd), .full(), .empty(empty_cnd));

signal_gen #(.N(N), .N_DDS(1), .GEN_DDS("FALSE")) DUT_CND (
   .rstn(rstn), .clk(clk),
   .fifo_rd_en_o(rd_cnd), .fifo_empty_i(empty_cnd), .fifo_dout_i(fdout_cnd),
   .mem_addr_o(maddr_cnd), .mem_dout_real_i(mreal_cnd), .mem_dout_imag_i(mimag_cnd),
   .m_axis_tready_i(1'b1), .m_axis_tvalid_o(tvalid_cnd), .m_axis_tdata_o(tdata_cnd));

always @(posedge clk) begin
   mreal_cnd <= env(maddr_cnd);     // one lane: address == sample index
   mimag_cnd <= 16'd0;
end

// ------------------------------------------------------------------- capture
bit [15:0] o_ref [$];  bit [15:0] o_cnd [$];
bit [31:0] a_ref [$];  bit [31:0] a_cnd [$];

always @(posedge clk) if (rstn) begin
   if (tvalid_ref) begin
      for (int i = 0; i < NREF; i++) o_ref.push_back(tdata_ref[i*16 +: 16]);
      a_ref.push_back(maddr_ref);
   end
   if (tvalid_cnd) begin
      o_cnd.push_back(tdata_cnd);
      a_cnd.push_back(maddr_cnd);
   end
end

// --------------------------------------------------------------------- drive
task automatic one_pass(input [1:0] outsel);
   int n, bad, addr_bad;
   o_ref.delete(); o_cnd.delete(); a_ref.delete(); a_cnd.delete();
   outsel_now = outsel;

   @(posedge clk);
   din_ref <= descr(LEN_CLK, outsel);
   din_cnd <= descr(LEN,     outsel);
   wr_ref  <= 1; wr_cnd <= 1;
   @(posedge clk);
   wr_ref  <= 0; wr_cnd <= 0;

   // wait for the slower (1-lane) DUT, with a bail-out
   fork begin
      fork
         wait (o_cnd.size() >= LEN);
         #40000;
      join_any
      disable fork;
   end join
   repeat (30) @(posedge clk);

   n = (o_ref.size() < LEN || o_cnd.size() < LEN) ? 0 : LEN;
   $display("");
   $display("--- src=%0d : ref=%0d samples (%0d clks), cnd=%0d samples (%0d clks)",
            outsel, o_ref.size(), a_ref.size(), o_cnd.size(), a_cnd.size());
   if (n == 0) begin
      $display("    INCONCLUSIVE - too few samples");
      fail_total++;
      return;
   end

   // A constant sample shift between the streams is expected: L clocks of
   // pipeline latency displaces the reference by L*NREF samples and the
   // candidate by L. Find the shift, then require an exact match under it.
   begin
      int best_shift = 0, best_bad = 1<<30, win;
      win = n - 4*NREF;                 // leave room for the shift search
      for (int sh = -(4*NREF); sh <= 4*NREF; sh++) begin
         int b = 0;
         for (int s = 2*NREF; s < win; s++)
            if (o_ref[s] !== o_cnd[s + sh]) b++;
         if (b < best_bad) begin best_bad = b; best_shift = sh; end
      end
      bad = best_bad;
      $display("    best sample shift = %0d", best_shift);
      if (bad) begin
         int shown = 0;
         for (int s = 2*NREF; s < win && shown < 4; s++)
            if (o_ref[s] !== o_cnd[s + best_shift]) begin
               $display("    MISMATCH s=%0d ref=%04h cnd=%04h",
                        s, o_ref[s], o_cnd[s + best_shift]);
               shown++;
            end
      end
   end

   // mem_addr_o must step by exactly 1 per clock in both
   addr_bad = 0;
   for (int k = 1; k < a_ref.size(); k++)
      if (a_ref[k] !== a_ref[k-1] + 1 && a_ref[k] !== 0) addr_bad++;
   for (int k = 1; k < a_cnd.size(); k++)
      if (a_cnd[k] !== a_cnd[k-1] + 1 && a_cnd[k] !== 0) addr_bad++;

   $display("    output: %0d mismatch(es) over %0d samples", bad, n);
   $display("    mem_addr_o: %0d step(s) != +1", addr_bad);
   if (bad || addr_bad) fail_total++;
endtask

initial begin
   rstn = 0; #200; rstn = 1; #200;
   $display("=== envelope + output-mux: N_DDS=1 vs N_DDS=%0d ===", NREF);
   one_pass(2'd2);   // envelope
   one_pass(2'd3);   // zero
   one_pass(2'd1);   // DDS (constant, GEN_DDS=FALSE)
   one_pass(2'd0);   // product (mem>>1)
   $display("");
   if (fail_total == 0) $display("RESULT: PASS - all four source selections agree");
   else                $display("RESULT: FAIL - %0d source selection(s) differ", fail_total);
   $finish;
end

endmodule
