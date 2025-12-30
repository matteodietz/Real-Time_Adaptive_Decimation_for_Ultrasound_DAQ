// X = Delay until relevant window - osc latency = initial_delay
// Y = Oscillator latency = 20 = osc_delay
// Z = Window length * CYCLES_PER_SAMPLE = 256 * N = window_delay

module counter_controller #(
    parameter int unsigned COUNTER_WIDTH = 16,
    parameter int unsigned N = 12  // Time-multiplexing factor
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    input  logic [COUNTER_WIDTH-1:0]     initial_delay,
    input  logic [COUNTER_WIDTH-1:0]     osc_delay,
    input  logic [COUNTER_WIDTH-1:0]     window_delay,
    input  logic                         clear_i,
    input  logic                         enable_i,
    
    output logic                         osc_reset,
    output logic                         osc_enable,
    output logic                         osc_phase_tvalid,
    output logic                         start,
    output logic                         sample_valid,
    output logic                         last_sample
);

    // Counter registers
    logic [COUNTER_WIDTH-1:0] count_d, count_q;
    
    // Control signal registers
    logic osc_reset_d, osc_reset_q;
    logic osc_enable_d, osc_enable_q;
    logic osc_phase_tvalid_d, osc_phase_tvalid_q;
    logic start_d, start_q;
    logic sample_valid_d, sample_valid_q;
    logic last_sample_d, last_sample_q;

    // =========================================================================
    // Combinational Logic - Set _d signals based on count_q
    // =========================================================================
    always_comb begin
        // Default: maintain current values
        count_d = count_q;
        osc_reset_d = osc_reset_q;
        osc_enable_d = osc_enable_q;
        osc_phase_tvalid_d = osc_phase_tvalid_q;
        start_d = start_q;
        sample_valid_d = sample_valid_q;
        last_sample_d = last_sample_q;

        if (clear_i) begin
            // Clear counter and all control signals
            count_d = '0;
            osc_reset_d = 1'b0;
            osc_enable_d = 1'b0;
            osc_phase_tvalid_d = 1'b0;
            start_d = 1'b0;
            sample_valid_d = 1'b0;
            last_sample_d = 1'b0;
        end else if (enable_i) begin
            // Increment counter
            count_d = count_q + 1'b1;
            
            // Set control signals based on next count value (count_d)
            // We want specific values at specific count_q values
            // So we set _d signals one cycle early
            
            if (count_q == initial_delay - 1) begin
                // Next cycle (count_q = X): osc_reset_q should be 1
                osc_reset_d = 1'b1;
            end
            
            if (count_q == initial_delay) begin
                // Next cycle (count_q = X+1): osc_reset_q should be 0
                osc_reset_d = 1'b0;
            end
            
            if (count_q == initial_delay + 1) begin
                // Next cycle (count_q = X+2): osc_enable_q and osc_phase_tvalid_q should be 1
                osc_enable_d = 1'b1;
                osc_phase_tvalid_d = 1'b1;
            end
            
            if (count_q == initial_delay + osc_delay - 2) begin
                // Next cycle (count_q = X+Y-1): start_q should be 1
                start_d = 1'b1;
            end
            
            if (count_q == initial_delay + osc_delay - 1) begin
                // Next cycle (count_q = X+Y): start_q should be 0
                start_d = 1'b0;
            end
            
            if (count_q == initial_delay + osc_delay) begin
                // Next cycle (count_q = X+Y+1): sample_valid_q should be 1
                sample_valid_d = 1'b1;
            end
            
            if (count_q == initial_delay + osc_delay + window_delay - N) begin
                // Next cycle (count_q = X+Y+Z-(N-1)): last_sample_q should be 1
                last_sample_d = 1'b1;
            end
            
            if (count_q == initial_delay + osc_delay + window_delay) begin
                // Next cycle (count_q = X+Y+Z+1): all signals go to 0
                sample_valid_d = 1'b0;
                last_sample_d = 1'b0;
                osc_enable_d = 1'b0;
                osc_phase_tvalid_d = 1'b0;
            end
        end
    end

    // =========================================================================
    // Sequential Logic - Update on posedge clk
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            count_q <= '0;
            osc_reset_q <= 1'b0;
            osc_enable_q <= 1'b0;
            osc_phase_tvalid_q <= 1'b0;
            start_q <= 1'b0;
            sample_valid_q <= 1'b0;
            last_sample_q <= 1'b0;
        end else begin
            count_q <= count_d;
            osc_reset_q <= osc_reset_d;
            osc_enable_q <= osc_enable_d;
            osc_phase_tvalid_q <= osc_phase_tvalid_d;
            start_q <= start_d;
            sample_valid_q <= sample_valid_d;
            last_sample_q <= last_sample_d;
        end
    end

    // =========================================================================
    // Output Assignments
    // =========================================================================
    assign osc_reset = osc_reset_q;
    assign osc_enable = osc_enable_q;
    assign osc_phase_tvalid = osc_phase_tvalid_q;
    assign start = start_q;
    assign sample_valid = sample_valid_q;
    assign last_sample = last_sample_q;

endmodule