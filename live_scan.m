%--------------------------------------------------------------------------
% live_scan.m
% June 2026 (updated August 2026)
%
% Description:
% Real-time NanoVNA radar acquisition with multiple live clutter
% suppression methods. Saves raw S21 data to enable flexible 
% post processing
%
% Notes:
% - All filtering only affects visualization
% - Raw S21 data is saved
% - H5 and basic .mat saving is supported
%--------------------------------------------------------------------------

clc;
clear;

%--------------------------------------------------------------------------
% Configuration
%--------------------------------------------------------------------------

codec = ConfigCodec();
config = [];

%--------------------------------------------------------------------------
% NanoVNA / Scan Configuration
%--------------------------------------------------------------------------

% com_port                 = 'com3';
com_port               = '/dev/ttyACM0';
config.f_lower           = 300e6;
config.f_upper           = 1500e6;
config.n_frequency_steps = 200; % Large number of scans to enable frequency selection in post processing; can be reduced for faster scans (be aware of unambiguous range)
config.n_scans_plotted   = 100;
config.t_max             = 50e-9;
config.time_plot_lim_ns  = [0 40];
config.ascan_ylim        = [-7 7]*1e7;

%--------------------------------------------------------------------------
% Experiment Metadata
%--------------------------------------------------------------------------

config.target_range = 0.3;
config.target_description = 'square';
config.soil_description = 'dry mulch';

config.waveform = [num2str(config.f_lower) ':'  num2str(config.f_upper) '('  num2str(config.n_frequency_steps) ')'];

config.platform = codec.resolve('platform','nanovna');
config.amp_tx = codec.resolve('amplifier','amp');
config.amp_rx = codec.resolve('amplifier','amp');
config.ant_tx = codec.resolve('antenna','viv');
config.ant_rx = codec.resolve('antenna','viv');
config.version = 0;

config.radar_configuration_str = ...
    codec.encode(...
        config.platform, ...
        config.amp_tx, ...
        config.amp_rx, ...
        config.ant_tx, ...
        config.ant_rx, ...
        config.version);


%--------------------------------------------------------------------------
% Acquisition Mode
%--------------------------------------------------------------------------

config.mode = 'continuous';
% config.mode = 'manual';
% config.mode = 'timed'; delaySec = 4;


%--------------------------------------------------------------------------
% Filtering Configuration
%--------------------------------------------------------------------------

config.enable_baseline_filter = true;
config.rolling_window = 20;
config.pca_window = 20;
config.pca_remove_components = 2;
config.ascan_average_count = 10;
config.baseline_scan_count = 10;
config.window_function = 'hann';

%--------------------------------------------------------------------------
% Saving Configuration
%--------------------------------------------------------------------------

config.save_mat_enabled = true;
config.save_hdf5_enabled = true;

default_path = sprintf('./data/%s/', datestr(now, 'yyyymmdd'));
if ~exist(default_path, 'dir'), mkdir(default_path); end
config.save_folder = default_path;

config.variables_to_save_mat = { ...
    'S21_raw_history', ...
    'f', ...
    'config', ...
    'notes'};

%--------------------------------------------------------------------------
% Console Info
%--------------------------------------------------------------------------

disp('--------------------------------------------------');
disp('NanoVNA Multifilter Radar Acquisition');
disp('--------------------------------------------------');

switch lower(config.mode)
    case 'continuous'
        disp('Mode: Continuous');
    case 'manual'
        disp('Mode: Manual');
    case 'timed'
        disp(['Mode: Timed (' num2str(delaySec) ' sec delay)']);
    otherwise
        error('Unknown acquisition mode');
end

disp('ESC = stop acquisition');

%--------------------------------------------------------------------------
% Cleanup Existing Serial Port
%--------------------------------------------------------------------------

try
    nanovna.cleanupNanoVNA(sp);
catch
end

%--------------------------------------------------------------------------
% Setup NanoVNA
%--------------------------------------------------------------------------

sp = nanovna.setupNanoVNA(com_port);
cleanObj = onCleanup(@() nanovna.cleanupNanoVNA(sp));

