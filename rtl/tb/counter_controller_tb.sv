module counter_controller_tb;

    // Clock and reset
    logic clk;
    logic rst_n;
    
    // Inputs
    logic [15:0] INITIAL_DELAY;
    logic [15:0] OSC_DELAY;
    logic [15:0] WINDOW_DELAY;
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
        .COUNTER_WIDTH(16),
        .N(1)
    ) dut (
        .clk_i(clk),
        .rst_ni(rst_n),
        .initial_delay(INITIAL_DELAY),
        .osc_delay(OSC_DELAY),
        .window_delay(WINDOW_DELAY),
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
        INITIAL_DELAY = 100;
        OSC_DELAY = 20;
        WINDOW_DELAY = 4;
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