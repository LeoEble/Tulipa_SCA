# Helper function to sum flows for a list of edges
function get_aggregated_flow(df, edges)
        subset = filter(row -> any((row.from_asset == u && row.to_asset == v) for (u, v) in edges), df)
        if isempty(subset)
            return DataFrame(time_block_start = eltype(df.time_block_start)[], value = Float64[])
        end
        gdf = groupby(subset, :time_block_start)
        return combine(gdf, :solution => sum => :value)
    end


