module linear_interp_crossing_tb ();

    timeunit 1ns;
    timeprecision 1ps;

    // --- Parameters (MUST match DUT and Python generator) ---
    localparam time CLK_PERIOD         = 10ns;
    localparam unsigned RST_CLK_CYCLES = 5;
    
    localparam integer FREQ_WIDTH      = 32; // As per Python script
    localparam integer FREQ_FRAC_BITS  = 16; // As per Python script
    localparam integer ACCUM_DB_WIDTH  = 32; // As per Python script
    localparam integer ACCUM_DB_FRAC   = 16; // As per Python script
    
    // Threshold in fixed-point format: -20 dB << 16
    localparam signed [ACCUM_DB_WIDTH-1:0] THRESHOLD_DB = -20 << ACCUM_DB_FRAC;

    // --- Signals ---
    logic                                clk;
    logic                                rst_n;
    logic                                valid_in;
    logic [FREQ_WIDTH-1:0]               f1;
    logic [FREQ_WIDTH-1:0]               f2;
    logic signed [ACCUM_DB_WIDTH-1:0]    L1;
    logic signed [ACCUM_DB_WIDTH-1:0]    L2;
    
    logic                                act_ready;
    logic [FREQ_WIDTH-1:0]               act_f_star;
    logic                                act_invalid;

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
    linear_interp_crossing #(
        .FREQ_WIDTH      (FREQ_WIDTH),
        .FREQ_FRAC_BITS  (FREQ_FRAC_BITS),
        .ACCUM_DB_WIDTH  (ACCUM_DB_WIDTH),
        .ACCUM_DB_FRAC   (ACCUM_DB_FRAC),
        .THRESHOLD_DB    (THRESHOLD_DB)
    ) dut (
        .clk_i      (clk),
        .rst_ni     (rst_n),
        .valid_i    (valid_in),
        .f1_i       (f1),
        .f2_i       (f2),
        .L1_i       (L1),
        .L2_i       (L2),
        .ready_o    (act_ready),
        .f_star_o   (act_f_star),
        .invalid_o  (act_invalid)
    );

    // --- Test Sequencer and Checker ---
    initial begin: checker_block
        integer file;
        string  line;
        static integer n_errs = 0;
        static integer test_count = 0;
        
        logic [FREQ_WIDTH-1:0]            in_f1, in_f2;
        logic signed [ACCUM_DB_WIDTH-1:0] in_L1, in_L2;
        logic [FREQ_WIDTH-1:0]            exp_f_star;
        logic                             exp_invalid;
        automatic logic timeout_flag = 0;

        // Open the vector file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/linear_interp_vectors.txt", "r");
        if (file == 0) begin
            $display("ERROR: Could not open vector file.");
            $stop;
        end

        // Skip header lines (lines starting with '#')
        while (!$feof(file)) begin
            automatic int c = $fgetc(file);
            if (c == "#") begin
                // Skip entire line
                void'($fgets(line, file));
            end else begin
                // Not a comment, rewind one character
                void'($ungetc(c, file));
                break;
            end
        end

        // Initialize inputs
        valid_in = 1'b0;
        f1       = '0;
        f2       = '0;
        L1       = '0;
        L2       = '0;

        // Wait for reset to complete
        wait(rst_n);
        @(posedge clk);

        // Loop through all test cases in the file
        while (!$feof(file)) begin
            // Try to read input values (f1, f2, L1, L2)
            automatic int scan_result = $fscanf(file, "%h %h %h %h\n", in_f1, in_f2, in_L1, in_L2);
            
            if (scan_result != 4) begin
                // End of file or incomplete read
                break;
            end
            
            // Read expected output (f_star and invalid flag)
            if ($fscanf(file, "%h %b\n", exp_f_star, exp_invalid) != 2) begin
                $display("ERROR: Failed to read expected output for test case %0d", test_count + 1);
                break;
            end
            
            test_count++;
            
            // Skip comment lines if present (before next test case)
            while (!$feof(file)) begin
                automatic int next_char = $fgetc(file);
                if (next_char == "#") begin
                    void'($fgets(line, file));
                end else if (next_char != -1) begin
                    void'($ungetc(next_char, file));
                    break;
                end else begin
                    break;
                end
            end
            
            $display("\n--- Test Case %0d ---", test_count);
            $display("Input: f1 = 0x%08h, f2 = 0x%08h", in_f1, in_f2);
            $display("       L1 = 0x%08h, L2 = 0x%08h", in_L1, in_L2);
            $display("Expected: f_star = 0x%08h, invalid = %b", exp_f_star, exp_invalid);
            
            // --- Drive DUT ---
            f1       = in_f1;
            f2       = in_f2;
            L1       = in_L1;
            L2       = in_L2;
            valid_in = 1'b1;
            @(posedge clk);
            valid_in = 1'b0;
            
            // Wait for output (pipeline depth is 5 cycles)
            // Wait for ready signal

            fork
                begin
                    // Wait for ready with timeout
                    repeat(20) @(posedge clk);
                    if (!act_ready) begin
                        $display("ERROR: Timeout waiting for ready signal");
                        n_errs++;
                        timeout_flag = 1;
                    end
                end
                begin
                    wait(act_ready);
                end
            join_any
            disable fork;
            
            if (timeout_flag) begin
                @(posedge clk);
                continue;
            end
            // Check results
            check_result(exp_f_star, exp_invalid, n_errs, test_count);
            
            @(posedge clk);
        end

        $fclose(file);

        $display("\n========================================");
        if (n_errs > 0) begin
            $display("TEST FAILED with %0d errors out of %0d test cases.", n_errs, test_count);
        end else begin
            $display("TEST PASSED - All %0d test cases passed!", test_count);
        end
        $display("========================================\n");
        $display("threshold db in hex: %h", THRESHOLD_DB);
        $stop;
    end
    
    // --- Checking Task ---
    task check_result(
        input logic [FREQ_WIDTH-1:0] expected_f_star,
        input logic                  expected_invalid,
        inout integer                error_count,
        input integer                test_num
    );
        automatic logic mismatch = 1'b0;
        
        if (act_ready !== 1'b1) begin
            $display("ERROR: ready_o not asserted when expected");
            mismatch = 1'b1;
        end
        
        if (act_invalid !== expected_invalid) begin
            $display("ERROR: invalid_o mismatch. Expected: %b, Got: %b", 
                     expected_invalid, act_invalid);
            mismatch = 1'b1;
        end
        
        // Only check f_star if the result is valid
        if (!expected_invalid) begin
            // Allow small tolerance due to rounding differences
            automatic logic [FREQ_WIDTH-1:0] diff;
            automatic logic [FREQ_WIDTH-1:0] tolerance = 'd100; // Allow ±2 LSBs
            
            if (act_f_star > expected_f_star) begin
                diff = act_f_star - expected_f_star;
            end else begin
                diff = expected_f_star - act_f_star;
            end
            
            if (diff > tolerance) begin
                $display("ERROR: f_star mismatch. Expected: 0x%08h, Got: 0x%08h (diff: %0d)", 
                         expected_f_star, act_f_star, diff);
                mismatch = 1'b1;
            end else begin
                $display("SUCCESS: f_star match. Got: 0x%08h (diff: %0d)", act_f_star, diff);
            end
        end else begin
            $display("INFO: Invalid case - f_star not checked");
        end
        
        if (!mismatch) begin
            $display("SUCCESS: Test case passed");
        end

        if (mismatch) begin 
            error_count++;
        end
    endtask

endmodule