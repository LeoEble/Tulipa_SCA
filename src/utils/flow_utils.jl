# Helper function to sum flows for a list of edges.
# Works with both raw rep-period data (:time_block_start) and
# post-reconstruction hourly data (:timestep).
function get_aggregated_flow(df, edges)
    time_col_name = "timestep" in names(df) ? :timestep : :time_block_start

    df_filtered = filter(row -> any((row.from_asset == u && row.to_asset == v) for (u, v) in edges), df)
    if isempty(df_filtered)
        return DataFrame(time_col_name => eltype(df[!, time_col_name])[], :value => Float64[])
    end
    gdf = groupby(df_filtered, time_col_name)
    return combine(gdf, :solution => sum => :value)
end
