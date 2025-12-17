%% Arbitrary Magnitude LPF Design - Example Script
% This script demonstrates how to design a lowpass filter with
% passband edge boosting for signal equalization

clear; close all; clc;

%% Input Parameters

% Decimation ratio (already calculated based on signal analysis)
I = 4;  % Example: decimation ratio of 4

% Bandwidth edge where signal is at -30dB (normalized frequency, 0 to 1)
% where 1 corresponds to the Nyquist frequency (Fs/2)
fs = 125;
fc = 3;
bw_edge = fc * 2 / fs;  % Example: 0.3 means the signal BW edge is at 0.3*Fs/2

% Edge boost to compensate for signal rolloff (in dB)
edge_boost_db = 10;  % 10 dB boost near passband edges

%% Design Filter with Different Shape Functions

fprintf('=== Comparing Different Passband Shapes ===\n\n');

% 1. Cosine-shaped boost (smooth, recommended)
fprintf('1. Designing with COSINE shape...\n');
[Hd_cos, coeffs_cos] = arbmag_lpf_design(I, bw_edge, edge_boost_db, ...
    'ShapeFunction', 'cosine', ...
    'BoostWidth', 0.25, ...
    'TransitionWidth', 0.05);

% 2. Quadratic-shaped boost
fprintf('\n2. Designing with QUADRATIC shape...\n');
[Hd_quad, coeffs_quad] = arbmag_lpf_design(I, bw_edge, edge_boost_db, ...
    'ShapeFunction', 'quadratic', ...
    'BoostWidth', 0.25, ...
    'TransitionWidth', 0.05, ...
    'PlotResponse', false);

% 3. Gaussian-shaped boost
fprintf('\n3. Designing with GAUSSIAN shape...\n');
[Hd_gauss, coeffs_gauss] = arbmag_lpf_design(I, bw_edge, edge_boost_db, ...
    'ShapeFunction', 'gaussian', ...
    'BoostWidth', 0.25, ...
    'TransitionWidth', 0.05, ...
    'PlotResponse', false);

%% Compare All Three Designs

figure('Position', [100 100 1400 600]);

subplot(1,2,1);
[h_cos, w] = freqz(coeffs_cos, 1, 2048);
[h_quad, ~] = freqz(coeffs_quad, 1, 2048);
[h_gauss, ~] = freqz(coeffs_gauss, 1, 2048);

plot(w/pi, abs(h_cos), 'b', 'LineWidth', 2); hold on;
plot(w/pi, abs(h_quad), 'r', 'LineWidth', 2);
plot(w/pi, abs(h_gauss), 'g', 'LineWidth', 2);
xline(bw_edge, 'k--', 'LineWidth', 1.5);
grid on;
xlabel('Normalized Frequency (\times\pi rad/sample)');
ylabel('Magnitude');
title('Magnitude Response Comparison (Linear)');
legend('Cosine', 'Quadratic', 'Gaussian', 'BW Edge', 'Location', 'best');
xlim([0 0.6]);

subplot(1,2,2);
plot(w/pi, 20*log10(abs(h_cos)), 'b', 'LineWidth', 2); hold on;
plot(w/pi, 20*log10(abs(h_quad)), 'r', 'LineWidth', 2);
plot(w/pi, 20*log10(abs(h_gauss)), 'g', 'LineWidth', 2);
xline(bw_edge, 'k--', 'LineWidth', 1.5);
yline(edge_boost_db, 'k:', 'LineWidth', 1);
yline(-30, 'm:', 'LineWidth', 1);
grid on;
xlabel('Normalized Frequency (\times\pi rad/sample)');
ylabel('Magnitude (dB)');
title('Magnitude Response Comparison (dB)');
legend('Cosine', 'Quadratic', 'Gaussian', 'BW Edge', 'Location', 'best');
xlim([0 0.6]);
ylim([-80 15]);

%% Advanced Example: Fine-tuning the Design

fprintf('\n=== Advanced Design with Custom Parameters ===\n');

% Custom parameters
custom_boost_width = 0.03;      % Wider boost region (30% of passband)
custom_trans_width = 0.008;     % Wider transition band
custom_stopband_atten = 80;    % Higher stopband attenuation

[Hd_custom, coeffs_custom] = arbmag_lpf_design(I, bw_edge, edge_boost_db, ...
    'ShapeFunction', 'cosine', ...
    'BoostWidth', custom_boost_width, ...
    'TransitionWidth', custom_trans_width, ...
    'StopbandAtten', custom_stopband_atten);

%% Export Coefficients

% Export as MAT file
% save('filter_coefficients.mat', 'coeffs_cos', 'coeffs_quad', ...
%     'coeffs_gauss', 'coeffs_custom', 'I', 'bw_edge', 'edge_boost_db');

% Export as text file (for use in other languages/platforms)
fid = fopen('filter_coefficients.txt', 'w');
fprintf(fid, '%% Filter Coefficients (Cosine Shape)\n');
fprintf(fid, '%% Number of Taps: %d\n', length(coeffs_cos));
fprintf(fid, '%% Filter Order: %d\n', length(coeffs_cos)-1);
fprintf(fid, '%% Decimation Ratio (I): %d\n', I);
fprintf(fid, '%% Bandwidth Edge: %.4f\n', bw_edge);
fprintf(fid, '%% Edge Boost: %.1f dB\n\n', edge_boost_db);
fprintf(fid, '%.15e\n', coeffs_cos);
fclose(fid);

fprintf('\nCoefficients exported to:\n');
fprintf('  - filter_coefficients.mat\n');
fprintf('  - filter_coefficients.txt\n');

%% Display Summary Statistics

fprintf('\n=== Filter Summary ===\n');
fprintf('Number of taps: %d (= 16 × I = 16 × %d)\n', length(coeffs_cos), I);
fprintf('Filter Order: %d\n', length(coeffs_cos)-1);
fprintf('Passband edge: %.4f × π rad/sample (%.2f%% of Nyquist)\n', ...
    bw_edge, bw_edge*100);
fprintf('Edge boost: %.1f dB\n', edge_boost_db);

% Measure actual passband ripple
passband_idx = w/pi <= bw_edge;
passband_response_db = 20*log10(abs(h_cos(passband_idx)));
passband_max = max(passband_response_db);
passband_min = min(passband_response_db);
fprintf('Passband ripple: %.2f dB (%.2f to %.2f dB)\n', ...
    passband_max - passband_min, passband_min, passband_max);

% Measure stopband attenuation
stopband_idx = w/pi >= bw_edge + 0.1;
stopband_response_db = 20*log10(abs(h_cos(stopband_idx)));
stopband_max = max(stopband_response_db);
fprintf('Stopband attenuation: %.1f dB\n', -stopband_max);

fprintf('\nDesign complete!\n');