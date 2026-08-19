function [f, S11, S21] = doNanoVNAScan(sp, f1, f2, Ns)
    arguments
        sp
        f1 (1,1) double = 300e6
        f2 (1,1) double = 1000e6
        Ns (1,1) double = 101
        % DISPLAY (1,1) logical = false
    end

    cmd = ['scan ',num2str(f1),' ',num2str(f2),' ',num2str(Ns),' 7'];

    % send command and skip echo
    writeline(sp, cmd);
    temp = readline(sp);

    % preallocate
    f = zeros(Ns, 1);
    S11 = complex(nan(Ns, 1));
    S21 = complex(nan(Ns, 1));

    valid = 0;
    while valid < Ns
        line = strtrim(readline(sp));
        vals = sscanf(line, "%f");
        if numel(vals)==5
            valid = valid + 1;
            f(valid)   = vals(1);
            S11(valid) = vals(2)+1j*vals(3);
            S21(valid) = vals(4)+1j*vals(5);
        else
            warning("Skipping malformed line: %s", line);
        end
    end
end
