# Core utility functions for Tulipa_SCA
# These are included in the main Tulipa_SCA module and can be used across your workflow

"""
    fetch_plotting_data(connection)

Fetches all necessary results and parameters from the DuckDB connection into a
Dictionary cache. This includes the 'rep_periods_mapping' required for
timeframe reconstruction.
"""
function fetch_plotting_data(connection)
    # Tables where the cache key differs from the DuckDB table name
    renamed_tables = Dict(
        "var_storage_level_clustered_year" => "var_storage_level_over_clustered_year",
    )

    # All other tables use the same name as key and table
    standard_tables = [
        "var_assets_investment",
        "var_assets_investment_energy",
        "var_flow",
        "var_storage_level_rep_period",
        "rep_periods_mapping",
        "asset",
        "asset_commission",
        "asset_milestone",
        "assets_profiles",
        "profiles_wide",
        "flow_milestone",
        "flows_profiles",
        "profiles_rep_periods"
    ]

    cache = Dict{String, DataFrame}()

    for key in standard_tables
        try
            cache[key] = TIO.get_table(connection, key)
        catch e
            @warn "Could not fetch table '$key': $e"
            cache[key] = DataFrame()
        end
    end

    for (key, table_name) in renamed_tables
        try
            cache[key] = TIO.get_table(connection, table_name)
        catch e
            @warn "Could not fetch table '$table_name' (key='$key'): $e"
            cache[key] = DataFrame()
        end
    end

    return cache
end

"""
    get_df(data, name)

Retrieve a DataFrame by name from either a Dict cache or a DuckDB connection.
"""
function get_df(data, name)
    if data isa Dict
        if !haskey(data, name)
            error("Key '$name' not found in data cache. Available keys: $(join(sort(collect(keys(data))), ", "))")
        end
        return data[name]
    end
    return TIO.get_table(data, name)
end

"""
    reconstruct_to_timeframe(input_source, table_name::String; year=nothing)

Reconstructs optimization variables from representative-period space to the base
timeframe using weights from the 'rep_periods_mapping' table.

Supports both Seasonal (Big Clock) and Representative (Small Clock) data types.
"""
function reconstruct_to_timeframe(input_source, table_name::String; year=nothing)
    # 1. Unified Fetch & Storage Detection
    is_storage = occursin("storage_level", table_name)

    function fetch_table(t_name)
        if input_source isa Dict
            return haskey(input_source, t_name) ? copy(input_source[t_name]) : nothing
        else
            try
                return TIO.get_table(input_source, t_name)
            catch e
                @warn "Could not fetch table '$t_name': $e"
                return nothing
            end
        end
    end

    # Helper function to harmonize time columns BEFORE joining
    function harmonize_time!(data)
        isnothing(data) && return data
        if "time_block_start" in names(data)
            rename!(data, :time_block_start => :timestep)
        end
        if "period_block_start" in names(data)
            rename!(data, :period_block_start => :timestep)
        end
        if "period" in names(data) && !("timestep" in names(data))
            rename!(data, :period => :timestep)
        end
        return data
    end

    # Fetch and harmonize the primary table
    df = harmonize_time!(fetch_table(table_name))

    # Fetch and harmonize the seasonal table (if applicable)
    if is_storage
        seasonal_df = harmonize_time!(fetch_table("var_storage_level_clustered_year"))

        if !isnothing(seasonal_df) && !isempty(seasonal_df)
            if !isnothing(df)
                df = vcat(df, seasonal_df, cols=:union)
            else
                df = seasonal_df
            end
        end
    end

    isnothing(df) && error("Table '$table_name' could not be found.")

    # 3. Seasonal Branching
    if !("rep_period" in names(df))
        dropmissing!(df, :timestep)
        return sort!(df, :timestep)
    end

    # Split into short-term and seasonal
    df_rp       = subset(df, :rep_period => ByRow(!ismissing))
    df_seasonal = subset(df, :rep_period => ByRow(ismissing))

    # 4. Reconstruct RP-based Data
    if !isempty(df_rp)
        rp_map = input_source isa Dict ? get(input_source, "rep_periods_mapping", nothing) : TIO.get_table(input_source, "rep_periods_mapping")

        possible_id_cols = ["asset", "from_asset", "to_asset", "year", "rep_period", "timestep", "solution"]
        actual_cols = [c for c in possible_id_cols if c in names(df_rp)]

        for col in ["year", "rep_period"]
            if col in names(df_rp)  df_rp[!, col]  = Int64.(df_rp[!, col]) end
            if col in names(rp_map) rp_map[!, col] = Int64.(rp_map[!, col]) end
        end

        join_keys = [c for c in ["year", "rep_period"] if c in names(df_rp) && c in names(rp_map)]

        df_joined = innerjoin(df_rp[!, actual_cols], rp_map, on = join_keys)

        id_cols   = [c for c in ["asset", "from_asset", "to_asset"] if c in actual_cols]
        group_cols = [id_cols; "year"; "period"; "timestep"]

        df_rp_reconstructed = combine(
            groupby(df_joined, group_cols),
            [:weight, :solution] => ((w, s) -> sum(w .* s)) => :solution
        )

        TC.combine_periods!(df_rp_reconstructed)
    else
        df_rp_reconstructed = DataFrame()
    end

    # 5. Expand seasonal data from period-space to hour-space
    # var_storage_level_over_clustered_year has one value per full-year period (period_block_start).
    # We use the period structure from the rep-period data to map each period index to its
    # corresponding hours in the full year, producing one row per hour per asset.
    if !isempty(df_seasonal) && !isempty(df_rp) && !isempty(df_rp_reconstructed)
        period_dur  = maximum(df_rp.timestep)               # timesteps per period (e.g. 72)
        total_steps = maximum(df_rp_reconstructed.timestep) # total hours in the year (e.g. 8760)

        # Build a lookup: every overall timestep → which period it belongs to
        period_of_hour = DataFrame(
            period   = Int.(div.(collect(0:total_steps-1), period_dur) .+ 1),
            timestep = collect(1:total_steps)
        )

        # df_seasonal.timestep == period_block_start == period index (1..N)
        rename!(df_seasonal, :timestep => :period)
        df_seasonal_expanded = innerjoin(df_seasonal, period_of_hour, on = :period)
        select!(df_seasonal_expanded, Not(:period))
        df_seasonal = df_seasonal_expanded
    end

    # 6. Final Merge
    final_df = vcat(df_rp_reconstructed, df_seasonal, cols=:union)

    dropmissing!(final_df, :timestep)

    sort_cols = "asset" in names(final_df) ? [:asset, :timestep] : [:timestep]
    return sort!(final_df, sort_cols)