%--------------------------------------------------------------------------
% Window Function
%--------------------------------------------------------------------------

switch lower(config.window_function)
    case 'hann'
        window = hann(config.n_frequency_steps);
    case 'hamming'
        window = hamming(config.n_frequency_steps);
    otherwise
        error('Unsupported window type');
end

%--------------------------------------------------------------------------
% Initial Scan
%--------------------------------------------------------------------------

disp('Performing initial scan...');
[f, ~, S21_init] = doNanoVNAScan(sp, config.f_lower, config.f_upper, config.n_frequency_steps);
df_k = [diff(f); diff(f(end-1:end))];

%--------------------------------------------------------------------------
% Time Axis Setup
%--------------------------------------------------------------------------
dt = 1e-10; % Adjusted per VT request
t_s = 0:dt:config.t_max;
t_ns = t_s * 1e9;
Nt   = length(t_s);

%--------------------------------------------------------------------------
% Baseline Collection
%--------------------------------------------------------------------------

if config.enable_baseline_filter
    disp('Collecting baseline scans...');
    S21_baseline = get_baseline_S21(...
        sp, ...
        config.f_lower, ...
        config.f_upper, ...
        config.n_frequency_steps, ...
        config.baseline_scan_count);

    disp('Baseline collection complete');
else
    S21_baseline = zeros(size(S21_init));
end

%--------------------------------------------------------------------------
% Figure Setup - A Scans
%--------------------------------------------------------------------------

figA = figure(1);
clf(figA);
set(figA,'Color','white');
tloA = tiledlayout(figA,3,1, 'Padding','compact', 'TileSpacing','compact');

axA1 = nexttile(tloA);
axA2 = nexttile(tloA);
axA3 = nexttile(tloA);

axesA = [axA1 axA2 axA3];

titlesA = { ...
    'Raw A-Scan', ...
    'Baseline Subtracted A-Scan', ...
    'Rolling Average Subtracted A-Scan'};

for k = 1:3
    ax = axesA(k);
    hold(ax,'on');
    hA_recent(k) = plot(ax, t_ns, nan(Nt,1), 'b-');
    hA_average(k) = plot(ax, t_ns, nan(Nt,1), 'k--');
    grid(ax,'on');
    xlabel(ax,'Time (ns)');
    ylabel(ax,'Amplitude');
    title(ax, titlesA{k}, 'FontWeight','normal');
    xlim(ax, config.time_plot_lim_ns);
    ylim(ax, config.ascan_ylim);
end

legend(axA1, ...
    'Most Recent', ...
    ['Average of Last ' ...
    num2str(config.ascan_average_count)]);

%--------------------------------------------------------------------------
% Figure Setup - B Scans
%--------------------------------------------------------------------------

figB = figure(2);
clf(figB);
set(figB,'Color','white');
tloB = tiledlayout(figB,3,1, 'Padding','compact', 'TileSpacing','compact');
axB1 = nexttile(tloB);
axB2 = nexttile(tloB);
axB3 = nexttile(tloB);
axesB = [axB1 axB2 axB3];
titlesB = { 'Raw B-Scan', 'Rolling Average Subtracted B-Scan', 'PCA Clutter Reduced B-Scan'};
initial_bscan = nan(Nt, config.n_scans_plotted);
xrange = [1 config.n_scans_plotted];
yrange = [t_ns(1) t_ns(end)];

for k = 1:3
    ax = axesB(k);
    hB(k) = imagesc(ax, xrange, yrange, initial_bscan);

    % Greyscale is often recommended in the literature. 
    % However, it may be worth experimenting with other 
    % maps to help different features stand out
    colormap(ax,'gray'); 
    % colormap(ax,'nebula');
    % colormap(ax,'parula');
    colorbar(ax);

    xlabel(ax,'Scan Index');
    ylabel(ax,'Time (ns)');
    title(ax, titlesB{k}, 'FontWeight','normal');
    set(ax,'YDir','reverse');
    ylim(ax, config.time_plot_lim_ns);
end

