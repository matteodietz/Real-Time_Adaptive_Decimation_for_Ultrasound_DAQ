module top_tb();

    timeunit 1ns;
    timeprecision 1ps;

    // --- Parameters (MUST match DUT and Python generator) ---
    localparam time CLK_PERIOD = 10ns;
    localparam unsigned RST_CLK_CYCLES = 5;
    
    // DFT Parameters
    localparam integer IQ_WIDTH = 16;
    localparam integer IQ_WIDTH_FRAC = 14;
    localparam integer WINDOW_WIDTH = 16;
    localparam integer WINDOW_WIDTH_FRAC = 14;
    localparam integer ACCUM_WIDTH = 64;
    localparam integer ACCUM_WIDTH_FRAC = 56;
    localparam integer NUM_BINS = 24;
    
    // Oscillator Parameters
    localparam integer OSC_WIDTH = 32;
    localparam integer OSC_WIDTH_FRAC = 30;
    localparam integer PHASE_WIDTH = 32;
    
    // Power Conversion Parameters
    localparam integer POWER_INPUT_WIDTH = 32;
    localparam integer POWER_WIDTH = 8;
    localparam integer POWER_FRAC = 0;
    
    // Timing Parameters
    localparam integer WINDOW_SIZE = 256;
    localparam integer OSC_LATENCY = 36;
    localparam integer COUNTER_WIDTH = 16;
    localparam integer SAMPLE_COUNT_WIDTH = 16;
    
    // Bandwidth Detection Parameters
    localparam integer FREQ_BIN_WIDTH = 16;
    localparam logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 8'h1E; // 30 dB
    
    // Test-specific parameters
    localparam integer MAX_SAMPLES = 8192;  // Maximum frame size
    
    // --- Signals ---
    logic clk;
    logic rst_n;
    
    // Control signals
    logic enable;
    logic clear;
    logic [15:0] delay_cycles;
    
    // Configuration
    logic [PHASE_WIDTH-1:0] freq_steps[NUM_BINS];
    logic [FREQ_BIN_WIDTH-1:0] freq_bins[NUM_BINS];
    
    // Data inputs
    logic sample_valid;
    logic signed [IQ_WIDTH-1:0] i_sample;
    logic signed [IQ_WIDTH-1:0] q_sample;
    logic signed [WINDOW_WIDTH-1:0] window_coeff;
    
    // Outputs
    logic dft_busy;
    logic threshold_ok;
    
    // Left edge outputs
    logic [FREQ_BIN_WIDTH-1:0] f1_left;
    logic [FREQ_BIN_WIDTH-1:0] f2_left;
    logic [POWER_WIDTH-1:0] L1_left;
    logic [POWER_WIDTH-1:0] L2_left;
    
    // Right edge outputs
    logic [FREQ_BIN_WIDTH-1:0] f1_right;
    logic [FREQ_BIN_WIDTH-1:0] f2_right;
    logic [POWER_WIDTH-1:0] L1_right;
    logic [POWER_WIDTH-1:0] L2_right;
    
    // Status outputs
    logic valid;
    logic busy;

    // --- Clock and Reset Generation ---
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    initial begin
        rst_n = 1'b0;
        repeat(RST_CLK_CYCLES) @(posedge clk);
        rst_n = 1'b1;
    end

    // --- DUT Instantiation ---
    top #(
        .IQ_WIDTH           (IQ_WIDTH),
        .IQ_WIDTH_FRAC      (IQ_WIDTH_FRAC),
        .WINDOW_WIDTH       (WINDOW_WIDTH),
        .WINDOW_WIDTH_FRAC  (WINDOW_WIDTH_FRAC),
        .ACCUM_WIDTH        (ACCUM_WIDTH),
        .ACCUM_WIDTH_FRAC   (ACCUM_WIDTH_FRAC),
        .NUM_BINS           (NUM_BINS),
        .OSC_WIDTH          (OSC_WIDTH),
        .OSC_WIDTH_FRAC     (OSC_WIDTH_FRAC),
        .PHASE_WIDTH        (PHASE_WIDTH),
        .POWER_INPUT_WIDTH  (POWER_INPUT_WIDTH),
        .POWER_WIDTH        (POWER_WIDTH),
        .POWER_FRAC         (POWER_FRAC),
        .WINDOW_SIZE        (WINDOW_SIZE),
        .OSC_LATENCY        (OSC_LATENCY),
        .COUNTER_WIDTH      (COUNTER_WIDTH),
        .SAMPLE_COUNT_WIDTH (SAMPLE_COUNT_WIDTH),
        .FREQ_BIN_WIDTH     (FREQ_BIN_WIDTH),
        .THRESHOLD_DROP     (THRESHOLD_DROP)
    ) dut (
        .clk_i          (clk),
        .rst_ni         (rst_n),
        .enable_i       (enable),
        .clear_i        (clear),
        .delay_cycles_i (delay_cycles),
        .freq_steps_i   (freq_steps),
        .freq_bin_i     (freq_bins),
        .sample_valid_i (sample_valid),
        .i_sample_i     (i_sample),
        .q_sample_i     (q_sample),
        .window_coeff_i (window_coeff),
        .dft_busy_o     (dft_busy),
        .threshold_ok_o (threshold_ok),
        .f1_left_o      (f1_left),
        .f2_left_o      (f2_left),
        .L1_left_o      (L1_left),
        .L2_left_o      (L2_left),
        .f1_right_o     (f1_right),
        .f2_right_o     (f2_right),
        .L1_right_o     (L1_right),
        .L2_right_o     (L2_right),
        .valid_o        (valid),
        .busy_o         (busy)
    );

    // --- Test Data Storage ---
    logic signed [IQ_WIDTH-1:0] i_samples[MAX_SAMPLES];
    logic signed [IQ_WIDTH-1:0] q_samples[MAX_SAMPLES];
    logic signed [WINDOW_WIDTH-1:0] window_coeffs[WINDOW_SIZE];
    
    // Expected outputs
    logic exp_threshold_ok;
    logic [FREQ_BIN_WIDTH-1:0] exp_f1_left;
    logic [FREQ_BIN_WIDTH-1:0] exp_f2_left;
    logic [POWER_WIDTH-1:0] exp_L1_left;
    logic [POWER_WIDTH-1:0] exp_L2_left;
    logic [FREQ_BIN_WIDTH-1:0] exp_f1_right;
    logic [FREQ_BIN_WIDTH-1:0] exp_f2_right;
    logic [POWER_WIDTH-1:0] exp_L1_right;
    logic [POWER_WIDTH-1:0] exp_L2_right;

    // --- Test Sequencer and Checker ---
    initial begin: checker_block
        integer file, status;
        string line, test_name;
        integer num_bins_read, num_samples_read, window_size_read;
        integer delay_cycles_read, osc_latency_read, threshold_drop_read;
        static integer n_errs = 0;
        static integer test_count = 0;
        logic valid_captured;
        
        // Initialize signals
        enable = 1'b0;
        clear = 1'b0;
        sample_valid = 1'b0;
        i_sample = '0;
        q_sample = '0;
        window_coeff = '0;
        delay_cycles = 16'd0;
        for (int k = 0; k < NUM_BINS; k++) begin
            freq_steps[k] = '0;
            freq_bins[k] = '0;
        end

        // Open the vector file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/top_vectors.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file.");
            $finish;
        end

        $display("=== Starting Top Module Testbench ===");
        
        // Skip header lines (14 lines)
        for (int i = 0; i < 14; i++) begin
            status = $fgets(line, file);
        end

        // Wait for reset to complete
        @(posedge rst_n);
        repeat(2) @(posedge clk);

        // Loop through all test cases
        while (!$feof(file)) begin
            // Read test name
            status = $fgets(line, file);
            if (status == 0) break;
            
            // Skip blank lines
            if (line == "\n" || line == "") continue;
            
            test_name = line;
            test_count++;
            $display("\n========================================");
            $display("Test Case %0d: %s", test_count, test_name);
            $display("========================================");
            
            // Read: NUM_BINS NUM_SAMPLES WINDOW_SIZE DELAY_CYCLES OSC_LATENCY THRESHOLD_DROP
            status = $fscanf(file, "%d %d %d %d %d %d\n", 
                           num_bins_read, num_samples_read, window_size_read, 
                           delay_cycles_read, osc_latency_read, threshold_drop_read);
            
            $display("  NUM_BINS: %0d", num_bins_read);
            $display("  NUM_SAMPLES: %0d", num_samples_read);
            $display("  WINDOW_SIZE: %0d", window_size_read);
            $display("  DELAY_CYCLES: %0d", delay_cycles_read);
            $display("  OSC_LATENCY: %0d", osc_latency_read);
            $display("  THRESHOLD_DROP: %0d dB", threshold_drop_read);
            
            // Set delay_cycles for this test
            delay_cycles = delay_cycles_read[15:0];
            
            if (num_samples_read > MAX_SAMPLES) begin
                $display("ERROR: num_samples (%0d) exceeds MAX_SAMPLES (%0d)", 
                        num_samples_read, MAX_SAMPLES);
                n_errs++;
                break;
            end
            
            if (num_bins_read != NUM_BINS) begin
                $display("ERROR: num_bins (%0d) doesn't match NUM_BINS (%0d)", 
                        num_bins_read, NUM_BINS);
                n_errs++;
                break;
            end
            
            if (window_size_read != WINDOW_SIZE) begin
                $display("ERROR: window_size (%0d) doesn't match WINDOW_SIZE (%0d)", 
                        window_size_read, WINDOW_SIZE);
                n_errs++;
                break;
            end
            
            // Read FREQ_STEPS (space-separated hex values)
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fscanf(file, "%h", freq_steps[k]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  Loaded %0d frequency steps", num_bins_read);
            
            // Read FREQ_BINS (space-separated hex values)
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fscanf(file, "%h", freq_bins[k]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  Loaded %0d frequency bins", num_bins_read);
            
            // Read WINDOW_COEFFS (space-separated hex values)
            for (int n = 0; n < window_size_read; n++) begin
                status = $fscanf(file, "%h", window_coeffs[n]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  Loaded %0d window coefficients", window_size_read);
            
            // Read I_SAMPLES (space-separated hex values, full frame)
            for (int n = 0; n < num_samples_read; n++) begin
                status = $fscanf(file, "%h", i_samples[n]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  Loaded %0d I samples", num_samples_read);
            
            // Read Q_SAMPLES (space-separated hex values, full frame)
            for (int n = 0; n < num_samples_read; n++) begin
                status = $fscanf(file, "%h", q_samples[n]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  Loaded %0d Q samples", num_samples_read);
            
            // Read EXPECTED_OUTPUTS: threshold_ok f1_left f2_left L1_left L2_left f1_right f2_right L1_right L2_right
            status = $fscanf(file, "%d %h %h %h %h %h %h %h %h\n",
                           exp_threshold_ok, 
                           exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left,
                           exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right);
            $display("  Loaded expected outputs");
            
            // Skip blank line between test cases
            status = $fgets(line, file);
            
            // --- Drive DUT ---
            $display("\n--- Starting Test Execution ---");
            
            // Step 1: Clear and enable the timing controller
            @(posedge clk);
            #1;
            enable = 1'b1;
            clear = 1'b1;
            
            @(posedge clk);
            #1;
            clear = 1'b0;
            
            $display("  Timing controller enabled and cleared");
            
            // Step 2: Stream all samples and watch for valid_o
            $display("  Streaming %0d samples...", num_samples_read);
            
            valid_captured = 1'b0;
            
            for (int n = 0; n < num_samples_read; n++) begin
                automatic int window_idx;
                @(posedge clk);
                #1;
                // Apply sample data
                sample_valid = 1'b1;
                i_sample = i_samples[n];
                q_sample = q_samples[n];
                
                // Window coefficients only apply during the DFT window
                if (n < delay_cycles_read) begin
                    window_coeff = '0;
                end else begin
                    window_idx = (n - delay_cycles_read) % window_size_read;
                    window_coeff = window_coeffs[window_idx];
                end

                // Check if valid_o was asserted
                if (valid && !valid_captured) begin
                    valid_captured = 1'b1;
                    $display("  Valid signal captured at sample %0d", n);
                    
                    // Immediately check results while valid is still high
                    @(posedge clk);
                    check_result(exp_threshold_ok,
                               exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left,
                               exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right,
                               n_errs);
                    
                    // We can break out now, remaining samples don't matter
                    break;
                end
                
                // Progress indicator
                if (n % 512 == 0 && n > 0) begin
                    $display("    Processed %0d/%0d samples...", n, num_samples_read);
                end
            end
            
            // Deassert control signals
            @(posedge clk);
            #1;
            sample_valid = 1'b0;

            // If valid not captured during streaming, wait for it
            if (!valid_captured) begin
                $display("  All samples streamed, waiting for valid...");
                
                fork
                    begin
                        wait (valid);
                        $display("  Valid signal received");
                        valid_captured = 1'b1;
                    end
                    begin
                        repeat(1000) @(posedge clk);
                        if (!valid_captured) begin
                            $display("  ERROR: Timeout waiting for valid signal");
                            n_errs++;
                        end
                    end
                join_any
                disable fork;
                
                // Check results
                if (valid_captured) begin
                    @(posedge clk); // Let outputs settle
                    check_result(exp_threshold_ok,
                               exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left,
                               exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right,
                               n_errs);
                end
            end
            
            // Disable timing controller
            @(posedge clk);
            #1;
            enable = 1'b0;
            
            // Wait between test cases
            $display("  Waiting 100 cycles before next test...");
            repeat(100) @(posedge clk);
        end

        $fclose(file);
        
        $display("\n========================================");
        $display("Test Summary");
        $display("========================================");
        $display("Total test cases: %0d", test_count);
        $display("Total errors:     %0d", n_errs);
        
        if (n_errs > 0) begin
            $display("\n*** TEST FAILED ***");
        end else begin
            $display("\n*** TEST PASSED ***");
        end
        $display("========================================\n");
        
        $finish;
    end

    // --- Checking Task ---
    task check_result(
        input logic expected_threshold_ok,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f1_left,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f2_left,
        input logic [POWER_WIDTH-1:0] expected_L1_left,
        input logic [POWER_WIDTH-1:0] expected_L2_left,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f1_right,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f2_right,
        input logic [POWER_WIDTH-1:0] expected_L1_right,
        input logic [POWER_WIDTH-1:0] expected_L2_right,
        inout integer error_count
    );
        automatic logic mismatch = 1'b0;
        
        $display("\n--- Checking Bandwidth Edge Detection Results ---");
        
        // Check threshold_ok
        if (threshold_ok !== expected_threshold_ok) begin
            $display("  ERROR: threshold_ok mismatch");
            $display("    Expected: %b", expected_threshold_ok);
            $display("    Got:      %b", threshold_ok);
            mismatch = 1'b1;
        end else begin
            $display("  OK: threshold_ok = %b", threshold_ok);
        end
        
        // Check left edge - frequencies
        $display("\n  Left Edge:");
        if (f1_left !== expected_f1_left) begin
            $display("    ERROR: f1_left mismatch");
            $display("      Expected: 0x%04h", expected_f1_left);
            $display("      Got:      0x%04h", f1_left);
            mismatch = 1'b1;
        end else begin
            $display("    OK: f1_left = 0x%04h", f1_left);
        end
        
        if (f2_left !== expected_f2_left) begin
            $display("    ERROR: f2_left mismatch");
            $display("      Expected: 0x%04h", expected_f2_left);
            $display("      Got:      0x%04h", f2_left);
            mismatch = 1'b1;
        end else begin
            $display("    OK: f2_left = 0x%04h", f2_left);
        end
        
        // Check left edge - powers (zero tolerance)
        if (L1_left !== expected_L1_left) begin
            $display("    ERROR: L1_left mismatch");
            $display("      Expected: 0x%02h (%0d dB)", expected_L1_left, expected_L1_left);
            $display("      Got:      0x%02h (%0d dB)", L1_left, L1_left);
            mismatch = 1'b1;
        end else begin
            $display("    OK: L1_left = 0x%02h (%0d dB)", L1_left, L1_left);
        end
        
        if (L2_left !== expected_L2_left) begin
            $display("    ERROR: L2_left mismatch");
            $display("      Expected: 0x%02h (%0d dB)", expected_L2_left, expected_L2_left);
            $display("      Got:      0x%02h (%0d dB)", L2_left, L2_left);
            mismatch = 1'b1;
        end else begin
            $display("    OK: L2_left = 0x%02h (%0d dB)", L2_left, L2_left);
        end
        
        // Check right edge - frequencies
        $display("\n  Right Edge:");
        if (f1_right !== expected_f1_right) begin
            $display("    ERROR: f1_right mismatch");
            $display("      Expected: 0x%04h", expected_f1_right);
            $display("      Got:      0x%04h", f1_right);
            mismatch = 1'b1;
        end else begin
            $display("    OK: f1_right = 0x%04h", f1_right);
        end
        
        if (f2_right !== expected_f2_right) begin
            $display("    ERROR: f2_right mismatch");
            $display("      Expected: 0x%04h", expected_f2_right);
            $display("      Got:      0x%04h", f2_right);
            mismatch = 1'b1;
        end else begin
            $display("    OK: f2_right = 0x%04h", f2_right);
        end
        
        // Check right edge - powers (zero tolerance)
        if (L1_right !== expected_L1_right) begin
            $display("    ERROR: L1_right mismatch");
            $display("      Expected: 0x%02h (%0d dB)", expected_L1_right, expected_L1_right);
            $display("      Got:      0x%02h (%0d dB)", L1_right, L1_right);
            mismatch = 1'b1;
        end else begin
            $display("    OK: L1_right = 0x%02h (%0d dB)", L1_right, L1_right);
        end
        
        if (L2_right !== expected_L2_right) begin
            $display("    ERROR: L2_right mismatch");
            $display("      Expected: 0x%02h (%0d dB)", expected_L2_right, expected_L2_right);
            $display("      Got:      0x%02h (%0d dB)", L2_right, L2_right);
            mismatch = 1'b1;
        end else begin
            $display("    OK: L2_right = 0x%02h (%0d dB)", L2_right, L2_right);
        end
        
        if (mismatch) begin
            error_count++;
            $display("\n  RESULT: FAIL");
        end else begin
            $display("\n  RESULT: PASS");
        end
    endtask

endmodule