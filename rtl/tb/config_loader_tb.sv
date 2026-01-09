module config_loader_example_tb;

    //--------------------------------------------------------------------------
    // Parameters
    //--------------------------------------------------------------------------
    
    localparam integer PHASE_WIDTH = 16;
    localparam integer FREQ_BIN_WIDTH = 5;
    localparam integer NUM_BINS = 24;
    localparam integer CONFIG_DATA_WIDTH = 16;
    
    localparam integer CLK_PERIOD = 10;
    
    //--------------------------------------------------------------------------
    // Signals
    //--------------------------------------------------------------------------
    
    logic clk;
    logic rst_n;
    
    // Config loader signals
    logic [CONFIG_DATA_WIDTH-1:0] s_axis_config_tdata;
    logic s_axis_config_tvalid;
    logic s_axis_config_tready;
    logic config_valid;
    
    logic [PHASE_WIDTH-1:0] freq_steps[NUM_BINS];
    logic [FREQ_BIN_WIDTH-1:0] freq_bin[NUM_BINS];
    
    logic enable;
    logic clear;
    
    //--------------------------------------------------------------------------
    // Clock Generation
    //--------------------------------------------------------------------------
    
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    //--------------------------------------------------------------------------
    // DUT Instantiation
    //--------------------------------------------------------------------------
    
    config_loader #(
        .PHASE_WIDTH     (PHASE_WIDTH),
        .FREQ_BIN_WIDTH  (FREQ_BIN_WIDTH),
        .NUM_BINS        (NUM_BINS),
        .DATA_WIDTH      (CONFIG_DATA_WIDTH)
    ) dut (
        .clk_i               (clk),
        .rst_ni              (rst_n),
        .clear_i             (clear),
        .s_axis_tdata_i      (s_axis_config_tdata),
        .s_axis_tvalid_i     (s_axis_config_tvalid),
        .s_axis_tready_o     (s_axis_config_tready),
        .freq_steps_o        (freq_steps),
        .freq_bin_o          (freq_bin),
        .config_valid_o      (config_valid)
    );
    
    //--------------------------------------------------------------------------
    // Test Stimulus
    //--------------------------------------------------------------------------
    
    initial begin
        // Initialize signals
        rst_n = 0;
        clear = 0;
        s_axis_config_tdata = 0;
        s_axis_config_tvalid = 0;
        enable = 0;
        
        // Reset
        #(CLK_PERIOD * 10);
        rst_n = 1;
        #(CLK_PERIOD * 5);
        
        $display("=== Starting Configuration Loading ===");
        
        
        // Load freq_steps (NUM_BINS = 24 values)
        $display("Loading freq_steps...");
        for (int i = 0; i < NUM_BINS; i++) begin
            @(posedge clk);
            s_axis_config_tdata = 16'h1000 + (i * 16'h0100);  // Example values
            s_axis_config_tvalid = 1;
            
            // Wait for ready
            while (!s_axis_config_tready) begin
                @(posedge clk);
            end
            
            $display("  freq_steps[%0d] = 0x%08h", i, s_axis_config_tdata);
        end
        
        @(posedge clk);
        s_axis_config_tvalid = 0;
        
        // Small delay between freq_steps and freq_bin
        #(CLK_PERIOD * 2);
        
        // Load freq_bin (NUM_BINS = 24 values)
        $display("Loading freq_bin...");
        for (int i = 0; i < NUM_BINS; i++) begin
            @(posedge clk);
            s_axis_config_tdata = 5'b01000 + (i * 5'b00100);  // Example values
            s_axis_config_tvalid = 1;
            
            // Wait for ready
            while (!s_axis_config_tready) begin
                @(posedge clk);
            end
            
            $display("  freq_bin[%0d] = 0x%04h", i, s_axis_config_tdata);
        end
        
        @(posedge clk);
        s_axis_config_tvalid = 0;
        
        // Wait for config_valid
        $display("Waiting for config_valid...");
        @(posedge clk);
        while (!config_valid) begin
            @(posedge clk);
        end
        
        $display("=== Configuration Complete! ===");
        $display("config_valid = %b", config_valid);
        
        // Now normal processing can start
        #(CLK_PERIOD * 10);
        enable = 1;
        $display("Processing enabled");
        
        #(CLK_PERIOD * 100);
        
        // Test clear functionality
        $display("=== Testing Clear ===");
        #1;
        clear = 1;
        #(CLK_PERIOD);
        #1;
        clear = 0;
        
        @(posedge clk);
        $display("After clear: config_valid = %b", config_valid);
        
        #(CLK_PERIOD * 10);
        $finish;
    end
    
    //--------------------------------------------------------------------------
    // Monitoring
    //--------------------------------------------------------------------------
    
    initial begin
        $monitor("Time=%0t clk=%b rst_n=%b config_valid=%b tready=%b tvalid=%b", 
                 $time, clk, rst_n, config_valid, 
                 s_axis_config_tready, s_axis_config_tvalid);
    end

endmodule