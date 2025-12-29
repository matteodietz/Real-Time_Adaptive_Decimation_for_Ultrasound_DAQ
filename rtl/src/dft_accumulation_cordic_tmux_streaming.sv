module dft_accumulation_cordic_tmux_streaming #(
    parameter integer IQ_WIDTH = 16,
    parameter integer IQ_WIDTH_FRAC = 14,
    parameter integer WINDOW_WIDTH = 16,
    parameter integer WINDOW_WIDTH_FRAC = 14,
    parameter integer ACCUM_WIDTH = 36,
    parameter integer ACCUM_WIDTH_FRAC = 32,
    parameter integer NUM_BINS = 24,
    parameter integer OSC_WIDTH = 16,
    parameter integer OSC_WIDTH_FRAC = 14,
    parameter integer PHASE_WIDTH = 16,
    parameter integer SAMPLE_COUNT_WIDTH = 16,
    parameter integer COUNTER_WIDTH = 5,
    parameter integer STAGE1_WIDTH = 20,
    parameter integer CORDIC_LATENCY = 20
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // --- DFT Control ---
    input  logic start_i,
    input  logic sample_valid_i,
    input  logic last_sample_i,
    
    // --- Oscillator Control ---
    input  logic osc_reset_i,
    input  logic osc_enable_i,
    input  logic osc_phase_tvalid_i,
    
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
    localparam int CYCLES_PER_SAMPLE = BINS_PER_CORDIC;

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
    // 1. Streaming Oscillator Bank Instantiation
    // =========================================================================
    logic signed [OSC_WIDTH-1:0] cos_out_0, sin_out_0;
    logic signed [OSC_WIDTH-1:0] cos_out_1, sin_out_1;
    logic [COUNTER_WIDTH-1:0] output_bin_0, output_bin_1;
    logic sincos_tvalid;
    
    oscillator_bank_tmux_streaming #(
        .NUM_BINS(NUM_BINS),
        .OSC_WIDTH(OSC_WIDTH),
        .PHASE_WIDTH(PHASE_WIDTH),
        .COUNTER_WIDTH(COUNTER_WIDTH),
        .CORDIC_LATENCY(CORDIC_LATENCY)
    ) osc_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .phase_acc_enable_i(osc_enable_i),
        .phase_acc_sync_reset_i(osc_reset_i),
        .cordic_phase_tvalid_i(osc_phase_tvalid_i),
        .counter_i(tmux_counter_q),
        .freq_steps_i(freq_steps_i),
        .cos_out_0_o(cos_out_0),
        .sin_out_0_o(sin_out_0),
        .cos_out_1_o(cos_out_1),
        .sin_out_1_o(sin_out_1),
        .output_bin_0_o(output_bin_0),
        .output_bin_1_o(output_bin_1),
        .sincos_tvalid_o(sincos_tvalid)
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
    logic signed [STAGE1_WIDTH-1:0] x_weighted_real_q, x_weighted_real_d;
    logic signed [STAGE1_WIDTH-1:0] x_weighted_imag_q, x_weighted_imag_d;
    logic windowed_sample_valid_q, windowed_sample_valid_d;
    logic windowed_last_sample_q, windowed_last_sample_d;
    logic [COUNTER_WIDTH-1:0] windowed_cycle_count_q, windowed_cycle_count_d;

    // --- Pipeline Stage 2a: Complex Multiplication Results (4 products per bin) ---
    logic signed [STAGE1_WIDTH+OSC_WIDTH-1:0] xr_wr_q[2], xr_wr_d[2];
    logic signed [STAGE1_WIDTH+OSC_WIDTH-1:0] xi_wi_q[2], xi_wi_d[2];
    logic signed [STAGE1_WIDTH+OSC_WIDTH-1:0] xr_wi_q[2], xr_wi_d[2];
    logic signed [STAGE1_WIDTH+OSC_WIDTH-1:0] xi_wr_q[2], xi_wr_d[2];
    
    logic [COUNTER_WIDTH-1:0] mult_bin_0_q, mult_bin_0_d;
    logic [COUNTER_WIDTH-1:0] mult_bin_1_q, mult_bin_1_d;
    logic sample_valid_mult_q, sample_valid_mult_d;
    logic last_sample_mult_q, last_sample_mult_d;

    // --- Pipeline Stage 2b: Complex Add/Subtract Results ---
    logic signed [STAGE1_WIDTH+OSC_WIDTH-1:0] prod_real_q[2], prod_real_d[2];
    logic signed [STAGE1_WIDTH+OSC_WIDTH-1:0] prod_imag_q[2], prod_imag_d[2];
    
    (* MAX_FANOUT = 12 *) logic [COUNTER_WIDTH-1:0] prod_bin_0_q, prod_bin_0_d;
    (* MAX_FANOUT = 12 *) logic [COUNTER_WIDTH-1:0] prod_bin_1_q, prod_bin_1_d;
    logic sample_valid_stage2_q, sample_valid_stage2_d;
    logic last_sample_stage2_q, last_sample_stage2_d;

    // --- Accumulators ---
    logic signed [ACCUM_WIDTH-1:0] A_real_q[NUM_BINS], A_real_d[NUM_BINS];
    logic signed [ACCUM_WIDTH-1:0] A_imag_q[NUM_BINS], A_imag_d[NUM_BINS];

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
            
            // Stage 2a registers
            for (int i = 0; i < 2; i++) begin
                xr_wr_q[i] <= '0;
                xi_wi_q[i] <= '0;
                xr_wi_q[i] <= '0;
                xi_wr_q[i] <= '0;
            end
            mult_bin_0_q <= '0;
            mult_bin_1_q <= '0;
            sample_valid_mult_q <= 1'b0;
            last_sample_mult_q <= 1'b0;
            
            // Stage 2b registers
            for (int i = 0; i < 2; i++) begin
                prod_real_q[i] <= '0;
                prod_imag_q[i] <= '0;
            end
            prod_bin_0_q <= '0;
            prod_bin_1_q <= '0;
            sample_valid_stage2_q <= 1'b0;
            last_sample_stage2_q <= 1'b0;
            
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
            
            // Stage 2a
            for (int i = 0; i < 2; i++) begin
                xr_wr_q[i] <= xr_wr_d[i];
                xi_wi_q[i] <= xi_wi_d[i];
                xr_wi_q[i] <= xr_wi_d[i];
                xi_wr_q[i] <= xi_wr_d[i];
            end
            mult_bin_0_q <= mult_bin_0_d;
            mult_bin_1_q <= mult_bin_1_d;
            sample_valid_mult_q <= sample_valid_mult_d;
            last_sample_mult_q <= last_sample_mult_d;
            
            // Stage 2b
            for (int i = 0; i < 2; i++) begin
                prod_real_q[i] <= prod_real_d[i];
                prod_imag_q[i] <= prod_imag_d[i];
            end
            prod_bin_0_q <= prod_bin_0_d;
            prod_bin_1_q <= prod_bin_1_d;
            sample_valid_stage2_q <= sample_valid_stage2_d;
            last_sample_stage2_q <= last_sample_stage2_d;
            
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
        logic signed [IQ_WIDTH+WINDOW_WIDTH-1:0] mult_real_full;
        logic signed [IQ_WIDTH+WINDOW_WIDTH-1:0] mult_imag_full;
        localparam int TRUNC_BITS = (IQ_WIDTH + WINDOW_WIDTH) - STAGE1_WIDTH;

        x_weighted_real_d = x_weighted_real_q;
        x_weighted_imag_d = x_weighted_imag_q;
        windowed_sample_valid_d = windowed_sample_valid_q;
        windowed_last_sample_d = windowed_last_sample_q;
        windowed_cycle_count_d = windowed_cycle_count_q;
        
        if (sample_valid_i && (state_q == ACCUMULATE) && (tmux_counter_q == '0)) begin
            // New sample: compute windowed values
            mult_real_full = $signed(i_sample_i) * $signed(window_coeff_i);
            mult_imag_full = $signed(q_sample_i) * $signed(window_coeff_i);

            // Round and Truncate
            x_weighted_real_d = (mult_real_full + (1'sb1 << (TRUNC_BITS-1))) >>> TRUNC_BITS;
            x_weighted_imag_d = (mult_imag_full + (1'sb1 << (TRUNC_BITS-1))) >>> TRUNC_BITS;

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
    // Combinational Logic: Stage 2a (Multiplication only)
    // -------------------------------------------------------------------------
    always_comb begin
        // Defaults
        for (int i = 0; i < 2; i++) begin
            xr_wr_d[i] = xr_wr_q[i];
            xi_wi_d[i] = xi_wi_q[i];
            xr_wi_d[i] = xr_wi_q[i];
            xi_wr_d[i] = xi_wr_q[i];
        end
        mult_bin_0_d = mult_bin_0_q;
        mult_bin_1_d = mult_bin_1_q;
        sample_valid_mult_d = 1'b0;
        last_sample_mult_d = 1'b0;

        if (windowed_sample_valid_q) begin
            // Perform 4 multiplications per CORDIC (8 total)
            // CORDIC_0 outputs (bin0)
            xr_wr_d[0] = x_weighted_real_q * cos_out_0;
            xi_wi_d[0] = x_weighted_imag_q * sin_out_0;
            xr_wi_d[0] = x_weighted_real_q * sin_out_0;
            xi_wr_d[0] = x_weighted_imag_q * cos_out_0;
            
            // CORDIC_1 outputs (bin1)
            xr_wr_d[1] = x_weighted_real_q * cos_out_1;
            xi_wi_d[1] = x_weighted_imag_q * sin_out_1;
            xr_wi_d[1] = x_weighted_real_q * sin_out_1;
            xi_wr_d[1] = x_weighted_imag_q * cos_out_1;
            
            // Register bin indices
            mult_bin_0_d = output_bin_0;
            mult_bin_1_d = output_bin_1;
            
            sample_valid_mult_d = 1'b1;
            last_sample_mult_d = windowed_last_sample_q && 
                                 (windowed_cycle_count_q == COUNTER_WIDTH'(CYCLES_PER_SAMPLE - 1));
        end
    end

    // -------------------------------------------------------------------------
    // Combinational Logic: Stage 2b (Add/Subtract only)
    // -------------------------------------------------------------------------
    always_comb begin
        // Defaults
        prod_real_d[0] = prod_real_q[0];
        prod_real_d[1] = prod_real_q[1];
        prod_imag_d[0] = prod_imag_q[0];
        prod_imag_d[1] = prod_imag_q[1];
        prod_bin_0_d = prod_bin_0_q;
        prod_bin_1_d = prod_bin_1_q;
        sample_valid_stage2_d = 1'b0;
        last_sample_stage2_d = 1'b0;

        if (sample_valid_mult_q) begin
            // Perform complex add/subtract
            prod_real_d[0] = xr_wr_q[0] - xi_wi_q[0];
            prod_imag_d[0] = xr_wi_q[0] + xi_wr_q[0];
            
            prod_real_d[1] = xr_wr_q[1] - xi_wi_q[1];
            prod_imag_d[1] = xr_wi_q[1] + xi_wr_q[1];
            
            // Pass through bin indices (one more pipeline stage)
            prod_bin_0_d = mult_bin_0_q;
            prod_bin_1_d = mult_bin_1_q;
            
            sample_valid_stage2_d = 1'b1;
            last_sample_stage2_d = last_sample_mult_q;
        end
    end

    // -------------------------------------------------------------------------
    // Combinational Logic: Accumulation using registered bin indices
    // -------------------------------------------------------------------------
    localparam int PROD_FRAC = (IQ_WIDTH_FRAC + WINDOW_WIDTH_FRAC - (IQ_WIDTH + WINDOW_WIDTH - STAGE1_WIDTH)) + OSC_WIDTH_FRAC;
    localparam int SHIFT_AMOUNT = PROD_FRAC - ACCUM_WIDTH_FRAC;
    
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
                    automatic int bin0 = prod_bin_0_q;
                    automatic int bin1 = prod_bin_1_q;
                    
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
            A_real_o[k] = A_real_q[k];
            A_imag_o[k] = A_imag_q[k];
        end
    end
    
    assign valid_o = (state_q == DONE);
    assign busy_o = (state_q == ACCUMULATE);

endmodule