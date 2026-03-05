# Core utility functions for Tulipa_SCA
# These are included in the main Tulipa_SCA module and can be used across your workflow
"""
    fetch_plotting_data(connection)

Fetches all necessary results and parameters from the DuckDB connection into a 
Dictionary cache. This includes the 'rep_periods_mapping' required for 
timeframe reconstruction.
"""
function fetch_plotting_data(connection)
    # Define the list of tables we want to attempt to cache
    # "var_" prefix denotes optimization results
    tables_to_cache = Dict(
        # --- Variables (Optimization Results) ---
        "var_assets_investment"        => "var_assets_investment",
        "var_assets_investment_energy" => "var_assets_investment_energy", 
        "var_flow"                     => "var_flow",
        "var_storage_level_rep_period"     => "var_storage_level_rep_period",
        "var_storage_level_clustered_year" => "var_storage_level_over_clustered_year",        
        
        # --- Temporal Mapping (Crucial for reconstruction) ---
        "rep_periods_mapping"          => "rep_periods_mapping",
        
        # --- Parameters (Input Data) ---
        "asset"                        => "asset",             
        "asset_commission"             => "asset_commission",
        "asset_milestone"              => "asset_milestone", 
        "assets_profiles"              => "assets_profiles",   
        "profiles_wide"                => "profiles_wide",
        "flow_milestone"               => "flow_milestone"
    )

    cache = Dict{String, DataFrame}()

    for (key, table_name) in tables_to_cache
        try
            # TIO.get_table returns a DataFrame
            cache[key] = TIO.get_table(connection, table_name)
        catch e
            @warn "Could not fetch table '$table_name'. It might not exist in the results."
            # Initialize empty DataFrame with a 'solution' column to prevent downstream crashes
            cache[key] = DataFrame(solution = Float64[]) 
        end
    end

    return cache
end

# Helper for Safe Data Fetching ---
function get_df(data, name)
    # If it's a Dictionary (Cache), just grab the key
    if data isa Dict
            return data[name]
    end
    # If it's a Connection, query the table
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
    
    function get_df(t_name)
        if input_source isa Dict
            return haskey(input_source, t_name) ? copy(input_source[t_name]) : nothing
        else
            try return TIO.get_table(input_source, t_name) catch; return nothing end
        end
    end

    # FIX: Helper function to harmonize time columns BEFORE joining
    function harmonize_time!(data)
        isnothing(data) && return data
        if "time_block_start" in names(data)
            rename!(data, :time_block_start => :timestep)
        end
        if "period_block_start" in names(data)
            rename!(data, :period_block_start => :timestep)
        end
        # FIX: Catch the seasonal storage 'period' column so it doesn't get dropped!
        if "period" in names(data) && !("timestep" in names(data))
            rename!(data, :period => :timestep)
        end
        return data
    end

    # Fetch and harmonize the primary table
    df = harmonize_time!(get_df(table_name))

    # Fetch and harmonize the seasonal table (if applicable)
    if is_storage
        seasonal_df = harmonize_time!(get_df("var_storage_level_clustered_year"))
        
        if !isnothing(seasonal_df) && !isempty(seasonal_df)
            if !isnothing(df)
                # Now both have 'timestep', so they align perfectly!
                df = vcat(df, seasonal_df, cols=:union)
            else
                df = seasonal_df
            end
        end
    end

    isnothing(df) && error("Table '$table_name' could not be found.")

    # 3. Seasonal Branching
    if !("rep_period" in names(df))
        dropmissing!(df, :timestep) # Defensive programming
        return sort!(df, :timestep)
    end

    # Split into short-term and seasonal
    # Using subset per the Julia Style Guide
    df_rp = subset(df, :rep_period => ByRow(!ismissing))
    df_seasonal = subset(df, :rep_period => ByRow(ismissing))

    # 4. Reconstruct RP-based Data
    if !isempty(df_rp)
        rp_map = input_source isa Dict ? get(input_source, "rep_periods_mapping", nothing) : TIO.get_table(input_source, "rep_periods_mapping")
        
        possible_id_cols = ["asset", "from_asset", "to_asset", "year", "rep_period", "timestep", "solution"]
        actual_cols = [c for c in possible_id_cols if c in names(df_rp)]

        for col in ["year", "rep_period"]
            if col in names(df_rp)  df_rp[!, col] = Int64.(df_rp[!, col]) end
            if col in names(rp_map) rp_map[!, col] = Int64.(rp_map[!, col]) end
        end

        join_keys = [c for c in ["year", "rep_period"] if c in names(df_rp) && c in names(rp_map)]
        
        df_joined = innerjoin(df_rp[!, actual_cols], rp_map, on = join_keys)

        id_cols = [c for c in ["asset", "from_asset", "to_asset"] if c in actual_cols]
        group_cols = [id_cols; "year"; "period"; "timestep"]
        
        df_rp_reconstructed = combine(
            groupby(df_joined, group_cols), 
            [:weight, :solution] => ((w, s) -> sum(w .* s)) => :solution
        )

        TC.combine_periods!(df_rp_reconstructed)
    else
        df_rp_reconstructed = DataFrame()
    end

    # 5. Final Merge
    final_df = vcat(df_rp_reconstructed, df_seasonal, cols=:union)
    
    # Clean up any rogue missing timesteps before plotting
    dropmissing!(final_df, :timestep)
    
    sort_cols = "asset" in names(final_df) ? [:asset, :timestep] : [:timestep]
    return sort!(final_df, sort_cols)
end