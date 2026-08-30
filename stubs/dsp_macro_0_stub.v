// QICK's ARITH unit instantiates dsp_macro_0, a Vivado DSP Macro generated for
// xczu49dr as a 27x18 multiply-accumulate. 7-series DSP48E1 is only 25x18, so
// that .xci cannot be regenerated as-is for xc7z020.
//
// The instantiation lives inside `generate if (ARITH == 1)` in
// qick_processor.sv, so with ARITH=0 it is never elaborated. This stub exists
// only so module resolution succeeds during synthesis. Enabling ARITH on
// 7-series needs a real 25x18 or cascaded-DSP replacement.
module dsp_macro_0 (
  input  wire        CLK,
  input  wire [3:0]  SEL,
  input  wire [26:0] A,
  input  wire [17:0] B,
  input  wire [31:0] C,
  input  wire [26:0] D,
  output wire [45:0] P
);
  assign P = 46'd0;
endmodule
