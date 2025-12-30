module bandwidth_edge_detector_tb();

    timeunit 1ns;
    timeprecision 1ps;

    // --- Parameters (MUST match DUT and Python generator) ---
    localparam time CLK_PERIOD         = 10ns;
    localparam unsigned RST_CLK_CYCLES = 5;
    
    // Parameters matching the stimulus generator
    localparam integer POWER_WIDTH     = 8;   // Q8.0
    localparam integer POWER_FRAC      = 0;
    localparam integer FREQ_BIN_WIDTH  = 5;  // Q4.12
    localparam integer NUM_BINS        = 24;
    localparam logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 8'h1E; // 30 dB

    // --- Signals ---
    logic clk;
    logic rst_n;
    logic valid_i;
    
    logic [POWER_WIDTH-1:0]     db_power[NUM_BINS];
    logic [FREQ_BIN_WIDTH-1:0]  freq_bins[NUM_BINS];
    
    // Left edge outputs
    logic [FREQ_BIN_WIDTH-1:0]  act_f1_left;
    logic [FREQ_BIN_WIDTH-1:0]  act_f2_left;
    logic [POWER_WIDTH-1:0]     act_L1_left;
    logic [POWER_WIDTH-1:0]     act_L2_left;
    
    // Right edge outputs
    logic [FREQ_BIN_WIDTH-1:0]  act_f1_right;
    logic [FREQ_BIN_WIDTH-1:0]  act_f2_right;
    logic [POWER_WIDTH-1:0]     act_L1_right;
    logic [POWER_WIDTH-1:0]     act_L2_right;
    
    // Status signals
    logic                       act_valid;
    logic                       act_threshold_ok;
    logic                       act_busy;

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
    bandwidth_edge_detector #(
        .POWER_WIDTH     (POWER_WIDTH),
        .POWER_FRAC      (POWER_FRAC),
        .THRESHOLD_DROP  (THRESHOLD_DROP),
        .FREQ_BIN_WIDTH  (FREQ_BIN_WIDTH),
        .NUM_BINS        (NUM_BINS)
    ) dut (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .valid_i            (valid_i),
        .db_power_i         (db_power),
        .freq_bin_i         (freq_bins),
        // Left edge outputs
        .f1_left_o          (act_f1_left),
        .f2_left_o          (act_f2_left),
        .L1_left_o          (act_L1_left),
        .L2_left_o          (act_L2_left),
        // Right edge outputs
        .f1_right_o         (act_f1_right),
        .f2_right_o         (act_f2_right),
        .L1_right_o         (act_L1_right),
        .L2_right_o         (act_L2_right),
        // Status outputs
        .valid_o            (act_valid),
        .threshold_ok_o     (act_threshold_ok),
        .busy_o             (act_busy)
    );

    // --- Test Sequencer and Checker ---
    initial begin: checker_block
        integer file;
        string  test_name, line_buffer;
        integer num_bins_read;
        static integer n_errs = 0;
        static integer test_count = 0;
        
        // Expected outputs
        logic [FREQ_BIN_WIDTH-1:0] exp_f1_left, exp_f2_left;
        logic [POWER_WIDTH-1:0]    exp_L1_left, exp_L2_left;
        logic [FREQ_BIN_WIDTH-1:0] exp_f1_right, exp_f2_right;
        logic [POWER_WIDTH-1:0]    exp_L1_right, exp_L2_right;
        logic                      exp_valid;
        
        integer timeout_counter;
        localparam integer TIMEOUT_CYCLES = 1000;

        // Initialize control signals at negedge to avoid race conditions
        @(negedge clk);
        valid_i = 1'b0;
        
        // Open the vector file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/edge_detector_vectors.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file.");
            $stop;
        end

        // Skip header lines
        for (int i = 0; i < 14; i++) begin
            $fgets(line_buffer, file);
        end

        // Loop through all test cases in the file
        while (!$feof(file)) begin
            // Try to read test name
            if ($fscanf(file, "%s\n", test_name) == 1) begin
                test_count++;
                $display("\n========================================");
                $display("Test Case %0d: %s", test_count, test_name);
                $display("========================================");
                
                // Read NUM_BINS
                if ($fscanf(file, "%d\n", num_bins_read) != 1) begin
                    $display("ERROR: Failed to read NUM_BINS");
                    break;
                end
                
                if (num_bins_read != NUM_BINS) begin
                    $display("ERROR: NUM_BINS mismatch. Expected: %0d, Got: %0d", 
                             NUM_BINS, num_bins_read);
                    n_errs++;
                    break;
                end
                
                $display("NUM_BINS: %0d", num_bins_read);
                
                // Read FREQ_BINS
                for (int i = 0; i < num_bins_read; i++) begin
                    if ($fscanf(file, "%h", freq_bins[i]) != 1) begin
                        $display("ERROR: Failed to read freq_bin[%0d]", i);
                        break;
                    end
                end
                $fgets(line_buffer, file); // Consume newline
                
                // Read POWER_VALS
                for (int i = 0; i < num_bins_read; i++) begin
                    if ($fscanf(file, "%h", db_power[i]) != 1) begin
                        $display("ERROR: Failed to read db_power[%0d]", i);
                        break;
                    end
                end
                $fgets(line_buffer, file); // Consume newline
                
                // Read EXPECTED_VALID
                if ($fscanf(file, "%b\n", exp_valid) != 1) begin
                    $display("ERROR: Failed to read expected valid");
                    break;
                end
                
                // Read EXPECTED_LEFT (f1 f2 L1 L2)
                if ($fscanf(file, "%h %h %h %h\n", 
                           exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left) != 4) begin
                    $display("ERROR: Failed to read expected left edge");
                    break;
                end
                
                // Read EXPECTED_RIGHT (f1 f2 L1 L2)
                if ($fscanf(file, "%h %h %h %h\n", 
                           exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right) != 4) begin
                    $display("ERROR: Failed to read expected right edge");
                    break;
                end
                
                // --- Drive DUT and Check ---
                wait(rst_n);
                
                // Set valid_i at negedge to avoid race conditions
                @(negedge clk);
                valid_i = 1'b1;
                $display("Driving DUT with valid_i=1");
                
                @(negedge clk);
                valid_i = 1'b0;
                $display("Deasserted valid_i");
                
                // Wait for valid_o with timeout
                timeout_counter = 0;
                while (!act_valid && timeout_counter < TIMEOUT_CYCLES) begin
                    @(posedge clk);
                    timeout_counter++;
                end
                
                if (timeout_counter >= TIMEOUT_CYCLES) begin
                    $display("ERROR: Timeout waiting for valid_o");
                    n_errs++;
                    continue;
                end
                
                $display("Received valid_o after %0d cycles", timeout_counter);
                
                // Sample outputs immediately when valid_o is high (don't wait!)
                // Check results NOW while valid is still asserted
                check_result(
                    exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left,
                    exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right,
                    exp_valid, n_errs
                );
                
                // Wait a few cycles before next test
                repeat(3) @(posedge clk);
            end
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
        
        $stop;
    end
    
    // --- Checking Task ---
    task check_result(
        input logic [FREQ_BIN_WIDTH-1:0] expected_f1_left,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f2_left,
        input logic [POWER_WIDTH-1:0]    expected_L1_left,
        input logic [POWER_WIDTH-1:0]    expected_L2_left,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f1_right,
        input logic [FREQ_BIN_WIDTH-1:0] expected_f2_right,
        input logic [POWER_WIDTH-1:0]    expected_L1_right,
        input logic [POWER_WIDTH-1:0]    expected_L2_right,
        input logic                       expected_valid,
        inout integer                     error_count
    );
        automatic logic mismatch = 1'b0;
        
        $display("\n--- Checking Results ---");
        
        // Check valid signal
        if (act_valid !== expected_valid) begin
            $display("ERROR: valid mismatch. Expected: %b, Got: %b", 
                     expected_valid, act_valid);
            mismatch = 1'b1;
        end else begin
            $display("OK: valid = %b", act_valid);
        end
        
        // Check left edge
        $display("\nLeft Edge:");
        if (act_f1_left !== expected_f1_left) begin
            $display("  ERROR: f1_left mismatch. Expected: 0x%h, Got: 0x%h", 
                     expected_f1_left, act_f1_left);
            mismatch = 1'b1;
        end else begin
            $display("  OK: f1_left = 0x%h", act_f1_left);
        end
        
        if (act_f2_left !== expected_f2_left) begin
            $display("  ERROR: f2_left mismatch. Expected: 0x%h, Got: 0x%h", 
                     expected_f2_left, act_f2_left);
            mismatch = 1'b1;
        end else begin
            $display("  OK: f2_left = 0x%h", act_f2_left);
        end
        
        if (act_L1_left !== expected_L1_left) begin
            $display("  ERROR: L1_left mismatch. Expected: 0x%h, Got: 0x%h", 
                     expected_L1_left, act_L1_left);
            mismatch = 1'b1;
        end else begin
            $display("  OK: L1_left = 0x%h", act_L1_left);
        end
        
        if (act_L2_left !== expected_L2_left) begin
            $display("  ERROR: L2_left mismatch. Expected: 0x%h, Got: 0x%h", 
                     expected_L2_left, act_L2_left);
            mismatch = 1'b1;
        end else begin
            $display("  OK: L2_left = 0x%h", act_L2_left);
        end
        
        // Check right edge
        $display("\nRight Edge:");
        if (act_f1_right !== expected_f1_right) begin
            $display("  ERROR: f1_right mismatch. Expected: 0x%h, Got: 0x%h", 
                     expected_f1_right, act_f1_right);
            mismatch = 1'b1;
        end else begin
            $display("  OK: f1_right = 0x%h", act_f1_right);
        end
        
        if (act_f2_right !== expected_f2_right) begin
            $display("  ERROR: f2_right mismatch. Expected: 0x%h, Got: 0x%h", 
                     expected_f2_right, act_f2_right);
            mismatch = 1'b1;
        end else begin
            $display("  OK: f2_right = 0x%h", act_f2_right);
        end
        
        if (act_L1_right !== expected_L1_right) begin
            $display("  ERROR: L1_right mismatch. Expected: 0x%h, Got: 0x%h", 
                     expected_L1_right, act_L1_right);
            mismatch = 1'b1;
        end else begin
            $display("  OK: L1_right = 0x%h", act_L1_right);
        end
        
        if (act_L2_right !== expected_L2_right) begin
            $display("  ERROR: L2_right mismatch. Expected: 0x%h, Got: 0x%h", 
                     expected_L2_right, act_L2_right);
            mismatch = 1'b1;
        end else begin
            $display("  OK: L2_right = 0x%h", act_L2_right);
        end
        
        if (mismatch) begin
            error_count++;
            $display("\n*** TEST CASE FAILED ***");
        end else begin
            $display("\n*** TEST CASE PASSED ***");
        end
    endtask

