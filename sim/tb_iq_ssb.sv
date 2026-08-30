// Is the complex (I/Q) output of the patched axis_signal_gen_v6 actually correct?
//
// With a constant real envelope and the DDS running, the output should be
// A * e^{jwt}: a single complex exponential. The decisive property is that its
// spectrum is ONE-SIDED. A real-valued output has an image at -f, and -- more
// usefully here -- if Q is misaligned against I by even one clock, or the sign
// convention of the imaginary partial products is wrong, the image reappears.
// So image rejection tests the sign convention and the pipeline alignment at
// once, which is exactly what is easy to get wrong in this change.
//
// Measured by capturing I and Q, forming I + jQ, and comparing the power at +f
// against the power at -f.
`timescale 1ns / 1ps

module tb_iq_ssb();

localparam int N       = 16;
localparam int NDDS    = 1;
localparam int LEN     = 4096;              // samples (== clocks at NDDS=1)
localparam bit [15:0] GAIN  = 16'd20000;
localparam bit [15:0] ENV   = 16'd12000;    // constant real envelope
localparam bit [31:0] PINC  = 32'd41943040; // ~ +1/102 of fs

reg clk = 0, rstn = 0;
always #5 clk = ~clk;

function automatic [159:0] descr(input [15:0] nsamp);
   descr = { 11'd0, 1'b1 /*phrst*/, 1'b0 /*stdysel*/, 1'b0 /*one-shot*/,
             2'd0 /*outsel = product*/, nsamp, 16'd0, GAIN, 16'd0,
             16'd0 /*addr*/, 32'd0 /*phase*/, PINC };
endfunction

wire [NDDS*32-1:0] tdata;   wire tvalid;
wire [N-1:0]       maddr;
wire               rd, empty;
reg                wr = 0;  reg [159:0] din;
wire [159:0]       fdout;
reg  [15:0]        mre, mim;

fifo_xpm #(.B(160), .N(16)) fifo_i (
   .rstn(rstn), .clk(clk), .wr_en(wr), .din(din),
   .rd_en(rd), .dout(fdout), .full(), .empty(empty));

signal_gen #(.N(N), .N_DDS(NDDS), .GEN_DDS("TRUE")) DUT (
   .rstn(rstn), .clk(clk),
   .fifo_rd_en_o(rd), .fifo_empty_i(empty), .fifo_dout_i(fdout),
   .mem_addr_o(maddr), .mem_dout_real_i(mre), .mem_dout_imag_i(mim),
   .m_axis_tready_i(1'b1), .m_axis_tvalid_o(tvalid), .m_axis_tdata_o(tdata));

// Constant envelope, one clock of read latency as real BRAM would give.
always @(posedge clk) begin
   mre <= ENV;
   mim <= 16'd0;
end

integer fh;
int nsent = 0;

initial begin
   fh = $fopen("iq_capture.txt", "w");
   rstn = 0; #200; rstn = 1; #200;
   @(posedge clk);
   din <= descr(LEN[15:0]);
   wr  <= 1;
   @(posedge clk);
   wr  <= 0;

   // Dump I and Q as signed decimals for offline analysis.
   forever begin
      @(posedge clk);
      if (rstn && tvalid && nsent < LEN) begin
         $fwrite(fh, "%0d %0d\n",
                 $signed(tdata[15:0]), $signed(tdata[31:16]));
         nsent++;
         if (nsent == LEN) begin
            $fclose(fh);
            $display("captured %0d I/Q pairs to iq_capture.txt", nsent);
            $finish;
         end
      end
   end
end

initial begin
   #400000;
   $display("TIMEOUT after %0d samples", nsent);
   if (nsent > 0) $fclose(fh);
   $finish;
end

endmodule