%--------------------------------------------------------------------------
% Shared Keyboard Controls
%--------------------------------------------------------------------------

setappdata(figA,'stopNow',false);
setappdata(figB,'stopNow',false);

setappdata(figA,'lastKey','');
setappdata(figB,'lastKey','');

set(figA,'KeyPressFcn', @(src,event) keypress_callback(figA,figB,event));
set(figB,'KeyPressFcn', @(src,event) keypress_callback(figA,figB,event));

%--------------------------------------------------------------------------
% Wait for User
%--------------------------------------------------------------------------

disp('Press SPACE to begin acquisition');
while true
    key = getappdata(figB,'lastKey');
    setappdata(figB,'lastKey','');
    if strcmp(key,'space')
        break;
    end
    pause(0.05);
end

%--------------------------------------------------------------------------
% History Allocation
%--------------------------------------------------------------------------

history_chunk_size = 1000;
S21_raw_history = complex(nan(config.n_frequency_steps, history_chunk_size));
raw_ascan_history = nan(Nt, config.n_scans_plotted);
baseline_ascan_history = nan(Nt, config.n_scans_plotted);
rolling_ascan_history = nan(Nt, config.n_scans_plotted);
pca_ascan_history = nan(Nt, config.n_scans_plotted);

%--------------------------------------------------------------------------
% Rolling Background Initialization
%--------------------------------------------------------------------------

rolling_background = S21_init;

%--------------------------------------------------------------------------
% Loop Counter
%--------------------------------------------------------------------------

loop_count = 0;
disp('Acquisition running...');

%--------------------------------------------------------------------------
% Main Acquisition Loop
%--------------------------------------------------------------------------

