%% Generic LPF Design Script
% Designs a Low Pass Filter with a specific number of taps and a specific
% 3dB cutoff frequency. Exports coefficients to a text file.

clear; close all; clc;

%% 1. Input Parameters

% Decimation Factor (Determines number of taps)
I = 4; 

% 3dB Cutoff Frequency (Normalized 0 to 1)
% 1.0 corresponds to the Nyquist frequency (Fs/2).
% Example: If Fs=125MHz, Nyquist=62.5MHz. 
% For a 5MHz cutoff: f_3dB = 5 / 62.5 = 0.08
fs = 125;
fc = 3;
f_3dB = fc * 2 / fs; 

% Output filename
output_file = 'generic_lpf_coeffs.txt';

%% 2. Design Filter

% Hardware Constraint: Number of taps is 16 * I
num_taps = 16 * I;

% Filter Order is always Taps - 1
filter_order = num_taps - 1;

fprintf('Designing Filter...\n');
fprintf('  Decimation (I): %d\n', I);
fprintf('  Num Taps:       %d\n', num_taps);
fprintf('  Order (N):      %d\n', filter_order);
fprintf('  3dB Cutoff:     %.4f (Normalized)\n', f_3dB);

% Create filter specification object
Hd = designfilt('lowpassfir', ...
    'FilterOrder', filter_order, ...
    'CutoffFrequency', f_3dB, ...
    'Window', 'hamming', ...
    'DesignMethod', 'window');

coeffs = Hd.Coefficients;


%% 3. Verify Design (Plotting)

fprintf('Plotting Frequency Response...\n');

% Calculate Frequency Response
[h, w] = freqz(coeffs, 1, 4096);
mag_db = 20*log10(abs(h));
norm_freq = w/pi; % 0 to 1

% Find actual attenuation at requested cutoff
% (Interpolate to find exact value at f_3dB)
act_atten = interp1(norm_freq, mag_db, f_3dB);

figure('Position', [100, 100, 1000, 600]);
plot(norm_freq, mag_db, 'b', 'LineWidth', 2); hold on;

% Mark the 3dB point
xline(f_3dB, 'r--', 'LineWidth', 1.5, 'Label', 'Target 3dB Freq');
yline(-3, 'k:', 'LineWidth', 1.5, 'Label', '-3dB');
plot(f_3dB, act_atten, 'ro', 'MarkerFaceColor', 'r');

grid on;
title(sprintf('Generic LPF Magnitude Response (Order=%d)', filter_order));
xlabel('Normalized Frequency (\times\pi rad/sample)');
ylabel('Magnitude (dB)');
ylim([-100 5]);
xlim([0 1]);

text(f_3dB + 0.02, -10, sprintf('Measured Attenuation\nat Cutoff: %.3f dB', act_atten));

%% 4. Export Coefficients

fprintf('Exporting coefficients to %s...\n', output_file);

fid = fopen(output_file, 'w');

% Write Header
fprintf(fid, '%% Generic LPF Coefficients\n');
fprintf(fid, '%% Decimation Ratio (I): %d\n', I);
fprintf(fid, '%% Number of Taps: %d\n', num_taps);
fprintf(fid, '%% Filter Order: %d\n', filter_order);
fprintf(fid, '%% 3dB Cutoff Freq: %.4f\n', f_3dB);
fprintf(fid, '%% ---------------------------------\n');

% Write Coefficients (High precision float)
fprintf(fid, '%.15e\n', coeffs);

fclose(fid);

fprintf('Done!\n');