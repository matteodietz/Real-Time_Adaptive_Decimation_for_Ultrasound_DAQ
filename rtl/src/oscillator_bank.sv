////////////////////////////////////////////////////////////////////////////////
//
//  Module: oscillator_bank
//
//  Function: Generates N complex oscillators (NCOs) in parallel.
//
////////////////////////////////////////////////////////////////////////////////

module oscillator_bank #(
    parameter int NUM_BINS = 16,
    parameter int OSC_WIDTH = 32,
    parameter int PHASE_WIDTH = 32
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    input  logic enable_i,
    input  logic sync_reset_i,
    input  logic phase_tvalid,
    
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    output logic sincos_tvalid,
    output logic signed [OSC_WIDTH-1:0] W_real_o[NUM_BINS],
    output logic signed [OSC_WIDTH-1:0] W_imag_o[NUM_BINS]
);

    // Phase Accumulators
    logic [PHASE_WIDTH-1:0] phase_acc[NUM_BINS];

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (int k = 0; k < NUM_BINS; k++) phase_acc[k] <= '0;
        end else begin
            if (sync_reset_i) begin
                for (int k = 0; k < NUM_BINS; k++) phase_acc[k] <= '0;
            end else if (enable_i) begin
                for (int k = 0; k < NUM_BINS; k++) begin
                    phase_acc[k] <= phase_acc[k] + freq_steps_i[k];
                end
            end
        end
    end

    // Parallel CORDIC Instantiations
    logic tvalid_per_bin[NUM_BINS];
    
    genvar k;
    generate
        for (k = 0; k < NUM_BINS; k++) begin : gen_nco
            
            logic signed [OSC_WIDTH-1:0] cos_out;
            logic signed [OSC_WIDTH-1:0] sin_out;
            logic [2*OSC_WIDTH-1:0] cordic_dout;
            
            // Xilinx CORDIC IP Core
            cordic_0 cordic_inst (
                .aclk(clk_i),
                .s_axis_phase_tvalid(phase_tvalid),
                .s_axis_phase_tdata(phase_acc[k]),
                .m_axis_dout_tvalid(tvalid_per_bin[k]),
                .m_axis_dout_tdata(cordic_dout)
            );
            
            // Unpack CORDIC output (typically [cos, sin] concatenated)
            // Check your CORDIC IP configuration for exact bit ordering
            assign cos_out = cordic_dout[OSC_WIDTH-1:0];
            assign sin_out = cordic_dout[2*OSC_WIDTH-1:OSC_WIDTH];
            
            // DFT requires exp(-j*theta) = cos(theta) - j*sin(theta)
            assign W_real_o[k] = cos_out;
            assign W_imag_o[k] = -sin_out;
        end
    endgenerate

    // Output valid signal (all bins should be valid together)
    assign sincos_tvalid = tvalid_per_bin[0];

endmodule