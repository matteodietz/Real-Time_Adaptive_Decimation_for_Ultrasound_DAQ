// X = delay until relevant window - osc latency
// Y = 36
// Z = 256 window length
module counter_controller #(
    parameter int unsigned COUNTER_WIDTH_X = 16,
    parameter int unsigned COUNTER_WIDTH_Y = 16,
    parameter int unsigned COUNTER_WIDTH_Z = 16
) (
    input  logic                      clk_i,
    input  logic                      rst_ni,
    input  logic [COUNTER_WIDTH_X-1:0]  X,
    input  logic [COUNTER_WIDTH_Y-1:0]  Y,
    input  logic [COUNTER_WIDTH_Z-1:0]  Z,
    input  logic                      clear_i,
    input  logic                      enable_i,
    
    output logic                      osc_reset,
    output logic                      osc_enable,
    output logic                      osc_phase_tvalid,
    output logic                      start,
    output logic                      sample_valid,
    output logic                      last_sample
);

    // Counter registers
    logic [COUNTER_WIDTH_X-1:0] count_d, count_q;

    // Combinational logic
    always_comb begin
        // Default: keep current count
        count_d = count_q;
        
        // Default outputs
        osc_reset = 1'b0;
        osc_enable = 1'b0;
        osc_phase_tvalid = 1'b0;
        start = 1'b0;
        sample_valid = 1'b0;
        last_sample = 1'b0;

        if (clear_i) begin
            count_d = '0;
        end else if (enable_i) begin
            if (count_q < X) begin
                // Still counting to X
                count_d = count_q + 1'b1;
            end else if (count_q == X) begin
                // Phase 0: Set osc_reset high
                osc_reset = 1'b1;
                count_d = count_q + 1'b1;
            end else if (count_q == X + 1) begin
                // Phase 1: Set osc_reset low
                osc_reset = 1'b0;
                count_d = count_q + 1'b1;
            end else if (count_q == X + 2) begin
                // Phase 2: Start oscillator
                osc_enable = 1'b1;
                osc_phase_tvalid = 1'b1;
                count_d = count_q + 1'b1;
            end else if (count_q < X + Y - 1) begin
                // Phase 3: Wait for CORDIC (maintain signals, count on posedge)
                osc_enable = 1'b1;
                osc_phase_tvalid = 1'b1;
                count_d = count_q + 1'b1;
            end else if (count_q == X + Y - 1) begin
                // Phase 4: Start DFT high
                osc_enable = 1'b1;
                osc_phase_tvalid = 1'b1;
                start = 1'b1;
                count_d = count_q + 1'b1;
            end else if (count_q == X + Y) begin
                // Phase 5: Start DFT low
                osc_enable = 1'b1;
                osc_phase_tvalid = 1'b1;
                start = 1'b0;
                count_d = count_q + 1'b1;
            end else if (count_q == X + Y + 1) begin
                // Phase 5: Start DFT low
                osc_enable = 1'b1;
                osc_phase_tvalid = 1'b1;
                sample_valid = 1'b1;
                count_d = count_q + 1'b1;
            end else if (count_q < X + Y + Z - 1) begin
                // Phase 6: Wait Y cycles (maintain signals)
                osc_enable = 1'b1;
                osc_phase_tvalid = 1'b1;
                count_d = count_q + 1'b1;
                sample_valid = 1'b1;
            end else if (count_q == X + Y + Z - 1) begin
                // Phase 6: Wait Y cycles (maintain signals)
                osc_enable = 1'b1;
                osc_phase_tvalid = 1'b1;
                count_d = count_q + 1'b1;
                sample_valid = 1'b1;
            end else if (count_q == X + Y + Z) begin
                // Phase 6: Wait Y cycles (maintain signals)
                osc_enable = 1'b1;
                osc_phase_tvalid = 1'b1;
                count_d = count_q + 1'b1;
                sample_valid = 1'b1;
                last_sample = 1'b1;
            end else if (count_q == X + Y + Z + 1) begin
                // Phase 7: Stop everything
                sample_valid = 1'b0;
                last_sample = 1'b0;
                osc_enable = 1'b0;
                osc_phase_tvalid = 1'b0;
                count_d = count_q + 1'b1;
            end else begin
                // Done - keep everything low
                sample_valid = 1'b0;
                last_sample = 1'b0;
                osc_enable = 1'b0;
                osc_phase_tvalid = 1'b0;
            end
        end
    end

    // Sequential logic - update on negedge
    always_ff @(negedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            count_q <= '0;
        end else begin
            count_q <= count_d;
        end
    end

endmodule