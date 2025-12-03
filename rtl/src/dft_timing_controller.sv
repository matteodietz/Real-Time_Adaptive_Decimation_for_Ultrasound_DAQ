////////////////////////////////////////////////////////////////////////////////
//
//  Module: dft_timing_controller
//
//  Description:
//      A simple counter-based timing generator.
//      Generates start pulses for the Oscillator (early) and the DFT (on time)
//      to account for the CORDIC pipeline latency.
//
//  Parameters:
//      DELAY_CYCLES : The cycle count where the DFT should actually start (Data arrival).
//      OSC_LATENCY  : The pipeline depth of the Oscillator/CORDIC.
//
////////////////////////////////////////////////////////////////////////////////

module dft_timing_controller #(
    parameter int DELAY_CYCLES = 1000,
    parameter int OSC_LATENCY  = 35,
    parameter int COUNTER_WIDTH = 16
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Controls
    input  logic enable_i,      // Set High to start/continue counting
    input  logic clear_i,       // Synchronous reset (sets count to 0)
    
    // Output Flags
    output logic start_osc_o,   // High when count == DELAY - (OSC_LATENCY - 1)
    output logic start_dft_o    // High when count == DELAY_CYCLES
);

    // -------------------------------------------------------------------------
    // Calculated Parameters
    // -------------------------------------------------------------------------
    // We need to start the oscillator early so the valid sine/cosine arrives
    // exactly when the data arrives at DELAY_CYCLES.
    // Time = Delay - (Latency - 1) because the multiply happens in the cycle 
    // *after* the data/osc values arrive at the inputs.
    localparam int OSC_START_CNT = DELAY_CYCLES - (OSC_LATENCY - 1);
    
    // Sanity check to ensure Delay is large enough
    initial begin
        if (OSC_START_CNT < 0) begin
            $error("Error: DELAY_CYCLES (%0d) must be greater than OSC_LATENCY (%0d)", 
                   DELAY_CYCLES, OSC_LATENCY);
        end
    end

    // -------------------------------------------------------------------------
    // Counter Logic
    // -------------------------------------------------------------------------
    logic [COUNTER_WIDTH-1:0] count_q, count_d;

    // Combinational Next-State Logic
    always_comb begin
        // Default: hold current value
        count_d = count_q;

        if (clear_i) begin
            count_d = '0;
        end else if (enable_i) begin
            count_d = count_q + 1;
        end
    end

    // Sequential State Update
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            count_q <= '0;
        end else begin
            count_q <= count_d;
        end
    end

    // -------------------------------------------------------------------------
    // Output Comparators
    // -------------------------------------------------------------------------
    // These generate a 1-cycle high pulse when the count matches the target.
    
    always_comb begin
        // Trigger Oscillator Pre-charge
        if (count_q == OSC_START_CNT[COUNTER_WIDTH-1:0]) begin
            start_osc_o = 1'b1;
        end else begin
            start_osc_o = 1'b0;
        end

        // Trigger DFT Accumulation (Data Arrival)
        if (count_q == DELAY_CYCLES[COUNTER_WIDTH-1:0]) begin
            start_dft_o = 1'b1;
        end else begin
            start_dft_o = 1'b0;
        end
    end

endmodule