module spectral_power_estimator_tb();

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
    localparam integer OSC_LATENCY = 35;
    localparam integer COUNTER_WIDTH = 16;
    localparam integer SAMPLE_COUNT_WIDTH = 16;
    
    // Test-specific parameters
    localparam integer MAX_SAMPLES = 8192;  // Maximum frame size
    
    // --- Signals ---
    logic clk;
    logic rst_n;
    
    // Control signals
    logic enable;
    logic clear;
    
    // Configuration
    logic [PHASE_WIDTH-1:0] freq_steps[NUM_BINS];
    
    // Data inputs
    logic sample_valid;
    logic signed [IQ_WIDTH-1:0] i_sample;
    logic signed [IQ_WIDTH-1:0] q_sample;
    logic signed [WINDOW_WIDTH-1:0] window_coeff;
    logic last_sample;
    
    // Outputs
    logic [POWER_WIDTH-1:0] act_db_power[NUM_BINS];
    logic act_valid;
    logic act_busy;

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
    spectral_power_estimator #(
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
        .DELAY_CYCLES       (1000),  // Will be overridden per test case
        .OSC_LATENCY        (OSC_LATENCY),
        .COUNTER_WIDTH      (COUNTER_WIDTH),
        .SAMPLE_COUNT_WIDTH (SAMPLE_COUNT_WIDTH)
    ) dut (
        .clk_i          (clk),
        .rst_ni         (rst_n),
        .enable_i       (enable),
        .clear_i        (clear),
        .freq_steps_i   (freq_steps),
        .sample_valid_i (sample_valid),
        .i_sample_i     (i_sample),
        .q_sample_i     (q_sample),
        .window_coeff_i (window_coeff),
        .last_sample_i  (last_sample),
        .db_power_o     (act_db_power),
        .valid_o        (act_valid),
        .busy_o         (act_busy)
    );

    // --- Test Data Storage ---
    logic signed [IQ_WIDTH-1:0] i_samples[MAX_SAMPLES];
    logic signed [IQ_WIDTH-1:0] q_samples[MAX_SAMPLES];
    logic signed [WINDOW_WIDTH-1:0] window_coeffs[WINDOW_SIZE];
    
    logic [POWER_WIDTH-1:0] exp_db_power[NUM_BINS];

    // --- Test Sequencer and Checker ---
    initial begin: checker_block
        integer file, status;
        string line, test_name;
        integer num_bins_read, num_samples_read, window_size_read;
        integer delay_cycles_read, osc_latency_read;
        static integer n_errs = 0;
        static integer test_count = 0;
        integer timeout_counter;
        localparam integer TIMEOUT_CYCLES = 50000;  // Long timeout for full frame processing
        
        // Initialize signals at negedge to avoid race conditions
        @(negedge clk);
        enable = 1'b0;
        clear = 1'b0;
        sample_valid = 1'b0;
        last_sample = 1'b0;
        i_sample = '0;
        q_sample = '0;
        window_coeff = '0;
        for (int k = 0; k < NUM_BINS; k++) begin
            freq_steps[k] = '0;
        end

        // Open the vector file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/spectral_power_estimator_vectors.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file.");
            $finish;
        end

        $display("=== Starting Spectral Power Estimator Testbench ===");
        
        // Skip header lines (11 lines)
        for (int i = 0; i < 11; i++) begin
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
            
            // Read: NUM_BINS NUM_SAMPLES WINDOW_SIZE DELAY_CYCLES OSC_LATENCY
            status = $fscanf(file, "%d %d %d %d %d\n", 
                           num_bins_read, num_samples_read, window_size_read, 
                           delay_cycles_read, osc_latency_read);
            
            $display("  NUM_BINS: %0d", num_bins_read);
            $display("  NUM_SAMPLES: %0d", num_samples_read);
            $display("  WINDOW_SIZE: %0d", window_size_read);
            $display("  DELAY_CYCLES: %0d", delay_cycles_read);
            $display("  OSC_LATENCY: %0d", osc_latency_read);
            
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
            
            // Read EXPECTED_POWER_DB (space-separated hex values)
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fscanf(file, "%h", exp_db_power[k]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  Loaded %0d expected power values", num_bins_read);
            
            // Skip blank line between test cases
            status = $fgets(line, file);
            
            // --- Drive DUT ---
            $display("\n--- Starting Test Execution ---");
            
            // Step 1: Clear and enable the timing controller
            @(negedge clk);
            clear = 1'b1;
            enable = 1'b1;
            
            @(negedge clk);
            clear = 1'b0;
            
            $display("  Timing controller enabled and cleared");
            
            // Step 2: Stream all samples with timing controller managing everything
            $display("  Streaming %0d samples...", num_samples_read);
            
            for (int n = 0; n < num_samples_read; n++) begin
                @(negedge clk);
                
                // Apply sample data
                sample_valid = 1'b1;
                i_sample = i_samples[n];
                q_sample = q_samples[n];
                
                // Calculate which window coefficient to use
                // The timing controller will handle when to actually process
                // We need to cycle through window coefficients for each window
                automatic int window_idx = n % window_size_read;
                window_coeff = window_coeffs[window_idx];
                
                // Mark last sample of the target window
                // This happens at delay_cycles + window_size - 1
                if (n == delay_cycles_read + window_size_read - 1) begin
                    last_sample = 1'b1;
                    $display("    Asserting last_sample at sample %0d", n);
                end
                
                // Progress indicator
                if (n % 512 == 0 && n > 0) begin
                    $display("    Processed %0d/%0d samples...", n, num_samples_read);
                end
            end
            
            // Deassert control signals
            @(negedge clk);
            sample_valid = 1'b0;
            last_sample = 1'b0;
            enable = 1'b0;
            
            $display("  All samples streamed, waiting for valid_o...");
            
            // Step 3: Wait for valid signal with timeout
            timeout_counter = 0;
            while (!act_valid && timeout_counter < TIMEOUT_CYCLES) begin
                @(posedge clk);
                timeout_counter++;
            end
            
            if (timeout_counter >= TIMEOUT_CYCLES) begin
                $display("  ERROR: Timeout waiting for valid_o after %0d cycles", TIMEOUT_CYCLES);
                n_errs++;
                
                // Reset for next test
                @(negedge clk);
                clear = 1'b1;
                @(negedge clk);
                clear = 1'b0;
                repeat(10) @(posedge clk);
                continue;
            end
            
            $display("  Valid signal received after %0d cycles", timeout_counter);
            
            // Step 4: Check results (sample immediately when valid is high)
            check_result(num_bins_read, exp_db_power, n_errs);
            
            // Wait before next test case
            $display("  Waiting before next test...");
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
        input integer num_bins,
        input logic [POWER_WIDTH-1:0] expected_db_power[NUM_BINS],
        inout integer error_count
    );
        automatic logic mismatch = 1'b0;
        automatic integer max_error = 0;
        automatic integer error_val;
        
        // Allow small tolerance for rounding differences
        // Since we're using integer log2, there might be ±1 bit differences
        automatic integer tolerance = 3;  // Allow ±3 dB error
        
        $display("\n--- Checking Results ---");
        
        for (int k = 0; k < num_bins; k++) begin
            // Calculate absolute error
            if (act_db_power[k] > expected_db_power[k]) begin
                error_val = act_db_power[k] - expected_db_power[k];
            end else begin
                error_val = expected_db_power[k] - act_db_power[k];
            end
            
            // Track maximum error
            if (error_val > max_error) max_error = error_val;
            
            // Check against tolerance
            if (error_val > tolerance) begin
                $display("  ERROR: Bin %0d power mismatch", k);
                $display("    Expected: 0x%02h (%0d dB)", expected_db_power[k], expected_db_power[k]);
                $display("    Got:      0x%02h (%0d dB)", act_db_power[k], act_db_power[k]);
                $display("    Error:    %0d dB", error_val);
                mismatch = 1'b1;
            end else begin
                $display("  OK: Bin %0d - Expected: 0x%02h, Got: 0x%02h, Error: %0d dB", 
                        k, expected_db_power[k], act_db_power[k], error_val);
            end
        end
        
        if (mismatch) begin
            error_count++;
            $display("\n*** TEST CASE FAILED ***");
        end else begin
            $display("\n*** TEST CASE PASSED ***");
        end
        
        $display("  Maximum error across all bins: %0d dB", max_error);
    endtask

endmodule