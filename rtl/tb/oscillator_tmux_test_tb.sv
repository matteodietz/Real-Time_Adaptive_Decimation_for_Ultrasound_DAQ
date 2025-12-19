// ////////////////////////////////////////////////////////////////////////////////
// //
// //  Testbench: oscillator_tmux_test_tb
// //
// //  Simple phase sweep for waveform observation - Time Multiplexed
// //
// ////////////////////////////////////////////////////////////////////////////////
// `timescale 1ns/1ps

// module oscillator_tmux_test_tb;

//     // Parameters
//     localparam int OSC_WIDTH = 32;
//     localparam int PHASE_WIDTH = 32;
//     localparam real CLK_PERIOD = 10.0; // 100 MHz
//     localparam int CORDIC_LATENCY = 36;
    
//     // DUT signals
//     logic clk;
//     logic rst_n;
//     logic phase_acc_enable;
//     logic phase_acc_sync_reset;
//     logic cordic_phase_tvalid;
//     logic [PHASE_WIDTH-1:0] freq_step_0;
//     logic [PHASE_WIDTH-1:0] freq_step_1;
    
//     logic signed [OSC_WIDTH-1:0] W_real_0;
//     logic signed [OSC_WIDTH-1:0] W_imag_0;
//     logic signed [OSC_WIDTH-1:0] W_real_1;
//     logic signed [OSC_WIDTH-1:0] W_imag_1;
//     logic sincos_tvalid;
    
//     // Clock generation
//     initial begin
//         clk = 0;
//         forever #(CLK_PERIOD/2) clk = ~clk;
//     end
    
//     // DUT instantiation
//     oscillator_tmux_test #(
//         .OSC_WIDTH(OSC_WIDTH),
//         .PHASE_WIDTH(PHASE_WIDTH)
//     ) dut (
//         .clk_i(clk),
//         .rst_ni(rst_n),
//         .phase_acc_enable_i(phase_acc_enable),
//         .phase_acc_sync_reset_i(phase_acc_sync_reset),
//         .cordic_phase_tvalid_i(cordic_phase_tvalid),
//         .freq_step_0_i(freq_step_0),
//         .freq_step_1_i(freq_step_1),
//         .W_real_0_o(W_real_0),
//         .W_imag_0_o(W_imag_0),
//         .W_real_1_o(W_real_1),
//         .W_imag_1_o(W_imag_1),
//         .sincos_tvalid_o(sincos_tvalid)
//     );
    
//     // Test sequence
//     initial begin
//         // Initialize
//         rst_n = 1'b0;
//         phase_acc_enable = 1'b0;
//         phase_acc_sync_reset = 1'b0;
//         cordic_phase_tvalid = 1'b0;
//         freq_step_0 = '0;
//         freq_step_1 = '0;
        
//         // Setup frequency steps
//         // Bin 0: Faster oscillation - completes cycle in ~128 updates = 256 clocks
//         // Bin 1: Slower oscillation - completes cycle in ~256 updates = 512 clocks
//         freq_step_0 = 32'h01000000;  // 2^32 / 256 ≈ 16777216
//         freq_step_1 = 32'h00800000;  // 2^32 / 512 ≈ 8388608
        
//         // Wait and release reset
//         repeat(10) @(posedge clk);
//         #1;
//         rst_n = 1'b1;
//         @(posedge clk);
        
//         $display("\n=============================================================");
//         $display("Time-Multiplexed Oscillator Test");
//         $display("=============================================================");
//         $display("Bin 0 freq_step: 0x%04h (faster)", freq_step_0);
//         $display("Bin 1 freq_step: 0x%04h (slower)", freq_step_1);
//         $display("\nTime-multiplexing: Counter alternates between bin 0 and 1");
//         $display("Each bin updates every 2 cycles (after CORDIC latency)");
//         $display("CORDIC latency: %0d cycles\n", CORDIC_LATENCY);
        
//         // Reset phase accumulators
//         @(posedge clk);
//         #1;
//         phase_acc_sync_reset = 1'b1;
//         @(posedge clk);
//         #1;
//         phase_acc_sync_reset = 1'b0;
        
//         $display("Starting oscillators...");
        
//         // Enable continuous operation
//         @(posedge clk);
//         #1;
//         phase_acc_enable = 1'b1;
//         cordic_phase_tvalid = 1'b1;
        
//         // Wait for CORDIC pipeline to fill
//         $display("Waiting %0d cycles for CORDIC pipeline...", CORDIC_LATENCY);
//         repeat(CORDIC_LATENCY) @(posedge clk);
        
