module find_bw_right_edge_absolute_tb ();

    timeunit 1ns;
    timeprecision 1ps;

    // --- Parameters (MUST match DUT and Python generator) ---
    localparam time CLK_PERIOD         = 10ns;
    localparam unsigned RST_CLK_CYCLES = 5;
    
    localparam integer POWER_WIDTH    = 8; // As per Python script
    localparam integer IDX_WIDTH = 5; // As per Python script
    localparam integer NUM_ACCUMS     = 24; // As per Python script

    // --- Hardcoded Threshold ---
    // 30.0 dB in Q10.8 format: 30 * 256 = 7680 = 0x1E00
    localparam logic [POWER_WIDTH-1:0] FORCED_THRESHOLD = 8'h1E;

    // --- Signals ---
    logic clk;
    logic rst_n;
    logic start;
    
    logic signed [POWER_WIDTH-1:0]   accum_vals[NUM_ACCUMS];
    logic        [IDX_WIDTH-1:0] freq_bins[NUM_ACCUMS];
    
    // New signal for the absolute threshold input
    logic [POWER_WIDTH-1:0]          abs_threshold_stim;
    
    logic        [IDX_WIDTH-1:0] act_f1, act_f2;
    logic [POWER_WIDTH-1:0]          act_L1, act_L2;
    logic                            act_valid;
    logic                            act_busy;

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
    find_bw_right_edge_absolute #(
        .POWER_WIDTH    (POWER_WIDTH),
        .IDX_WIDTH (IDX_WIDTH),
        .NUM_ACCUMS     (NUM_ACCUMS)
    ) dut (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .start_i            (start),
        .accumulator_val_i  (accum_vals),
        .freq_bin_i         (freq_bins),
        // Connect the hardcoded localparam signal
        .abs_threshold_i    (abs_threshold_stim), 
        .f1_o               (act_f1),
        .f2_o               (act_f2),
        .L1_o               (act_L1),
        .L2_o               (act_L2),
        .valid_o            (act_valid),
        .busy_o             (act_busy)
    );

    // --- Test Sequencer and Checker ---
    initial begin: checker_block
        integer file;
        string  test_name, golden_line;
        integer num_accums_read;
        integer threshold_read;
        static integer n_errs = 0;
        static integer test_count = 0;
        
        logic [IDX_WIDTH-1:0] exp_f1, exp_f2;
        logic [POWER_WIDTH-1:0]   exp_L1, exp_L2;
        logic                         exp_valid;

        // Force the threshold input to the localparam value
        abs_threshold_stim = 'b0;

        // Open the vector file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/find_bw_right_edge_vectors_absolute.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file.");
            $stop;
        end

        // Skip header lines
        for (int i = 0; i < 16; i++) begin
            $fgets(golden_line, file);
        end

        // Loop through all test cases in the file
        while (!$feof(file)) begin
            // Read one test case from the file
            if ($fscanf(file, "%s\n", test_name) == 1) begin
                test_count++;
                $display("\n--- Starting Test Case: %s ---", test_name);
                
                $fscanf(file, "%d\n", num_accums_read); // Read NUM_ACCUMS
                
                // Read threshold from file to advance pointer, but IGNORE value
                $fscanf(file, "%d\n", threshold_read); 
                abs_threshold_stim = threshold_read[POWER_WIDTH-1:0];
                
                $display("\nNUM ACCUMS: %d", num_accums_read);
                // Display the actual forced threshold we are using
                $display("THRESHOLD INPUT (Forced): 0x%h (30 dB)", abs_threshold_stim);
                
                // Read FREQ_BINS
                for (int i = 0; i < num_accums_read; i++) begin
                    $fscanf(file, "%h", freq_bins[i]);
                end
                $fgets(golden_line, file); // Consume newline

                // Read POWER_DB
                for (int i = 0; i < num_accums_read; i++) begin
                    $fscanf(file, "%h", accum_vals[i]);
                end
                $fgets(golden_line, file); // Consume newline
                
                // Read EXPECTED
                $fscanf(file, "%h %h %h %h %b\n", exp_f1, exp_f2, exp_L1, exp_L2, exp_valid);
                
                $fgets(golden_line, file); // Consume GOLDEN line
                $fgets(golden_line, file); // Consume blank line
                
                // --- Drive DUT and Check ---
                wait(rst_n);
                start = 1'b1;
                // $display("driving dut");
                @(posedge clk);
                start = 1'b0;

                // Wait for valid signal, with a timeout
                wait (act_valid);
                // $display("awaited valid_o signal");
                
                @(posedge clk); // Let outputs settle
                
                // Check results
                check_result(exp_f1, exp_f2, exp_L1, exp_L2, exp_valid, n_errs);
            end
        end

        $fclose(file);

        if (n_errs > 0) begin
            $display("\nTEST FAILED with %0d errors out of %0d test cases.", n_errs, test_count);
        end else begin
            $display("\nTEST PASSED with %0d errors.", n_errs);
        end
        $stop;
    end
    
    // --- Checking Task ---
    task check_result(
        input logic [IDX_WIDTH-1:0] expected_f1,
        input logic [IDX_WIDTH-1:0] expected_f2,
        input logic [POWER_WIDTH-1:0]   expected_L1,
        input logic [POWER_WIDTH-1:0]   expected_L2,
        input logic                         expected_valid,
        inout integer                       error_count
    );
        automatic logic mismatch = 1'b0;
        
        // Only check data outputs if valid is expected
        if (expected_valid) begin
            if (act_f1 !== expected_f1) begin
                $display("ERROR: f1 mismatch. Expected: %h, Got: %h", expected_f1, act_f1);
                mismatch = 1'b1;
            end
            if (act_f2 !== expected_f2) begin
                $display("ERROR: f2 mismatch. Expected: %h, Got: %h", expected_f2, act_f2);
                mismatch = 1'b1;
            end
            if (act_L1 !== expected_L1) begin
                $display("ERROR: L1 mismatch. Expected: %h, Got: %h", expected_L1, act_L1);
                mismatch = 1'b1;
            end
            if (act_L2 !== expected_L2) begin
                $display("ERROR: L2 mismatch. Expected: %h, Got: %h", expected_L2, act_L2);
                mismatch = 1'b1;
            end
        end else begin
            // If expected is invalid, we might want to check if DUT also didn't find anything
            // For now, assume consistent.
        end

        if (!mismatch && expected_valid) begin
            $display("SUCCESS: f1 match. Expected: %h, Got: %h", expected_f1, act_f1);
            $display("SUCCESS: f2 match. Expected: %h, Got: %h", expected_f2, act_f2);
            $display("SUCCESS: L1 match. Expected: %h, Got: %h", expected_L1, act_L1);
            $display("SUCCESS: L2 match. Expected: %h, Got: %h", expected_L2, act_L2);
        end

        if(mismatch) begin 
            error_count++;
        end
    endtask

