////////////////////////////////////////////////////////////////////////////////
//
//  Module: oscillator_bank
//
//  Function: Generates N complex oscillators (NCOs) in parallel.
//
//  Method:   Direct Digital Synthesis (DDS)
//            1. Phase Accumulation: phase[n] = phase[n-1] + freq_step
//            2. CORDIC: Converts phase angle to Sin/Cos (W_real/W_imag)
//
//  Drift:    Zero amplitude drift (unlike recursive multipliers).
//
////////////////////////////////////////////////////////////////////////////////

module oscillator_bank #(
    parameter int NUM_BINS = 16,
    parameter int OSC_WIDTH = 27,       // Width of Output (W)
    parameter int PHASE_WIDTH = 32      // Precision of the frequency/phase accumulator
)(
    input  logic clk_i,
    input  logic rst_ni,
    
    // Control
    input  logic enable_i,              // Update oscillators (sample_valid)
    input  logic sync_reset_i,          // Reset phases to 0 (start of frame)
    
    // Configuration (From Register File / APU)
    // freq_step = (f_bin / f_sample) * 2^PHASE_WIDTH
    input  logic [PHASE_WIDTH-1:0] freq_steps_i[NUM_BINS],
    
    // Outputs to DFT Module
    output logic signed [OSC_WIDTH-1:0] W_real_o[NUM_BINS], // Cos
    output logic signed [OSC_WIDTH-1:0] W_imag_o[NUM_BINS]  // -Sin (Standard DFT exp(-j...))
);

    // =========================================================================
    // 1. Phase Accumulators
    // =========================================================================
    logic [PHASE_WIDTH-1:0] phase_acc[NUM_BINS];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int k = 0; k < NUM_BINS; k++) phase_acc[k] <= '0;
        end else begin
            if (sync_reset_i) begin
                // Reset phase to 0 at start of DFT frame
                for (int k = 0; k < NUM_BINS; k++) phase_acc[k] <= '0;
            end else if (enable_i) begin
                // Increment phase: theta[n] = theta[n-1] - freq_step
                // Note: DFT uses exp(-j*2*pi*f*n). 
                // We can subtract phase here, or output -Sin later. 
                // Let's add here and assume CORDIC outputs Sin/Cos. 
                // DFT W = Cos - jSin.
                for (int k = 0; k < NUM_BINS; k++) begin
                    phase_acc[k] <= phase_acc[k] + freq_steps_i[k];
                end
            end
        end
    end

    // =========================================================================
    // 2. Parallel CORDIC Instantiations
    // =========================================================================
    // In a real FPGA, these would be IP Core instances.
    // For 24 bins, instantiating 24 parallel CORDICs is area-heavy but highest performance.
    
    genvar k;
    generate
        for (k = 0; k < NUM_BINS; k++) begin : gen_nco
            
            logic signed [OSC_WIDTH-1:0] cos_out;
            logic signed [OSC_WIDTH-1:0] sin_out;
            
            // This is a behavioral wrapper. 
            // In Synthesis: Replace this with your CORDIC IP Core.
            // Map 'phase_i' to the 'PHASE_IN' port of the IP.
            behavioral_cordic #(
                .WIDTH(OSC_WIDTH),
                .PHASE_WIDTH(PHASE_WIDTH)
            ) cordic_inst (
                .clk_i(clk_i),
                .phase_i(phase_acc[k]),
                .cos_o(cos_out),
                .sin_o(sin_out)
            );
            
            // Map outputs to W (DFT requires exp(-j*theta) = cos - j*sin)
            // W_real = cos(theta)
            // W_imag = -sin(theta) (or sin(-theta))
            assign W_real_o[k] = cos_out;
            assign W_imag_o[k] = -sin_out; 
        end
    endgenerate

endmodule


// =============================================================================
// Behavioral CORDIC (For Simulation Only)
// =============================================================================
// This mimics the latency and behavior of a Xilinx CORDIC 6.0 IP core
// in "Sin/Cos" mode with Pipelining.
module behavioral_cordic #(
    parameter int WIDTH = 27,
    parameter int PHASE_WIDTH = 32
)(
    input  logic clk_i,
    input  logic [PHASE_WIDTH-1:0] phase_i, // Fixed point phase: 0 = 0 rad, 2^32 = 2*pi
    output logic signed [WIDTH-1:0] cos_o,
    output logic signed [WIDTH-1:0] sin_o
);

    // Xilinx CORDIC usually has latency approx equal to WIDTH or WIDTH/2
    localparam int LATENCY = 20; 
    
    // We use reals for simulation accuracy, then quantize back
    real phase_rad;
    real cos_real, sin_real;
    
    // Shift register for pipeline delay simulation
    logic signed [WIDTH-1:0] cos_pipe [LATENCY];
    logic signed [WIDTH-1:0] sin_pipe [LATENCY];
    
    always_comb begin
        // 1. Convert Fixed Point Phase to Radians
        // phase_i is unsigned [0, 2^32) mapping to [0, 2pi)
        // Check for signed/unsigned interpretation in your specific IP settings
        phase_rad = (real'(phase_i) / (2.0**PHASE_WIDTH)) * 2.0 * 3.14159265359;
        
        // 2. Compute Sin/Cos
        cos_real = $cos(phase_rad);
        sin_real = $sin(phase_rad);
    end

    always_ff @(posedge clk_i) begin
        // 3. Quantize to Fixed Point Output (Q3.24 for 27 bits roughly)
        // Assuming user wants full scale range usage.
        // Usually CORDIC outputs are Q1.N-2
        
        // Scale by 2^(WIDTH-2) to leave room for sign and integer bit
        cos_pipe[0] <= $rtoi(cos_real * (2.0**(WIDTH-2)));
        sin_pipe[0] <= $rtoi(sin_real * (2.0**(WIDTH-2)));
        
        // 4. Pipeline Shift
        for (int i = 1; i < LATENCY; i++) begin
            cos_pipe[i] <= cos_pipe[i-1];
            sin_pipe[i] <= sin_pipe[i-1];
        end
    end

    assign cos_o = cos_pipe[LATENCY-1];
    assign sin_o = sin_pipe[LATENCY-1];

endmodule