//         $display("Pipeline filled, outputs should now be valid");
//         $display("Running for 2048 clock cycles...");
//         $display("Watch W_real_0_o, W_imag_0_o, W_real_1_o, W_imag_1_o in waveform viewer!\n");
        
//         // Run for several full cycles
//         // Since each bin updates every 2 cycles, 2048 cycles = 1024 updates per bin
//         repeat(2048) @(posedge clk);
//         #1;
        
//         phase_acc_enable = 1'b0;
//         cordic_phase_tvalid = 1'b0;
        
//         repeat(20) @(posedge clk);
        
//         $display("\n=============================================================");
//         $display("Test completed - check waveforms!");
//         $display("Expected behavior:");
//         $display("  - W_real_0/W_imag_0: Faster sinusoid, updates every 2 cycles");
//         $display("  - W_real_1/W_imag_1: Slower sinusoid, updates every 2 cycles");
//         $display("  - Real and imaginary should be 90° out of phase");
//         $display("  - Values held constant between updates (staircase pattern)");
//         $display("=============================================================\n");
        
//         $finish;
//     end
    
//     // Optional: Monitor to print first few samples
//     integer sample_count = 0;
//     always @(posedge clk) begin
//         if (sincos_tvalid && sample_count < 40) begin
//             $display("Sample %3d: Bin0(Re=%08h, Im=%08h)  Bin1(Re=%08h, Im=%08h)", 
//                      sample_count,
//                      W_real_0, W_imag_0,
//                      W_real_1, W_imag_1);
//             sample_count++;
//         end
//     end

// endmodule