while ~getappdata(figB,'stopNow')
    %--------------------------------------------------------------
    % Acquire Scan
    %--------------------------------------------------------------

    [f, ~, S21] = doNanoVNAScan(sp, config.f_lower, config.f_upper, config.n_frequency_steps);
    loop_count = loop_count + 1;

    %--------------------------------------------------------------
    % Expand Raw Storage If Needed
    %--------------------------------------------------------------

    if loop_count > size(S21_raw_history,2)
        S21_raw_history = [S21_raw_history ...
            complex(nan(config.n_frequency_steps,history_chunk_size))];
    end

    %--------------------------------------------------------------
    % Save Raw Data
    %--------------------------------------------------------------

    S21_raw_history(:,loop_count) = S21;

    %--------------------------------------------------------------
    % Raw Branch
    %--------------------------------------------------------------

    raw_ascan = compute_ascan(S21, f, df_k, t_s, window);

    %--------------------------------------------------------------
    % Baseline Branch
    %--------------------------------------------------------------

    baseline_S21 = S21 - S21_baseline;
    baseline_ascan = compute_ascan(baseline_S21, f, df_k, t_s, window);

    %--------------------------------------------------------------
    % Rolling Average Branch
    %--------------------------------------------------------------

    if loop_count == 1
        rolling_background = S21;
    else
        alpha = (config.rolling_window - 1) / config.rolling_window;
        rolling_background = alpha .* rolling_background + (1-alpha) .* S21;
    end

    rolling_S21 = S21 - rolling_background;
    rolling_ascan = compute_ascan(rolling_S21, f, df_k, t_s, window);

    %--------------------------------------------------------------
    % Update Histories
    %--------------------------------------------------------------

    raw_ascan_history(:,1:end-1) = raw_ascan_history(:,2:end);
    raw_ascan_history(:,end) = real(raw_ascan);
    baseline_ascan_history(:,1:end-1) = baseline_ascan_history(:,2:end);
    baseline_ascan_history(:,end) = real(baseline_ascan);
    rolling_ascan_history(:,1:end-1) = rolling_ascan_history(:,2:end);
    rolling_ascan_history(:,end) = real(rolling_ascan);

    %--------------------------------------------------------------
    % PCA Processing
    %--------------------------------------------------------------

    pca_column = real(rolling_ascan);

    valid_columns = find(~all(isnan(rolling_ascan_history),1));

    % if numel(valid_columns) >= 3
    if numel(valid_columns) > config.pca_remove_components
        pca_window = min(config.pca_window, numel(valid_columns));
        X = rolling_ascan_history(:, valid_columns(end-pca_window+1:end));
        pca_column = apply_pca_filter(X, config.pca_remove_components);

    end

    %--------------------------------------------------------------
    % Update PCA History
    %--------------------------------------------------------------

    pca_ascan_history(:,1:end-1) = pca_ascan_history(:,2:end);
    pca_ascan_history(:,end) = pca_column;

    %--------------------------------------------------------------
    % Average Trace Calculations
    %--------------------------------------------------------------

    avg_count = min(config.ascan_average_count, max(1, numel(valid_columns)));
    raw_avg = compute_recent_average(raw_ascan_history, avg_count);
    baseline_avg = compute_recent_average(baseline_ascan_history, avg_count);
    rolling_avg = compute_recent_average(rolling_ascan_history, avg_count);

    %--------------------------------------------------------------
    % Update A-Scan Figure
    %--------------------------------------------------------------

    set(hA_recent(1), 'YData', raw_ascan_history(:,end));
    set(hA_average(1), 'YData', raw_avg);
    set(hA_recent(2), 'YData', baseline_ascan_history(:,end));
    set(hA_average(2), 'YData', baseline_avg);
    set(hA_recent(3), 'YData', rolling_ascan_history(:,end));
    set(hA_average(3), 'YData', rolling_avg);

    %--------------------------------------------------------------
    % Update B-Scan Figure
    %--------------------------------------------------------------

    set(hB(1), 'CData', raw_ascan_history);
    set(hB(2), 'CData', rolling_ascan_history);
    set(hB(3), 'CData', pca_ascan_history);

    %--------------------------------------------------------------
    % Refresh Displays
    %--------------------------------------------------------------

    drawnow limitrate;

    %--------------------------------------------------------------
    % Keyboard Handling
    %--------------------------------------------------------------

    key = getappdata(figB,'lastKey');
    setappdata(figB,'lastKey','');
    if strcmp(key,'escape')
        setappdata(figB,'stopNow',true);
        break;
    end

    %--------------------------------------------------------------
    % Mode Handling
    %--------------------------------------------------------------
    switch lower(config.mode)
        case 'continuous'
            % Nothing needed

        case 'manual'
            while true
                key = getappdata(figB,'lastKey');
                setappdata(figB,'lastKey','');
                if strcmp(key,'escape')
                    setappdata(figB,'stopNow',true);
                    break;
                elseif strcmp(key,'space')
                    break;
                end
                pause(0.05);
            end

        case 'timed'
            fs = 8000;
            tt = 0:1/fs:0.05;
            sound(sin(2*pi*600*tt),fs);

            tStart = tic;
            while toc(tStart) < delaySec
                key = getappdata(figB,'lastKey');
                setappdata(figB,'lastKey','');
                if strcmp(key,'escape')
                    setappdata(figB,'stopNow',true);
                    break;
                end
                pause(0.05);
            end
            sound(sin(2*pi*1000*tt),fs);
            pause(0.15);
    end
end

%--------------------------------------------------------------
% Acquisition Complete
%--------------------------------------------------------------

disp('Scan stopped.');
S21_raw_history = S21_raw_history(:,1:loop_count);
soil_tag = regexprep(config.soil_description,'[^a-zA-Z0-9]','_');
soil_tag = soil_tag(1:min(3,length(soil_tag)));
base_filename = sprintf('%03dcm_%s_%s', round(config.target_range*100), ...
    soil_tag, config.radar_configuration_str);

full_filename = save_dotmat(...
    config.save_folder, ...
    base_filename, ...
    config.variables_to_save_mat, ...
    config.save_mat_enabled);

