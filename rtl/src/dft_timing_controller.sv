// ////////////////////////////////////////////////////////////////////////////////
// //
// //  Module: dft_timing_controller
// //
// //  Description:
// //      Counter-based timing generator for DFT processing.
// //      Generates timing signals for the Oscillator and DFT accounting for
// //      CORDIC pipeline latency.
// //
// //  Key Changes from Original:
// //      - start_osc_o is now CONTINUOUS (high for entire window duration)
// //      - start_dft_o remains a single-cycle pulse
// //      - Added WINDOW_SIZE parameter to know when to stop oscillator
// //
// //  Parameters:
// //      DELAY_CYCLES : The cycle count where the DFT should start (data arrival)
// //      OSC_LATENCY  : The pipeline depth of the Oscillator/CORDIC
// //      WINDOW_SIZE  : Number of samples in the DFT window
// //
// ////////////////////////////////////////////////////////////////////////////////

// module dft_timing_controller #(
//     parameter int DELAY_CYCLES = 1000,
//     parameter int OSC_LATENCY  = 35,
//     parameter int WINDOW_SIZE  = 256,
//     parameter int COUNTER_WIDTH = 16
// )(
//     input  logic clk_i,
//     input  logic rst_ni,
    
//     // Controls
//     input  logic enable_i,      // Set High to start/continue counting
//     input  logic clear_i,       // Synchronous reset (sets count to 0)
    
//     // Output Flags
//     output logic start_osc_o,   // CONTINUOUS: High from OSC_START to end of window
//     output logic start_dft_o    // PULSE: High for one cycle at DELAY_CYCLES
// );

//     // -------------------------------------------------------------------------
//     // Calculated Parameters
//     // -------------------------------------------------------------------------
    
//     // Start oscillator early so valid sine/cosine values arrive when data arrives
//     localparam int OSC_START_CNT = DELAY_CYCLES - (OSC_LATENCY);  // removed -1 in the brackets
    
//     // End oscillator after all samples have been processed
//     // The oscillator needs to run for WINDOW_SIZE samples after DFT starts
//     localparam int OSC_END_CNT = DELAY_CYCLES + WINDOW_SIZE - 1;
    
//     // Sanity checks
//     initial begin
//         if (OSC_START_CNT < 0) begin
//             $error("Error: DELAY_CYCLES (%0d) must be >= OSC_LATENCY (%0d)", 
//                    DELAY_CYCLES, OSC_LATENCY);
//         end
//         if (WINDOW_SIZE < 1) begin
//             $error("Error: WINDOW_SIZE (%0d) must be >= 1", WINDOW_SIZE);
//         end
//     end
    
//     // -------------------------------------------------------------------------
//     // Counter Logic
//     // -------------------------------------------------------------------------
    
//     logic [COUNTER_WIDTH-1:0] count_q, count_d;
    
//     // Combinational Next-State Logic
//     always_comb begin
//         // Default: hold current value
//         count_d = count_q;
        
//         if (clear_i) begin
//             count_d = '0;
//         end else if (enable_i) begin
//             count_d = count_q + 1;
//         end
//     end
    
//     // Sequential State Update
//     always_ff @(posedge clk_i) begin
//         if (!rst_ni) begin
//             count_q <= '0;
//         end else begin
//             count_q <= count_d;
//         end
//     end
    
//     // -------------------------------------------------------------------------
//     // Output Generation
//     // -------------------------------------------------------------------------
    
//     // Oscillator Enable: CONTINUOUS from OSC_START_CNT to OSC_END_CNT
//     always_comb begin
//         if ((count_q >= OSC_START_CNT[COUNTER_WIDTH-1:0]) && 
//             (count_q <= OSC_END_CNT[COUNTER_WIDTH-1:0])) begin
//             start_osc_o = 1'b1;
//         end else begin
//             start_osc_o = 1'b0;
//         end
//     end
    
//     // DFT Start: SINGLE PULSE at DELAY_CYCLES
//     always_comb begin
//         if (count_q == DELAY_CYCLES[COUNTER_WIDTH-1:0]) begin
//             start_dft_o = 1'b1;
//         end else begin
//             start_dft_o = 1'b0;
//         end
//     end
    
//     // -------------------------------------------------------------------------
//     // Assertions for Debug
//     // -------------------------------------------------------------------------
    
//     // Verify oscillator runs for the full window duration
//     property osc_duration_check;
//         @(posedge clk_i) disable iff (!rst_ni)
//         (start_dft_o) |-> ##[0:WINDOW_SIZE] start_osc_o;
//     endproperty
    
//     assert property (osc_duration_check)
//         else $warning("Oscillator not enabled for full window duration");

