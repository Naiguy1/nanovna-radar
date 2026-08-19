classdef ConfigCodec

    properties
        maps % struct of mapping definitions
    end

    methods
        %% Constructor
        function obj = ConfigCodec()
            obj.maps = struct();

            % --- Default registrations ---
            obj = obj.register('platform', ...
                [0, 1], ...
                {'NanoVNA', 'RFSoC 4x2'}, ...
                {{'nanovna','vna'}, {'rfsoc','rfsoc4x2','zynq'}});

            obj = obj.register('amplifier', ...
                [0, 1], ...
                {'None', 'lpa-6-26'}, ...
                {{'none','off'}, {'amp','amplifier','lpa'}});

            obj = obj.register('antenna', ...
                [0, 1, 2], ...
                {'Loopback', 'Vivaldi', 'Eli Bowtie'}, ...
                {{'loopback'}, {'vivaldi', 'lft3'}, {'bowtie','eli', 'beantie'}});

        end

        %% Register new mapping (extensibility hook)
        function obj = register(obj, name, keys, labels, aliases)

            mapStruct.keys = keys;
            mapStruct.labels = labels;
            mapStruct.aliases = aliases;

            obj.maps.(name) = mapStruct;
        end

        %% Encode (numeric → string)
        function config = encode(obj, p, atx, arx, ant_tx, ant_rx, ver)
            config = sprintf('%01d_%01d%01d_%01d%01d_%05d', ...
                p, atx, arx, ant_tx, ant_rx, ver);
        end

        %% Decode (string → struct)
        function decoded = decode(obj, config)

            configStr = char(config);
            parts = split(config, '_');
            assert(numel(parts) == 4, 'Invalid configuration format');

            platform    = str2double(parts{1});
            amps        = char(parts{2});
            antennas    = char(parts{3});
            version_num = str2double(parts{4});

            amp_tx = str2double(amps(1));
            amp_rx = str2double(amps(2));

            ant_tx = str2double(antennas(1));
            ant_rx = str2double(antennas(2));

            decoded.raw = struct( ...
                'platform', platform, ...
                'amp_tx', amp_tx, ...
                'amp_rx', amp_rx, ...
                'ant_tx', ant_tx, ...
                'ant_rx', ant_rx, ...
                'version', version_num);

            decoded.labels = struct( ...
                'platform', obj.lookup('platform', platform), ...
                'amp_tx', obj.lookup('amplifier', amp_tx), ...
                'amp_rx', obj.lookup('amplifier', amp_rx), ...
                'ant_tx', obj.lookup('antenna', ant_tx), ...
                'ant_rx', obj.lookup('antenna', ant_rx), ...
                'version', sprintf('v%d', version_num));

            decoded.string = get_config_string(decoded.labels);
        end

        %% Fuzzy resolve (string → numeric key)
        function key = resolve(obj, mapName, inputStr)

            mapStruct = obj.maps.(mapName);
            query = obj.normalize(inputStr);

            % --- Exact match ---
            for i = 1:numel(mapStruct.keys)
                candidates = [{mapStruct.labels{i}}, mapStruct.aliases{i}];
                for j = 1:numel(candidates)
                    if strcmp(obj.normalize(candidates{j}), query)
                        key = mapStruct.keys(i);
                        return;
                    end
                end
            end


            % --- Partial match ---
            for i = 1:numel(mapStruct.keys)
                candidates = [{mapStruct.labels{i}}, mapStruct.aliases{i}];
                for j = 1:numel(candidates)
                    if contains(obj.normalize(candidates{j}), query)
                        key = mapStruct.keys(i);
                        return;
                    end
                end
            end

            % --- Edit distance fallback ---
            bestDist = inf;
            bestKey = NaN;

            for i = 1:numel(mapStruct.keys)
                candidates = [{mapStruct.labels{i}}, mapStruct.aliases{i}];
                for j = 1:numel(candidates)
                    d = obj.editDistance(obj.normalize(candidates{j}), query);
                    if d < bestDist
                        bestDist = d;
                        bestKey = mapStruct.keys(i);
                    end
                end
            end

            if bestDist <= 2
                key = bestKey;
            else
                error('No match for "%s" in map "%s"', inputStr, mapName);
            end
        end

        %% Lookup numeric → label
        function val = lookup(obj, mapName, key)

            mapStruct = obj.maps.(mapName);

            idx = find(mapStruct.keys == key, 1);
            if isempty(idx)
                val = sprintf('Unknown (%d)', key);
            else
                val = mapStruct.labels{idx};
            end
        end

        %% Normalize string
        function s = normalize(~, str)
            s = lower(str);
            s = regexprep(s, '[^a-z0-9]', '');
        end

        %% Levenshtein distance
        function d = editDistance(~, s1, s2)

            m = length(s1);
            n = length(s2);

            D = zeros(m+1, n+1);

            for i = 1:m+1, D(i,1) = i-1; end
            for j = 1:n+1, D(1,j) = j-1; end

            for i = 2:m+1
                for j = 2:n+1
                    cost = ~(s1(i-1) == s2(j-1));
                    D(i,j) = min([ ...
                        D(i-1,j) + 1, ...
                        D(i,j-1) + 1, ...
                        D(i-1,j-1) + cost ...
                    ]);
                end
            end

            d = D(m+1,n+1);
        end

    end
end


function config_str = get_config_string(config_struct)
    % get_config_string - Converts a VNA config struct into a clean, 
    %                     human-readable string for plot titles/notes.
    
    % --- 1. Process Amplifier State ---
    % Standardize string comparison to ignore case or trailing spaces
    has_tx_amp = ~strcmpi(trim_NaN_str(config_struct.amp_tx), 'none') && ~isempty(config_struct.amp_tx);
    has_rx_amp = ~strcmpi(trim_NaN_str(config_struct.amp_rx), 'none') && ~isempty(config_struct.amp_rx);
    
    if has_tx_amp && has_rx_amp
        amp_str = 'Dual Amp';
    elseif has_tx_amp
        amp_str = 'Tx Amp';
    elseif has_rx_amp
        amp_str = 'Rx Amp';
    else
        amp_str = 'No Amp';
    end
    
    % --- 2. Process Antenna Names ---
    ant_tx = strtrim(config_struct.ant_tx);
    ant_rx = strtrim(config_struct.ant_rx);
    
    if strcmpi(ant_tx, ant_rx)
        % If they match, just list the name once with a dual/paired indicator
        ant_str = sprintf('%s (Tx/Rx)', ant_tx);
    else
        % Fallback if you ever use mismatched antennas
        ant_str = sprintf('Tx: %s, Rx: %s', ant_tx, ant_rx);
    end
    
    % --- 3. Combine into Final String ---
    config_str = sprintf('%s | %s', ant_str, amp_str);
end

function clean_str = trim_NaN_str(val)
    % Helper to safely cast to string and clean up spaces
    if ischar(val) || isstring(val)
        clean_str = strtrim(char(val));
    else
        clean_str = 'None';
    end
end