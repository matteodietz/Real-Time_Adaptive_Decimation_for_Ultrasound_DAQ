////////////////////////////////////////////////////////////////////////////////
//
//  Module: oscillator_bank_tmux (Time-Multiplexed Oscillator Bank)
//
//  Function: Generates N complex oscillators using 2 CORDIC blocks time-multiplexed
//            CORDIC_0 handles bins 0-11, CORDIC_1 handles bins 12-23
//
////////////////////////////////////////////////////////////////////////////////
module oscillator_bank_tmux #(
    parameter int NUM_BINS = 24,           // MUST BE EVEN
    parameter int OSC_WIDTH = 32,
    parameter int PHASE_WIDTH = 16,
    parameter int COUNTER_WIDTH = 4        // clog2(NUM_BINS/2)
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Phase accumulator control
    input  logic phase_acc_enable_i,       // Enable phase accumulator updates
    input  logic phase_acc_sync_reset_i,   // Reset all phase accumulators
    
    // CORDIC control
    input  logic cordic_phase_tvalid_i,    // CORDIC input valid
    input  logic [COUNTER_WIDTH-1:0] counter_i,  // Bin select counter (0 to NUM_BINS/2-1)
    
    // Configuration
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    // Outputs (2 bins per cycle)
    output logic sincos_tvalid_o,
    output logic signed [OSC_WIDTH-1:0] W_real_o[2],   // [0] = bin counter_i, [1] = bin counter_i+12
    output logic signed [OSC_WIDTH-1:0] W_imag_o[2]
);

    localparam int BINS_PER_CORDIC = NUM_BINS / 2;

    // =========================================================================
    // Phase Accumulators (24 total, updated once every 12 cycles)
    // =========================================================================
    logic [PHASE_WIDTH-1:0] phase_acc_d[NUM_BINS];
    logic [PHASE_WIDTH-1:0] phase_acc_q[NUM_BINS];
    
    always_comb begin
        // Default: hold values
        for (int k = 0; k < NUM_BINS; k++) begin
            phase_acc_d[k] = phase_acc_q[k];
        end
        
        if (phase_acc_sync_reset_i) begin
            for (int k = 0; k < NUM_BINS; k++) begin
                phase_acc_d[k] = '0;
            end
        end else if (phase_acc_enable_i) begin
            // Update the two bins corresponding to current counter value
            phase_acc_d[counter_i] = phase_acc_q[counter_i] + freq_steps_i[counter_i];
            phase_acc_d[counter_i + BINS_PER_CORDIC] = 
                phase_acc_q[counter_i + BINS_PER_CORDIC] + freq_steps_i[counter_i + BINS_PER_CORDIC];
        end
    end
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (int k = 0; k < NUM_BINS; k++) begin
                phase_acc_q[k] <= '0;
            end
        end else begin
            for (int k = 0; k < NUM_BINS; k++) begin
                phase_acc_q[k] <= phase_acc_d[k];
            end
        end
    end

    // =========================================================================
    // CORDIC Instantiations (2 blocks)
    // =========================================================================
    
    // CORDIC 0: Handles bins 0-11
    logic [PHASE_WIDTH-1:0] phase_scaled_0;
    logic signed [OSC_WIDTH-1:0] cos_out_0, sin_out_0;
    logic [2*OSC_WIDTH-1:0] cordic_dout_0;
    logic tvalid_0;
    
    assign phase_scaled_0 = { 
        {2{phase_acc_q[counter_i][PHASE_WIDTH-1]}}, 
        phase_acc_q[counter_i][PHASE_WIDTH-1:2] 
    };
    
    cordic_0 cordic_inst_0 (
        .aclk(clk_i),
        .s_axis_phase_tvalid(cordic_phase_tvalid_i),
        .s_axis_phase_tdata(phase_scaled_0),
        .m_axis_dout_tvalid(tvalid_0),
        .m_axis_dout_tdata(cordic_dout_0)
    );
    
    assign cos_out_0 = cordic_dout_0[OSC_WIDTH-1:0];
    assign sin_out_0 = cordic_dout_0[2*OSC_WIDTH-1:OSC_WIDTH];
    
    // CORDIC 1: Handles bins 12-23
    logic [PHASE_WIDTH-1:0] phase_scaled_1;
    logic signed [OSC_WIDTH-1:0] cos_out_1, sin_out_1;
    logic [2*OSC_WIDTH-1:0] cordic_dout_1;
    logic tvalid_1;
    
    assign phase_scaled_1 = { 
        {2{phase_acc_q[counter_i + BINS_PER_CORDIC][PHASE_WIDTH-1]}}, 
        phase_acc_q[counter_i + BINS_PER_CORDIC][PHASE_WIDTH-1:2] 
    };
    
    cordic_0 cordic_inst_1 (
        .aclk(clk_i),
        .s_axis_phase_tvalid(cordic_phase_tvalid_i),
        .s_axis_phase_tdata(phase_scaled_1),
        .m_axis_dout_tvalid(tvalid_1),
        .m_axis_dout_tdata(cordic_dout_1)
    );
    
    assign cos_out_1 = cordic_dout_1[OSC_WIDTH-1:0];
    assign sin_out_1 = cordic_dout_1[2*OSC_WIDTH-1:OSC_WIDTH];
    
    // =========================================================================
    // Output Assignments
    // =========================================================================
    
    // DFT requires exp(-j*theta) = cos(theta) - j*sin(theta)
    assign W_real_o[0] = cos_out_0;
    assign W_imag_o[0] = -sin_out_0;
    
    assign W_real_o[1] = cos_out_1;
    assign W_imag_o[1] = -sin_out_1;
    
    assign sincos_tvalid_o = tvalid_0 && tvalid_1;

endmodule