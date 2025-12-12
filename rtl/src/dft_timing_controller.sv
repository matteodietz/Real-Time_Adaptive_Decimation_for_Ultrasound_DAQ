// module dft_timing_controller #(
//     parameter int OSC_LATENCY  = 35,
//     parameter int WINDOW_SIZE  = 256,
//     parameter int COUNTER_WIDTH = 16
// )(
//     input  logic clk_i,
//     input  logic rst_ni,
    
//     // Controls
//     input  logic enable_i,                      // Set High to start/continue counting
//     input  logic clear_i,                       // Synchronous reset (sets count to 0)
//     input  logic [COUNTER_WIDTH-1:0] delay_cycles_i,  // Variable delay cycles per test
    
//     // Output Flags
//     output logic start_osc_o,       // CONTINUOUS: High from OSC_START to end of window
//     output logic start_dft_o,       // PULSE: High for one cycle at delay_cycles_i
//     output logic last_sample_o,     // PULSE: High for one cycle at delay_cycles_i + WINDOW_SIZE - 1
//     output logic osc_reset_o,       // PULSE: High for one cycle BEFORE oscillator starts
//     output logic dft_sample_valid_o // CONTINUOUS: High during DFT accumulation window
// );

//     // -------------------------------------------------------------------------
//     // Internal Signals
//     // -------------------------------------------------------------------------
    
//     logic [COUNTER_WIDTH-1:0] osc_start_cnt = 'b0;
//     logic [COUNTER_WIDTH-1:0] osc_end_cnt = 'b0;
//     logic [COUNTER_WIDTH-1:0] last_sample_cnt = 'b0;
//     logic [COUNTER_WIDTH-1:0] osc_reset_cnt = 'b0;
//     logic [COUNTER_WIDTH-1:0] dft_start_cnt = 'b0;
//     logic [COUNTER_WIDTH-1:0] dft_first_valid_sample_cnt = 'b0;
//     logic [COUNTER_WIDTH-1:0] dft_end_cnt = 'b0;
    
//     // -------------------------------------------------------------------------
//     // Calculated Values (Combinational)
//     // -------------------------------------------------------------------------
//     // NOTE: All counts are adjusted -1 because outputs are registered (1 cycle delay)
    
//     // Reset oscillator one cycle before it starts (adjusted for output register)
//     always_comb begin
//         osc_reset_cnt = delay_cycles_i - (OSC_LATENCY) - 1;
//     end
    
//     // Start oscillator early so valid sine/cosine values arrive when data arrives
//     // -3 because start signals and first sample introduce delays in dft module
//     // Additional -1 because output is registered
//     always_comb begin
//         osc_start_cnt = delay_cycles_i - (OSC_LATENCY - 1);
//     end
    
//     // End oscillator after all samples have been processed
//     // The oscillator needs to run for WINDOW_SIZE samples after DFT starts
//     // -1 because output is registered
//     always_comb begin
//         osc_end_cnt = delay_cycles_i + WINDOW_SIZE - 1;
//     end
    
//     // Last sample position (same as osc_end_cnt)
//     always_comb begin
//         last_sample_cnt = delay_cycles_i + WINDOW_SIZE - 1;
//     end
    
//     // DFT sample valid window: starts 2 cycles after start_dft_o pulse
//     // (due to internal pipeline delays in dft_accumulation_cordic)
//     // -1 because output is registered
//     always_comb begin
//         dft_start_cnt = delay_cycles_i -1;
//         dft_first_valid_sample_cnt = delay_cycles_i;
//     end
    
//     // DFT accumulation ends after WINDOW_SIZE samples
//     // -1 because output is registered
//     always_comb begin
//         dft_end_cnt = delay_cycles_i + WINDOW_SIZE - 1;
//     end
    
//     // -------------------------------------------------------------------------
//     // Sanity checks
//     // -------------------------------------------------------------------------
    
//     // Runtime check that delay_cycles is large enough
//     always_ff @(posedge clk_i) begin
//         if (rst_ni && enable_i) begin
//             if (delay_cycles_i < (OSC_LATENCY - 3)) begin
//                 $error("Error: delay_cycles_i (%0d) must be >= (OSC_LATENCY - 3) (%0d)", 
//                        delay_cycles_i, OSC_LATENCY - 3);
//             end
//         end
//     end
    
//     initial begin
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
//     // Output Generation (REGISTERED to avoid race conditions)
//     // -------------------------------------------------------------------------
    
//     // All outputs are registered so they arrive one cycle after counter reaches target
//     // This avoids race conditions with modules sampling at the same clock edge
    
//     always_ff @(posedge clk_i) begin
//         if (!rst_ni) begin
//             start_osc_o <= 1'b0;
//             start_dft_o <= 1'b0;
//             last_sample_o <= 1'b0;
//             osc_reset_o <= 1'b0;
//             dft_sample_valid_o <= 1'b0;
//         end else if (enable_i) begin
//             // Oscillator Enable: CONTINUOUS from osc_start_cnt to osc_end_cnt
//             start_osc_o <= ((count_q >= osc_start_cnt) && (count_q <= osc_end_cnt));
            
