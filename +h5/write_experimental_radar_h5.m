function write_experimental_radar_h5(filename, headerData, responseData, sourceData, varargin)
% WRITE_EXPERIMENTAL_RADAR_H5 Writes experimental radar data to an HDF5 file
% matching the unified EM data schema.

    %% 1. Input Parsing
    p = inputParser;
    addRequired(p, 'filename', @(x) ischar(x) || isstring(x));
    addRequired(p, 'headerData', @isstruct);
    addRequired(p, 'responseData', @isstruct);
    addRequired(p, 'sourceData', @isstruct);
    
    addParameter(p, 'f', [], @isnumeric);
    addParameter(p, 'S21', [], @isnumeric);
    addParameter(p, 'transmit_position', [], @isnumeric);
    addParameter(p, 'receive_position', [], @isnumeric);
    addParameter(p, 'Overwrite', false, @islogical);
    
    parse(p, filename, headerData, responseData, sourceData, varargin{:});
    opts = p.Results;

    if opts.Overwrite && exist(filename, 'file')
        delete(filename);
    end

    %% 2. Write /header Group
    write_dataset(filename, '/header/date', char(headerData.date));
    write_dataset(filename, '/header/target_range', headerData.target_range);
    write_dataset(filename, '/header/target_description', headerData.target_description);
    write_dataset(filename, '/header/soil_description', headerData.soil_description);
    write_dataset(filename, '/header/waveform', headerData.waveform);
    write_dataset(filename, '/header/configuration', headerData.configuration);

    if ~isempty(opts.f)
        write_dataset(filename, '/header/f', opts.f);
    end
    if ~isempty(opts.transmit_position)
        write_dataset(filename, '/header/transmit_position', opts.transmit_position);
    end
    if ~isempty(opts.receive_position)
        write_dataset(filename, '/header/receive_position', opts.receive_position);
    end

    %% 3. Write /response Group
    write_dataset(filename, '/response/dt_in_seconds', responseData.dt_in_seconds);
    write_dataset(filename, '/response/voltage_in_V', responseData.voltage_in_V);

    %% 4. Write /source Group
    write_dataset(filename, '/source/dt_in_seconds', sourceData.dt_in_seconds);
    write_dataset(filename, '/source/voltage_in_V', sourceData.voltage_in_V);

    %% 5. Write Optional Datasets
    if ~isempty(opts.S21)
        write_dataset(filename, '/S21', opts.S21);
    end
end

% =========================================================================
% Helper Functions
% =========================================================================

function write_dataset(filename, datasetPath, data)
    if isempty(data)
        return;
    end
   
    
    if isstring(data)
        data = cellstr(data);
    end
    
    % Split complex data into real/imaginary parts
    if isnumeric(data) && ~isreal(data)
        write_dataset(filename, [datasetPath '_real'], real(data));
        write_dataset(filename, [datasetPath '_imag'], imag(data));
        return;
    end
    
    dims = size(data);

    if iscell(data)
        h5create(filename, datasetPath, dims, 'Datatype', 'string');
        h5write(filename, datasetPath, data);
    elseif ischar(data)
        h5create(filename, datasetPath, 1, 'Datatype', 'string');
        h5write(filename, datasetPath, {data});
    else
        datatype = class(data);
        h5create(filename, datasetPath, dims, 'Datatype', datatype);
        h5write(filename, datasetPath, data);
    end
end