////////////////////////////////////////////////////////////////////////////////
//
//  Testbench: oscillator_bank_tmux_tb
//
//  Tests time-multiplexed oscillator bank with 4 frequency bins
//
////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

module oscillator_bank_tmux_tb;

    // Parameters
    localparam int NUM_BINS = 24;
    localparam int OSC_WIDTH = 32;
    localparam int PHASE_WIDTH = 32;
    localparam int COUNTER_WIDTH = 4;
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
    logic signed [OSC_WIDTH-1:0] W_real[2];
    logic signed [OSC_WIDTH-1:0] W_imag[2];
    
    // Separate storage for observing each bin's waveform
    // Bins 0, 1 from CORDIC_0 and bins 12, 13 from CORDIC_1
    logic signed [OSC_WIDTH-1:0] bin0_W_real, bin0_W_imag;   // Bin 0 (counter=0, CORDIC_0)
    logic signed [OSC_WIDTH-1:0] bin1_W_real, bin1_W_imag;   // Bin 1 (counter=1, CORDIC_0)
    logic signed [OSC_WIDTH-1:0] bin12_W_real, bin12_W_imag; // Bin 12 (counter=0, CORDIC_1)
    logic signed [OSC_WIDTH-1:0] bin13_W_real, bin13_W_imag; // Bin 13 (counter=1, CORDIC_1)
    
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
    
    // Pipeline to track which bin the output corresponds to (accounts for CORDIC latency)
    logic [COUNTER_WIDTH-1:0] counter_pipe[CORDIC_LATENCY];
    logic [COUNTER_WIDTH-1:0] output_counter;
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < CORDIC_LATENCY; i++) begin
                counter_pipe[i] <= '0;
            end
        end else if (counter_enable) begin
            counter_pipe[0] <= counter;
            for (int i = 1; i < CORDIC_LATENCY; i++) begin
                counter_pipe[i] <= counter_pipe[i-1];
            end
        end
    end
    
    assign output_counter = counter_pipe[CORDIC_LATENCY-1];
    
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
    
    // Demultiplex outputs to separate signals for waveform viewing
    // W_real[0] and W_imag[0] correspond to bin output_counter
    // W_real[1] and W_imag[1] correspond to bin output_counter + 12
    always_ff @(posedge clk) begin
        if (sincos_tvalid) begin
            case (output_counter)
                4'd0: begin
                    bin0_W_real  <= W_real[0];  // Bin 0 from CORDIC_0
                    bin0_W_imag  <= W_imag[0];
                    bin12_W_real <= W_real[1];  // Bin 12 from CORDIC_1
                    bin12_W_imag <= W_imag[1];
                end
                4'd1: begin
                    bin1_W_real  <= W_real[0];  // Bin 1 from CORDIC_0
                    bin1_W_imag  <= W_imag[0];
                    bin13_W_real <= W_real[1];  // Bin 13 from CORDIC_1
                    bin13_W_imag <= W_imag[1];
                end
                // Other counter values don't update our 4 bins of interest
            endcase
        end
    end
    
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
        // Phase range is 0 to 2^16-1, representing -1 to +1
        freq_steps[0] = 32'h01000000;  // 2^32 / 256 ≈ 16777216
        freq_steps[1] = 32'h00800000;  // 2^32 / 512 ≈ 8388608
        freq_steps[12] = 32'h06000000;  // Medium-fast - completes cycle in ~11 counter periods
        freq_steps[13] = 32'h02000000;  // Slowest - completes cycle in ~32 counter periods
        
        // Wait and release reset
        repeat(10) @(posedge clk);
        #1;
        rst_n = 1;
        @(posedge clk);
        
        $display("\n=============================================================");
        $display("Time-Multiplexed Oscillator Bank Waveform Test");
        $display("=============================================================");
        $display("Testing 4 bins with different frequencies:");
        $display("  Bin 0  (CORDIC_0, counter=0):  freq_step = 0x%04h", freq_steps[0]);
        $display("  Bin 1  (CORDIC_0, counter=1):  freq_step = 0x%04h", freq_steps[1]);
        $display("  Bin 12 (CORDIC_1, counter=0):  freq_step = 0x%04h", freq_steps[12]);
        $display("  Bin 13 (CORDIC_1, counter=1):  freq_step = 0x%04h", freq_steps[13]);
        $display("\nEach bin updates once every 12 cycles (time-multiplexed)");
        $display("CORDIC latency: %0d cycles", CORDIC_LATENCY);
        $display("\nObserve these signals in waveform viewer:");
        $display("  - bin0_W_real, bin0_W_imag   (fastest)");
        $display("  - bin1_W_real, bin1_W_imag   (medium)");
        $display("  - bin12_W_real, bin12_W_imag (medium-fast)");
        $display("  - bin13_W_real, bin13_W_imag (slowest)");
        $display("=============================================================\n");
        
        // Reset phase accumulators
        @(posedge clk);
        #1;
        phase_acc_sync_reset = 1'b1;
        @(posedge clk);
        #1;
        phase_acc_sync_reset = 1'b0;
        
        // Enable continuous operation
        @(posedge clk);
        #1;
        phase_acc_enable = 1'b1;
        cordic_phase_tvalid = 1'b1;
        counter_enable = 1'b1;
        
        // Wait for CORDIC pipeline to fill
        $display("Waiting %0d cycles for CORDIC pipeline to fill...", CORDIC_LATENCY);
        repeat(CORDIC_LATENCY) @(posedge clk);
        
        // Run for enough cycles to see multiple complete waveforms
        // Each bin updates every 12 cycles
        // Run 2400 cycles = 200 updates per bin = several complete cycles
        $display("Running for 2400 cycles (200 updates per bin)...\n");
        repeat(2400) @(posedge clk);
        #1;
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
        $display("  4. Each bin updates every 12 clock cycles");
        $display("=============================================================\n");
        
        $finish;
    end
    
    // Optional: Monitor to print a few samples for verification
    integer sample_count = 0;
    always @(posedge clk) begin
        if (sincos_tvalid && output_counter <= 1 && sample_count < 40) begin
            if (output_counter == 0) begin
                $display("Counter=%2d: Bin0 (Re=%08h, Im=%08h)  Bin12(Re=%08h, Im=%08h)", 
                         output_counter,
                         W_real[0], W_imag[0],
                         W_real[1], W_imag[1]);
            end else if (output_counter == 1) begin
                $display("Counter=%2d: Bin1 (Re=%08h, Im=%08h)  Bin13(Re=%08h, Im=%08h)", 
                         output_counter,
                         W_real[0], W_imag[0],
                         W_real[1], W_imag[1]);
                sample_count++;
            end
        end
    end

endmodule