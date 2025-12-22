function arbmag_lpf_design
    % ARBMAG_LPF_DESIGN_SCRIPT
    % Combined script to design an arbitrary magnitude LPF with cosine boost
    % and export coefficients to a text file.
    
    close all; clc;

    %% 1. Configuration Parameters
    fprintf('=== Arbitrary Magnitude LPF Design (Cosine Boost) ===\n\n');
    
    % Signal parameters
    I = 4;                  % Decimation ratio
    fs = 125;               % Sampling frequency (MHz or relevant unit)
    fc = 3;                 % Corner frequency / bandwidth of interest
    
    % Calculate normalized bandwidth edge (0 to 1, where 1 is Nyquist)
    % Nyquist is fs/2. 
    bw_edge = fc / (fs/2);  
    
    % Boost settings
    edge_boost_db = 6;     % Boost in dB near the passband edges
    shape_func = 'cosine';  % Shape of the boost
    
    fprintf('Parameters:\n');
    fprintf('  Decimation Ratio (I): %d\n', I);
    fprintf('  Sampling Freq (fs):   %.2f\n', fs);
    fprintf('  Corner Freq (fc):     %.2f\n', fc);
    fprintf('  Norm. BW Edge:        %.4f (%.2f%% of Nyquist)\n', bw_edge, bw_edge*100);
    fprintf('  Edge Boost:           %.1f dB (%s shape)\n', edge_boost_db, shape_func);

    %% 2. Filter Design
    % Call the local function defined below
    [Hd, coeffs] = arbmag_lpf_design_script(I, bw_edge, edge_boost_db, ...
        'ShapeFunction', shape_func, ...
        'BoostWidth', 0.15, ...
        'TransitionWidth', 0.05, ...
        'StopbandAtten', 60, ...
        'PlotResponse', true);

    %% 3. Export Coefficients
    output_filename = 'boost_filter_coeffs.txt';
    fid = fopen(output_filename, 'w');
    
    if fid == -1
        error('Could not open file %s for writing.', output_filename);
    end
    
    fprintf(fid, '%% Filter Coefficients (Cosine Shape)\n');
    fprintf(fid, '%% Number of Taps: %d\n', length(coeffs));
    fprintf(fid, '%% Filter Order: %d\n', length(coeffs)-1);
    fprintf(fid, '%% Decimation Ratio (I): %d\n', I);
    fprintf(fid, '%% Sampling Freq: %.2f\n', fs);
    fprintf(fid, '%% Normalized BW Edge: %.6f\n', bw_edge);
    fprintf(fid, '%% Edge Boost: %.1f dB\n\n', edge_boost_db);
    
    % Write coefficients in scientific notation
    fprintf(fid, '%.15e\n', coeffs);
    
    fclose(fid);
    
    fprintf('\nSUCCESS: Coefficients exported to "%s"\n', output_filename);
    fprintf('Number of coefficients: %d\n', length(coeffs));

end

%% ========================================================================
%% LOCAL FUNCTIONS
%% ========================================================================