endmodule

// module bandwidth_edge_detector_tb();

//     timeunit 1ns;
//     timeprecision 1ps;

//     // --- Parameters (MUST match DUT and Python generator) ---
//     localparam time CLK_PERIOD         = 10ns;
//     localparam unsigned RST_CLK_CYCLES = 5;
    
//     // Parameters matching the stimulus generator
//     localparam integer POWER_WIDTH     = 8;   // Q8.0
//     localparam integer POWER_FRAC      = 0;
//     localparam integer NUM_BINS        = 24;
//     localparam integer INDEX_WIDTH     = $clog2(NUM_BINS); // 5 bits for indices
//     localparam logic [POWER_WIDTH-1:0] THRESHOLD_DROP = 8'h1E; // 30 dB

//     // --- Signals ---
//     logic clk;
//     logic rst_n;
//     logic valid_i;
    
//     logic [POWER_WIDTH-1:0]     db_power[NUM_BINS];
//     logic [POWER_WIDTH-1:0]     abs_threshold;
    
//     // Left edge outputs (now indices)
//     logic [INDEX_WIDTH-1:0]     act_f1_left;
//     logic [INDEX_WIDTH-1:0]     act_f2_left;
//     logic [POWER_WIDTH-1:0]     act_L1_left;
//     logic [POWER_WIDTH-1:0]     act_L2_left;
    
