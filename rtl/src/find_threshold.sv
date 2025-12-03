////////////////////////////////////////////////////////////////////////////////
//
//  Module: calc_abs_threshold
//
//  Function: Calculates the absolute cutoff threshold based on peak power.
//            Combinational Logic Only (Zero Cycle Latency).
//
//  Logic:    If (Max_Power < Drop) -> Threshold = 0 (Signal too weak)
//            Else                  -> Threshold = Max_Power - Drop
//
////////////////////////////////////////////////////////////////////////////////

module calc_abs_threshold #(
    parameter int POWER_WIDTH = 32,
    // Default: 30dB in Q16.16 format (0x001E_0000)
    parameter logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 32'h001E_0000
)(
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

    always_comb begin
        // 1. Default Assignments (Prevents latches)
        abs_threshold_o = '0;
        threshold_ok_o  = 1'b0;
        valid_o         = max_power_valid_i; // Output is valid immediately if input is valid

        // 2. Calculation Logic
        if (max_power_valid_i) begin
            if (max_power_i < THRESHOLD_DROP) begin
                // Case: Signal is buried in noise (Max < 30dB)
                // We clamp the threshold to 0.
                abs_threshold_o = '0;
                threshold_ok_o  = 1'b0; 
            end else begin
                // Case: Strong signal
                // Calculate absolute level: Peak - 30dB
                abs_threshold_o = max_power_i - THRESHOLD_DROP;
                threshold_ok_o  = 1'b1; 
            end
        end
    end

endmodule