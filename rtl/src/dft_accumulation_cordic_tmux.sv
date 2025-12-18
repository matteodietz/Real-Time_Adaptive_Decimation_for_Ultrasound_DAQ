module dft_accumulation_cordic_tmux #(
    parameter integer IQ_WIDTH = 16,
    parameter integer IQ_WIDTH_FRAC = 14,
    parameter integer WINDOW_WIDTH = 16,
    parameter integer WINDOW_WIDTH_FRAC = 14,
    parameter integer ACCUM_WIDTH = 48,
    parameter integer ACCUM_WIDTH_FRAC = 40,
    parameter integer NUM_BINS = 24,            // MUST BE EVEN
    parameter integer OSC_WIDTH = 32,
    parameter integer OSC_WIDTH_FRAC = 30,
    parameter integer PHASE_WIDTH = 16,
    parameter integer SAMPLE_COUNT_WIDTH = 16,
    parameter integer COUNTER_WIDTH = 4,       // clog2(NUM_BINS/2)
    parameter integer OSC_LATENCY = 36         // CORDIC latency
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- DFT Control ---
    input  logic start_i,              // Start new DFT computation
    input  logic sample_valid_i,       // New I/Q sample available
    input  logic last_sample_i,        // Last sample in window
    
    // Configuration
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    // Data Inputs
    input  logic signed [IQ_WIDTH-1:0] i_sample_i,
    input  logic signed [IQ_WIDTH-1:0] q_sample_i,
    input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    
    // Outputs
    output logic signed [ACCUM_WIDTH-1:0] A_real_o[NUM_BINS],
    output logic signed [ACCUM_WIDTH-1:0] A_imag_o[NUM_BINS],
    output logic valid_o,
    output logic busy_o
);

    localparam int BINS_PER_CORDIC = NUM_BINS / 2;
    localparam int CYCLES_PER_SAMPLE = BINS_PER_CORDIC;  // 12 cycles per sample

    // =========================================================================
    // State Machine
    // =========================================================================
    typedef enum logic [2:0] {
        IDLE = 3'b000,
        OSC_STARTUP = 3'b001,      // Wait for CORDIC latency
        ACCUMULATE = 3'b010,
        DONE = 3'b011
    } state_t;

    state_t state_q, state_d;
    logic [SAMPLE_COUNT_WIDTH-1:0] sample_count_q, sample_count_d;
    logic [COUNTER_WIDTH-1:0] osc_startup_counter_q, osc_startup_counter_d;

    // =========================================================================
    // Counter for Time Multiplexing (0 to CYCLES_PER_SAMPLE-1)
    // =========================================================================
    logic [COUNTER_WIDTH-1:0] tmux_counter_q, tmux_counter_d;
    logic tmux_counter_enable;
    logic tmux_counter_reset;
    
    always_comb begin
        tmux_counter_d = tmux_counter_q;
        
        if (tmux_counter_reset) begin
            tmux_counter_d = '0;
        end else if (tmux_counter_enable) begin
            if (tmux_counter_q == COUNTER_WIDTH'(CYCLES_PER_SAMPLE - 1)) begin
                tmux_counter_d = '0;
            end else begin
                tmux_counter_d = tmux_counter_q + 1;
            end
        end
    end
    
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            tmux_counter_q <= '0;
        end else begin
            tmux_counter_q <= tmux_counter_d;
        end
    end

    // =========================================================================
    // Oscillator Bank Instantiation
    // =========================================================================
    logic signed [OSC_WIDTH-1:0] W_real_tmux[2];
    logic signed [OSC_WIDTH-1:0] W_imag_tmux[2];
    logic sincos_tvalid;
    logic phase_acc_enable;
    logic phase_acc_sync_reset;
    logic cordic_phase_tvalid;
    
    oscillator_bank_tmux #(
        .NUM_BINS(NUM_BINS),
        .OSC_WIDTH(OSC_WIDTH),
        .PHASE_WIDTH(PHASE_WIDTH),
        .COUNTER_WIDTH(COUNTER_WIDTH)
    ) osc_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .phase_acc_enable_i(phase_acc_enable),
        .phase_acc_sync_reset_i(phase_acc_sync_reset),
        .cordic_phase_tvalid_i(cordic_phase_tvalid),
        .counter_i(tmux_counter_q),
        .freq_steps_i(freq_steps_i),
        .sincos_tvalid_o(sincos_tvalid),
        .W_real_o(W_real_tmux),
        .W_imag_o(W_imag_tmux)
    );

    // =========================================================================
    // Pipeline: Stage 1 - Windowing (held for 12 cycles)
    // =========================================================================
    logic signed [IQ_WIDTH+WINDOW_WIDTH-1:0] x_weighted_real_q, x_weighted_real_d;
    logic signed [IQ_WIDTH+WINDOW_WIDTH-1:0] x_weighted_imag_q, x_weighted_imag_d;
    logic windowed_sample_valid_q, windowed_sample_valid_d;
    logic windowed_last_sample_q, windowed_last_sample_d;
    logic [COUNTER_WIDTH-1:0] windowed_cycle_count_q, windowed_cycle_count_d;
    
    always_comb begin
        x_weighted_real_d = x_weighted_real_q;
        x_weighted_imag_d = x_weighted_imag_q;
        windowed_sample_valid_d = windowed_sample_valid_q;
        windowed_last_sample_d = windowed_last_sample_q;
        windowed_cycle_count_d = windowed_cycle_count_q;
        
        if (sample_valid_i && (state_q == ACCUMULATE) && (tmux_counter_q == '0)) begin
            // New sample: compute windowed values
            x_weighted_real_d = $signed(i_sample_i) * $signed(window_coeff_i);
            x_weighted_imag_d = $signed(q_sample_i) * $signed(window_coeff_i);
            windowed_sample_valid_d = 1'b1;
            windowed_last_sample_d = last_sample_i;
            windowed_cycle_count_d = '0;
        end else if (windowed_sample_valid_q) begin
            // Hold windowed sample for 12 cycles
            if (windowed_cycle_count_q == COUNTER_WIDTH'(CYCLES_PER_SAMPLE - 1)) begin
                windowed_sample_valid_d = 1'b0;
                windowed_last_sample_d = 1'b0;
            end else begin
                windowed_cycle_count_d = windowed_cycle_count_q + 1;
            end
        end
    end

    // =========================================================================
    // Pipeline: Stage 2 - Complex Multiplication (aligned with oscillator output)
    // =========================================================================
    logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] prod_real_d[2], prod_real_q[2];
    logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] prod_imag_d[2], prod_imag_q[2];
    logic prod_valid_q, prod_valid_d;
    logic [COUNTER_WIDTH-1:0] prod_counter_q, prod_counter_d;  // Which bins these products are for
    
    always_comb begin
        prod_real_d[0] = prod_real_q[0];
        prod_real_d[1] = prod_real_q[1];
        prod_imag_d[0] = prod_imag_q[0];
        prod_imag_d[1] = prod_imag_q[1];
        prod_valid_d = 1'b0;
        prod_counter_d = prod_counter_q;
        
        if (windowed_sample_valid_q && sincos_tvalid) begin
            // Complex multiplication: (x_real + j*x_imag) * (W_real + j*W_imag)
            for (int i = 0; i < 2; i++) begin
                logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] xr_wr, xi_wi, xr_wi, xi_wr;
                
                xr_wr = x_weighted_real_q * W_real_tmux[i];
                xi_wi = x_weighted_imag_q * W_imag_tmux[i];
                xr_wi = x_weighted_real_q * W_imag_tmux[i];
                xi_wr = x_weighted_imag_q * W_real_tmux[i];
                
                prod_real_d[i] = xr_wr - xi_wi;
                prod_imag_d[i] = xr_wi + xi_wr;
            end
            
            prod_valid_d = 1'b1;
            prod_counter_d = tmux_counter_q;  // Track which bins these products belong to
        end
    end

    // =========================================================================
    // Accumulators (24 bins)
    // =========================================================================
    logic signed [ACCUM_WIDTH-1:0] A_real_q[NUM_BINS], A_real_d[NUM_BINS];
    logic signed [ACCUM_WIDTH-1:0] A_imag_q[NUM_BINS], A_imag_d[NUM_BINS];
    
    localparam int SHIFT_AMOUNT = IQ_WIDTH_FRAC + WINDOW_WIDTH_FRAC + OSC_WIDTH_FRAC - ACCUM_WIDTH_FRAC;
    
    always_comb begin
        // Default: hold values
        for (int k = 0; k < NUM_BINS; k++) begin
            A_real_d[k] = A_real_q[k];
            A_imag_d[k] = A_imag_q[k];
        end
        
        // Accumulate into correct bins
        if (prod_valid_q) begin
            // Bin indices from counter
            int bin0 = prod_counter_q;
            int bin1 = prod_counter_q + BINS_PER_CORDIC;
            
            if (SHIFT_AMOUNT > 0) begin
                A_real_d[bin0] = A_real_q[bin0] + (prod_real_q[0] >>> SHIFT_AMOUNT);
                A_imag_d[bin0] = A_imag_q[bin0] + (prod_imag_q[0] >>> SHIFT_AMOUNT);
                
                A_real_d[bin1] = A_real_q[bin1] + (prod_real_q[1] >>> SHIFT_AMOUNT);
                A_imag_d[bin1] = A_imag_q[bin1] + (prod_imag_q[1] >>> SHIFT_AMOUNT);
            end else begin
                A_real_d[bin0] = A_real_q[bin0] + prod_real_q[0];
                A_imag_d[bin0] = A_imag_q[bin0] + prod_imag_q[0];
                
                A_real_d[bin1] = A_real_q[bin1] + prod_real_q[1];
                A_imag_d[bin1] = A_imag_q[bin1] + prod_imag_q[1];
            end
        end
    end

    // =========================================================================
    // State Machine Logic
    // =========================================================================
    always_comb begin
        state_d = state_q;
        sample_count_d = sample_count_q;
        osc_startup_counter_d = osc_startup_counter_q;
        
        // Control signals
        tmux_counter_enable = 1'b0;
        tmux_counter_reset = 1'b0;
        phase_acc_enable = 1'b0;
        phase_acc_sync_reset = 1'b0;
        cordic_phase_tvalid = 1'b0;
        
        case (state_q)
            IDLE: begin
                if (start_i) begin
                    state_d = OSC_STARTUP;
                    sample_count_d = '0;
                    osc_startup_counter_d = '0;
                    tmux_counter_reset = 1'b1;
                    phase_acc_sync_reset = 1'b1;
                    
                    // Clear accumulators
                    for (int k = 0; k < NUM_BINS; k++) begin
                        A_real_d[k] = '0;
                        A_imag_d[k] = '0;
                    end
                end
            end
            
            OSC_STARTUP: begin
                // Run oscillator for OSC_LATENCY-1 cycles before accepting data
                tmux_counter_enable = 1'b1;
                phase_acc_enable = 1'b1;
                cordic_phase_tvalid = 1'b1;
                
                if (tmux_counter_q == COUNTER_WIDTH'(CYCLES_PER_SAMPLE - 1)) begin
                    osc_startup_counter_d = osc_startup_counter_q + 1;
                    
                    if (osc_startup_counter_q == COUNTER_WIDTH'(OSC_LATENCY - 1)) begin
                        state_d = ACCUMULATE;
                    end
                end
            end
            
            ACCUMULATE: begin
                tmux_counter_enable = 1'b1;
                phase_acc_enable = 1'b1;
                cordic_phase_tvalid = 1'b1;
                
                // Count completed samples
                if (windowed_sample_valid_q && 
                    (windowed_cycle_count_q == COUNTER_WIDTH'(CYCLES_PER_SAMPLE - 1))) begin
                    sample_count_d = sample_count_q + 1;
                    
                    if (windowed_last_sample_q) begin
                        state_d = DONE;
                    end
                end
            end
            
            DONE: begin
                state_d = IDLE;
            end
            
            default: state_d = IDLE;
        endcase
    end

    // =========================================================================
    // Sequential Logic
    // =========================================================================
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            sample_count_q <= '0;
            osc_startup_counter_q <= '0;
            
            x_weighted_real_q <= '0;
            x_weighted_imag_q <= '0;
            windowed_sample_valid_q <= 1'b0;
            windowed_last_sample_q <= 1'b0;
            windowed_cycle_count_q <= '0;
            
            prod_valid_q <= 1'b0;
            prod_counter_q <= '0;
            
            for (int i = 0; i < 2; i++) begin
                prod_real_q[i] <= '0;
                prod_imag_q[i] <= '0;
            end
            
            for (int k = 0; k < NUM_BINS; k++) begin
                A_real_q[k] <= '0;
                A_imag_q[k] <= '0;
            end
        end else begin
            state_q <= state_d;
            sample_count_q <= sample_count_d;
            osc_startup_counter_q <= osc_startup_counter_d;
            
            x_weighted_real_q <= x_weighted_real_d;
            x_weighted_imag_q <= x_weighted_imag_d;
            windowed_sample_valid_q <= windowed_sample_valid_d;
            windowed_last_sample_q <= windowed_last_sample_d;
            windowed_cycle_count_q <= windowed_cycle_count_d;
            
            prod_valid_q <= prod_valid_d;
            prod_counter_q <= prod_counter_d;
            
            for (int i = 0; i < 2; i++) begin
                prod_real_q[i] <= prod_real_d[i];
                prod_imag_q[i] <= prod_imag_d[i];
            end
            
            for (int k = 0; k < NUM_BINS; k++) begin
                A_real_q[k] <= A_real_d[k];
                A_imag_q[k] <= A_imag_d[k];
            end
        end
    end

    // =========================================================================
    // Outputs
    // =========================================================================
    always_comb begin
        for (int k = 0; k < NUM_BINS; k++) begin
            A_real_o[k] = A_real_q[k];
            A_imag_o[k] = A_imag_q[k];
        end
    end
    
    assign valid_o = (state_q == DONE);
    assign busy_o = (state_q == OSC_STARTUP) || (state_q == ACCUMULATE);

endmodule