function sp = setupNanoVNA(port, baudrate, timeout, terminator)
    arguments
        port (1, :) char = '/dev/ttyACM0'
        baudrate (1,1) double = 115200
        timeout (1,1) double = 10
        terminator (1, :) char = 'LF'
    end

    if exist("sp", "var")
        try
            delete(sp);
            clear sp;
        catch
            warning("Could not clean up previous serial object.");
        end
    end

    sp = serialport(port, baudrate, "Timeout", timeout);
    configureTerminator(sp, terminator);
    flush(sp);
end