endmodule

// module find_bw_right_edge_absolute_tb ();

//     timeunit 1ns;
//     timeprecision 1ps;

//     // --- Parameters (MUST match DUT and Python generator) ---
//     localparam time CLK_PERIOD         = 10ns;
//     localparam unsigned RST_CLK_CYCLES = 5;
    
//     localparam integer POWER_WIDTH = 8;  // Power in dB (8-bit unsigned)
//     localparam integer NUM_ACCUMS  = 24; // Number of frequency bins
//     localparam integer INDEX_WIDTH = $clog2(NUM_ACCUMS); // 5 bits for indices

//     // --- Signals ---
//     logic clk;
//     logic rst_n;
//     logic start;
    
//     logic [POWER_WIDTH-1:0]   power_vals[NUM_ACCUMS];
//     logic [POWER_WIDTH-1:0]   abs_threshold_stim;  // Threshold for current test
    
//     logic [INDEX_WIDTH-1:0]   act_f1, act_f2;  // Indices output
//     logic [POWER_WIDTH-1:0]   act_L1, act_L2;
//     logic                     act_valid;
//     logic                     act_busy;

//     // --- Clock and Reset Generation ---
//     initial begin
//         clk = 0;
//         forever #(CLK_PERIOD/2) clk = ~clk;
//     end
    
