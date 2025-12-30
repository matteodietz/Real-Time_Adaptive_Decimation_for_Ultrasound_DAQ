////////////////////////////////////////////////////////////////////////////////
//
//  Testbench: find_max_power_tb
//
//  Description:
//      Testbench for the find_max_power module.
//      Simplified for fixed NUM_BINS = 24.
//
////////////////////////////////////////////////////////////////////////////////

module find_max_power_tb();

    timeunit 1ns;
    timeprecision 1ps;

    // Timing parameters
    localparam time CLK_PERIOD = 10ns;
    localparam unsigned RST_CLK_CYCLES = 5;
    
    // DUT parameters
    localparam integer POWER_WIDTH = 8;
    localparam integer POWER_FRAC = 0;
    localparam integer NUM_BINS = 24; // Fixed to 24
    
    // Clock and reset
    logic clk;
    logic rst_n;
    
    // DUT signals
    logic valid_in;
    logic [POWER_WIDTH-1:0] power_values[NUM_BINS];
    logic valid_out;
    logic [POWER_WIDTH-1:0] max_power_out;
    
    ////////////////////////////////////////////////////////////////////////////
    // Clock generation
    ////////////////////////////////////////////////////////////////////////////
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // Reset generation
    ////////////////////////////////////////////////////////////////////////////
    initial begin
        rst_n = 1'b0;
        repeat(RST_CLK_CYCLES) @(posedge clk);
        rst_n = 1'b1;
    end
    
    ////////////////////////////////////////////////////////////////////////////
    // DUT instantiation
    ////////////////////////////////////////////////////////////////////////////
    find_max_power #(
        .NUM_BINS(NUM_BINS),
        .POWER_WIDTH(POWER_WIDTH)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .valid_i(valid_in),
        .power_values_i(power_values), // Passing the full unpacked array
        .valid_o(valid_out),
        .max_power_o(max_power_out)
    );
    
    ////////////////////////////////////////////////////////////////////////////
    // Test stimulus and checking
    ////////////////////////////////////////////////////////////////////////////
    initial begin: test_runner
        integer file, status, c;
        string line, test_name;
        integer num_bins_read;
        logic [POWER_WIDTH-1:0] expected_max;
        logic [POWER_WIDTH-1:0] power_val;
        integer i;
        integer test_count = 0;
        integer pass_count = 0;
        integer fail_count = 0;
        integer latency;
        real expected_float, actual_float, error;
        
        // Initialize inputs
        valid_in = 1'b0;
        for (i = 0; i < NUM_BINS; i++) begin
            power_values[i] = '0;
        end
        
        // Calculate expected pipeline latency for timeouts
        // Latency = ceil(log2(24)) + 1 = 5 + 1 = 6 cycles
        latency = $clog2(NUM_BINS) + 1;
        $display("DUT Pipeline Latency: %0d cycles", latency);

        // Open vector file
        // Ensure this path matches where your Python script saves the file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/find_max_power_vectors.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file");
            $finish;
        end
        
        $display("========================================");
        $display("Find Max Power Testbench (24 Bins)");
        $display("========================================");
        
        // Skip header lines
        for (int i = 0; i < 15; i++) begin
            status = $fgets(line, file);
        end
        // Wait for reset to complete
        wait(rst_n == 1'b1);
        repeat(2) @(posedge clk);
        
        // Run all test cases
        while (!$feof(file)) begin
            // 1. Read Test Name
            status = $fgets(line, file);
            if (status == 0) break; // End of file
            
            // Trim newline
            test_name = line.substr(0, line.len()-2);
            
            // Handle potential blank lines between cases
            if (test_name == "" || test_name == "\n") continue;
            
            test_count++;
            $display("\nTest %0d: %s", test_count, test_name);
            
            // 2. Read Number of Bins (Verification check)
            status = $fscanf(file, "%d\n", num_bins_read);
            if (num_bins_read != NUM_BINS) begin
                $display("WARNING: Vector file has %0d bins, TB configured for %0d", num_bins_read, NUM_BINS);
            end
            
            // 3. Read Power Values
            for (i = 0; i < NUM_BINS; i++) begin
                status = $fscanf(file, "%h\n", power_val);
                power_values[i] = power_val;
            end
            
            // 4. Read Expected Maximum
            status = $fscanf(file, "%h\n", expected_max);
            
            // Consume any trailing newlines after the hex value to align for next fgets
            // (Python script writes expected hex + newline, then a blank line)
            // status = $fgets(line, file); // Consumes rest of expected line if any
            // status = $fgets(line, file); // Consumes the blank line
            
            // --- Drive DUT ---
            @(posedge clk);
            #1; // Delay to separate from clock edge
            valid_in = 1'b1;
            
            @(posedge clk);
            #1;
            valid_in = 1'b0; // Single pulse valid
            
            // --- Monitor Output ---
            // Simple wait. If DUT hangs, global timeout catches it.
            while (valid_out == 1'b0) begin
                @(posedge clk);
            end
            
            // --- Check Results ---
            if (valid_out) begin
                // Latch values at the clock edge where valid_out is high
                // Since we are in the middle of a cycle (due to wait statement), 
                // the values max_power_out are currently valid.
                
                // Convert to real for display (Assuming Unsigned Q16.16 based on Python script)
                expected_float = $itor(expected_max) / 65536.0;
                actual_float   = $itor(max_power_out) / 65536.0;
                
                error = actual_float - expected_float;
                if (error < 0) error = -error;
                
                // Bitwise comparison
                if (expected_max === max_power_out) begin
                    $display("RESULT: PASS");
                    pass_count++;
                end else begin
                    $display("RESULT: FAIL");
                    $display("  Expected: %h (%.4f)", expected_max, expected_float);
                    $display("  Got:      %h (%.4f)", max_power_out, actual_float);
                    fail_count++;
                end
            end
            
            // Add some spacing between tests
            repeat(2) @(posedge clk);
        end
        
        $fclose(file);
        
        // Final Summary
        $display("\n========================================");
        $display("SUMMARY: %0d Tests, %0d Passed, %0d Failed", test_count, pass_count, fail_count);
        $display("========================================");
        
        if (fail_count == 0) 
            $display("SUCCESS: All tests passed.");
        else 
            $display("FAILURE: Some tests failed.");
            
        $finish;
    end
    
    // Global Timeout
    initial begin
        #10ms;
        $display("\nERROR: Simulation Global Timeout!");
        $finish;
    end

endmodule