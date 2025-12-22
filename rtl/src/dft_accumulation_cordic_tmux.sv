module dft_accumulation_cordic_tmux #(
    parameter integer IQ_WIDTH = 16,
    parameter integer IQ_WIDTH_FRAC = 14,
    parameter integer WINDOW_WIDTH = 16,
    parameter integer WINDOW_WIDTH_FRAC = 14,
    parameter integer ACCUM_WIDTH = 48,
    parameter integer ACCUM_WIDTH_FRAC = 40,
    parameter integer NUM_BINS = 24,
    parameter integer OSC_WIDTH = 24, //32
    parameter integer OSC_WIDTH_FRAC = 22, //30
    parameter integer PHASE_WIDTH = 24, //32
    parameter integer SAMPLE_COUNT_WIDTH = 16,
    parameter integer COUNTER_WIDTH = 5        // clog2(NUM_BINS) = 5 bits for 0-23
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- DFT Control ---
    input  logic start_i,              // Clears accumulators, prepares for data
    input  logic sample_valid_i,       // Indicates i_sample_i is valid
    input  logic last_sample_i,        // Indicates the last sample of the window
    
    // --- Oscillator Control ---
    // Top module orchestrates timing to ensure W values align with data pipeline
    input  logic osc_reset_i,          // Resets Phase to 0
    input  logic osc_enable_i,         // Advances Phase
    input  logic osc_phase_tvalid_i,   // Phase valid signal for CORDIC
    
    // Configuration
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],

    // Data Inputs
    input  logic signed [IQ_WIDTH-1:0] i_sample_i,
    input  logic signed [IQ_WIDTH-1:0] q_sample_i,
    input  logic signed [WINDOW_WIDTH-1:0] window_coeff_i,
    
    // Outputs
    output logic signed [48-1:0] A_real_o[NUM_BINS], // accum_width-1
    output logic signed [48-1:0] A_imag_o[NUM_BINS], // accum_width-1
    output logic valid_o,
    output logic busy_o
);

    localparam int BINS_PER_CORDIC = NUM_BINS / 2;  // 12
    localparam int CYCLES_PER_SAMPLE = BINS_PER_CORDIC;  // 12 cycles per sample

    // =========================================================================
    // Parameter Sanity Checks
    // =========================================================================
    initial begin
        assert (ACCUM_WIDTH <= IQ_WIDTH + WINDOW_WIDTH + OSC_WIDTH)
            else $warning("ACCUM_WIDTH (%0d) exceeds allowed sum IQ_WIDTH + WINDOW_WIDTH + OSC_WIDTH (%0d)",
                        ACCUM_WIDTH, IQ_WIDTH + WINDOW_WIDTH + OSC_WIDTH);

        assert (ACCUM_WIDTH_FRAC <= IQ_WIDTH_FRAC + WINDOW_WIDTH_FRAC + OSC_WIDTH_FRAC)
            else $warning("ACCUM_WIDTH_FRAC (%0d) exceeds allowed sum IQ_WIDTH_FRAC + WINDOW_WIDTH_FRAC + OSC_WIDTH_FRAC (%0d)",
                        ACCUM_WIDTH_FRAC, IQ_WIDTH_FRAC + WINDOW_WIDTH_FRAC + OSC_WIDTH_FRAC);
    end

    // =========================================================================
    // Time-Multiplexing Counter (0 to 11)
    // =========================================================================
    logic [COUNTER_WIDTH-1:0] tmux_counter_q, tmux_counter_d;
    
    always_comb begin
        tmux_counter_d = tmux_counter_q;
        
        if (osc_reset_i) begin
            tmux_counter_d = '0;
        end else if (osc_enable_i) begin
            if (tmux_counter_q == COUNTER_WIDTH'(BINS_PER_CORDIC - 1)) begin
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
    // 1. Oscillator Bank Instantiation (Time-Multiplexed)
    // =========================================================================
    logic signed [OSC_WIDTH-1:0] W_real_internal[NUM_BINS];
    logic signed [OSC_WIDTH-1:0] W_imag_internal[NUM_BINS];
    logic sincos_tvalid_internal;
    
    oscillator_bank_tmux #(
        .NUM_BINS(NUM_BINS),
        .OSC_WIDTH(OSC_WIDTH),
        .PHASE_WIDTH(PHASE_WIDTH),
        .COUNTER_WIDTH(COUNTER_WIDTH)
    ) osc_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .phase_acc_enable_i(osc_enable_i),
        .phase_acc_sync_reset_i(osc_reset_i),
        .cordic_phase_tvalid_i(osc_phase_tvalid_i),
        .counter_i(tmux_counter_q),
        .freq_steps_i(freq_steps_i),
        .sincos_tvalid_o(sincos_tvalid_internal),
        .W_real_o(W_real_internal),
        .W_imag_o(W_imag_internal)
    );

    // =========================================================================
    // 2. DFT Core Logic
    // =========================================================================
    
    typedef enum logic [1:0] {
        IDLE = 2'b00,
        ACCUMULATE = 2'b01,
        DONE = 2'b10
    } state_t;

    state_t state_q, state_d;
    logic [SAMPLE_COUNT_WIDTH-1:0] sample_count_q, sample_count_d;

    // --- Pipeline Stage 1: Window Multiplication (held for 12 cycles) ---
    logic signed [IQ_WIDTH+WINDOW_WIDTH-1:0] x_weighted_real_q, x_weighted_real_d;
    logic signed [IQ_WIDTH+WINDOW_WIDTH-1:0] x_weighted_imag_q, x_weighted_imag_d;
    logic windowed_sample_valid_q, windowed_sample_valid_d;
    logic windowed_last_sample_q, windowed_last_sample_d;
    logic [COUNTER_WIDTH-1:0] windowed_cycle_count_q, windowed_cycle_count_d;

    // --- Pipeline Stage 2: Complex Multiplication (2 bins per cycle) ---
    logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] prod_real_q[2], prod_real_d[2];
    logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] prod_imag_q[2], prod_imag_d[2];
    
    logic sample_valid_stage2_q, sample_valid_stage2_d;
    logic last_sample_stage2_q, last_sample_stage2_d;
    logic [COUNTER_WIDTH-1:0] prod_bin_counter_q, prod_bin_counter_d;  // Which bin pair (0-11)

    // --- Accumulators ---
    logic signed [56-1:0] A_real_q[NUM_BINS], A_real_d[NUM_BINS]; //accum_width-1
    logic signed [56-1:0] A_imag_q[NUM_BINS], A_imag_d[NUM_BINS]; //accum_width-1

    // -------------------------------------------------------------------------
    // Sequential Logic
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            sample_count_q <= '0;
            
            x_weighted_real_q <= '0;
            x_weighted_imag_q <= '0;
            windowed_sample_valid_q <= 1'b0;
            windowed_last_sample_q <= 1'b0;
            windowed_cycle_count_q <= '0;
            
            sample_valid_stage2_q <= 1'b0;
            last_sample_stage2_q <= 1'b0;
            prod_bin_counter_q <= '0;
            
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
            
            x_weighted_real_q <= x_weighted_real_d;
            x_weighted_imag_q <= x_weighted_imag_d;
            windowed_sample_valid_q <= windowed_sample_valid_d;
            windowed_last_sample_q <= windowed_last_sample_d;
            windowed_cycle_count_q <= windowed_cycle_count_d;
            
            sample_valid_stage2_q <= sample_valid_stage2_d;
            last_sample_stage2_q <= last_sample_stage2_d;
            prod_bin_counter_q <= prod_bin_counter_d;
            
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

    // -------------------------------------------------------------------------
    // Combinational Logic: Stage 1 (Windowing - held for 12 cycles)
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Assertion: Window coefficient MSB check
    // -------------------------------------------------------------------------
    property window_msb_ok;
        @(posedge clk_i)
        (sample_valid_i && state_q == ACCUMULATE && (WINDOW_WIDTH < IQ_WIDTH))
            |-> (window_coeff_i[WINDOW_WIDTH-1] == 1'b0);
    endproperty

    assert_window_msb_ok: assert property (window_msb_ok)
        else $error("window_coeff_i gets sign extended as a negative number in the first multiplication stage");


    // -------------------------------------------------------------------------
    // Combinational Logic: Stage 2 (Complex Mult - 2 bins per cycle)
    // -------------------------------------------------------------------------
    always_comb begin
        prod_real_d[0] = prod_real_q[0];
        prod_real_d[1] = prod_real_q[1];
        prod_imag_d[0] = prod_imag_q[0];
        prod_imag_d[1] = prod_imag_q[1];
        sample_valid_stage2_d = 1'b0;
        last_sample_stage2_d = 1'b0;
        prod_bin_counter_d = prod_bin_counter_q;

        if (windowed_sample_valid_q) begin
            // Use windowed_cycle_count_q instead of tmux_counter_q
            // This correctly tracks which bins we're computing for
            automatic int bin0 = windowed_cycle_count_q;                    // 0-11
            automatic int bin1 = windowed_cycle_count_q + BINS_PER_CORDIC;  // 12-23
            
            // Complex multiplication for bin0
            logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] xr_wr_0, xi_wi_0, xr_wi_0, xi_wr_0;
            logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] xr_wr_1, xi_wi_1, xr_wi_1, xi_wr_1;

            xr_wr_0 = x_weighted_real_q * W_real_internal[bin0];
            xi_wi_0 = x_weighted_imag_q * W_imag_internal[bin0];
            xr_wi_0 = x_weighted_real_q * W_imag_internal[bin0];
            xi_wr_0 = x_weighted_imag_q * W_real_internal[bin0];
            
            prod_real_d[0] = xr_wr_0 - xi_wi_0;
            prod_imag_d[0] = xr_wi_0 + xi_wr_0;
            
            // Complex multiplication for bin1
            xr_wr_1 = x_weighted_real_q * W_real_internal[bin1];
            xi_wi_1 = x_weighted_imag_q * W_imag_internal[bin1];
            xr_wi_1 = x_weighted_real_q * W_imag_internal[bin1];
            xi_wr_1 = x_weighted_imag_q * W_real_internal[bin1];
            
            prod_real_d[1] = xr_wr_1 - xi_wi_1;
            prod_imag_d[1] = xr_wi_1 + xi_wr_1;
            
            sample_valid_stage2_d = 1'b1;
            last_sample_stage2_d = windowed_last_sample_q && 
                                (windowed_cycle_count_q == COUNTER_WIDTH'(CYCLES_PER_SAMPLE - 1));
            prod_bin_counter_d = windowed_cycle_count_q;  // Use cycle count, not tmux_counter
        end else begin
            sample_valid_stage2_d = 1'b0;
            last_sample_stage2_d = 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Combinational Logic: Accumulation & State (2 bins per cycle)
    // -------------------------------------------------------------------------
    localparam int SHIFT_AMOUNT = IQ_WIDTH_FRAC + WINDOW_WIDTH_FRAC + OSC_WIDTH_FRAC - 48; //-accum_width_frac
    
    always_comb begin
        state_d = state_q;
        sample_count_d = sample_count_q;
        
        // Default: hold all accumulator values
        for (int k = 0; k < NUM_BINS; k++) begin
            A_real_d[k] = A_real_q[k];
            A_imag_d[k] = A_imag_q[k];
        end

        case (state_q)
            IDLE: begin
                if (start_i) begin
                    state_d = ACCUMULATE;
                    sample_count_d = '0;
                    for (int k = 0; k < NUM_BINS; k++) begin
                        A_real_d[k] = '0;
                        A_imag_d[k] = '0;
                    end
                end
            end

            ACCUMULATE: begin
                if (sample_valid_stage2_q) begin
                    // Accumulate into 2 bins this cycle
                    int bin0 = prod_bin_counter_q;
                    int bin1 = prod_bin_counter_q + BINS_PER_CORDIC;
                    
                    if (SHIFT_AMOUNT > 0) begin
                        // Scale down products to fit accumulator
                        A_real_d[bin0] = A_real_q[bin0] + (prod_real_q[0] >>> SHIFT_AMOUNT);
                        A_imag_d[bin0] = A_imag_q[bin0] + (prod_imag_q[0] >>> SHIFT_AMOUNT);
                        
                        A_real_d[bin1] = A_real_q[bin1] + (prod_real_q[1] >>> SHIFT_AMOUNT);
                        A_imag_d[bin1] = A_imag_q[bin1] + (prod_imag_q[1] >>> SHIFT_AMOUNT);
                    end else begin
                        // No scaling needed
                        A_real_d[bin0] = A_real_q[bin0] + prod_real_q[0];
                        A_imag_d[bin0] = A_imag_q[bin0] + prod_imag_q[0];
                        
                        A_real_d[bin1] = A_real_q[bin1] + prod_real_q[1];
                        A_imag_d[bin1] = A_imag_q[bin1] + prod_imag_q[1];
                    end
                    
                    // Count completed samples (after all 12 cycles complete)
                    if (last_sample_stage2_q) begin
                        sample_count_d = sample_count_q + 1;
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

    // -------------------------------------------------------------------------
    // Output Assignments
    // -------------------------------------------------------------------------
    always_comb begin
        for (int k = 0; k < NUM_BINS; k++) begin
            A_real_o[k] = A_real_q[k][56-1:56-48];
            A_imag_o[k] = A_imag_q[k][56-1:56-48];
        end
    end
    
    assign valid_o = (state_q == DONE);
    assign busy_o = (state_q == ACCUMULATE);

endmodule