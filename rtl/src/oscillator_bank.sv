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
    input  logic phase_tvalid_i,
    
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    output logic sincos_tvalid_o,
    output logic signed [OSC_WIDTH-1:0] W_real_o[NUM_BINS],
    output logic signed [OSC_WIDTH-1:0] W_imag_o[NUM_BINS]
);

    logic [PHASE_WIDTH-1:0] phase_acc_d[NUM_BINS];
    logic [PHASE_WIDTH-1:0] phase_acc_q[NUM_BINS];

    always_comb begin
        // handle defaults
        for (int k = 0; k < NUM_BINS; k++) phase_acc_d[k] = phase_acc_q[k];

        if (sync_reset_i) begin
                for (int k = 0; k < NUM_BINS; k++) phase_acc_d[k] = '0;
        end else if (enable_i) begin
            for (int k = 0; k < NUM_BINS; k++) begin
                phase_acc_d[k] = phase_acc_q[k] + freq_steps_i[k];
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (int k = 0; k < NUM_BINS; k++) phase_acc_q[k] <= '0;
        end else begin
            for (int k = 0; k < NUM_BINS; k++) phase_acc_q[k] <= phase_acc_d[k];
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

            // Arithmetic Right Shift by 2. because cordic IP with scaled radians 
            // Forces Q2.29 input, but phase needs to be between -1 and 1
            // between 111000.. and 001000...
            // Makes the entire system easier because we dont need to multiply with pi,
            // Also, we dont need to detect overflow (phase > pi)
            // Also, now the phase steps are represented perfectly in binary
            // Use concatenation to force the sign extension explicitly.
            logic [PHASE_WIDTH-1:0] phase_scaled;
            assign phase_scaled = { {2{phase_acc_q[k][PHASE_WIDTH-1]}}, phase_acc_q[k][PHASE_WIDTH-1:2] };
            
            // Xilinx CORDIC IP Core
            cordic_0 cordic_inst (
                .aclk(clk_i),
                .s_axis_phase_tvalid(phase_tvalid_i),
                .s_axis_phase_tdata(phase_scaled),
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
    assign sincos_tvalid_o = tvalid_per_bin[0];

endmodule