////////////////////////////////////////////////////////////////////////////////
//
//  Testbench: oscillator_bank_tb
//
//  Simple phase sweep for waveform observation
//
////////////////////////////////////////////////////////////////////////////////

`timescale 1ns/1ps

module oscillator_bank_tb;

    // Parameters
    localparam int NUM_BINS = 2;
    localparam int OSC_WIDTH = 16;
    localparam int PHASE_WIDTH = 32;
    localparam real CLK_PERIOD = 10.0; // 100 MHz
    
    // DUT signals
    logic clk_i;
    logic rst_ni;
    logic enable_i;
    logic sync_reset_i;
    logic phase_tvalid;
    logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS];
    logic sincos_tvalid;
    logic signed [OSC_WIDTH-1:0] W_real_o[NUM_BINS];
    logic signed [OSC_WIDTH-1:0] W_imag_o[NUM_BINS];
    
    // Clock generation
    initial begin
        clk_i = 0;
        forever #(CLK_PERIOD/2) clk_i = ~clk_i;
    end
    
    // DUT instantiation
    oscillator_bank #(
        .NUM_BINS(NUM_BINS),
        .OSC_WIDTH(OSC_WIDTH),
        .PHASE_WIDTH(PHASE_WIDTH)
    ) dut (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .enable_i(enable_i),
        .sync_reset_i(sync_reset_i),
        .phase_tvalid(phase_tvalid),
        .freq_steps_i(freq_steps_i),
        .sincos_tvalid(sincos_tvalid),
        .W_real_o(W_real_o),
        .W_imag_o(W_imag_o)
    );
    
    // Simple continuous phase generation
    initial begin
        // Initialize
        rst_ni = 0;
        enable_i = 0;
        sync_reset_i = 0;
        phase_tvalid = 0;
        
        // Setup frequency steps
        // Bin 0: Sweep through full phase range in ~256 clocks (fast)
        // Bin 1: Sweep through full phase range in ~512 clocks (slower)
        freq_steps_i[0] = 32'h01000000;  // 2^32 / 256 ≈ 16777216
        freq_steps_i[1] = 32'h00800000;  // 2^32 / 512 ≈ 8388608
        
        // Wait and release reset
        repeat(10) @(posedge clk_i);
        rst_ni = 1;
        @(posedge clk_i);
        
        $display("\n=============================================================");
        $display("Phase Sweep Test for Waveform Observation");
        $display("=============================================================");
        $display("Bin 0 freq_step: 0x%08h (completes ~4 full cycles in 1024 clocks)", freq_steps_i[0]);
        $display("Bin 1 freq_step: 0x%08h (completes ~2 full cycles in 1024 clocks)", freq_steps_i[1]);
        $display("\nRunning for 1024 clock cycles...");
        $display("Watch the waveforms in your simulator!\n");
        
        // Enable continuous operation
        @(posedge clk_i);
        enable_i = 1;
        phase_tvalid = 1;
        
        // Run for several full cycles
        repeat(1024) @(posedge clk_i);
        
        enable_i = 0;
        phase_tvalid = 0;
        
        repeat(20) @(posedge clk_i);
        
        $display("\n=============================================================");
        $display("Test completed - check waveforms!");
        $display("=============================================================\n");
        $finish;
    end
    
    // Optional: Simple monitor to print a few samples
    integer sample_count = 0;
    always @(posedge clk_i) begin
        if (sincos_tvalid && sample_count < 20) begin
            $display("Sample %3d: Bin0(Re=%6d, Im=%6d)  Bin1(Re=%6d, Im=%6d)", 
                     sample_count,
                     W_real_o[0], W_imag_o[0],
                     W_real_o[1], W_imag_o[1]);
            sample_count++;
        end
    end
    
    // Waveform dump
    initial begin
        $dumpfile("oscillator_bank.vcd");
        $dumpvars(0, oscillator_bank_tb);
    end

endmodule