//     // Right edge outputs (now indices)
//     logic [INDEX_WIDTH-1:0]     act_f1_right;
//     logic [INDEX_WIDTH-1:0]     act_f2_right;
//     logic [POWER_WIDTH-1:0]     act_L1_right;
//     logic [POWER_WIDTH-1:0]     act_L2_right;
    
//     // Status signals
//     logic                       act_valid;
//     logic                       act_threshold_ok;
//     logic                       act_busy;

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
//     bandwidth_edge_detector #(
//         .POWER_WIDTH     (POWER_WIDTH),
//         .POWER_FRAC      (POWER_FRAC),
//         .THRESHOLD_DROP  (THRESHOLD_DROP),
//         .NUM_BINS        (NUM_BINS)
//     ) dut (
//         .clk_i              (clk),
//         .rst_ni             (rst_n),
//         .valid_i            (valid_i),
//         .db_power_i         (db_power),
//         // Left edge outputs (indices)
//         .f1_left_o          (act_f1_left),
//         .f2_left_o          (act_f2_left),
//         .L1_left_o          (act_L1_left),
//         .L2_left_o          (act_L2_left),
//         // Right edge outputs (indices)
//         .f1_right_o         (act_f1_right),
//         .f2_right_o         (act_f2_right),
//         .L1_right_o         (act_L1_right),
//         .L2_right_o         (act_L2_right),
//         // Absolute threshold output
//         .abs_threshold_o    (abs_threshold),
//         // Status outputs
//         .valid_o            (act_valid),
//         .threshold_ok_o     (act_threshold_ok),
//         .busy_o             (act_busy)
//     );

