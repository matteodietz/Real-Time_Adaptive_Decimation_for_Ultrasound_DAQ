////////////////////////////////////////////////////////////////////////////////
//
//  Testbench: simplified_dft_timing_wrapper_tb
//
//  Description:
//      Tests the simplified_dft_timing_wrapper module which integrates
//      the timing controller with DFT accumulation. This testbench streams
//      all samples (padding + signal) continuously and lets the timing
//      controller handle when to start the DFT window.
//
////////////////////////////////////////////////////////////////////////////////

module simplified_dft_timing_wrapper_tb ();

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
    localparam integer COUNTER_WIDTH = 16;
    localparam integer SAMPLE_COUNT_WIDTH = 16;
    
    // Maximum window size
    localparam integer MAX_WINDOW_SIZE = 8;
    
    // Maximum total samples (padding + signal)
    localparam integer MAX_SAMPLES = 512;

    // --- Signals ---
    logic clk;
    logic rst_n;
    
    // Control signals
    logic enable;
    logic clear;
    logic [COUNTER_WIDTH-1:0] delay_cycles;
    
    // Configuration
    logic [PHASE_WIDTH-1:0] freq_steps[NUM_BINS];
    
    // Data input
    logic sample_valid;
    logic signed [IQ_WIDTH-1:0] i_sample;
    logic signed [IQ_WIDTH-1:0] q_sample;
    logic signed [WINDOW_WIDTH-1:0] window_coeff;
    
    // Outputs
    logic signed [ACCUM_WIDTH-1:0] act_A_real[NUM_BINS];
    logic signed [ACCUM_WIDTH-1:0] act_A_imag[NUM_BINS];
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
    simplified_dft_timing_wrapper #(
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
        .WINDOW_SIZE(MAX_WINDOW_SIZE),
        .OSC_LATENCY(35),
        .COUNTER_WIDTH(COUNTER_WIDTH),
        .SAMPLE_COUNT_WIDTH(SAMPLE_COUNT_WIDTH)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .enable_i(enable),
        .clear_i(clear),
        .delay_cycles_i(delay_cycles),
        .freq_steps_i(freq_steps),
        .sample_valid_i(sample_valid),
        .i_sample_i(i_sample),
        .q_sample_i(q_sample),
        .window_coeff_i(window_coeff),
        .A_real_o(act_A_real),
        .A_imag_o(act_A_imag),
        .valid_o(act_valid),
        .busy_o(act_busy)
    );

    // --- Test Data Storage ---
    logic signed [IQ_WIDTH-1:0] i_samples[MAX_SAMPLES];
    logic signed [IQ_WIDTH-1:0] q_samples[MAX_SAMPLES];
    logic signed [WINDOW_WIDTH-1:0] window_coeffs[MAX_SAMPLES];
    
    logic signed [ACCUM_WIDTH-1:0] exp_A_real[NUM_BINS];
    logic signed [ACCUM_WIDTH-1:0] exp_A_imag[NUM_BINS];

    // --- Test Sequencer and Checker ---
    initial begin: checker_block
        integer file, status;
        string line, test_name;
        integer num_samples_read, num_bins_read, window_size_read;
        integer delay_cycles_read, osc_latency_read;
        static integer n_errs = 0;
        static integer test_count = 0;
        logic valid_captured;
        
        // Initialize signals
        enable = 1'b0;
        clear = 1'b0;
        delay_cycles = '0;
        sample_valid = 1'b0;
        i_sample = '0;
        q_sample = '0;
        window_coeff = '0;
        for (int k = 0; k < NUM_BINS; k++) begin
            freq_steps[k] = '0;
        end

        // Open the vector file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/simplified_dft_timing_vectors.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file.");
            $finish;
        end

        $display("=== Starting Simplified DFT Timing Wrapper Testbench ===");
        
        // Skip header lines (22 lines)
        for (int i = 0; i < 22; i++) begin
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
            
            // Read: num_bins num_samples window_size delay_cycles osc_latency
            status = $fscanf(file, "%d %d %d %d %d\n", 
                           num_bins_read, num_samples_read, window_size_read,
                           delay_cycles_read, osc_latency_read);
            $display("  Bins: %0d, Total Samples: %0d, Window Size: %0d", 
                    num_bins_read, num_samples_read, window_size_read);
            $display("  Delay Cycles: %0d, OSC Latency: %0d", 
                    delay_cycles_read, osc_latency_read);
            
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
            
            if (window_size_read > MAX_WINDOW_SIZE) begin
                $display("ERROR: window_size (%0d) exceeds MAX_WINDOW_SIZE (%0d)", 
                        window_size_read, MAX_WINDOW_SIZE);
                $finish;
            end
            
            // Read frequency steps (newline separated)
            $display("  Reading frequency steps...");
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fscanf(file, "%h\n", freq_steps[k]);
            end
            $display("  Frequency steps configured");
            
            // Read window coefficients (space-separated, one line)
            $display("  Reading window coefficients...");
            for (int n = 0; n < num_samples_read; n++) begin
                status = $fscanf(file, "%h", window_coeffs[n]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  Window coefficients loaded");
            
            // Read I samples (space-separated, one line)
            $display("  Reading I samples...");
            for (int n = 0; n < num_samples_read; n++) begin
                status = $fscanf(file, "%h", i_samples[n]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  I samples loaded");
            
            // Read Q samples (space-separated, one line)
            $display("  Reading Q samples...");
            for (int n = 0; n < num_samples_read; n++) begin
                status = $fscanf(file, "%h", q_samples[n]);
            end
            status = $fgets(line, file); // Consume newline
            $display("  Q samples loaded");
            $display("  Total %0d samples loaded (padding + signal)", num_samples_read);
            
            // Read expected A_real values (newline separated)
            $display("  Reading expected A_real...");
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fscanf(file, "%h\n", exp_A_real[k]);
            end
            
            // Read expected A_imag values (newline separated)
            $display("  Reading expected A_imag...");
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fscanf(file, "%h\n", exp_A_imag[k]);
            end
            
            // Skip blank line
            // status = $fgets(line, file);
            
            // --- Drive DUT with timing controller ---
            $display("\n  Configuring timing controller...");
            $display("    delay_cycles = %0d", delay_cycles_read);
            
            // Set delay_cycles
            delay_cycles = delay_cycles_read;
            
            // Assert enable and clear to start timing sequence
            @(posedge clk);
            #1;
            enable = 1'b1;
            clear = 1'b1;
            
            @(posedge clk);
            #1;
            clear = 1'b0;
            
            $display("  Timing controller started, streaming samples...");
            
            // Stream all samples continuously (padding + signal)
            // The timing controller will automatically:
            //   1. Reset oscillators at the right time
            //   2. Start oscillators early
            //   3. Start DFT at delay_cycles
            //   4. Gate sample_valid during DFT window
            //   5. Assert last_sample at the end
            
            valid_captured = 1'b0;
            
            for (int n = 0; n < num_samples_read; n++) begin
                @(posedge clk);
                #1;
                
                // Stream sample
                sample_valid = 1'b1;
                i_sample = i_samples[n];
                q_sample = q_samples[n];
                window_coeff = window_coeffs[n];
                
                // Check if valid has been asserted during streaming
                if (act_valid && !valid_captured) begin
                    $display("  Valid signal received at sample %0d", n);
                    valid_captured = 1'b1;
                    
                    // Check results immediately
                    @(posedge clk); // Let outputs settle
                    check_result(num_bins_read, exp_A_real, exp_A_imag, n_errs);
                    
                    // Can break early since result is captured
                    break;
                end
                
                if (n % 16 == 0) begin
                    $display("    Streaming sample %0d/%0d...", n, num_samples_read);
                end
            end
            
            // Deassert sample_valid
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
                    check_result(num_bins_read, exp_A_real, exp_A_imag, n_errs);
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
        input logic signed [ACCUM_WIDTH-1:0] expected_A_real[NUM_BINS],
        input logic signed [ACCUM_WIDTH-1:0] expected_A_imag[NUM_BINS],
        inout integer error_count
    );
        automatic logic mismatch = 1'b0;
        automatic longint max_error_real = 0;
        automatic longint max_error_imag = 0;
        automatic longint error_real, error_imag;
        automatic real error_real_float, error_imag_float;
        
        // Define tolerance (adjust based on expected quantization error)
        automatic longint tolerance = 2; // Allow ±2 LSBs of error
        
        $display("  Checking results...");
        
        for (int k = 0; k < num_bins; k++) begin
            // Calculate absolute errors
            if (act_A_real[k] > expected_A_real[k]) begin
                error_real = act_A_real[k] - expected_A_real[k];
            end else begin
                error_real = expected_A_real[k] - act_A_real[k];
            end
            
            if (act_A_imag[k] > expected_A_imag[k]) begin
                error_imag = act_A_imag[k] - expected_A_imag[k];
            end else begin
                error_imag = expected_A_imag[k] - act_A_imag[k];
            end
            
            // Track maximum error
            if (error_real > max_error_real) max_error_real = error_real;
            if (error_imag > max_error_imag) max_error_imag = error_imag;
            
            // Convert errors to floating point for display
            error_real_float = $itor(longint'(error_real)) / (2.0**ACCUM_WIDTH_FRAC);
            error_imag_float = $itor(longint'(error_imag)) / (2.0**ACCUM_WIDTH_FRAC);
            
            // Check against tolerance
            if (error_real > tolerance || error_imag > tolerance) begin
                $display("    ERROR: Bin %0d mismatch", k);
                $display("      A_real: Expected=%016h, Got=%016h, Error=%f", 
                        expected_A_real[k], act_A_real[k], error_real_float);
                $display("      A_imag: Expected=%016h, Got=%016h, Error=%f", 
                        expected_A_imag[k], act_A_imag[k], error_imag_float);
                mismatch = 1'b1;
            end else begin
                $display("    SUCCESS: Bin %0d matches (within tolerance)", k);
                $display("      A_real: Expected=%016h, Got=%016h, Error=%f", 
                        expected_A_real[k], act_A_real[k], error_real_float);
                $display("      A_imag: Expected=%016h, Got=%016h, Error=%f", 
                        expected_A_imag[k], act_A_imag[k], error_imag_float);
            end
        end
        
        if (mismatch) begin
            error_count++;
            $display("  RESULT: FAIL");
        end else begin
            $display("  RESULT: PASS");
        end
        
        $display("    Max error: Real=%f, Imag=%f", 
                 $itor(longint'(max_error_real)) / (2.0**ACCUM_WIDTH_FRAC),
                 $itor(longint'(max_error_imag)) / (2.0**ACCUM_WIDTH_FRAC));
    endtask

endmodule