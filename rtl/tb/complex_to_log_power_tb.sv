module complex_to_log_power_tb ();

    timeunit 1ns;
    timeprecision 1ps;

    // --- Parameters ---
    localparam time CLK_PERIOD         = 10ns;
    localparam unsigned RST_CLK_CYCLES = 5;
    
    localparam integer INPUT_WIDTH  = 18; 
    localparam integer OUTPUT_WIDTH = 8;
    localparam integer OUTPUT_FRAC  = 0; 

    // --- Signals ---
    logic                                 clk;
    logic                                 rst_n;
    logic                                 valid_in;
    logic signed [INPUT_WIDTH-1:0]        i_data;
    logic signed [INPUT_WIDTH-1:0]        q_data;
    
    logic                                 act_valid;
    logic        [OUTPUT_WIDTH-1:0]       act_db_power;

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
    complex_to_log_power #(
        .INPUT_WIDTH  (INPUT_WIDTH),
        .OUTPUT_WIDTH (OUTPUT_WIDTH),
        .OUTPUT_FRAC  (OUTPUT_FRAC)
    ) dut (
        .clk_i        (clk),
        .rst_ni       (rst_n),
        .valid_i      (valid_in),
        .i_data_i     (i_data),
        .q_data_i     (q_data),
        .valid_o      (act_valid),
        .db_power_o   (act_db_power)
    );

    // --- Test Sequencer and Checker ---
    initial begin: checker_block
        integer file;
        string  line;
        static integer n_errs = 0;
        static integer test_count = 0;
        
        logic [INPUT_WIDTH-1:0]  in_i, in_q;
        logic [OUTPUT_WIDTH-1:0] exp_db_power;

        // Open the vector file
        file = $fopen("/home/bsc25h10/mdietz/bachelors_thesis/rtl/simvectors/log_power_vectors.txt", "r");
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
        i_data   = '0;
        q_data   = '0;

        // Wait for reset to complete
        wait(rst_n);
        @(posedge clk);

        // Loop through all test cases in the file
        while (!$feof(file)) begin
            // Read I and Q values
            automatic int scan_result = $fscanf(file, "%d %d\n", in_i, in_q);
            
            if (scan_result != 2) begin
                // End of file or incomplete read
                break;
            end
            
            // Read expected output
            if ($fscanf(file, "%d\n", exp_db_power) != 1) begin
                $display("ERROR: Failed to read expected output for test case %0d", test_count + 1);
                break;
            end
            
            test_count++;
            
            // Skip comment line (before next test case)
            $fgets(line, file);
            
            $display("\n--- Test Case %0d ---", test_count);
            $display("Input: I = 0x%04h, Q = 0x%04h", in_i, in_q);
            $display("Expected: db_power = 0x%02h", exp_db_power);
            
            // --- Drive DUT ---
            i_data   = in_i;
            q_data   = in_q;
            valid_in = 1'b1;
            @(posedge clk);
            #1;
            valid_in = 1'b0;
            
            // Wait for output
            repeat(3) @(posedge clk);
            
            // Check results
            #1;
            check_result(exp_db_power, n_errs, test_count);
            
            // @(posedge clk); // Idle cycle before next tc starts
        end

        $fclose(file);

        $display("\n========================================");
        if (n_errs > 0) begin
            $display("TEST FAILED with %0d errors out of %0d test cases.", n_errs, test_count);
        end else begin
            $display("TEST PASSED - All %0d test cases passed!", test_count);
        end
        $display("========================================\n");
        $stop;
    end
    
    // --- Checking Task ---
    task check_result(
        input logic [OUTPUT_WIDTH-1:0] expected_db_power,
        inout integer                  error_count,
        input integer                  test_num
    );
        automatic logic mismatch = 1'b0;
        
        if (act_valid !== 1'b1) begin
            $display("ERROR: valid_o not asserted when expected");
            mismatch = 1'b1;
        end
        
        if (act_db_power !== expected_db_power) begin
            $display("ERROR: db_power mismatch. Expected: 0x%08h, Got: 0x%08h", 
                     expected_db_power, act_db_power);
            mismatch = 1'b1;
        end else begin
            $display("SUCCESS: db_power match. Got: 0x%08h", act_db_power);
        end

        if (mismatch) begin 
            error_count++;
        end
    endtask

endmodule