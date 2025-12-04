////////////////////////////////////////////////////////////////////////////////
//
//  Module: calc_abs_threshold
//
//  Function: Calculates the absolute cutoff threshold based on peak power.
//            Synchronous Design (One Cycle Latency).
//
//  Logic:    If (Max_Power < Drop) -> Threshold = 0 (Signal too weak)
//            Else                  -> Threshold = Max_Power - Drop
//
//  Latency:  1 clock cycle from max_power_valid_i assertion to valid_o assertion
//
////////////////////////////////////////////////////////////////////////////////

module calc_abs_threshold #(
    parameter int POWER_WIDTH = 32,
    // Default: 30dB in Q16.16 format (0x001E_0000)
    parameter logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 32'h001E_0000
)(
    // Clock and Reset
    input  logic                   clk_i,
    input  logic                   rst_ni,  // Active-low reset
    
    // Data Inputs
    input  logic [POWER_WIDTH-1:0] max_power_i,
    input  logic                   max_power_valid_i,

    // Outputs
    output logic [POWER_WIDTH-1:0] abs_threshold_o,
    
    // Handshake: Indicates a calculation was performed and output is ready
    output logic                   valid_o,       
    
    // Status: Indicates if the resulting threshold is valid (non-clamped)
    // 1 = Signal was strong enough (Threshold > 0)
    // 0 = Signal was too weak (Threshold clamped to 0)
    output logic                   threshold_ok_o 
);

    // Internal registers
    logic [POWER_WIDTH-1:0] abs_threshold_d, abs_threshold_q;
    logic                   threshold_ok_d, threshold_ok_q;
    logic                   valid_d, valid_q;

    // Combinational logic: Calculate next values
    always_comb begin
        // Default: Hold current values
        abs_threshold_d = abs_threshold_q;
        threshold_ok_d  = threshold_ok_q;
        valid_d         = 1'b0;  // Valid is pulsed for one cycle

        // Perform calculation when input is valid
        if (max_power_valid_i) begin
            if (max_power_i < THRESHOLD_DROP) begin
                // Case: Signal is buried in noise (Max < 30dB)
                // Clamp the threshold to 0
                abs_threshold_d = '0;
                threshold_ok_d  = 1'b0; 
            end else begin
                // Case: Strong signal
                // Calculate absolute level: Peak - 30dB
                abs_threshold_d = max_power_i - THRESHOLD_DROP;
                threshold_ok_d  = 1'b1; 
            end
            valid_d = 1'b1;  // Assert valid on next cycle
        end
    end

    // Sequential logic: Register outputs
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            abs_threshold_q <= '0;
            threshold_ok_q  <= 1'b0;
            valid_q         <= 1'b0;
        end else begin
            abs_threshold_q <= abs_threshold_d;
            threshold_ok_q  <= threshold_ok_d;
            valid_q         <= valid_d;
        end
    end

    // Output assignments
    assign abs_threshold_o = abs_threshold_q;
    assign threshold_ok_o  = threshold_ok_q;
    assign valid_o         = valid_q;

endmodule