if config.save_hdf5_enabled
    % Create Header Metadata Struct
    header.date               = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    header.target_range       = config.target_range; % meters
    header.target_description = config.target_description;
    header.soil_description   = config.soil_description;
    header.waveform           = config.waveform;
    header.configuration      = config.radar_configuration_str;

    % Create Response Data Struct
    response.dt_in_seconds    = dt;
    response.voltage_in_V     = raw_ascan_history;

    % Create Source Data Struct
    source.dt_in_seconds      = dt;
    source.voltage_in_V       = zeros(size(t_s));

    % Call Function
    outputH5 = fullfile(config.save_folder, [base_filename, '.h5']);
    write_experimental_radar_h5(outputH5, header, response, source, 'f', f, 'S21', S21_raw_history);
end
try
    nanovna.cleanupNanoVNA(sp);
catch
end

%--------------------------------------------------------------------------
% PCA Clutter Removal
%
% Input:
%   X = [Nt x Nwindow]
%
% Output:
%   newest filtered column
%
% Removes the strongest singular vectors and returns only the
% most recent filtered A-scan.
%--------------------------------------------------------------------------
function newest_column = apply_pca_filter(X, n_components_remove)
    X = double(X);
    column_mean = mean(X,2,'omitnan');
    Xc = X - column_mean;
    [U,S,V] = svd(Xc,'econ');
    k = min(n_components_remove, size(U,2));
    if k > 0
        clutter = U(:,1:k) * S(1:k,1:k) * V(:,1:k);
        Xfiltered = Xc - clutter;
    else
        Xfiltered = Xc;
    end
    newest_column = Xfiltered(:,end);
end

%--------------------------------------------------------------------------
% Compute Mean Of Most Recent Columns
%--------------------------------------------------------------------------
function avg_trace = compute_recent_average(history, N)
    valid_columns = find(~all(isnan(history),1));
    if isempty(valid_columns)
        avg_trace = nan(size(history,1),1);
        return;
    end

    N = min(N,numel(valid_columns));
    cols = valid_columns(end-N+1:end);
    avg_trace = mean(history(:,cols),2,'omitnan');
end

%--------------------------------------------------------------------------
% Shared Figure Keypress Callback
%--------------------------------------------------------------------------
function keypress_callback(figA,figB,event)
    setappdata(figA,'lastKey',event.Key);
    setappdata(figB,'lastKey',event.Key);
end

%--------------------------------------------------------------------------
% Baseline Collection
%
% Collects multiple scans and averages them.
%--------------------------------------------------------------------------
function S21_base = get_baseline_S21(sp, f1, f2, Ns, Navg)
    if nargin < 5
        Navg = 10;
    end
    accumulator = complex(zeros(Ns,1));
    fprintf('Collecting %d baseline scans...\n',Navg);
    for n = 1:Navg
        [~,~,S21] = doNanoVNAScan(sp, f1, f2, Ns);
        accumulator = accumulator + S21(:);
        fprintf('  Baseline %d/%d\n',n,Navg);
    end
    S21_base = accumulator / Navg;
end

%--------------------------------------------------------------------------
% Save .mat
%--------------------------------------------------------------------------
function full_filename = save_dotmat(save_folder, base_filename, variables_to_save, save_enabled)
    full_filename = '';

    if ~save_enabled
        disp('Automatic .mat saving disabled.');
        return;
    end

    if ~exist(save_folder,'dir')
        mkdir(save_folder);
    end

    timestamp = datetime("now"); % datestr(now,'yyyy-mm-dd_HH-MM-SS');
    if ~ismember('timestamp',variables_to_save)
        variables_to_save{end+1} = 'timestamp';
    end

    ext = '.mat';
    count = 0;
    full_filename = fullfile(save_folder, [base_filename ext]);

    while exist(full_filename,'file')
        count = count + 1;
        full_filename = fullfile(save_folder, sprintf('%s_%d%s', base_filename, count, ext));
    end

    temp = struct();
    for k = 1:numel(variables_to_save)
        varname = variables_to_save{k};
        if strcmp(varname,'timestamp')
            temp.timestamp = timestamp;
            continue;
        end
        try
            temp.(varname) = evalin('base',varname);
        catch
            warning('Variable "%s" not found.', varname);
        end
    end
    save(full_filename,'-struct','temp');
    disp('Saved:');
    disp(full_filename);

end