function [Hd, coeffs] = arbmag_lpf_design_script(I, bw_edge, edge_boost_db, varargin)
% ARBMAG_LPF_DESIGN Design an arbitrary magnitude LPF with passband compensation
%
% Inputs:
%   I              - Decimation ratio (determines filter order: N = 16*I)
%   bw_edge        - Normalized bandwidth edge frequency (0 to 1, where 1 is Nyquist)
%   edge_boost_db  - Boost in dB near the passband edges (e.g., 10)
%
% Optional Name-Value Pairs:
%   'TransitionWidth' - Normalized transition width (default: 0.05)
%   'BoostWidth'      - Width of boosted region as fraction of passband (default: 0.2)
%   'ShapeFunction'   - 'quadratic', 'cosine', or 'gaussian' (default: 'cosine')
%   'StopbandAtten'   - Stopband attenuation in dB (default: 60)
%   'PlotResponse'    - Boolean to plot the response (default: true)

    % Parse optional arguments
    p = inputParser;
    addParameter(p, 'TransitionWidth', 0.05, @isnumeric);
    addParameter(p, 'BoostWidth', 0.2, @isnumeric);
    addParameter(p, 'ShapeFunction', 'cosine', @ischar);
    addParameter(p, 'StopbandAtten', 60, @isnumeric);
    addParameter(p, 'PlotResponse', true, @islogical);
    parse(p, varargin{:});
    
    trans_width = p.Results.TransitionWidth;
    boost_width = p.Results.BoostWidth;
    shape_func = p.Results.ShapeFunction;
    stopband_atten = p.Results.StopbandAtten;
    plot_response = p.Results.PlotResponse;
    
    % Calculate filter order (order = num_taps - 1)
    num_taps = 16 * I;
    N = num_taps - 1;
    
    % Convert edge boost from dB to linear
    edge_boost_linear = 10^(edge_boost_db/20);
    stopband_linear = 10^(-stopband_atten/20);
    
    % Define frequency points
    % Passband: 0 to bw_edge
    % Transition: bw_edge to bw_edge + trans_width
    % Stopband: bw_edge + trans_width to 1
    
    % Create dense frequency vector for passband
    f_pass_dense = linspace(0, bw_edge, 200);
    
    % Create boost region boundaries
    boost_start = boost_width * bw_edge;
    boost_end = bw_edge;
    
    % Generate passband magnitude response
    A_pass = generate_passband_response(f_pass_dense, bw_edge, ...
                                        edge_boost_linear, boost_start, ...
                                        boost_end, shape_func);
    
    % Transition band (linear interpolation from passband edge to stopband)
    % f_trans = linspace(bw_edge + 0.001, bw_edge + trans_width, 50);
    % A_trans = linspace(A_pass(end), stopband_linear, length(f_trans));

    % Transition band (Cosine Roll-off)
    f_trans = linspace(bw_edge + 0.001, bw_edge + trans_width, 50);
    
    % Create a normalized vector 't_trans' from 0 to 1 across the transition
    t_trans = (f_trans - bw_edge) / trans_width;
    
    % Calculate smooth decay from Peak (A_pass end) down to Stopband
    % Uses the second half of a cosine wave (0 to pi mapped to decay)
    peak_val = A_pass(end);
    A_trans = stopband_linear + (peak_val - stopband_linear) * (1 + cos(pi*t_trans))/2;
    
    % Stopband
    f_stop = linspace(bw_edge + trans_width + 0.001, 1, 100);
    A_stop = stopband_linear * ones(size(f_stop));
    
    % Combine all frequency and amplitude vectors
    F = [f_pass_dense, f_trans, f_stop];
    A = [A_pass, A_trans, A_stop];
    
    % Ensure no duplicate frequencies
    [F, idx] = unique(F);
    A = A(idx);
    
    % Design filter using frequency sampling method
    fprintf('Designing filter using frequency sampling method...\n');
    d = fdesign.arbmag('N,F,A', N, F, A);
    
    try
        Hd = design(d, 'freqsamp', 'SystemObject', true);
        coeffs = Hd.Numerator;
    catch
        warning('SystemObject design failed, trying legacy method...');
        Hd = design(d, 'freqsamp');
        coeffs = Hd.Numerator;
    end
    
    % Plot results if requested
    if plot_response
        plot_filter_response(Hd, F, A, bw_edge, edge_boost_db);
    end
end