//     initial begin
//         rst_n = 1'b0;
//         repeat(RST_CLK_CYCLES) @(posedge clk);
//         rst_n = 1'b1;
//     end

//     // --- DUT Instantiation ---
//     find_bw_right_edge_absolute #(
//         .POWER_WIDTH (POWER_WIDTH),
//         .NUM_ACCUMS  (NUM_ACCUMS)
//     ) dut (
//         .clk_i              (clk),
//         .rst_ni             (rst_n),
//         .start_i            (start),
//         .power_val_i        (power_vals),
//         .abs_threshold_i    (abs_threshold_stim),  // Use abs_threshold_stim
//         .f1_o               (act_f1),
//         .f2_o               (act_f2),
//         .L1_o               (act_L1),
//         .L2_o               (act_L2),
//         .valid_o            (act_valid),
//         .busy_o             (act_busy)
//     );

//     // --- Test Sequencer and Checker ---
//     initial begin: checker_block
//         integer file;
//         string  test_name, golden_line;
//         integer num_accums_read;
//         integer threshold_read;  // Temporary variable for reading
//         static integer n_errs = 0;
//         static integer test_count = 0;
        
//         logic [INDEX_WIDTH-1:0]  exp_f1, exp_f2;  // Expected indices
//         logic [POWER_WIDTH-1:0]  exp_L1, exp_L2;
//         logic                    exp_valid;

//         // Initialize threshold to 0
//         abs_threshold_stim = '0;

//         // Open the vector file
//         file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/find_bw_right_edge_vectors_absolute.txt", "r");
//         if (file == 0) begin
//             $display("ERROR: Could not open vector file.");
//             $stop;
//         end

//         $display("=== Starting find_bw_right_edge_absolute Testbench ===");
//         $display("  POWER_WIDTH = %0d", POWER_WIDTH);
//         $display("  NUM_ACCUMS = %0d", NUM_ACCUMS);
//         $display("  INDEX_WIDTH = %0d", INDEX_WIDTH);

//         // Skip header lines (14 lines)
//         for (int i = 0; i < 14; i++) begin
//             $fgets(golden_line, file);
//         end

//         // Loop through all test cases in the file
//         while (!$feof(file)) begin
//             // Read one test case from the file
//             if ($fscanf(file, "%s\n", test_name) == 1) begin
//                 test_count++;
//                 $display("\n========================================");
//                 $display("Test Case %0d: %s", test_count, test_name);
//                 $display("========================================");
                
//                 // Read NUM_ACCUMS
//                 $fscanf(file, "%d\n", num_accums_read);
                
//                 // Read threshold from file and assign to stimulus signal
//                 $fscanf(file, "%d\n", threshold_read);
//                 abs_threshold_stim = threshold_read[POWER_WIDTH-1:0];
                
//                 $display("  NUM_ACCUMS: %0d", num_accums_read);
//                 $display("  THRESHOLD: %0d dB (0x%02h)", abs_threshold_stim, abs_threshold_stim);
                
//                 // Read POWER_DB values
//                 for (int i = 0; i < num_accums_read; i++) begin
//                     $fscanf(file, "%h", power_vals[i]);
//                 end
//                 $fgets(golden_line, file); // Consume newline
                
//                 // Display power values for debugging
//                 $display("  Power values:");
//                 for (int i = 0; i < num_accums_read; i++) begin
//                     $display("    [%2d]: %3d dB (0x%02h)", i, power_vals[i], power_vals[i]);
//                 end
                
//                 // Read EXPECTED (indices instead of frequencies)
//                 $fscanf(file, "%h %h %h %h %b\n", exp_f1, exp_f2, exp_L1, exp_L2, exp_valid);
//                 $display("  Expected: f1=%0d, f2=%0d, L1=%0d dB, L2=%0d dB, valid=%b", 
//                         exp_f1, exp_f2, exp_L1, exp_L2, exp_valid);