end

"""
    reconstruct_soc_from_flows(data_cache, asset_id) -> DataFrame

Reconstructs the hourly state-of-charge for a seasonal storage asset by
cumulating hourly net flows within each full-year period, anchored at the
period-boundary values from `var_storage_level_over_clustered_year`.

Returns a DataFrame with columns `[:timestep, :solution]`, or an empty
DataFrame if `asset_id` is not found in the seasonal storage table.

Note: since the optimizer only enforces storage capacity at period boundaries
(not at every intra-period timestep), the reconstructed SOC may temporarily
exceed or fall below capacity limits within a period. This is a known consequence
of the coarser seasonal-storage formulation and is shown faithfully by this function.
"""
function reconstruct_soc_from_flows(data_cache, asset_id)
    # 1. Period-boundary SOC (var_storage_level_over_clustered_year, one value per period)
    soc_per_period = DataFrame(filter(row -> row.asset == asset_id,
                                     data_cache["var_storage_level_clustered_year"]))
    isempty(soc_per_period) && return DataFrame(timestep=Int[], solution=Float64[])

    sort!(soc_per_period, [:period_block_start])
    num_periods = maximum(soc_per_period.period_block_start)

    # 2. Hourly reconstructed flows for this asset
    flows      = data_cache["var_flow_8760"]
    total_steps = maximum(flows.timestep)

    inflows  = filter(row -> row.to_asset   == asset_id, flows)
    outflows = filter(row -> row.from_asset == asset_id, flows)

    net_df = DataFrame(timestep = collect(1:total_steps), net_flow = zeros(Float64, total_steps))

    if !isempty(inflows)
        agg = combine(groupby(inflows, :timestep), :solution => sum => :flow)
        leftjoin!(net_df, agg, on = :timestep)
        net_df.net_flow .+= coalesce.(net_df.flow, 0.0)
        select!(net_df, Not(:flow))
    end
    if !isempty(outflows)
        agg = combine(groupby(outflows, :timestep), :solution => sum => :flow)
        leftjoin!(net_df, agg, on = :timestep)
        net_df.net_flow .-= coalesce.(net_df.flow, 0.0)
        select!(net_df, Not(:flow))
    end

    # 3. Period duration — read directly from the rep-period storage timestep range
    period_dur = if !isempty(data_cache["var_storage_level_rep_period"])
        maximum(data_cache["var_storage_level_rep_period"].time_block_start)
    else
        round(Int, total_steps / num_periods)
    end

    net_df.period = Int.(div.(net_df.timestep .- 1, period_dur) .+ 1)

    # 4. SOC at end of each period → used as start-of-next-period anchor (cyclic year)
    soc_at_end = Dict(row.period_block_start => row.solution for row in eachrow(soc_per_period))

    # 5. Cumulate net flows within each period, starting from the previous period boundary
    net_df.solution = zeros(Float64, total_steps)
    for p in 1:num_periods
        start_soc = get(soc_at_end, p == 1 ? num_periods : p - 1, 0.0)
        rows = findall(net_df.period .== p)
        isempty(rows) && continue
        net_df[rows, :solution] = start_soc .+ cumsum(net_df[rows, :net_flow])
    end

    return net_df[!, [:timestep, :solution]]
end
