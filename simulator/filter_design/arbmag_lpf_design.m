function [Hd, coeffs] = arbmag_lpf_design(I, bw_edge, edge_boost_db, varargin)
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
%
% Outputs:
%   Hd     - Digital filter object
%   coeffs - Filter coefficients
%
% Example:
%   I = 4;
%   bw_edge = 0.3;
%   edge_boost_db = 10;
%   [Hd, coeffs] = arbmag_lpf_design(I, bw_edge, edge_boost_db);

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
    fprintf('Designing filter with %d taps (order N = %d)\n', num_taps, N);
    fprintf('Passband edge: %.4f (normalized frequency)\n', bw_edge);
    fprintf('Edge boost: %.1f dB\n', edge_boost_db);
    
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
    f_trans = linspace(bw_edge + 0.001, bw_edge + trans_width, 50);
    A_trans = linspace(A_pass(end), stopband_linear, length(f_trans));
    
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
        fprintf('Filter design successful! Number of coefficients: %d\n', length(coeffs));
    catch ME
        warning('SystemObject design failed, trying legacy method...');
        Hd = design(d, 'freqsamp');
        coeffs = Hd.Numerator;
        fprintf('Filter design successful! Number of coefficients: %d\n', length(coeffs));
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
                    % Using inverted parabola: y = 1 + (boost-1) * (-4*(t-0.5)^2 + 1)
                    A_pass(i) = 1 + (edge_boost - 1) * (1 - 4*(t - 0.5)^2);
                    
                case 'cosine'
                    % Smooth cosine-based transition
                    % Peaks in the middle of the boost region
                    A_pass(i) = 1 + (edge_boost - 1) * (1 - cos(2*pi*t))/2;
                    
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
    
    figure('Position', [100 100 1200 800]);
    
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

%% Example usage
% Uncomment to run as standalone script
%{
% Example parameters
I = 4;                % Decimation ratio
bw_edge = 0.3;        % Normalized bandwidth edge (0.3 * Nyquist)
edge_boost_db = 10;   % 10 dB boost near edges

% Design filter with default settings
[Hd, coeffs] = arbmag_lpf_design(I, bw_edge, edge_boost_db);

% Design with custom settings
[Hd2, coeffs2] = arbmag_lpf_design(I, bw_edge, edge_boost_db, ...
    'TransitionWidth', 0.08, ...
    'BoostWidth', 0.25, ...
    'ShapeFunction', 'gaussian', ...
    'StopbandAtten', 70);

% Display filter properties
fprintf('\nFilter coefficients (first 10): \n');
disp(coeffs(1:10));

% Save coefficients to file
save('lpf_coefficients.mat', 'coeffs', 'I', 'bw_edge', 'edge_boost_db');
fprintf('\nCoefficients saved to lpf_coefficients.mat\n');
%}