////////////////////////////////////////////////////////////////////////////////
//
//  Testbench: oscillator_bank_tmux_tb
//
//  Tests time-multiplexed oscillator bank with 4 frequency bins
//  Updated for version with stored outputs per bin
//
////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module oscillator_bank_tmux_tb;

    // Parameters
    localparam int NUM_BINS = 24;
    localparam int OSC_WIDTH = 32;
    localparam int PHASE_WIDTH = 32;
    localparam int COUNTER_WIDTH = 5;
    localparam int CORDIC_LATENCY = 36;
    localparam real CLK_PERIOD = 10.0; // 100 MHz (representing 375 MHz in real system)
    localparam int BINS_PER_CORDIC = NUM_BINS / 2;
    
    // DUT signals
    logic clk;
    logic rst_n;
    logic phase_acc_enable;
    logic phase_acc_sync_reset;
    logic cordic_phase_tvalid;
    logic [COUNTER_WIDTH-1:0] counter;
    logic [PHASE_WIDTH-1:0] freq_steps[NUM_BINS];
    
    logic sincos_tvalid;
    logic signed [OSC_WIDTH-1:0] W_real[NUM_BINS];   // Now all bins
    logic signed [OSC_WIDTH-1:0] W_imag[NUM_BINS];   // Now all bins
    
    // Convenient aliases for observing specific bins in waveform viewer
    logic signed [OSC_WIDTH-1:0] bin0_W_real, bin0_W_imag;
    logic signed [OSC_WIDTH-1:0] bin1_W_real, bin1_W_imag;
    logic signed [OSC_WIDTH-1:0] bin12_W_real, bin12_W_imag;
    logic signed [OSC_WIDTH-1:0] bin13_W_real, bin13_W_imag;
    
    // Direct assignment from stored bin values
    assign bin0_W_real  = W_real[0];
    assign bin0_W_imag  = W_imag[0];
    assign bin1_W_real  = W_real[1];
    assign bin1_W_imag  = W_imag[1];
    assign bin12_W_real = W_real[12];
    assign bin12_W_imag = W_imag[12];
    assign bin13_W_real = W_real[13];
    assign bin13_W_imag = W_imag[13];
    
    // Counter generation (mimics the counter in dft_accumulation_cordic_tmux)
    logic counter_enable;
    logic counter_reset;
    
    always_ff @(posedge clk) begin
        if (!rst_n || counter_reset) begin
            counter <= '0;
        end else if (counter_enable) begin
            if (counter == COUNTER_WIDTH'(BINS_PER_CORDIC - 1)) begin
                counter <= '0;
            end else begin
                counter <= counter + 1;
            end
        end
    end
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // DUT instantiation
    oscillator_bank_tmux #(
        .NUM_BINS(NUM_BINS),
        .OSC_WIDTH(OSC_WIDTH),
        .PHASE_WIDTH(PHASE_WIDTH),
        .COUNTER_WIDTH(COUNTER_WIDTH)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .phase_acc_enable_i(phase_acc_enable),
        .phase_acc_sync_reset_i(phase_acc_sync_reset),
        .cordic_phase_tvalid_i(cordic_phase_tvalid),
        .counter_i(counter),
        .freq_steps_i(freq_steps),
        .sincos_tvalid_o(sincos_tvalid),
        .W_real_o(W_real),
        .W_imag_o(W_imag)
    );
    
    // Test sequence
    initial begin
        // Initialize
        rst_n = 1'b0;
        phase_acc_enable = 1'b0;
        phase_acc_sync_reset = 1'b0;
        cordic_phase_tvalid = 1'b0;
        counter_enable = 1'b0;
        counter_reset = 1'b0;
        
        // Initialize all frequency steps to 0
        for (int i = 0; i < NUM_BINS; i++) begin
            freq_steps[i] = '0;
        end
        
        // Setup frequency steps for 4 bins (2 per CORDIC)
        // Choose values that create visible oscillations in waveform viewer
        freq_steps[0]  = 32'h02000000;  // Fastest - 2^32 / 256
        freq_steps[1]  = 32'h00800000;  // Medium  - 2^32 / 512
        freq_steps[12] = 32'h00C00000;  // Medium-fast
        freq_steps[13] = 32'h04000000;  // Slowest
        
        // Wait and release reset
        repeat(10) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        
        $display("\n=============================================================");
        $display("Time-Multiplexed Oscillator Bank Waveform Test");
        $display("=============================================================");
        $display("Testing 4 bins with different frequencies:");
        $display("  Bin 0  (CORDIC_0, counter=0):  freq_step = 0x%08h", freq_steps[0]);
        $display("  Bin 1  (CORDIC_0, counter=1):  freq_step = 0x%08h", freq_steps[1]);
        $display("  Bin 12 (CORDIC_1, counter=0):  freq_step = 0x%08h", freq_steps[12]);
        $display("  Bin 13 (CORDIC_1, counter=1):  freq_step = 0x%08h", freq_steps[13]);
        $display("\nEach bin updates once every 12 cycles (time-multiplexed)");
        $display("CORDIC latency: %0d cycles", CORDIC_LATENCY);
        $display("\nOutputs are stored per bin - no demux needed!");
        $display("Observe these signals in waveform viewer:");
        $display("  - bin0_W_real, bin0_W_imag   (or W_real[0], W_imag[0])");
        $display("  - bin1_W_real, bin1_W_imag   (or W_real[1], W_imag[1])");
        $display("  - bin12_W_real, bin12_W_imag (or W_real[12], W_imag[12])");
        $display("  - bin13_W_real, bin13_W_imag (or W_real[13], W_imag[13])");
        $display("=============================================================\n");
        
        // Reset phase accumulators
        @(posedge clk);
        phase_acc_sync_reset = 1'b1;
        @(posedge clk);
        phase_acc_sync_reset = 1'b0;
        
        // Enable continuous operation
        @(posedge clk);
        phase_acc_enable = 1'b1;
        cordic_phase_tvalid = 1'b1;
        counter_enable = 1'b1;
        
        // Wait for CORDIC pipeline to fill
        $display("Waiting %0d cycles for CORDIC pipeline to fill...", CORDIC_LATENCY * BINS_PER_CORDIC);
        repeat(CORDIC_LATENCY * BINS_PER_CORDIC) @(posedge clk);
        
        // Run for enough cycles to see multiple complete waveforms
        // Each bin updates every 12 cycles
        // Run 2400 cycles = 200 updates per bin = several complete cycles
        $display("Running for 2400 cycles (200 updates per bin)...\n");
        repeat(10000) @(posedge clk);
        
        phase_acc_enable = 1'b0;
        cordic_phase_tvalid = 1'b0;
        counter_enable = 1'b0;
        
        repeat(20) @(posedge clk);
        
        $display("\n=============================================================");
        $display("Test completed successfully!");
        $display("Check waveforms to verify:");
        $display("  1. Each bin shows a sinusoidal pattern");
        $display("  2. Real and imaginary parts are 90° out of phase");
        $display("  3. Each bin has different frequency according to freq_step");
        $display("  4. Each bin updates every 12 clock cycles (staircase)");
        $display("  5. Values persist in registers between updates");
        $display("=============================================================\n");
        
        $finish;
    end
    
    // Optional: Monitor to print samples showing stored values
    integer sample_count = 0;
    always @(posedge clk) begin
        if (counter == 0 && counter_enable && sample_count < 20) begin
            $display("Cycle %4d: Bin0=%08h/%08h  Bin1=%08h/%08h  Bin12=%08h/%08h  Bin13=%08h/%08h", 
                     sample_count * 12,
                     W_real[0], W_imag[0],
                     W_real[1], W_imag[1],
                     W_real[12], W_imag[12],
                     W_real[13], W_imag[13]);
            sample_count++;
        end
    end

endmodule