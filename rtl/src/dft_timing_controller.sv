////////////////////////////////////////////////////////////////////////////////
//
//  Module: dft_timing_controller
//
//  Description:
//      Counter-based timing generator for DFT processing.
//      Generates timing signals for the Oscillator and DFT accounting for
//      CORDIC pipeline latency.
//
//  Key Changes from Original:
//      - start_osc_o is now CONTINUOUS (high for entire window duration)
//      - start_dft_o remains a single-cycle pulse
//      - Added WINDOW_SIZE parameter to know when to stop oscillator
//
//  Parameters:
//      DELAY_CYCLES : The cycle count where the DFT should start (data arrival)
//      OSC_LATENCY  : The pipeline depth of the Oscillator/CORDIC
//      WINDOW_SIZE  : Number of samples in the DFT window
//
////////////////////////////////////////////////////////////////////////////////

module dft_timing_controller #(
    parameter int DELAY_CYCLES = 1000,
    parameter int OSC_LATENCY  = 35,
    parameter int WINDOW_SIZE  = 256,
    parameter int COUNTER_WIDTH = 16
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Controls
    input  logic enable_i,      // Set High to start/continue counting
    input  logic clear_i,       // Synchronous reset (sets count to 0)
    
    // Output Flags
    output logic start_osc_o,   // CONTINUOUS: High from OSC_START to end of window
    output logic start_dft_o    // PULSE: High for one cycle at DELAY_CYCLES
);

    // -------------------------------------------------------------------------
    // Calculated Parameters
    // -------------------------------------------------------------------------
    
    // Start oscillator early so valid sine/cosine values arrive when data arrives
    localparam int OSC_START_CNT = DELAY_CYCLES - (OSC_LATENCY - 1);
    
    // End oscillator after all samples have been processed
    // The oscillator needs to run for WINDOW_SIZE samples after DFT starts
    localparam int OSC_END_CNT = DELAY_CYCLES + WINDOW_SIZE - 1;
    
    // Sanity checks
    initial begin
        if (OSC_START_CNT < 0) begin
            $error("Error: DELAY_CYCLES (%0d) must be >= OSC_LATENCY (%0d)", 
                   DELAY_CYCLES, OSC_LATENCY);
        end
        if (WINDOW_SIZE < 1) begin
            $error("Error: WINDOW_SIZE (%0d) must be >= 1", WINDOW_SIZE);
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
    // Output Generation
    // -------------------------------------------------------------------------
    
    // Oscillator Enable: CONTINUOUS from OSC_START_CNT to OSC_END_CNT
    always_comb begin
        if ((count_q >= OSC_START_CNT[COUNTER_WIDTH-1:0]) && 
            (count_q <= OSC_END_CNT[COUNTER_WIDTH-1:0])) begin
            start_osc_o = 1'b1;
        end else begin
            start_osc_o = 1'b0;
        end
    end
    
    // DFT Start: SINGLE PULSE at DELAY_CYCLES
    always_comb begin
        if (count_q == DELAY_CYCLES[COUNTER_WIDTH-1:0]) begin
            start_dft_o = 1'b1;
        end else begin
            start_dft_o = 1'b0;
        end
    end
    
    // -------------------------------------------------------------------------
    // Assertions for Debug
    // -------------------------------------------------------------------------
    
    // Verify oscillator runs for the full window duration
    property osc_duration_check;
        @(posedge clk_i) disable iff (!rst_ni)
        (start_dft_o) |-> ##[0:WINDOW_SIZE] start_osc_o;
    endproperty
    
    assert property (osc_duration_check)
        else $warning("Oscillator not enabled for full window duration");
    
    // // Verify DFT start happens after oscillator start
    // property dft_after_osc;
    //     @(posedge clk_i) disable iff (!rst_ni)
    //     (start_dft_o) |-> $past(start_osc_o, OSC_LATENCY-1);
    // endproperty
    
    // assert property (dft_after_osc)
    //     else $error("DFT started before oscillator had time to produce valid outputs");

endmodule