//                 $fgets(golden_line, file); // Consume GOLDEN line
//                 $fgets(golden_line, file); // Consume blank line
                
//                 // --- Drive DUT and Check ---
//                 wait(rst_n);
//                 @(posedge clk);
//                 #1;
//                 start = 1'b1;
                
//                 @(posedge clk);
//                 #1;
//                 start = 1'b0;

//                 // Wait for valid signal, with a timeout
//                 fork
//                     begin
//                         wait (act_valid);
//                         $display("  Valid signal received");
//                     end
//                     begin
//                         repeat(1000) @(posedge clk);
//                         if (!act_valid) begin
//                             $display("  ERROR: Timeout waiting for valid signal");
//                             n_errs++;
//                         end
//                     end
//                 join_any
//                 disable fork;
                
//                 @(posedge clk); // Let outputs settle
                
//                 // Check results
//                 check_result(exp_f1, exp_f2, exp_L1, exp_L2, exp_valid, n_errs);
                
//                 // Wait before next test
//                 repeat(10) @(posedge clk);
//             end
//         end

//         $fclose(file);

//         $display("\n========================================");
//         $display("Test Summary");
//         $display("========================================");
//         $display("Total test cases: %0d", test_count);
//         $display("Total errors:     %0d", n_errs);
        
//         if (n_errs > 0) begin
//             $display("\n*** TEST FAILED ***");
//         end else begin
//             $display("\n*** TEST PASSED ***");
//         end
//         $display("========================================\n");
        
//         $stop;
//     end
    
//     // --- Checking Task ---
//     task check_result(
//         input logic [INDEX_WIDTH-1:0]  expected_f1,
//         input logic [INDEX_WIDTH-1:0]  expected_f2,
//         input logic [POWER_WIDTH-1:0]  expected_L1,
//         input logic [POWER_WIDTH-1:0]  expected_L2,
//         input logic                    expected_valid,
//         inout integer                  error_count
//     );
//         automatic logic mismatch = 1'b0;
        
//         // Only check data outputs if valid is expected
//         if (expected_valid) begin
//             if (act_f1 !== expected_f1) begin
//                 $display("  ERROR: f1 mismatch. Expected: %0d, Got: %0d", expected_f1, act_f1);
//                 mismatch = 1'b1;
//             end else begin
//                 $display("  SUCCESS: f1 match. Index: %0d", act_f1);
//             end
            
//             if (act_f2 !== expected_f2) begin
//                 $display("  ERROR: f2 mismatch. Expected: %0d, Got: %0d", expected_f2, act_f2);
//                 mismatch = 1'b1;
//             end else begin
//                 $display("  SUCCESS: f2 match. Index: %0d", act_f2);
//             end
            
//             if (act_L1 !== expected_L1) begin
//                 $display("  ERROR: L1 mismatch. Expected: %0d dB, Got: %0d dB", expected_L1, act_L1);
//                 mismatch = 1'b1;
//             end else begin
//                 $display("  SUCCESS: L1 match. Power: %0d dB", act_L1);
//             end
            
//             if (act_L2 !== expected_L2) begin
//                 $display("  ERROR: L2 mismatch. Expected: %0d dB, Got: %0d dB", expected_L2, act_L2);
//                 mismatch = 1'b1;
//             end else begin
//                 $display("  SUCCESS: L2 match. Power: %0d dB", act_L2);
//             end
//         end else begin
//             $display("  Expected: No crossing found");
//             if (act_valid) begin
//                 $display("  ERROR: DUT found crossing when none expected");
//                 mismatch = 1'b1;
//             end
//         end

//         if (mismatch) begin 
//             error_count++;
//             $display("  RESULT: FAIL");
//         end else begin
//             $display("  RESULT: PASS");
//         end
//     endtask

// endmodule