// endmodule

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
//      - Added last_sample_o output to indicate last sample of window
//
//  Parameters:
//      DELAY_CYCLES : The cycle count where the DFT should start (data arrival)
//      OSC_LATENCY  : The pipeline depth of the Oscillator/CORDIC
//      WINDOW_SIZE  : Number of samples in the DFT window
//
////////////////////////////////////////////////////////////////////////////////

// module dft_timing_controller #(
//     parameter int DELAY_CYCLES = 1000,
//     parameter int OSC_LATENCY  = 35,
//     parameter int WINDOW_SIZE  = 256,
//     parameter int COUNTER_WIDTH = 16
// )(
//     input  logic clk_i,
//     input  logic rst_ni,
    
//     // Controls
//     input  logic enable_i,      // Set High to start/continue counting
//     input  logic clear_i,       // Synchronous reset (sets count to 0)
    
//     // Output Flags
//     output logic start_osc_o,   // CONTINUOUS: High from OSC_START to end of window
//     output logic start_dft_o,   // PULSE: High for one cycle at DELAY_CYCLES
//     output logic last_sample_o  // PULSE: High for one cycle at DELAY_CYCLES + WINDOW_SIZE - 1
// );

//     // -------------------------------------------------------------------------
//     // Calculated Parameters
//     // -------------------------------------------------------------------------
    
//     // Start oscillator early so valid sine/cosine values arrive when data arrives
//     localparam int OSC_START_CNT = DELAY_CYCLES - (OSC_LATENCY - 3);  // -3 because start signals and first sample introduce delays in dft module
//     // End oscillator after all samples have been processed
//     // The oscillator needs to run for WINDOW_SIZE samples after DFT starts
//     localparam int OSC_END_CNT = DELAY_CYCLES + WINDOW_SIZE - 1;
    
//     // Last sample position (same as OSC_END_CNT)
//     localparam int LAST_SAMPLE_CNT = DELAY_CYCLES + WINDOW_SIZE - 1;
    
//     // Sanity checks
//     initial begin
//         if (OSC_START_CNT < 0) begin
//             $error("Error: DELAY_CYCLES (%0d) must be >= OSC_LATENCY (%0d)", 
//                    DELAY_CYCLES, OSC_LATENCY);
//         end
//         if (WINDOW_SIZE < 1) begin
//             $error("Error: WINDOW_SIZE (%0d) must be >= 1", WINDOW_SIZE);
//         end
//     end
    
//     // -------------------------------------------------------------------------
//     // Counter Logic
//     // -------------------------------------------------------------------------
    
//     logic [COUNTER_WIDTH-1:0] count_q, count_d;
    
//     // Combinational Next-State Logic
//     always_comb begin
//         // Default: hold current value
//         count_d = count_q;
        
//         if (clear_i) begin
//             count_d = '0;
//         end else if (enable_i) begin
//             count_d = count_q + 1;
//         end
//     end
    
//     // Sequential State Update
//     always_ff @(posedge clk_i) begin
//         if (!rst_ni) begin
//             count_q <= '0;
//         end else begin
//             count_q <= count_d;
//         end
//     end
    
//     // -------------------------------------------------------------------------
//     // Output Generation
//     // -------------------------------------------------------------------------
    
//     // Oscillator Enable: CONTINUOUS from OSC_START_CNT to OSC_END_CNT
//     always_comb begin
//         if ((count_q >= OSC_START_CNT[COUNTER_WIDTH-1:0]) && 
//             (count_q <= OSC_END_CNT[COUNTER_WIDTH-1:0])) begin
//             start_osc_o = 1'b1;
//         end else begin
//             start_osc_o = 1'b0;
//         end
//     end
    
//     // DFT Start: SINGLE PULSE at DELAY_CYCLES
//     always_comb begin
//         if (count_q == DELAY_CYCLES[COUNTER_WIDTH-1:0]) begin
//             start_dft_o = 1'b1;
//         end else begin
//             start_dft_o = 1'b0;
//         end
//     end
    
//     // Last Sample: SINGLE PULSE at DELAY_CYCLES + WINDOW_SIZE - 1
//     always_comb begin
//         if (count_q == LAST_SAMPLE_CNT[COUNTER_WIDTH-1:0]) begin
//             last_sample_o = 1'b1;
//         end else begin
//             last_sample_o = 1'b0;
//         end
//     end
    
//     // -------------------------------------------------------------------------
//     // Assertions for Debug
//     // -------------------------------------------------------------------------
    
//     // Verify oscillator runs for the full window duration
//     property osc_duration_check;
//         @(posedge clk_i) disable iff (!rst_ni)
//         (start_dft_o) |-> ##[0:WINDOW_SIZE] start_osc_o;
//     endproperty
    
