// Does axis_signal_gen_v6's phase generator behave correctly at N_DDS=1?
//
// QICK only ever ships N_DDS >= 4 (RFSoC RF-DACs take 16 samples/clock), but the
// AD9361 interface is 1 sample/clock. The IP-XACT permits N_DDS minimum=1, and
// it synthesises -- this checks whether it is actually *correct*.
//
// The invariant: with N lanes at one clock, lane i of clock t carries sample
// s = t*N + i. So for identical pinc, a reference build with NREF lanes and a
// candidate with 1 lane must produce the same per-sample phase sequence:
//
//     phase_ref[t][i]  ==  phase_cnd[t*NREF + i]
//
// nsamp is in clocks (each yielding N_DDS samples), so it is scaled per DUT to
// keep the physical waveform length equal.
`timescale 1ns / 1ps

module tb_ndds_equiv();

localparam int N        = 16;   // envelope memory address width
localparam int NREF     = 4;    // reference lanes
localparam int LEN_CLK  = 32;   // reference duration in clocks
localparam int LEN      = LEN_CLK * NREF;   // waveform length in samples

localparam bit [31:0] PINC  = 32'd1234567;  // per-sample phase increment
localparam bit [31:0] PHASE = 32'd0;

reg clk = 0, rstn = 0;
always #5 clk = ~clk;

// ---------------------------------------------------------------- descriptors
function automatic [159:0] descr(input [15:0] nsamp);
   descr = { 11'd0,          // pad
             1'b1,           // phrst  - reset phase once, so both start aligned
             1'b0,           // stdysel
             1'b0,           // mode   - ONE-SHOT. mode=1 is periodic replay:
                             //          READ_ST re-enters CNT_ST unconditionally,
                             //          and sync fires on every reload, so with
                             //          phrst=1 the accumulator resets each period
                             //          and the base phase never advances.
             2'd2,           // outsel: DDS
             nsamp,          // nsamp (clocks)
             16'd0,
             16'd40,         // gain
             16'd0,
             16'd0,          // addr
             PHASE,
             PINC };
endfunction

// -------------------------------------------------------------------- ref DUT
wire [NREF*72-1:0] ctrl_ref;
wire               rd_ref, empty_ref, en_ref;
reg                wr_ref = 0;
reg  [159:0]       din_ref;

wire [159:0] fifo_ref_dout;

fifo_xpm #(.B(160), .N(16)) fifo_ref (
   .rstn(rstn), .clk(clk),
   .wr_en(wr_ref), .din(din_ref),
   .rd_en(rd_ref), .dout(fifo_ref_dout), .full(), .empty(empty_ref));

ctrl_sg_v6 #(.N(N), .N_DDS(NREF)) DUT_REF (
   .rstn(rstn), .clk(clk),
   .fifo_rd_en_o(rd_ref), .fifo_empty_i(empty_ref), .fifo_dout_i(fifo_ref_dout),
   .dds_ctrl_o(ctrl_ref), .mem_addr_o(), .gain_o(), .src_o(), .stdy_o(),
   .en_o(en_ref));

// ------------------------------------------------------------------- cand DUT
wire [1*72-1:0]  ctrl_cnd;
wire             rd_cnd, empty_cnd, en_cnd;
reg              wr_cnd = 0;
reg  [159:0]     din_cnd;
wire [159:0]     fifo_cnd_dout;

fifo_xpm #(.B(160), .N(16)) fifo_cnd (
   .rstn(rstn), .clk(clk),
   .wr_en(wr_cnd), .din(din_cnd),
   .rd_en(rd_cnd), .dout(fifo_cnd_dout), .full(), .empty(empty_cnd));

ctrl_sg_v6 #(.N(N), .N_DDS(1)) DUT_CND (
   .rstn(rstn), .clk(clk),
   .fifo_rd_en_o(rd_cnd), .fifo_empty_i(empty_cnd), .fifo_dout_i(fifo_cnd_dout),
   .dds_ctrl_o(ctrl_cnd), .mem_addr_o(), .gain_o(), .src_o(), .stdy_o(),
   .en_o(en_cnd));

// ------------------------------------------------------------------- capture
bit [31:0] q_ref [$];
bit [31:0] q_cnd [$];

bit [31:0] p_ref [$];   // pinc_N seen by the reference DUT
bit [31:0] p_cnd [$];

always @(posedge clk) if (rstn && en_ref) begin
   for (int i = 0; i < NREF; i++) q_ref.push_back(ctrl_ref[i*72 + 32 +: 32]);
   p_ref.push_back(ctrl_ref[0 +: 32]);
end

always @(posedge clk) if (rstn && en_cnd) begin
   q_cnd.push_back(ctrl_cnd[32 +: 32]);
   p_cnd.push_back(ctrl_cnd[0 +: 32]);
end

// ---------------------------------------------------------------------- drive
initial begin
   rstn = 0; #200; rstn = 1; #100;

   @(posedge clk);
   din_ref <= descr(LEN_CLK);        // NREF lanes -> LEN_CLK clocks
   din_cnd <= descr(LEN);            // 1 lane     -> LEN clocks
   wr_ref  <= 1; wr_cnd <= 1;
   @(posedge clk);
   wr_ref  <= 0; wr_cnd <= 0;

   // long enough for the 1-lane DUT to finish
   wait (q_cnd.size() >= LEN);
   repeat (20) @(posedge clk);

   check();
   $finish;
end

// ---------------------------------------------------------------------- check
//
// dds_ctrl_o carries {sync, phase, pinc_N} where `phase` is a *static per-lane
// start offset* and pinc_N is the increment the DDS compiler accumulates each
// clock. cnt_n_reg only latches at sync, so `phase` does not run -- the DDS does
// the accumulating. So the effective phase of sample s = t*N + i is
//
//     phase[i]  +  t * pinc_N        where pinc_N = N * PINC
//               =  i*PINC + t*N*PINC
//               =  (t*N + i) * PINC  =  s * PINC
//
// which must hold for any N, including 1. That is what we check.
task automatic check();
   int bad_off, bad_pinc, bad_equiv;
   bit [31:0] eff_ref, eff_cnd;
   int t, i, s_idx;

   $display("");
   $display("=== N_DDS=1 equivalence vs N_DDS=%0d ===", NREF);
   $display("captured: ref=%0d samples over %0d clks, cnd=%0d over %0d clks",
            q_ref.size(), p_ref.size(), q_cnd.size(), p_cnd.size());

   if (q_ref.size() < LEN || q_cnd.size() < LEN) begin
      $display("RESULT: INCONCLUSIVE - not enough samples"); return;
   end

   // 1. pinc_N must scale with lane count.
   bad_pinc = 0;
   for (int k = 0; k < p_ref.size(); k++)
      if (p_ref[k] !== (PINC * NREF)) bad_pinc++;
   for (int k = 0; k < p_cnd.size(); k++)
      if (p_cnd[k] !== PINC) bad_pinc++;
   $display("pinc_N: ref[0]=%08h (want %08h)  cnd[0]=%08h (want %08h)  bad=%0d",
            p_ref[0], PINC*NREF, p_cnd[0], PINC, bad_pinc);

   // 2. Static per-lane offsets: lane i must be i*PINC; the 1-lane DUT must be 0.
   bad_off = 0;
   for (t = 0; t < LEN/NREF; t++)
      for (i = 0; i < NREF; i++)
         if (q_ref[t*NREF + i] !== (PINC * i)) bad_off++;
   for (t = 0; t < LEN; t++)
      if (q_cnd[t] !== 32'd0) bad_off++;
   $display("lane offsets: %0d deviation(s) from i*PINC (ref) / 0 (cnd)", bad_off);

   // 3. The real invariant: reconstructed per-sample phase must agree.
   bad_equiv = 0;
   for (t = 0; t < LEN/NREF; t++) begin
      for (i = 0; i < NREF; i++) begin
         s_idx   = t*NREF + i;
         eff_ref = q_ref[t*NREF + i] + t      * p_ref[t];
         eff_cnd = q_cnd[s_idx]      + s_idx  * p_cnd[s_idx];
         if (eff_ref !== eff_cnd) begin
            if (bad_equiv < 6)
               $display("  MISMATCH s=%0d: ref=%08h cnd=%08h", s_idx, eff_ref, eff_cnd);
            bad_equiv++;
         end
         // and both must equal s*PINC
         if (eff_cnd !== (PINC * s_idx)) begin
            if (bad_equiv < 6)
               $display("  s=%0d: cnd eff=%08h but s*PINC=%08h", s_idx, eff_cnd, PINC*s_idx);
         end
      end
   end
   $display("effective phase: %0d mismatch(es) over %0d samples", bad_equiv, LEN);

   if (bad_pinc == 0 && bad_off == 0 && bad_equiv == 0)
      $display("RESULT: PASS - N_DDS=1 is equivalent to N_DDS=%0d per sample", NREF);
   else
      $display("RESULT: FAIL");
endtask

endmodule
