module sincos #(
    parameter int OSC_WIDTH = 32,
    parameter int PHASE_WIDTH = 32
)(
    input logic                 clk_i,
    input logic [PHASE_WIDTH-1:0] phase_i,
    input logic                 phase_tvalid_i,

    output logic [OSC_WIDTH-1:0]  cos_o,
    output logic [OSC_WIDTH-1:0]  sin_o,
    output logic                sincos_tvalid_o
);

cordic_0 cordic_0_inst (
    .aclk(clk_i),
    .s_axis_phase_tvalid(phase_tvalid_i),
    .s_axis_phase_tdata(phase_i),
    .m_axis_dout_tvalid(sincos_tvalid_o),
    .m_axis_dout_tdata({sin_o, cos_o})
);

endmodule