//     // --- Test Sequencer and Checker ---
//     initial begin: checker_block
//         integer file;
//         string  test_name, line_buffer;
//         integer num_bins_read;
//         static integer n_errs = 0;
//         static integer test_count = 0;
        
//         // Expected outputs (indices)
//         logic [INDEX_WIDTH-1:0]    exp_f1_left, exp_f2_left;
//         logic [POWER_WIDTH-1:0]    exp_L1_left, exp_L2_left;
//         logic [INDEX_WIDTH-1:0]    exp_f1_right, exp_f2_right;
//         logic [POWER_WIDTH-1:0]    exp_L1_right, exp_L2_right;
//         logic                      exp_valid;
        
//         integer timeout_counter;
//         localparam integer TIMEOUT_CYCLES = 1000;

//         // Initialize control signals at negedge to avoid race conditions
//         @(negedge clk);
//         valid_i = 1'b0;
        
//         // Open the vector file
//         file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/edge_detector_vectors.txt", "r");
//         if (file == 0) begin
//             $display("ERROR: Could not open vector file.");
//             $stop;
//         end

//         $display("=== Starting bandwidth_edge_detector Testbench ===");
//         $display("  POWER_WIDTH = %0d", POWER_WIDTH);
//         $display("  NUM_BINS = %0d", NUM_BINS);
//         $display("  INDEX_WIDTH = %0d", INDEX_WIDTH);
//         $display("  THRESHOLD_DROP = %0d dB", THRESHOLD_DROP);

//         // Skip header lines (12 lines based on the format)
//         for (int i = 0; i < 12; i++) begin
//             $fgets(line_buffer, file);
//         end

//         // Loop through all test cases in the file
//         while (!$feof(file)) begin
//             // Try to read test name
//             if ($fscanf(file, "%s\n", test_name) == 1) begin
//                 test_count++;
//                 $display("\n========================================");
//                 $display("Test Case %0d: %s", test_count, test_name);
//                 $display("========================================");
                
