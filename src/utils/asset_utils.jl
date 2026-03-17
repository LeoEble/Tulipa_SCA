# Helper for storage — works with both raw rep-period data (:time_block_start)
# and post-reconstruction hourly data (:timestep).
function get_storage_level(df, asset_name)
    time_col = "timestep" in names(df) ? :timestep : :time_block_start
    df_filtered = filter(row -> row.asset == asset_name, df)
    if isempty(df_filtered)
        return DataFrame(time_col => eltype(df[!, time_col])[], :value => Float64[])
    end
    return select(df_filtered, time_col, :solution => :value)
end
