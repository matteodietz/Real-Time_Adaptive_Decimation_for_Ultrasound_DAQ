module counter_controller_tb;

    // Clock and reset
    logic clk;
    logic rst_n;
    
    // Inputs
    logic [15:0] X;
    logic [15:0] Y;
    logic [15:0] Z;
    logic clear;
    logic enable;
    
    // Outputs
    logic osc_reset;
    logic osc_enable;
    logic osc_phase_tvalid;
    logic start;
    logic sample_valid;
    logic last_sample;

    // Instantiate DUT
    counter_controller #(
        .COUNTER_WIDTH_X(16),
        .COUNTER_WIDTH_Y(16),
        .COUNTER_WIDTH_Z(16)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .X(X),
        .Y(Y),
        .Z(Z),
        .clear_i(clear),
        .enable_i(enable),
        .osc_reset(osc_reset),
        .osc_enable(osc_enable),
        .osc_phase_tvalid(osc_phase_tvalid),
        .start(start),
        .sample_valid(sample_valid),
        .last_sample(last_sample)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Test stimulus
    initial begin
        // Initialize
        rst_n = 0;
        X = 20;
        Y = 36;
        Z = 4;
        clear = 0;
        enable = 0;
        
        // Reset
        #20;
        rst_n = 1;
        
        // Start the counter
        @(posedge clk);
        enable = 1;
        
        // Run for 100 clock cycles
        repeat(100) @(posedge clk);
        
        $finish;
    end

endmodule