//                 // Read NUM_BINS
//                 if ($fscanf(file, "%d\n", num_bins_read) != 1) begin
//                     $display("ERROR: Failed to read NUM_BINS");
//                     break;
//                 end
                
//                 if (num_bins_read != NUM_BINS) begin
//                     $display("ERROR: NUM_BINS mismatch. Expected: %0d, Got: %0d", 
//                              NUM_BINS, num_bins_read);
//                     n_errs++;
//                     break;
//                 end
                
//                 $display("NUM_BINS: %0d", num_bins_read);
                
//                 // Read POWER_VALS
//                 for (int i = 0; i < num_bins_read; i++) begin
//                     if ($fscanf(file, "%h", db_power[i]) != 1) begin
//                         $display("ERROR: Failed to read db_power[%0d]", i);
//                         break;
//                     end
//                 end
//                 $fgets(line_buffer, file); // Consume newline
                
//                 // Display power values for debugging
//                 $display("Power values (dB):");
//                 for (int i = 0; i < num_bins_read; i++) begin
//                     $display("  [%2d]: %3d (0x%02h)", i, db_power[i], db_power[i]);
//                 end
                
//                 // Read EXPECTED_VALID
//                 if ($fscanf(file, "%b\n", exp_valid) != 1) begin
//                     $display("ERROR: Failed to read expected valid");
//                     break;
//                 end
                
//                 // Read EXPECTED_LEFT (f1_idx f2_idx L1 L2)
//                 if ($fscanf(file, "%h %h %h %h\n", 
//                            exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left) != 4) begin
//                     $display("ERROR: Failed to read expected left edge");
//                     break;
//                 end
                
//                 // Read EXPECTED_RIGHT (f1_idx f2_idx L1 L2)
//                 if ($fscanf(file, "%h %h %h %h\n", 
//                            exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right) != 4) begin
//                     $display("ERROR: Failed to read expected right edge");
//                     break;
//                 end
                
//                 $display("Expected results:");
//                 $display("  Valid: %b", exp_valid);
//                 $display("  Left:  f1=%0d, f2=%0d, L1=%0d dB, L2=%0d dB", 
//                         exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left);
//                 $display("  Right: f1=%0d, f2=%0d, L1=%0d dB, L2=%0d dB", 
//                         exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right);
                
//                 // --- Drive DUT and Check ---
//                 wait(rst_n);
                
//                 // Set valid_i at negedge to avoid race conditions
//                 @(negedge clk);
//                 valid_i = 1'b1;
//                 $display("\nDriving DUT with valid_i=1");
                
//                 @(negedge clk);
//                 valid_i = 1'b0;
//                 $display("Deasserted valid_i");
                
//                 // Wait for valid_o with timeout
//                 timeout_counter = 0;
//                 while (!act_valid && timeout_counter < TIMEOUT_CYCLES) begin
//                     @(posedge clk);
//                     timeout_counter++;
//                 end
                
//                 if (timeout_counter >= TIMEOUT_CYCLES) begin
//                     $display("ERROR: Timeout waiting for valid_o");
//                     n_errs++;
//                     continue;
//                 end
                
//                 $display("Received valid_o after %0d cycles", timeout_counter);
//                 $display("Threshold OK: %b, Absolute threshold: %0d dB", 
//                         act_threshold_ok, abs_threshold);
                
//                 // Check results
//                 check_result(
//                     exp_f1_left, exp_f2_left, exp_L1_left, exp_L2_left,
//                     exp_f1_right, exp_f2_right, exp_L1_right, exp_L2_right,
//                     exp_valid, n_errs
//                 );
                
