`timescale 1ns/1ps

module sincos_tb;

localparam CLK_PERIOD = 10;         // 100 MHz clk
localparam int OSC_WIDTH = 32;
localparam int PHASE_WIDTH = 32;
localparam signed [PHASE_WIDTH-1:0] PI_POS = 32'b0110_0100_1000_0111_1110_1101_0101_0001; // + pi
localparam signed [PHASE_WIDTH-1:0] PI_NEG = 32'b1001_1011_0111_1000_0001_0010_1010_1111; // - pi

logic clk = 1'b0;
logic rst_n = 1'b1;

logic signed [PHASE_WIDTH-1:0] phase = 'b0;
logic phase_tvalid = 1'b0;
logic signed [OSC_WIDTH-1:0] cos, sin;
logic sincos_tvalid;

localparam PHASE_INC = 16777216;

sincos sincos_inst (
    .clk_i(clk),
    .phase_i(phase),
    .phase_tvalid_i(phase_tvalid),
    .cos_o(cos),
    .sin_o(sin),
    .sincos_tvalid_o(sincos_tvalid)
);

initial begin
    clk = 1'b0;
    rst_n = 1'b1;
    rst_n = #(CLK_PERIOD * 10) 'b0;
end

always begin
    clk = #(CLK_PERIOD / 2) ~clk;
end

always @(posedge clk) begin
    if (rst_n) begin
        phase <= 'b0;
        phase_tvalid <= 1'b0;
    end else begin
        phase_tvalid <= 1'b1;
        if (phase+PHASE_INC < PI_POS) begin
            phase <= phase + PHASE_INC;
        end else begin
            phase <= PI_NEG;
        end
    end
end


endmodule