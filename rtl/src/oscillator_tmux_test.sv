////////////////////////////////////////////////////////////////////////////////
//
//  Module: oscillator_tmux_test
//
//  Simple time-multiplexed oscillator with 1 CORDIC alternating between 2 bins
//  Outputs are stored in FFs for each bin
//
////////////////////////////////////////////////////////////////////////////////
module oscillator_tmux_test #(
    parameter int OSC_WIDTH = 32,
    parameter int PHASE_WIDTH = 32
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Phase accumulator control
    input  logic phase_acc_enable_i,       // Enable phase accumulator updates
    input  logic phase_acc_sync_reset_i,   // Reset phase accumulators
    
    // CORDIC control
    input  logic cordic_phase_tvalid_i,    // CORDIC input valid
    
    // Configuration
    input  logic [PHASE_WIDTH-1:0] freq_step_0_i,  // Frequency step for bin 0
    input  logic [PHASE_WIDTH-1:0] freq_step_1_i,  // Frequency step for bin 1
    
    // Outputs - stored values for each bin
    output logic signed [OSC_WIDTH-1:0] W_real_0_o,
    output logic signed [OSC_WIDTH-1:0] W_imag_0_o,
    output logic signed [OSC_WIDTH-1:0] W_real_1_o,
    output logic signed [OSC_WIDTH-1:0] W_imag_1_o,
    output logic sincos_tvalid_o
);

    // =========================================================================
    // Counter to select bin (toggles between 0 and 1)
    // =========================================================================
    logic counter_q, counter_d;
    
    always_comb begin
        if (phase_acc_enable_i) begin
            counter_d = ~counter_q;  // Toggle
        end else begin
            counter_d = counter_q;
        end
    end
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni || phase_acc_sync_reset_i) begin
            counter_q <= 1'b0;
        end else begin
            counter_q <= counter_d;
        end
    end

    // =========================================================================
    // Phase Accumulators (2 total)
    // =========================================================================
    logic [PHASE_WIDTH-1:0] phase_acc_0_q, phase_acc_0_d;
    logic [PHASE_WIDTH-1:0] phase_acc_1_q, phase_acc_1_d;
    
    always_comb begin
        // Default: hold values
        phase_acc_0_d = phase_acc_0_q;
        phase_acc_1_d = phase_acc_1_q;
        
        if (phase_acc_sync_reset_i) begin
            phase_acc_0_d = '0;
            phase_acc_1_d = '0;
        end else if (phase_acc_enable_i) begin
            // Update the bin corresponding to current counter value
            if (counter_q == 1'b0) begin
                phase_acc_0_d = phase_acc_0_q + freq_step_0_i;
            end else begin
                phase_acc_1_d = phase_acc_1_q + freq_step_1_i;
            end
        end
    end
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            phase_acc_0_q <= '0;
            phase_acc_1_q <= '0;
        end else begin
            phase_acc_0_q <= phase_acc_0_d;
            phase_acc_1_q <= phase_acc_1_d;
        end
    end

    // =========================================================================
    // Mux to select which phase goes to CORDIC
    // =========================================================================
    logic [PHASE_WIDTH-1:0] phase_to_cordic;
    
    assign phase_to_cordic = counter_q ? phase_acc_1_q : phase_acc_0_q;

    // =========================================================================
    // CORDIC Instantiation
    // =========================================================================
    logic [PHASE_WIDTH-1:0] phase_scaled;
    logic signed [OSC_WIDTH-1:0] cos_out, sin_out;
    logic [2*OSC_WIDTH-1:0] cordic_dout;
    logic tvalid;
    
    // Scale phase for CORDIC (Q2.14 format requirement)
    assign phase_scaled = { 
        {2{phase_to_cordic[PHASE_WIDTH-1]}}, 
        phase_to_cordic[PHASE_WIDTH-1:2] 
    };
    
    cordic_0 cordic_inst (
        .aclk(clk_i),
        .s_axis_phase_tvalid(cordic_phase_tvalid_i),
        .s_axis_phase_tdata(phase_scaled),
        .m_axis_dout_tvalid(tvalid),
        .m_axis_dout_tdata(cordic_dout)
    );
    
    assign cos_out = cordic_dout[OSC_WIDTH-1:0];
    assign sin_out = cordic_dout[2*OSC_WIDTH-1:OSC_WIDTH];

    // =========================================================================
    // Pipeline to track which bin the output corresponds to
    // Delay counter by CORDIC latency (36 cycles)
    // =========================================================================
    localparam int CORDIC_LATENCY = 36;
    logic counter_pipe[CORDIC_LATENCY];
    logic output_bin_select;
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (int i = 0; i < CORDIC_LATENCY; i++) begin
                counter_pipe[i] <= 1'b0;
            end
        end else if (cordic_phase_tvalid_i) begin
            counter_pipe[0] <= counter_q;
            for (int i = 1; i < CORDIC_LATENCY; i++) begin
                counter_pipe[i] <= counter_pipe[i-1];
            end
        end
    end
    
    assign output_bin_select = counter_pipe[CORDIC_LATENCY-1];

    // =========================================================================
    // Output Storage FFs - Store latest value for each bin
    // =========================================================================
    logic signed [OSC_WIDTH-1:0] W_real_0_q, W_real_0_d;
    logic signed [OSC_WIDTH-1:0] W_imag_0_q, W_imag_0_d;
    logic signed [OSC_WIDTH-1:0] W_real_1_q, W_real_1_d;
    logic signed [OSC_WIDTH-1:0] W_imag_1_q, W_imag_1_d;
    
    always_comb begin
        // Default: hold values
        W_real_0_d = W_real_0_q;
        W_imag_0_d = W_imag_0_q;
        W_real_1_d = W_real_1_q;
        W_imag_1_d = W_imag_1_q;
        
        // When CORDIC output is valid, store to appropriate bin
        if (tvalid) begin
            if (output_bin_select == 1'b0) begin
                // Update bin 0
                W_real_0_d = cos_out;
                W_imag_0_d = -sin_out;  // DFT requires -j*sin
            end else begin
                // Update bin 1
                W_real_1_d = cos_out;
                W_imag_1_d = -sin_out;  // DFT requires -j*sin
            end
        end
    end
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            W_real_0_q <= '0;
            W_imag_0_q <= '0;
            W_real_1_q <= '0;
            W_imag_1_q <= '0;
        end else begin
            W_real_0_q <= W_real_0_d;
            W_imag_0_q <= W_imag_0_d;
            W_real_1_q <= W_real_1_d;
            W_imag_1_q <= W_imag_1_d;
        end
    end

    // =========================================================================
    // Output Assignments
    // =========================================================================
    assign W_real_0_o = W_real_0_q;
    assign W_imag_0_o = W_imag_0_q;
    assign W_real_1_o = W_real_1_q;
    assign W_imag_1_o = W_imag_1_q;
    assign sincos_tvalid_o = tvalid;

endmodule