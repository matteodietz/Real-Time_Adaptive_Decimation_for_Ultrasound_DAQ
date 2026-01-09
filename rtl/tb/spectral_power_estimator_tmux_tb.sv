module spectral_power_estimator_tmux_tb();

    timeunit 1ns;
    timeprecision 1ps;

    // --- Parameters ---
    localparam time CLK_PERIOD = 10ns;
    localparam unsigned RST_CLK_CYCLES = 5;
    
    // DFT Parameters
    localparam integer IQ_WIDTH = 16;
    localparam integer IQ_WIDTH_FRAC = 14;
    localparam integer WINDOW_WIDTH = 16;
    localparam integer WINDOW_WIDTH_FRAC = 14;
    localparam integer ACCUM_WIDTH = 36;
    localparam integer ACCUM_WIDTH_FRAC = 28;
    localparam integer NUM_BINS = 24;
    
    // Oscillator Parameters
    localparam integer OSC_WIDTH = 16;
    localparam integer OSC_WIDTH_FRAC = 14;
    localparam integer PHASE_WIDTH = 16;
    
    // Power Conversion Parameters
    localparam integer POWER_INPUT_WIDTH = 18;
    localparam integer POWER_WIDTH = 8;
    localparam integer POWER_FRAC = 0;
    
    // Timing Parameters
    localparam integer WINDOW_SIZE = 256;
    localparam integer OSC_LATENCY = 20;
    localparam integer COUNTER_WIDTH = 16;
    localparam integer SAMPLE_COUNT_WIDTH = 16;
    localparam integer TMUX_COUNTER_WIDTH = 5;
    localparam integer STAGE1_WIDTH = 24;
    
    // Time-multiplexing parameters
    localparam integer CYCLES_PER_SAMPLE = 12;  // Hold each sample for 12 cycles
    
    // Test-specific parameters
    localparam integer MAX_SAMPLES = 8192;  // Maximum frame size
    
    // --- Signals ---
    logic clk;
    logic rst_n;
    
    // Control signals
    logic enable;
    logic clear;
    logic [15:0] delay_cycles;  // Variable delay cycles per test
    logic [31:0] tmp;
    
    // Configuration
    logic [PHASE_WIDTH-1:0] freq_steps[NUM_BINS];
    
    // Data inputs
    logic sample_valid;
    logic signed [IQ_WIDTH-1:0] i_sample;
    logic signed [IQ_WIDTH-1:0] q_sample;
    logic signed [WINDOW_WIDTH-1:0] window_coeff;
    
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
    spectral_power_estimator_tmux #(
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
        .TMUX_COUNTER_WIDTH (TMUX_COUNTER_WIDTH),
        .CYCLES_PER_SAMPLE  (CYCLES_PER_SAMPLE),
        .STAGE1_WIDTH       (STAGE1_WIDTH)
    ) dut (
        .clk_i          (clk),
        .rst_ni         (rst_n),
        .enable_i       (enable),
        .clear_i        (clear),
        .delay_cycles_i (delay_cycles),
        .freq_steps_i   (freq_steps),
        .sample_valid_i (sample_valid),
        .i_sample_i     (i_sample),
        .q_sample_i     (q_sample),
        .window_coeff_i (window_coeff),
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
        end

        // Open the vector file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/spectral_power_estimator_vectors.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file.");
            $finish;
        end

        $display("=== Starting Spectral Power Estimator Time-Multiplexed Testbench ===");
        
        // Skip header lines (12 lines)
        for (int i = 0; i < 12; i++) begin
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
            $display("  DELAY_CYCLES (samples): %0d", delay_cycles_read);
            $display("  OSC_LATENCY: %0d", osc_latency_read);
            
            // Set delay_cycles for this test
            // CRITICAL: Multiply by CYCLES_PER_SAMPLE because delay_cycles_read is in 
            // slow samples, but counter_controller runs at fast clock (12x)
            // logic [31:0] tmp;

            tmp = delay_cycles_read * CYCLES_PER_SAMPLE;
            delay_cycles = tmp[15:0];

            // delay_cycles = logic'(delay_cycles_read * CYCLES_PER_SAMPLE)[15:0];
            $display("  DELAY_CYCLES (fast clocks): %0d", delay_cycles);
            
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
            @(posedge clk);
            #1;
            enable = 1'b1;
            clear = 1'b1;
            
            @(posedge clk);
            #1;
            clear = 1'b0;
            
            $display("  Timing controller enabled and cleared");
            
            // Step 2: Stream all samples (each held for 12 cycles) and watch for valid_o
            $display("  Streaming %0d samples (each held for %0d cycles)...", 
                    num_samples_read, CYCLES_PER_SAMPLE);
            
            valid_captured = 1'b0;
            
            for (int n = 0; n < num_samples_read; n++) begin
                automatic int window_idx;
                
                // Set up sample data at the beginning of the 12-cycle period
                #1;
                sample_valid = 1'b1;
                i_sample = i_samples[n];
                q_sample = q_samples[n];
                
                // Window coefficients only apply during the DFT window
                // The delay_cycles value needs to account for the 12x clock multiplier
                // So actual sample index in the original (slow) sample stream is n
                if (n < delay_cycles_read) begin
                    // Before the DFT window starts
                    window_coeff = '0;
                end else begin
                    // During and after the DFT window
                    window_idx = (n - delay_cycles_read) % window_size_read;
                    window_coeff = window_coeffs[window_idx];
                end
                
                // Hold sample for 12 cycles
                for (int cycle = 0; cycle < CYCLES_PER_SAMPLE; cycle++) begin
                    @(posedge clk);
                    
                    // Check if valid_o was asserted during this sample period
                    if (act_valid && !valid_captured) begin
                        valid_captured = 1'b1;
                        $display("  Valid signal captured during sample %0d, cycle %0d", n, cycle);
                        
                        // Let the current cycle complete, then check results
                        @(posedge clk);
                        check_result(num_bins_read, exp_db_power, n_errs);
                        
                        // Break out of both loops
                        break;
                    end
                end
                
                // If valid was captured, exit outer loop too
                if (valid_captured) break;
                
                // Progress indicator
                if (n % 64 == 0 && n > 0) begin
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
                        wait (act_valid);
                        $display("  Valid signal received");
                        valid_captured = 1'b1;
                    end
                    begin
                        repeat(2000) @(posedge clk);
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
                    check_result(num_bins_read, exp_db_power, n_errs);
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
        input integer num_bins,
        input logic [POWER_WIDTH-1:0] expected_db_power[NUM_BINS],
        inout integer error_count
    );
        automatic logic mismatch = 1'b0;
        automatic integer max_error = 0;
        automatic integer error_val;
        automatic integer max_power_expected;
        automatic integer max_power_actual;
        automatic integer max_power_overall;
        automatic integer threshold_margin = 30;  // dB below max to ignore errors
        logic in_noise_floor;
        
        // Allow tolerance for rounding differences in significant bins
        automatic integer tolerance = 3;  // Allow +/-3 dB error
        
        $display("  Checking power results...");
        
        // First pass: Find the maximum power value across both expected and actual
        max_power_expected = 0;
        max_power_actual = 0;
        for (int k = 0; k < num_bins; k++) begin
            if (expected_db_power[k] > max_power_expected) 
                max_power_expected = expected_db_power[k];
            if (act_db_power[k] > max_power_actual) 
                max_power_actual = act_db_power[k];
        end
        
        // Use the minimum of the two as the reference
        max_power_overall = (max_power_expected > max_power_actual) ? 
                            max_power_expected : max_power_actual;
        
        $display("    Maximum power: Expected=%0d dB, Actual=%0d dB, Overall=%0d dB", 
                max_power_expected, max_power_actual, max_power_overall);
        $display("    Ignoring errors for bins more than %0d dB below maximum", 
                threshold_margin);
        
        // Second pass: Check each bin
        for (int k = 0; k < num_bins; k++) begin
            // Calculate absolute error
            if (act_db_power[k] > expected_db_power[k]) begin
                error_val = act_db_power[k] - expected_db_power[k];
            end else begin
                error_val = expected_db_power[k] - act_db_power[k];
            end
            
            // Track maximum error
            if (error_val > max_error) max_error = error_val;
            
            // Check if both values are in the "noise floor" region
            in_noise_floor = 
                (expected_db_power[k] < (max_power_overall - threshold_margin)) &&
                (act_db_power[k] < (max_power_overall - threshold_margin));
            
            // Check against tolerance
            if (error_val > tolerance) begin
                if (in_noise_floor) begin
                    // Large error but in noise floor - just warn, don't fail
                    $display("    WARNING: Bin %0d has large error but below noise floor", k);
                    $display("      Expected: 0x%02h (%0d dB)", expected_db_power[k], expected_db_power[k]);
                    $display("      Got:      0x%02h (%0d dB)", act_db_power[k], act_db_power[k]);
                    $display("      Error:    %0d dB (ignored - below %0d dB threshold)", 
                            error_val, max_power_overall - threshold_margin);
                end else begin
                    // Significant error in a significant bin - this is a real error
                    $display("    ERROR: Bin %0d power mismatch", k);
                    $display("      Expected: 0x%02h (%0d dB)", expected_db_power[k], expected_db_power[k]);
                    $display("      Got:      0x%02h (%0d dB)", act_db_power[k], act_db_power[k]);
                    $display("      Error:    %0d dB", error_val);
                    mismatch = 1'b1;
                end
            end else begin
                $display("    SUCCESS: Bin %0d - Expected: 0x%02h, Got: 0x%02h, Error: %0d dB", 
                        k, expected_db_power[k], act_db_power[k], error_val);
            end
        end
        
        if (mismatch) begin
            error_count++;
            $display("  RESULT: FAIL");
        end else begin
            $display("  RESULT: PASS");
        end
        
        $display("    Max error across all bins: %0d dB", max_error);
    endtask

endmodule