//     assert property (osc_duration_check)
//         else $warning("Oscillator not enabled for full window duration");
    
//     // Verify last_sample_o occurs exactly WINDOW_SIZE-1 cycles after start_dft_o
//     property last_sample_timing_check;
//         @(posedge clk_i) disable iff (!rst_ni)
//         (start_dft_o) |-> ##(WINDOW_SIZE-1) last_sample_o;
//     endproperty
    
//     assert property (last_sample_timing_check)
//         else $error("last_sample_o did not occur at correct time relative to start_dft_o");

// endmodule

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
//      - Added last_sample_o output to indicate last sample of window
//      - DELAY_CYCLES is now an INPUT instead of parameter for per-test flexibility
//
//  Parameters:
//      OSC_LATENCY  : The pipeline depth of the Oscillator/CORDIC
//      WINDOW_SIZE  : Number of samples in the DFT window
//
//  Inputs:
//      delay_cycles_i : The cycle count where the DFT should start (data arrival)
//
////////////////////////////////////////////////////////////////////////////////

module dft_timing_controller #(
    parameter int OSC_LATENCY  = 35,
    parameter int WINDOW_SIZE  = 256,
    parameter int COUNTER_WIDTH = 16
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Controls
    input  logic enable_i,                      // Set High to start/continue counting
    input  logic clear_i,                       // Synchronous reset (sets count to 0)
    input  logic [COUNTER_WIDTH-1:0] delay_cycles_i,  // Variable delay cycles per test
    
    // Output Flags
    output logic start_osc_o,   // CONTINUOUS: High from OSC_START to end of window
    output logic start_dft_o,   // PULSE: High for one cycle at delay_cycles_i
    output logic last_sample_o  // PULSE: High for one cycle at delay_cycles_i + WINDOW_SIZE - 1
);

    // -------------------------------------------------------------------------
    // Internal Signals
    // -------------------------------------------------------------------------
    
    logic [COUNTER_WIDTH-1:0] osc_start_cnt;
    logic [COUNTER_WIDTH-1:0] osc_end_cnt;
    logic [COUNTER_WIDTH-1:0] last_sample_cnt;
    
    // -------------------------------------------------------------------------
    // Calculated Values (Combinational)
    // -------------------------------------------------------------------------
    
    // Start oscillator early so valid sine/cosine values arrive when data arrives
    // -3 because start signals and first sample introduce delays in dft module
    always_comb begin
        osc_start_cnt = delay_cycles_i - (OSC_LATENCY); // TODO: something wrong here.
    end
    
    // End oscillator after all samples have been processed
    // The oscillator needs to run for WINDOW_SIZE samples after DFT starts
    always_comb begin
        osc_end_cnt = delay_cycles_i + WINDOW_SIZE - 1;
    end
    
    // Last sample position (same as osc_end_cnt)
    always_comb begin
        last_sample_cnt = delay_cycles_i + WINDOW_SIZE - 1;
    end
    
    // -------------------------------------------------------------------------
    // Sanity checks
    // -------------------------------------------------------------------------
    
    // Runtime check that delay_cycles is large enough
    always_ff @(posedge clk_i) begin
        if (rst_ni && enable_i) begin
            if (delay_cycles_i < (OSC_LATENCY - 3)) begin
                $error("Error: delay_cycles_i (%0d) must be >= (OSC_LATENCY - 3) (%0d)", 
                       delay_cycles_i, OSC_LATENCY - 3);
            end
        end
    end
    
    initial begin
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
    
    // Oscillator Enable: CONTINUOUS from osc_start_cnt to osc_end_cnt
    always_comb begin
        if ((count_q >= osc_start_cnt) && (count_q <= osc_end_cnt)) begin
            start_osc_o = 1'b1;
        end else begin
            start_osc_o = 1'b0;
        end
    end
    
    // DFT Start: SINGLE PULSE at delay_cycles_i
    always_comb begin
        if (count_q == delay_cycles_i) begin
            start_dft_o = 1'b1;
        end else begin
            start_dft_o = 1'b0;
        end
    end
    
    // Last Sample: SINGLE PULSE at last_sample_cnt
    always_comb begin
        if (count_q == last_sample_cnt) begin
            last_sample_o = 1'b1;
        end else begin
            last_sample_o = 1'b0;
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
    
    // Verify last_sample_o occurs exactly WINDOW_SIZE-1 cycles after start_dft_o
    property last_sample_timing_check;
        @(posedge clk_i) disable iff (!rst_ni)
        (start_dft_o) |-> ##(WINDOW_SIZE-1) last_sample_o;
    endproperty
    
    assert property (last_sample_timing_check)
        else $error("last_sample_o did not occur at correct time relative to start_dft_o");

endmodule