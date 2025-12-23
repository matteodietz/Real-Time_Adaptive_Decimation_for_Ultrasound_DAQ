module dft_accumulation_cordic_tmux_tb ();

    timeunit 1ns;
    timeprecision 1ps;

    // --- Parameters (MUST match DUT and Python generator) ---
    localparam time CLK_PERIOD = 10ns;
    localparam unsigned RST_CLK_CYCLES = 5;
    
    localparam integer IQ_WIDTH = 16;
    localparam integer IQ_WIDTH_FRAC = 14;
    localparam integer WINDOW_WIDTH = 16;
    localparam integer WINDOW_WIDTH_FRAC = 14;
    localparam integer ACCUM_WIDTH = 40;
    localparam integer ACCUM_WIDTH_FRAC = 32;
    localparam integer OSC_WIDTH = 16;  //24
    localparam integer OSC_WIDTH_FRAC = 14;  //22
    localparam integer PHASE_WIDTH = 16; //24
    localparam integer NUM_BINS = 24;
    localparam integer SAMPLE_COUNT_WIDTH = 16;
    localparam integer COUNTER_WIDTH = 5;
    localparam integer STAGE1_WIDTH = 24;
    
    // Timing constants
    localparam integer CORDIC_LATENCY = 20; 
    localparam integer WINDOWING_LATENCY = 1;
    localparam integer CYCLES_PER_SAMPLE = 12;  // NUM_BINS/2 - counter cycles per sample
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
    
    logic signed [ACCUM_WIDTH-1:0] act_A_real[NUM_BINS]; // accum_width-1
    logic signed [ACCUM_WIDTH-1:0] act_A_imag[NUM_BINS]; // accum_width-1
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
    dft_accumulation_cordic_tmux #(
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
        .SAMPLE_COUNT_WIDTH(SAMPLE_COUNT_WIDTH),
        .COUNTER_WIDTH(COUNTER_WIDTH),
        .STAGE1_WIDTH(STAGE1_WIDTH)
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
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/dft_cordic_vectors.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file.");
            $finish;
        end

        $display("=== Starting DFT Accumulation with CORDIC Time-Multiplexed Testbench ===");
        
        // Skip header lines
        for (int i = 0; i < 21; i++) begin
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
            
            // Read FREQ_STEPS line
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
            
            // Read EXPECTED keyword
            status = $fgets(line, file);
            
            // Read expected A_real values
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fscanf(file, "%h", exp_A_real[k]);
                status = $fgets(line, file); // Consume newline
            end
            
            // Read expected A_imag values
            for (int k = 0; k < num_bins_read; k++) begin
                status = $fscanf(file, "%h", exp_A_imag[k]);
                status = $fgets(line, file); // Consume newline
            end
            
            // Skip GOLDEN line
            status = $fgets(line, file);
            
            // Skip blank line
            status = $fgets(line, file);
            
            // --- Drive DUT with proper timing ---
            $display("  Starting oscillator bank (35 cycles early)...");
            
            // Step 1: Reset oscillator phase accumulators
            @(posedge clk);
            @(negedge clk);
            osc_reset = 1'b1;
            @(negedge clk);
            osc_reset = 1'b0;
            
            // Step 2: Start oscillator bank (enable and phase_tvalid)
            @(negedge clk);
            osc_enable = 1'b1;
            osc_phase_tvalid = 1'b1;
            
            // Step 3: Wait for CORDIC latency minus windowing stage (35 cycles)
            $display("  Waiting %0d cycles for CORDIC pipeline...", OSC_EARLY_START);
            // repeat(OSC_EARLY_START-3) @(posedge clk);
            // -3 adjustment for timing (same as non-tmux version)
            repeat(CORDIC_LATENCY - 4) @(posedge clk);

            // Step 4: Start DFT accumulation
            $display("  Starting DFT accumulation...");
            @(posedge clk);
            @(negedge clk);
            start = 1'b1;
            // sample_valid = 1'b1;
             @(negedge clk);
             start = 1'b0;
            
            // Step 5: Stream samples (each held for 12 cycles)
            $display("  Streaming samples (each held for %0d cycles)...", CYCLES_PER_SAMPLE);
            for (int n = 0; n < num_samples_read; n++) begin
                // Wait for counter to wrap to 0 (ready for new sample)
                // In the module, samples are accepted when tmux_counter == 0

                
                // @(posedge clk);
                #1;
                
                // Set up sample data
                i_sample = i_samples[n];
                q_sample = q_samples[n];
                window_coeff = window_coeffs[n];

                @(negedge clk);
                sample_valid = 1'b1;
                
                // Assert last_sample on final sample
                if (n == num_samples_read - 1) begin
                    last_sample = 1'b1;
                end else begin
                    last_sample = 1'b0;
                end

                // @(negedge clk);
                // start = 1'b0;
                
                // Hold sample for 12 cycles while counter cycles through bins
                repeat(CYCLES_PER_SAMPLE) @(posedge clk);
                
                if (n % 16 == 0) begin
                    $display("    Processing sample %0d/%0d...", n, num_samples_read);
                end
            end
            
            // Deassert control signals
            @(posedge clk);
            @(negedge clk);
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
                    repeat(2000) @(posedge clk);
                    $display("  ERROR: Timeout waiting for valid signal");
                    n_errs++;
                end
            join_any
            disable fork;
            
            // Check results
            if (act_valid) begin
                @(posedge clk); // Let outputs settle
                check_result(num_bins_read, exp_A_real, exp_A_imag, n_errs);
            end
            
            // Wait before next test case
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
        input logic signed [ACCUM_WIDTH-1:0] expected_A_real[NUM_BINS], //accum_width-1
        input logic signed [ACCUM_WIDTH-1:0] expected_A_imag[NUM_BINS], //accum_width-1
        inout integer error_count
    );
        automatic logic mismatch = 1'b0;
        automatic longint max_error_real = 0;
        automatic longint max_error_imag = 0;
        automatic longint error_real, error_imag;
        automatic real error_real_float, error_imag_float;
        
        // automatic longint tolerance = 2; // Allow +/-2 LSBs of error
        automatic real tolerance_float = 0.001; // Allow +/-10^-3 error
        
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
            error_real_float = $itor(longint'(error_real)) / (2.0**ACCUM_WIDTH_FRAC); //**ACCUM_WIDTH_FRAC
            error_imag_float = $itor(longint'(error_imag)) / (2.0**ACCUM_WIDTH_FRAC); //**ACCUM_WIDTH_FRAC
            
            // Check against tolerance
            if (error_real_float > tolerance_float || error_imag_float > tolerance_float) begin
                $display("    ERROR: Bin %0d mismatch", k);
                $display("      A_real: Expected=%012h, Got=%012h, Error=%f", 
                        expected_A_real[k], act_A_real[k], error_real_float);
                $display("      A_imag: Expected=%012h, Got=%012h, Error=%f", 
                        expected_A_imag[k], act_A_imag[k], error_imag_float);
                mismatch = 1'b1;
            end else begin
                $display("    SUCCESS: Bin %0d matches (within tolerance)", k);
                $display("      A_real: Expected=%012h, Got=%012h, Error=%f", 
                        expected_A_real[k], act_A_real[k], error_real_float);
                $display("      A_imag: Expected=%012h, Got=%012h, Error=%f", 
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
                 $itor(longint'(max_error_real)) / (2.0**ACCUM_WIDTH_FRAC), //**ACCUM_WIDTH_FRAC
                 $itor(longint'(max_error_imag)) / (2.0**ACCUM_WIDTH_FRAC)); //**ACCUM_WIDTH_FRAC
    endtask

endmodule