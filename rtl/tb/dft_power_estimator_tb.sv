module dft_power_estimator_tb();

    timeunit 1ns;
    timeprecision 1ps;

    // --- Parameters (MUST match DUT and Python generator) ---
    localparam time CLK_PERIOD = 10ns;
    localparam unsigned RST_CLK_CYCLES = 5;
    
    localparam integer IQ_WIDTH = 16;
    localparam integer IQ_WIDTH_FRAC = 14;
    localparam integer WINDOW_WIDTH = 16;
    localparam integer WINDOW_WIDTH_FRAC = 14;
    localparam integer ACCUM_WIDTH = 64;
    localparam integer ACCUM_WIDTH_FRAC = 56;
    localparam integer OSC_WIDTH = 32;
    localparam integer OSC_WIDTH_FRAC = 30;
    localparam integer PHASE_WIDTH = 32;
    localparam integer NUM_BINS = 24;
    localparam integer SAMPLE_COUNT_WIDTH = 16;
    
    // Power conversion parameters
    localparam integer POWER_INPUT_WIDTH = 32;
    localparam integer POWER_WIDTH = 8;
    localparam integer POWER_FRAC = 0;
    
    // Timing constants
    localparam integer CORDIC_LATENCY = 36;
    localparam integer WINDOWING_LATENCY = 1;
    localparam integer OSC_EARLY_START = CORDIC_LATENCY - WINDOWING_LATENCY; // 35 cycles
    
    // Maximum samples per test
    localparam integer MAX_SAMPLES = 256;

    // --- Signals ---
    logic clk;
    logic rst_n;
    logic start;
    logic sample_valid;
    logic last_sample;
    
    // Oscillator control signals
    logic osc_reset;
    logic osc_enable;
    logic osc_phase_tvalid;
    
    // Frequency steps for oscillator bank
    logic [PHASE_WIDTH-1:0] freq_steps[NUM_BINS];
    
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
    dft_power_estimator #(
        .IQ_WIDTH(IQ_WIDTH),
        .IQ_WIDTH_FRAC(IQ_WIDTH_FRAC),
        .WINDOW_WIDTH(WINDOW_WIDTH),
        .WINDOW_WIDTH_FRAC(WINDOW_WIDTH_FRAC),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ACCUM_WIDTH_FRAC(ACCUM_WIDTH_FRAC),
        .NUM_BINS(NUM_BINS),
        .OSC_WIDTH(OSC_WIDTH),
        .OSC_WIDTH_FRAC(OSC_WIDTH_FRAC),
        .PHASE_WIDTH(PHASE_WIDTH),
        .POWER_INPUT_WIDTH(POWER_INPUT_WIDTH),
        .POWER_WIDTH(POWER_WIDTH),
        .POWER_FRAC(POWER_FRAC),
        .SAMPLE_COUNT_WIDTH(SAMPLE_COUNT_WIDTH)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .start_i(start),
        .sample_valid_i(sample_valid),
        .last_sample_i(last_sample),
        .osc_reset_i(osc_reset),
        .osc_enable_i(osc_enable),
        .osc_phase_tvalid_i(osc_phase_tvalid),
        .freq_steps_i(freq_steps),
        .i_sample_i(i_sample),
        .q_sample_i(q_sample),
        .window_coeff_i(window_coeff),
        .db_power_o(act_db_power),
        .valid_o(act_valid),
        .busy_o(act_busy)
    );

    // --- Test Data Storage ---
    logic signed [IQ_WIDTH-1:0] i_samples[MAX_SAMPLES];
    logic signed [IQ_WIDTH-1:0] q_samples[MAX_SAMPLES];
    logic signed [WINDOW_WIDTH-1:0] window_coeffs[MAX_SAMPLES];
    
    logic [POWER_WIDTH-1:0] exp_db_power[NUM_BINS];

    // --- Test Sequencer and Checker ---
    initial begin: checker_block
        integer file, status;
        string line, test_name;
        integer num_samples_read, num_bins_read;
        real fs_read;
        static integer n_errs = 0;
        static integer test_count = 0;
        
        // Initialize signals
        start = 1'b0;
        sample_valid = 1'b0;
        last_sample = 1'b0;
        osc_reset = 1'b0;
        osc_enable = 1'b0;
        osc_phase_tvalid = 1'b0;
        i_sample = '0;
        q_sample = '0;
        window_coeff = '0;
        for (int k = 0; k < NUM_BINS; k++) begin
            freq_steps[k] = '0;
        end

        // Open the vector file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/dft_power_vectors.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file.");
            $finish;
        end

        $display("=== Starting DFT Power Estimator Testbench ===");
        
        // Skip header lines (23 lines based on the format)
        for (int i = 0; i < 23; i++) begin
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
            $display("=== Test Case %0d: %s ===", test_count, test_name);
            $display("========================================");
            
            // Read num_samples, num_bins, fs
            status = $fscanf(file, "%d %d %e\n", num_samples_read, num_bins_read, fs_read);
            $display("  Samples: %0d, Bins: %0d, Fs: %e Hz", num_samples_read, num_bins_read, fs_read);
            
            if (num_samples_read > MAX_SAMPLES) begin
                $display("ERROR: num_samples (%0d) exceeds MAX_SAMPLES (%0d)", 
                        num_samples_read, MAX_SAMPLES);
                $finish;
            end
            
            if (num_bins_read > NUM_BINS) begin
                $display("ERROR: num_bins (%0d) exceeds NUM_BINS (%0d)", 
                        num_bins_read, NUM_BINS);
                $finish;
            end
            
            // Read FREQ_BINS line (skip it, just reference)
            status = $fgets(line, file);
            $display("  Frequencies: %s", line);
            
            // Read FREQ_STEPS
            $display("  Frequency Steps:");
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fgets(line, file);
                status = $fscanf(file, "%h", freq_steps[k]);
                $display(" %h ", freq_steps[k]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  Frequency steps configured");
            
            status = $fgets(line, file);
            
            // Read SAMPLES keyword
            status = $fgets(line, file);
            
            // Read all sample data
            for (int n = 0; n < num_samples_read; n++) begin
                status = $fscanf(file, "%h %h %h", 
                               i_samples[n], q_samples[n], window_coeffs[n]);
                status = $fgets(line, file); // Consume newline
            end
            $display("  Loaded %0d samples", num_samples_read);
            
            // Read EXPECTED_POWER keyword
            status = $fgets(line, file);
            
            // Read expected power values (dB)
            $display("\nExpected Power Values (dB):");
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fscanf(file, "%h", exp_db_power[k]);
                status = $fgets(line, file); // Consume newline
                $display(" %02h (%0d dB)", exp_db_power[k], exp_db_power[k]);
            end
            
            // Skip GOLDEN line
            status = $fgets(line, file);
            
            // Skip blank line
            status = $fgets(line, file);
            
            // --- Drive DUT with proper timing ---
            $display("  Starting oscillator bank (35 cycles early)...");
            
            // Step 1: Reset oscillator phase accumulators
            @(posedge clk);
            #1;
            osc_reset = 1'b1;
            @(posedge clk);
            #1;
            osc_reset = 1'b0;
            
            // Step 2: Start oscillator bank (enable and phase_tvalid)
            @(posedge clk);
            #1;
            osc_enable = 1'b1;
            osc_phase_tvalid = 1'b1;
            
            // Step 3: Wait for CORDIC latency minus windowing stage (35 cycles)
            $display("  Waiting %0d cycles for CORDIC pipeline...", OSC_EARLY_START);
            repeat(OSC_EARLY_START-3) @(posedge clk);
            // -3 because start signal and first sample introduce delays

            // Step 4: Start DFT accumulation
            $display("  Starting DFT accumulation...");
            @(posedge clk);
            #1;
            start = 1'b1;
            @(posedge clk);
            #1;
            start = 1'b0;
            
            // Step 5: Stream samples
            for (int n = 0; n < num_samples_read; n++) begin
                @(posedge clk);
                #1;
                
                // Apply sample data
                sample_valid = 1'b1;
                i_sample = i_samples[n];
                q_sample = q_samples[n];
                window_coeff = window_coeffs[n];
                
                // Assert last_sample on final sample
                if (n == num_samples_read - 1) begin
                    last_sample = 1'b1;
                end
                
                if (n % 64 == 0) begin
                    $display("    Processing sample %0d/%0d...", n, num_samples_read);
                end
            end
            
            @(posedge clk);
            #1;
            sample_valid = 1'b0;
            last_sample = 1'b0;
            osc_enable = 1'b0;
            osc_phase_tvalid = 1'b0;
            
            $display("  All samples streamed, waiting for valid...");
            
            // Wait for valid signal with timeout
            fork
                begin
                    wait (act_valid);
                    $display("  Valid signal received");
                end
                begin
                    repeat(1000) @(posedge clk);
                    $display("  ERROR: Timeout waiting for valid signal");
                    n_errs++;
                end
            join_any
            disable fork;
            
            // Check results
            if (act_valid) begin
                @(posedge clk); // Let outputs settle
                check_result(num_bins_read, exp_db_power, n_errs);
            end
            
            // Wait 50 cycles before next test case
            $display("  Waiting 50 cycles before next test...");
            repeat(50) @(posedge clk);
        end

        $fclose(file);
        
        $display("\n========================================");
        $display("=== Test Summary ===");
        $display("========================================");
        if (n_errs > 0) begin
            $display("FAILED: %0d errors out of %0d test cases", n_errs, test_count);
        end else begin
            $display("PASSED: All %0d test cases passed!", test_count);
        end
        
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
        
        // Allow tolerance for rounding differences
        automatic integer tolerance = 3;  // Allow ±3 dB error
        
        $display("  Checking power results...");
        
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
                $display("    ERROR: Bin %0d power mismatch", k);
                $display("      Expected: 0x%02h (%0d dB)", expected_db_power[k], expected_db_power[k]);
                $display("      Got:      0x%02h (%0d dB)", act_db_power[k], act_db_power[k]);
                $display("      Error:    %0d dB", error_val);
                mismatch = 1'b1;
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