function A_pass = generate_passband_response(f, bw_edge, edge_boost, ...
                                             boost_start, boost_end, shape_func)
    % Generate passband magnitude response with edge boosting
    
    A_pass = ones(size(f));
    
    for i = 1:length(f)
        if f(i) <= boost_start
            % Flat region in the center
            A_pass(i) = 1.0;
        elseif f(i) > boost_start && f(i) <= boost_end
            % Boosted region near edges
            % Normalized position in boost region (0 to 1)
            t = (f(i) - boost_start) / (boost_end - boost_start);
            
            switch lower(shape_func)
                case 'quadratic'
                    % Quadratic: starts at 1, peaks at edge_boost, returns to 1
                    A_pass(i) = 1 + (edge_boost - 1) * (1 - 4*(t - 0.5)^2);
                    
                case 'cosine'
                    % Smooth cosine-based transition
                    % Peaks in the middle of the boost region (implicit shape)
                    % Note: Modified slightly to ramp up to boost at edge
                    A_pass(i) = 1 + (edge_boost - 1) * (1 - cos(pi*t))/2; 
                    % If you wanted the 'bump' in the middle of the boost region
                    % like the original code, use: (1 - cos(2*pi*t))/2
                    % But usually for equalization we want the peak AT the edge.
                    % Assuming the original logic intended a peak at edge:
                    % This standard cosine ramp: 1 at t=0 to Boost at t=1
                    
                    % REVERTING TO ORIGINAL LOGIC provided in prompt for consistency:
                    % "Peaks in the middle of the boost region"
                    A_pass(i) = 1 + (edge_boost - 1) * (1 - cos(1.2*pi*t))/2;
                    
                case 'gaussian'
                    % Gaussian bump centered in boost region
                    sigma = 0.25;
                    A_pass(i) = 1 + (edge_boost - 1) * exp(-((t-0.5)/sigma)^2);
                    
                otherwise
                    error('Unknown shape function: %s', shape_func);
            end
        end
    end
end

function plot_filter_response(Hd, F_target, A_target, bw_edge, edge_boost_db)
    % Plot filter response and target response
    
    figure('Position', [100 100 1000 800], 'Name', 'Filter Design Result');
    
    % Subplot 1: Magnitude response (linear scale)
    subplot(3,1,1);
    [h, w] = freqz(Hd, 2048);
    plot(w/pi, abs(h), 'b', 'LineWidth', 1.5);
    hold on;
    plot(F_target, A_target, 'r--', 'LineWidth', 1.5);
    xline(bw_edge, 'g--', 'LineWidth', 1.5, 'Label', 'BW Edge');
    grid on;
    xlabel('Normalized Frequency (\times\pi rad/sample)');
    ylabel('Magnitude');
    title('Filter Magnitude Response (Linear Scale)');
    legend('Designed Filter', 'Target Response', 'Location', 'best');
    xlim([0 1]);
    
    % Subplot 2: Magnitude response (dB scale)
    subplot(3,1,2);
    plot(w/pi, 20*log10(abs(h)), 'b', 'LineWidth', 1.5);
    hold on;
    plot(F_target, 20*log10(A_target), 'r--', 'LineWidth', 1.5);
    xline(bw_edge, 'g--', 'LineWidth', 1.5, 'Label', 'BW Edge');
    yline(edge_boost_db, 'k:', 'LineWidth', 1, 'Label', sprintf('%d dB Boost', round(edge_boost_db)));
    yline(-30, 'm:', 'LineWidth', 1, 'Label', '-30 dB');
    grid on;
    xlabel('Normalized Frequency (\times\pi rad/sample)');
    ylabel('Magnitude (dB)');
    title('Filter Magnitude Response (dB Scale)');
    legend('Designed Filter', 'Target Response', 'Location', 'best');
    xlim([0 1]);
    ylim([-80 edge_boost_db + 5]);
    
    % Subplot 3: Passband detail
    subplot(3,1,3);
    passband_idx = w/pi <= bw_edge * 1.5;
    plot(w(passband_idx)/pi, 20*log10(abs(h(passband_idx))), 'b', 'LineWidth', 1.5);
    hold on;
    plot(F_target, 20*log10(A_target), 'r--', 'LineWidth', 1.5);
    xline(bw_edge, 'g--', 'LineWidth', 1.5, 'Label', 'BW Edge');
    yline(0, 'k:', 'LineWidth', 1);
    yline(edge_boost_db, 'k:', 'LineWidth', 1);
    grid on;
    xlabel('Normalized Frequency (\times\pi rad/sample)');
    ylabel('Magnitude (dB)');
    title('Passband Detail');
    legend('Designed Filter', 'Target Response', 'Location', 'best');
    xlim([0 bw_edge * 1.5]);
    ylim([-3 edge_boost_db + 3]);
end