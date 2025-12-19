module dft_accumulation_cordic #(
    parameter integer IQ_WIDTH = 16,
    parameter integer IQ_WIDTH_FRAC = 14,
    parameter integer WINDOW_WIDTH = 16,
    parameter integer WINDOW_WIDTH_FRAC = 14,
    parameter integer ACCUM_WIDTH = 48,
    parameter integer ACCUM_WIDTH_FRAC = 40,
    parameter integer NUM_BINS = 16,
    parameter integer OSC_WIDTH = 32,
    parameter integer OSC_WIDTH_FRAC = 30,
    parameter integer PHASE_WIDTH = 32,
    parameter integer SAMPLE_COUNT_WIDTH = 16
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
    output logic signed [ACCUM_WIDTH-1:0] A_real_o[NUM_BINS],
    output logic signed [ACCUM_WIDTH-1:0] A_imag_o[NUM_BINS],
    output logic valid_o,
    output logic busy_o
);

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
    // 1. Oscillator Bank Instantiation
    // =========================================================================
    logic signed [OSC_WIDTH-1:0] W_real_internal[NUM_BINS];
    logic signed [OSC_WIDTH-1:0] W_imag_internal[NUM_BINS];
    logic sincos_tvalid_internal;
    
    oscillator_bank #(
        .NUM_BINS(NUM_BINS),
        .OSC_WIDTH(OSC_WIDTH),
        .PHASE_WIDTH(PHASE_WIDTH)
    ) osc_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .enable_i(osc_enable_i),
        .sync_reset_i(osc_reset_i),
        .phase_tvalid_i(osc_phase_tvalid_i),
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

    // --- Pipeline Stage 1: Window Multiplication ---
    logic signed [IQ_WIDTH+WINDOW_WIDTH-1:0] x_weighted_real_q, x_weighted_real_d;
    logic signed [IQ_WIDTH+WINDOW_WIDTH-1:0] x_weighted_imag_q, x_weighted_imag_d;
    
    logic sample_valid_stage1_q, sample_valid_stage1_d;
    logic last_sample_stage1_q, last_sample_stage1_d;

    // --- Pipeline Stage 2: Complex Multiplication ---
    logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] prod_real_q[NUM_BINS], prod_real_d[NUM_BINS];
    logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] prod_imag_q[NUM_BINS], prod_imag_d[NUM_BINS];
    
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
            sample_valid_stage1_q <= 1'b0;
            last_sample_stage1_q <= 1'b0;
            
            sample_valid_stage2_q <= 1'b0;
            last_sample_stage2_q <= 1'b0;
            
            for (int k = 0; k < NUM_BINS; k++) begin
                prod_real_q[k] <= '0;
                prod_imag_q[k] <= '0;
                A_real_q[k] <= '0;
                A_imag_q[k] <= '0;
            end
        end else begin
            state_q <= state_d;
            sample_count_q <= sample_count_d;
            
            x_weighted_real_q <= x_weighted_real_d;
            x_weighted_imag_q <= x_weighted_imag_d;
            sample_valid_stage1_q <= sample_valid_stage1_d;
            last_sample_stage1_q <= last_sample_stage1_d;
            
            sample_valid_stage2_q <= sample_valid_stage2_d;
            last_sample_stage2_q <= last_sample_stage2_d;
            
            for (int k = 0; k < NUM_BINS; k++) begin
                prod_real_q[k] <= prod_real_d[k];
                prod_imag_q[k] <= prod_imag_d[k];
                A_real_q[k] <= A_real_d[k];
                A_imag_q[k] <= A_imag_d[k];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Combinational Logic: Stage 1 (Windowing)
    // -------------------------------------------------------------------------
     always_comb begin
        // Default
        x_weighted_real_d = x_weighted_real_q;
        x_weighted_imag_d = x_weighted_imag_q;
        sample_valid_stage1_d = sample_valid_stage1_q;
        last_sample_stage1_d = last_sample_stage1_q;
        
        // Compute windowed samples when new sample arrives
        if (sample_valid_i && (state_q == ACCUMULATE)) begin
            // Multiply I and Q with window coefficient
            x_weighted_real_d = $signed(i_sample_i) * $signed(window_coeff_i);
            x_weighted_imag_d = $signed(q_sample_i) * $signed(window_coeff_i);
            
            // Pass control signals through pipeline
            sample_valid_stage1_d = 1'b1;
            last_sample_stage1_d = last_sample_i;
            
        end else begin
            sample_valid_stage1_d = 1'b0;
            last_sample_stage1_d = 1'b0;
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
    // Combinational Logic: Stage 2 (Complex Mult with Oscillator)
    // -------------------------------------------------------------------------
    always_comb begin
        for (int k = 0; k < NUM_BINS; k++) begin
            prod_real_d[k] = prod_real_q[k];
            prod_imag_d[k] = prod_imag_q[k];
        end
        sample_valid_stage2_d = 1'b0;
        last_sample_stage2_d = 1'b0;  // before: last_sample_stage2_q

        if (sample_valid_stage1_q) begin
            for (int k = 0; k < NUM_BINS; k++) begin
                // W values come directly from oscillator bank
                // Top module ensures timing alignment
                logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] xr_wr;
                logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] xi_wi;
                logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] xr_wi;
                logic signed [IQ_WIDTH+WINDOW_WIDTH+OSC_WIDTH-1:0] xi_wr;
                
                xr_wr = x_weighted_real_q * W_real_internal[k];
                xi_wi = x_weighted_imag_q * W_imag_internal[k];
                xr_wi = x_weighted_real_q * W_imag_internal[k];
                xi_wr = x_weighted_imag_q * W_real_internal[k];
                
                prod_real_d[k] = xr_wr - xi_wi;
                prod_imag_d[k] = xr_wi + xi_wr;
            end
            sample_valid_stage2_d = 1'b1;
            last_sample_stage2_d = last_sample_stage1_q;
        end else begin
            sample_valid_stage2_d = 1'b0;
            last_sample_stage2_d = 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Combinational Logic: Accumulation & State
    // -------------------------------------------------------------------------
    always_comb begin
        state_d = state_q;
        sample_count_d = sample_count_q;
        
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
                    for (int k = 0; k < NUM_BINS; k++) begin
                        // Fixed-point scaling
                        localparam int SHIFT_AMOUNT = IQ_WIDTH_FRAC + WINDOW_WIDTH_FRAC + OSC_WIDTH_FRAC - ACCUM_WIDTH_FRAC;
                        
                        if (SHIFT_AMOUNT > 0) begin
                            // Scale down products to fit accumulator
                            A_real_d[k] = A_real_q[k] + (prod_real_q[k] >>> SHIFT_AMOUNT);
                            A_imag_d[k] = A_imag_q[k] + (prod_imag_q[k] >>> SHIFT_AMOUNT);
                        end else begin
                            // No scaling needed
                            A_real_d[k] = A_real_q[k] + prod_real_q[k];
                            A_imag_d[k] = A_imag_q[k] + prod_imag_q[k];
                        end
                    end
                    
                    sample_count_d = sample_count_q + 1;
                    
                    if (last_sample_stage2_q) begin
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