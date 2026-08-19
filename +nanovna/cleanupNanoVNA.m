function cleanupNanoVNA(sp)
    if exist("sp", "var") && ~isempty(sp)
        try
            delete(sp);
            clear sp;
        catch
            warning("Could not delete serial object.");
        end
    end
end