//             // DFT Start: SINGLE PULSE at delay_cycles_i
//             start_dft_o <= (count_q == dft_start_cnt);
            
//             // Last Sample: SINGLE PULSE at last_sample_cnt
//             last_sample_o <= (count_q == last_sample_cnt);
            
//             // Oscillator Reset: SINGLE PULSE one cycle before oscillator starts
//             osc_reset_o <= (count_q == osc_reset_cnt);
            
//             // DFT Sample Valid: CONTINUOUS during DFT accumulation window
//             dft_sample_valid_o <= ((count_q >= dft_first_valid_sample_cnt) && (count_q <= dft_end_cnt));
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
    output logic start_osc_o,       // CONTINUOUS: High from OSC_START to end of window
    output logic start_dft_o,       // PULSE: High for one cycle at delay_cycles_i
    output logic last_sample_o,     // PULSE: High for one cycle at delay_cycles_i + WINDOW_SIZE - 1
    output logic osc_reset_o,       // PULSE: High for one cycle BEFORE oscillator starts
    output logic dft_sample_valid_o // CONTINUOUS: High during DFT accumulation window
);

    // -------------------------------------------------------------------------
    // Internal Signals
    // -------------------------------------------------------------------------
    
    logic [COUNTER_WIDTH-1:0] osc_start_cnt = 'b0;
    logic [COUNTER_WIDTH-1:0] osc_end_cnt = 'b0;
    logic [COUNTER_WIDTH-1:0] last_sample_cnt = 'b0;
    logic [COUNTER_WIDTH-1:0] osc_reset_cnt = 'b0;
    logic [COUNTER_WIDTH-1:0] dft_start_cnt = 'b0;
    logic [COUNTER_WIDTH-1:0] dft_first_valid_sample_cnt = 'b0;
    logic [COUNTER_WIDTH-1:0] dft_end_cnt = 'b0;
    
    // -------------------------------------------------------------------------
    // Calculated Values (Combinational)
    // -------------------------------------------------------------------------
    // NOTE: All counts are adjusted -1 because outputs are registered (1 cycle delay)
    
    // Reset oscillator one cycle before it starts (adjusted for output register)
    always_comb begin
        osc_reset_cnt = delay_cycles_i - (OSC_LATENCY);
    end
    
    // Start oscillator early so valid sine/cosine values arrive when data arrives
    // -3 because start signals and first sample introduce delays in dft module
    // Additional -1 because output is registered
    always_comb begin
        osc_start_cnt = delay_cycles_i - (OSC_LATENCY - 2);
    end
    
    // End oscillator after all samples have been processed
    // The oscillator needs to run for WINDOW_SIZE samples after DFT starts
    // -1 because output is registered
    always_comb begin
        osc_end_cnt = delay_cycles_i + WINDOW_SIZE;
    end
    
    // Last sample position (same as osc_end_cnt)
    always_comb begin
        last_sample_cnt = delay_cycles_i + WINDOW_SIZE;
    end
    
    // DFT sample valid window: starts 2 cycles after start_dft_o pulse
    // (due to internal pipeline delays in dft_accumulation_cordic)
    // -1 because output is registered
    always_comb begin
        dft_start_cnt = delay_cycles_i;
        dft_first_valid_sample_cnt = delay_cycles_i;
    end
    
    // DFT accumulation ends after WINDOW_SIZE samples
    // -1 because output is registered
    always_comb begin
        dft_end_cnt = delay_cycles_i + WINDOW_SIZE;
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
    
    // Sequential State Update (POSEDGE)
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            count_q <= '0;
        end else begin
            count_q <= count_d;
        end
    end
    
    // -------------------------------------------------------------------------
    // Output Generation (NEGEDGE to avoid race conditions in Vivado)
    // -------------------------------------------------------------------------
    
    // All outputs are registered on negedge to avoid race conditions with modules
    // sampling on posedge. The counter updates on posedge, then outputs update on
    // negedge of the same cycle, giving consuming logic a clean half-cycle setup time.
    
    always_ff @(negedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            start_osc_o <= 1'b0;
            start_dft_o <= 1'b0;
            last_sample_o <= 1'b0;
            osc_reset_o <= 1'b0;
            dft_sample_valid_o <= 1'b0;
        end else if (enable_i) begin
            // Oscillator Enable: CONTINUOUS from osc_start_cnt to osc_end_cnt
            start_osc_o <= ((count_q >= osc_start_cnt) && (count_q <= osc_end_cnt));
            
            // DFT Start: SINGLE PULSE at delay_cycles_i
            start_dft_o <= (count_q == dft_start_cnt);
            
            // Last Sample: SINGLE PULSE at last_sample_cnt
            last_sample_o <= (count_q == last_sample_cnt);
            
            // Oscillator Reset: SINGLE PULSE one cycle before oscillator starts
            osc_reset_o <= (count_q == osc_reset_cnt);
            
            // DFT Sample Valid: CONTINUOUS during DFT accumulation window
            dft_sample_valid_o <= ((count_q >= dft_first_valid_sample_cnt) && (count_q <= dft_end_cnt));
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