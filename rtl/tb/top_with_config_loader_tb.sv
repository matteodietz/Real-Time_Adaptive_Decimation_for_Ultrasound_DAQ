// //////////////////////////////////////////////////////////////////////////////
//
//  Module: top_with_config_loader_tb
//
//  Description:
//      Testbench for top module with AXI-Stream configuration interface.
//      Loads configuration via AXI-Stream, then streams I/Q data
//      Updated for time-multiplexed operation (12 cycles per sample)
//
// //////////////////////////////////////////////////////////////////////////////

module top_with_config_loader_tb();

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
    
    // Bandwidth Detection Parameters
    localparam integer FREQ_BIN_WIDTH = 5; //16
    localparam logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 8'h1E; // 30 dB
    
    // Config Loader Parameters
    localparam integer CONFIG_DATA_WIDTH = 16;
    
    // Time-multiplexing parameters
    localparam integer TMUX_COUNTER_WIDTH = 5;
    localparam integer CYCLES_PER_SAMPLE = 12;  // Hold each sample for 12 cycles
    
    // Test-specific parameters
    localparam integer MAX_SAMPLES = 8192;  // Maximum frame size
    
    // --- Signals ---
    logic clk;
    logic rst_n;
    
    // Configuration Loading Interface (AXI-Stream)
    logic [CONFIG_DATA_WIDTH-1:0] s_axis_config_tdata;
    logic s_axis_config_tvalid;
    logic s_axis_config_tready;
    logic config_valid;
    
    // Control signals
    logic enable;
    logic clear;
    logic [15:0] delay_cycles;
    logic [31:0] tmp;  // Temporary for delay_cycles scaling
    
    // Data inputs
    logic sample_valid;
    logic signed [IQ_WIDTH-1:0] i_sample;
    logic signed [IQ_WIDTH-1:0] q_sample;
    logic signed [WINDOW_WIDTH-1:0] window_coeff;
    
    // Outputs
    // logic dft_busy;
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

    logic [POWER_WIDTH-1:0] abs_threshold;
    
    // Status outputs
    logic valid;

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
    top_with_config_loader #(
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
        .THRESHOLD_DROP     (THRESHOLD_DROP),
        .CONFIG_DATA_WIDTH  (CONFIG_DATA_WIDTH),
        .TMUX_COUNTER_WIDTH (TMUX_COUNTER_WIDTH),
        .CYCLES_PER_SAMPLE  (CYCLES_PER_SAMPLE)
    ) dut (
        .clk_i                   (clk),
        .rst_ni                  (rst_n),
        .s_axis_config_tdata_i   (s_axis_config_tdata),
        .s_axis_config_tvalid_i  (s_axis_config_tvalid),
        .s_axis_config_tready_o  (s_axis_config_tready),
        .config_valid_o          (config_valid),
        .enable_i                (enable),
        .clear_i                 (clear),
        .delay_cycles_i          (delay_cycles),
        .sample_valid_i          (sample_valid),
        .i_sample_i              (i_sample),
        .q_sample_i              (q_sample),
        .window_coeff_i          (window_coeff),
        .threshold_ok_o          (threshold_ok),
        .f1_left_o               (f1_left),
        .f2_left_o               (f2_left),
        .L1_left_o               (L1_left),
        .L2_left_o               (L2_left),
        .f1_right_o              (f1_right),
        .f2_right_o              (f2_right),
        .L1_right_o              (L1_right),
        .L2_right_o              (L2_right),
        .abs_threshold_o         (abs_threshold),
        .valid_o                 (valid)
    );

    // --- Test Data Storage ---
    logic signed [IQ_WIDTH-1:0] i_samples[MAX_SAMPLES];
    logic signed [IQ_WIDTH-1:0] q_samples[MAX_SAMPLES];
    logic signed [WINDOW_WIDTH-1:0] window_coeffs[WINDOW_SIZE];
    logic [PHASE_WIDTH-1:0] freq_steps[NUM_BINS];
    logic [FREQ_BIN_WIDTH-1:0] freq_bins[NUM_BINS];
    
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
        integer file, status, csv_file;
        string line, test_name;
        integer num_bins_read, num_samples_read, window_size_read;
        integer delay_cycles_read, osc_latency_read, threshold_drop_read;
        integer angle, channel, window_number;
        static integer n_errs = 0;
        static integer test_count = 0;
        logic valid_captured;
        
        string vector_path;
        string csv_path;
        
        $display("=== Starting Top Module with Config Loader Testbench (Time-Multiplexed) ===");
        
        // Build file paths
        vector_path = "/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/top_vectors.txt";
        csv_path = "/home/bsc25h10/mdietz/bachelors_thesis/rtl/sim_results/top_with_config_loader_tmux_results.csv";
        
        $display("Vector file: %s", vector_path);
        $display("Results file: %s", csv_path);
        
        // Initialize signals
        enable = 1'b0;
        clear = 1'b0;
        sample_valid = 1'b0;
        i_sample = '0;
        q_sample = '0;
        window_coeff = '0;
        delay_cycles = 16'd0;
        s_axis_config_tdata = '0;
        s_axis_config_tvalid = 1'b0;

        // Open the vector file
        file = $fopen(vector_path, "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file: %s", vector_path);
            $finish;
        end

        // Open CSV results file
        csv_file = $fopen(csv_path, "w");
        if (csv_file == 0) begin
            $display("ERROR: Could not open CSV results file: %s", csv_path);
            $fclose(file);
            $finish;
        end

        // Write CSV header
        $fwrite(csv_file, "channel,angle,window,");
        $fwrite(csv_file, "exp_f1_left,exp_f2_left,exp_L1_left,exp_L2_left,");
        $fwrite(csv_file, "exp_f1_right,exp_f2_right,exp_L1_right,exp_L2_right,");
        $fwrite(csv_file, "act_f1_left,act_f2_left,act_L1_left,act_L2_left,");
        $fwrite(csv_file, "act_f1_right,act_f2_right,act_L1_right,act_L2_right,");
        $fwrite(csv_file, "abs_threshold,warning,error\n");
        
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
            
            // Read: NUM_BINS NUM_SAMPLES WINDOW_SIZE DELAY_CYCLES OSC_LATENCY THRESHOLD_DROP ANGLE CHANNEL WINDOW_NUM
            status = $fscanf(file, "%d %d %d %d %d %d %d %d %d\n", 
                           num_bins_read, num_samples_read, window_size_read, 
                           delay_cycles_read, osc_latency_read, threshold_drop_read,
                           angle, channel, window_number);
            
            $display("  NUM_BINS: %0d", num_bins_read);
            $display("  NUM_SAMPLES: %0d", num_samples_read);
            $display("  WINDOW_SIZE: %0d", window_size_read);
            $display("  DELAY_CYCLES (samples): %0d", delay_cycles_read);
            $display("  OSC_LATENCY: %0d", osc_latency_read);
            $display("  THRESHOLD_DROP: %0d dB", threshold_drop_read);
            $display("  ANGLE: %0d, CHANNEL: %0d, WINDOW: %0d", angle, channel, window_number);
            
            // Set delay_cycles for this test
            // CRITICAL: Multiply by CYCLES_PER_SAMPLE because delay_cycles_read is in 
            // slow samples, but counter_controller runs at fast clock (12x)
            tmp = delay_cycles_read * CYCLES_PER_SAMPLE;
            delay_cycles = tmp[15:0];
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

            
            // --- Drive DUT ---
            $display("\n--- Starting Test Execution ---");
            
            // Step 1: Load configuration via AXI-Stream
            $display("  Loading configuration via AXI-Stream...");

            @(negedge clk);
            clear = 1'b1;
            @(negedge clk);
            clear = 1'b0;
            
            // Load freq_steps (NUM_BINS = 24 values)
            $display("    Loading freq_steps...");
            for (int i = 0; i < num_bins_read; i++) begin
                @(posedge clk);
                s_axis_config_tdata = freq_steps[i];
                s_axis_config_tvalid = 1'b1;
                
                // Wait for ready (handshake)
                while (!s_axis_config_tready) begin
                    @(posedge clk);
                end
            end
            
            @(posedge clk);
            s_axis_config_tvalid = 1'b0;
            
            // Load freq_bin (NUM_BINS = 24 values)
            $display("    Loading freq_bins...");
            for (int i = 0; i < num_bins_read; i++) begin
                @(posedge clk);
                s_axis_config_tdata = {16'h0000, freq_bins[i]};  // Zero-extend to 32 bits
                s_axis_config_tvalid = 1'b1;
                
                // Wait for ready (handshake)
                while (!s_axis_config_tready) begin
                    @(posedge clk);
                end
            end
            
            @(posedge clk);
            s_axis_config_tvalid = 1'b0;
            
            // Wait for config_valid
            $display("    Waiting for config_valid...");
            @(posedge clk);
            while (!config_valid) begin
                @(posedge clk);
            end
            $display("    Configuration loaded successfully!");
            
            // Step 2: Clear and enable the timing controller
            @(posedge clk);
            #1;
            enable = 1'b1;
            
            @(posedge clk);
            #1;
            
            $display("  Timing controller enabled and cleared");

            // Step 3: Stream all samples (each held for 12 cycles) and watch for valid
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
                if (n < delay_cycles_read) begin
                    window_coeff = '0;
                end else begin
                    window_idx = (n - delay_cycles_read) % window_size_read;
                    window_coeff = window_coeffs[window_idx];
                end

                // Hold sample for 12 cycles
                for (int cycle = 0; cycle < CYCLES_PER_SAMPLE; cycle++) begin
                    @(posedge clk);
                    
                    // Check if valid was asserted during this sample period
                    if (valid && !valid_captured) begin
                        valid_captured = 1'b1;
                        $display("  Valid signal captured during sample %0d, cycle %0d", n, cycle);
                        
                        // Let the current cycle complete, then check results
                        @(posedge clk);
                        check_result(csv_file, angle, channel, window_number,
                                exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left,
                                exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right,
                                abs_threshold, n_errs);
                        
                        // Break out of both loops
                        break;
                    end
                end
                
                // If valid was captured, exit outer loop too
                if (valid_captured) break;
                
                // Progress indicator
                if (n % 512 == 0 && n > 0) begin
                    $display("    Processed %0d/%0d samples...", n, num_samples_read);
                end
            end

            // Deassert control signals
            @(posedge clk);
            #1;
            sample_valid = 1'b0;
            
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
                    check_result(csv_file, angle, channel, window_number,
                               exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left,
                               exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right,
                               abs_threshold, n_errs);
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
        $fclose(csv_file);
        
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
        input integer csv_file,
        input integer angle,
        input integer channel,
        input integer window_num,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f1_left,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f2_left,
        input logic [POWER_WIDTH-1:0] expected_L1_left,
        input logic [POWER_WIDTH-1:0] expected_L2_left,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f1_right,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f2_right,
        input logic [POWER_WIDTH-1:0] expected_L1_right,
        input logic [POWER_WIDTH-1:0] expected_L2_right,
        input logic [POWER_WIDTH-1:0] actual_abs_threshold,
        inout integer error_count
    );
        automatic logic has_error = 1'b0;
        automatic logic has_warning = 1'b0;
        automatic integer L1_left_error, L2_left_error;
        automatic integer L1_right_error, L2_right_error;
        automatic integer power_tolerance = 6;  // Allow ±6 dB for power values
        
        // Check left edge frequencies
        if (f1_left == expected_f1_left && f2_left == expected_f2_left) begin
            // Perfect match - no action needed
        end else if ((f1_left == expected_f1_left - 1 && f2_left == expected_f2_left - 1) ||
                    (f1_left == expected_f1_left + 1 && f2_left == expected_f2_left + 1)) begin
            // Off by 1 bin in the same direction - warning
            has_warning = 1'b1;
            $display("    WARNING: Left edge bins off by 1 (Expected: %0d,%0d Got: %0d,%0d)",
                    expected_f1_left, expected_f2_left, f1_left, f2_left);
        end else begin
            // Larger mismatch - error
            has_error = 1'b1;
            $display("    ERROR: Left edge bins mismatch (Expected: %0d,%0d Got: %0d,%0d)",
                    expected_f1_left, expected_f2_left, f1_left, f2_left);
        end
        
        // Check right edge frequencies
        if (f1_right == expected_f1_right && f2_right == expected_f2_right) begin
            // Perfect match - no action needed
        end else if ((f1_right == expected_f1_right - 1 && f2_right == expected_f2_right - 1) ||
                    (f1_right == expected_f1_right + 1 && f2_right == expected_f2_right + 1)) begin
            // Off by 1 bin in the same direction - warning
            has_warning = 1'b1;
            $display("    WARNING: Right edge bins off by 1 (Expected: %0d,%0d Got: %0d,%0d)",
                    expected_f1_right, expected_f2_right, f1_right, f2_right);
        end else begin
            // Larger mismatch - error
            has_error = 1'b1;
            $display("    ERROR: Right edge bins mismatch (Expected: %0d,%0d Got: %0d,%0d)",
                    expected_f1_right, expected_f2_right, f1_right, f2_right);
        end
        
        // Check powers (±6 dB tolerance)
        // L1_left
        if (L1_left > expected_L1_left) begin
            L1_left_error = L1_left - expected_L1_left;
        end else begin
            L1_left_error = expected_L1_left - L1_left;
        end
        if (L1_left_error > power_tolerance) begin
            has_error = 1'b1;
            $display("    ERROR: L1_left power error %0d dB (tolerance +/-%0d dB)", 
                    L1_left_error, power_tolerance);
        end else if (L1_left_error > 0) begin
            has_warning = 1'b1;
            $display("    WARNING: L1_left power error %0d dB", L1_left_error);
        end
        
        // L2_left
        if (L2_left > expected_L2_left) begin
            L2_left_error = L2_left - expected_L2_left;
        end else begin
            L2_left_error = expected_L2_left - L2_left;
        end
        if (L2_left_error > power_tolerance) begin
            has_error = 1'b1;
            $display("    ERROR: L2_left power error %0d dB (tolerance +/-%0d dB)", 
                    L2_left_error, power_tolerance);
        end else if (L2_left_error > 0) begin
            has_warning = 1'b1;
            $display("    WARNING: L2_left power error %0d dB", L2_left_error);
        end
        
        // L1_right
        if (L1_right > expected_L1_right) begin
            L1_right_error = L1_right - expected_L1_right;
        end else begin
            L1_right_error = expected_L1_right - L1_right;
        end
        if (L1_right_error > power_tolerance) begin
            has_error = 1'b1;
            $display("    ERROR: L1_right power error %0d dB (tolerance +/-%0d dB)", 
                    L1_right_error, power_tolerance);
        end else if (L1_right_error > 0) begin
            has_warning = 1'b1;
            $display("    WARNING: L1_right power error %0d dB", L1_right_error);
        end
        
        // L2_right
        if (L2_right > expected_L2_right) begin
            L2_right_error = L2_right - expected_L2_right;
        end else begin
            L2_right_error = expected_L2_right - L2_right;
        end
        if (L2_right_error > power_tolerance) begin
            has_error = 1'b1;
            $display("    ERROR: L2_right power error %0d dB (tolerance +/-%0d dB)", 
                    L2_right_error, power_tolerance);
        end else if (L2_right_error > 0) begin
            has_warning = 1'b1;
            $display("    WARNING: L2_right power error %0d dB", L2_right_error);
        end
        
        // Write to CSV
        $fwrite(csv_file, "%0d,%0d,%0d,", channel, angle, window_num);
        $fwrite(csv_file, "%0d,%0d,%0d,%0d,", expected_f1_left, expected_f2_left, expected_L1_left, expected_L2_left);
        $fwrite(csv_file, "%0d,%0d,%0d,%0d,", expected_f1_right, expected_f2_right, expected_L1_right, expected_L2_right);
        $fwrite(csv_file, "%0d,%0d,%0d,%0d,", f1_left, f2_left, L1_left, L2_left);
        $fwrite(csv_file, "%0d,%0d,%0d,%0d,", f1_right, f2_right, L1_right, L2_right);
        $fwrite(csv_file, "%0d,%0d,%0d\n", actual_abs_threshold, has_warning, has_error);
        
        // Update error count
        if (has_error) begin
            error_count++;
            $display("  RESULT: FAIL");
        end else if (has_warning) begin
            $display("  RESULT: PASS (with warnings)");
        end else begin
            $display("  RESULT: PASS");
        end
    endtask

endmodule