//                 // Wait a few cycles before next test
//                 repeat(5) @(posedge clk);
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
//         input logic [INDEX_WIDTH-1:0]    expected_f1_left,
//         input logic [INDEX_WIDTH-1:0]    expected_f2_left,
//         input logic [POWER_WIDTH-1:0]    expected_L1_left,
//         input logic [POWER_WIDTH-1:0]    expected_L2_left,
//         input logic [INDEX_WIDTH-1:0]    expected_f1_right,
//         input logic [INDEX_WIDTH-1:0]    expected_f2_right,
//         input logic [POWER_WIDTH-1:0]    expected_L1_right,
//         input logic [POWER_WIDTH-1:0]    expected_L2_right,
//         input logic                      expected_valid,
//         inout integer                    error_count
//     );
//         automatic logic mismatch = 1'b0;
        
//         $display("\n--- Checking Results ---");
        
//         // Check valid signal
//         if (act_valid !== expected_valid) begin
//             $display("ERROR: valid mismatch. Expected: %b, Got: %b", 
//                      expected_valid, act_valid);
//             mismatch = 1'b1;
//         end else begin
//             $display("OK: valid = %b", act_valid);
//         end
        
//         // Check left edge (indices)
//         $display("\nLeft Edge:");
//         if (act_f1_left !== expected_f1_left) begin
//             $display("  ERROR: f1_left mismatch. Expected: %0d, Got: %0d", 
//                      expected_f1_left, act_f1_left);
//             mismatch = 1'b1;
//         end else begin
//             $display("  OK: f1_left = %0d (index)", act_f1_left);
//         end
        
//         if (act_f2_left !== expected_f2_left) begin
//             $display("  ERROR: f2_left mismatch. Expected: %0d, Got: %0d", 
//                      expected_f2_left, act_f2_left);
//             mismatch = 1'b1;
//         end else begin
//             $display("  OK: f2_left = %0d (index)", act_f2_left);
//         end
        
//         if (act_L1_left !== expected_L1_left) begin
//             $display("  ERROR: L1_left mismatch. Expected: %0d dB, Got: %0d dB", 
//                      expected_L1_left, act_L1_left);
//             mismatch = 1'b1;
//         end else begin
//             $display("  OK: L1_left = %0d dB", act_L1_left);
//         end
        
//         if (act_L2_left !== expected_L2_left) begin
//             $display("  ERROR: L2_left mismatch. Expected: %0d dB, Got: %0d dB", 
//                      expected_L2_left, act_L2_left);
//             mismatch = 1'b1;
//         end else begin
//             $display("  OK: L2_left = %0d dB", act_L2_left);
//         end
        
//         // Check right edge (indices)
//         $display("\nRight Edge:");
//         if (act_f1_right !== expected_f1_right) begin
//             $display("  ERROR: f1_right mismatch. Expected: %0d, Got: %0d", 
//                      expected_f1_right, act_f1_right);
//             mismatch = 1'b1;
//         end else begin
//             $display("  OK: f1_right = %0d (index)", act_f1_right);
//         end
        
//         if (act_f2_right !== expected_f2_right) begin
//             $display("  ERROR: f2_right mismatch. Expected: %0d, Got: %0d", 
//                      expected_f2_right, act_f2_right);
//             mismatch = 1'b1;
//         end else begin
//             $display("  OK: f2_right = %0d (index)", act_f2_right);
//         end
        
//         if (act_L1_right !== expected_L1_right) begin
//             $display("  ERROR: L1_right mismatch. Expected: %0d dB, Got: %0d dB", 
//                      expected_L1_right, act_L1_right);
//             mismatch = 1'b1;
//         end else begin
//             $display("  OK: L1_right = %0d dB", act_L1_right);
//         end
        
//         if (act_L2_right !== expected_L2_right) begin
//             $display("  ERROR: L2_right mismatch. Expected: %0d dB, Got: %0d dB", 
//                      expected_L2_right, act_L2_right);
//             mismatch = 1'b1;
//         end else begin
//             $display("  OK: L2_right = %0d dB", act_L2_right);
//         end
        
//         if (mismatch) begin
//             error_count++;
//             $display("\n*** TEST CASE FAILED ***");
//         end else begin
//             $display("\n*** TEST CASE PASSED ***");
//         end
//     endtask

// endmodule