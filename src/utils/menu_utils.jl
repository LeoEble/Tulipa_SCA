using DataFrames
using CSV
using Dates

# ========================================================================================
# 1. CONFIGURATION & AUTOMATION TOOLS
# ========================================================================================

# PATHS
input_folder = "data/raw/methanol_v01_short"   
output_folder = "data/raw/methanol_menuapproach_v01"  

struct MenuOption
    capacity::Float64
    capex_per_unit::Float64
    efficiency::Union{Float64, Missing}
end

# HELPER FUNCTION: Automates the generation of options based on ranges
# It interpolates linearly between the start and end values.
# n_steps: Number of distinct options to generate
function create_range_options(; n_steps::Int, cap_range::Tuple, cost_range::Tuple, eff_range::Tuple)
    options = MenuOption[]
    
    # Safely handle the case where n_steps is 1 to avoid division by zero
    if n_steps < 2
        return [MenuOption(cap_range[1], cost_range[1], eff_range[1])]
    end

    for i in 1:n_steps
        # Calculate the fraction (0.0 to 1.0) for the current step
        frac = (i - 1) / (n_steps - 1)
        
        # Linear Interpolation: Start + (Diff * Fraction)
        c = cap_range[1] + (cap_range[2] - cap_range[1]) * frac
        # Note: Cost usually goes DOWN as capacity goes UP, so ensure your cost_range tuple is (High, Low)
        cost = cost_range[1] + (cost_range[2] - cost_range[1]) * frac
        e = eff_range[1] + (eff_range[2] - eff_range[1]) * frac
        
        push!(options, MenuOption(round(c, digits=2), round(cost, digits=2), round(e, digits=4)))
    end
    return options
end

# ========================================================================================
# DEFINE YOUR MENUS HERE
# ========================================================================================

menu_config = Dict(
     
    # EXAMPLE 1: Electrolyzer
    # We want 5 options ranging from 10MW to 100MW.
    # Cost drops from 4000 to 2500 EUR/kW.
    # Efficiency improves from 60% to 70%.
    "electrolyzer" => create_range_options(
        n_steps = 5,
        cap_range = (10.0, 150.0),    # Min Cap -> Max Cap
        cost_range = (130000000*1.2, 130000000*0.8), # High Cost -> Low Cost (Economies of scale)
        eff_range = (0.017, 0.015)      # Low Eff -> High Eff
    ),

    # EXAMPLE 2: Methanol Synthesis
    # 3 options, cost drops slightly, efficiency stays flat (1.0 to 1.0)
    "CH3OH_synthesis" => create_range_options(
        n_steps = 5,
        cap_range = (10.0, 50.0),
        cost_range = (7000000*1.2, 7000000*0.8),
        eff_range = (0.637, 0.637)
    )
)

# ========================================================================================
# 2. LOADING DATA
# ========================================================================================

function load_csv(folder, filename)
    path = joinpath(folder, filename)
    if isfile(path)
        println("Loading $filename...")
        # stringtype=String prevents the "String15" optimization error
        return CSV.read(path, DataFrame; stringtype=String)
    else
        error("File not found: $path")
    end
end

println("Reading input files from: $input_folder")

df_asset               = load_csv(input_folder, "asset.csv")
df_asset_both          = load_csv(input_folder, "asset-both.csv")
df_asset_commission    = load_csv(input_folder, "asset-commission.csv")
df_asset_milestone     = load_csv(input_folder, "asset-milestone.csv")
df_flow                = load_csv(input_folder, "flow.csv")
df_flow_commission     = load_csv(input_folder, "flow-commission.csv")
df_flow_milestone      = load_csv(input_folder, "flow-milestone.csv")
df_flows_relationships = load_csv(input_folder, "flows-relationships.csv")

# ========================================================================================
# 3. PROCESSING LOGIC
# ========================================================================================

function generate_menu_tables(
    menu_config::Dict,
    df_asset, df_asset_both, df_asset_commission, df_asset_milestone,
    df_flow, df_flow_commission, df_flow_milestone, df_flows_relationships
)
    # Create copies
    new_asset = copy(df_asset)
    new_asset_both = copy(df_asset_both)
    new_asset_commission = copy(df_asset_commission)
    new_asset_milestone = copy(df_asset_milestone)
    
    new_flow = copy(df_flow)
    new_flow_commission = copy(df_flow_commission)
    new_flow_milestone = copy(df_flow_milestone)
    new_flows_relationships = copy(df_flows_relationships)

    # HELPER: Safely copy a row, modify it, and push it
    function push_modified_row!(target_df, source_row, changes::Dict)
        # Convert immutable row to mutable Dict
        row_dict = Dict(pairs(source_row))
        for (col, val) in changes
            row_dict[col] = val
        end
        push!(target_df, row_dict; cols=:subset)
    end

    for (base_asset_name, options) in menu_config
        println("  -> Creating menu for asset: $base_asset_name ($(length(options)) variants)")
        
        # 1. Remove base asset from working copies
        filter!(row -> row.asset != base_asset_name, new_asset)
        filter!(row -> row.asset != base_asset_name, new_asset_both)
        filter!(row -> row.asset != base_asset_name, new_asset_commission)
        filter!(row -> row.asset != base_asset_name, new_asset_milestone)

        # 2. Grab base rows
        _rows_asset = filter(row -> row.asset == base_asset_name, df_asset)
        _rows_both  = filter(row -> row.asset == base_asset_name, df_asset_both)
        _rows_comm  = filter(row -> row.asset == base_asset_name, df_asset_commission)
        _rows_mile  = filter(row -> row.asset == base_asset_name, df_asset_milestone)

        for (tbl, rows) in [("asset", _rows_asset), ("asset-both", _rows_both),
                             ("asset-commission", _rows_comm), ("asset-milestone", _rows_mile)]
            isempty(rows) && error("Asset '$base_asset_name' not found in table '$tbl'. " *
                                   "Check menu_config keys match asset names in the input CSVs.")
        end

        base_row_asset = _rows_asset[1, :]
        base_row_both  = _rows_both[1, :]
        base_row_comm  = _rows_comm[1, :]
        base_row_mile  = _rows_mile[1, :]

        for (i, opt) in enumerate(options)
            new_name = "$(base_asset_name)_option_$(i)"
            
            # --- Update asset tables ---
            
            # Asset.csv
            changes_asset = Dict{Symbol, Any}(
                :asset => new_name, 
                :capacity => opt.capacity, 
                :investment_integer => true
            )
            if !ismissing(base_row_asset.unit_commitment) && base_row_asset.unit_commitment == true
                changes_asset[:unit_commitment_integer] = true
            end
            push_modified_row!(new_asset, base_row_asset, changes_asset)

            # Asset-both.csv
            push_modified_row!(new_asset_both, base_row_both, Dict{Symbol, Any}(:asset => new_name))

            # Asset-commission.csv
            changes_comm = Dict{Symbol, Any}(
                :asset => new_name,
                :investment_limit => 1.0, 
                :investment_cost => opt.capacity * opt.capex_per_unit
            )
            if !ismissing(opt.efficiency)
                changes_comm[:conversion_efficiency] = opt.efficiency
            end
            push_modified_row!(new_asset_commission, base_row_comm, changes_comm)

            # Asset-milestone.csv
            push_modified_row!(new_asset_milestone, base_row_mile, Dict{Symbol, Any}(:asset => new_name))

            # 3. Duplicate Flows
            # FIX: Added eachrow(...) wrapper to the filter results
            function duplicate_flows!(target_df, source_df, base_name, new_name)
                # Source flows (where asset is source)
                for row in eachrow(filter(r -> r.from_asset == base_name, source_df))
                    push_modified_row!(target_df, row, Dict{Symbol, Any}(:from_asset => new_name))
                end
                # Target flows (where asset is destination)
                for row in eachrow(filter(r -> r.to_asset == base_name, source_df))
                    push_modified_row!(target_df, row, Dict{Symbol, Any}(:to_asset => new_name))
                end
            end

            duplicate_flows!(new_flow, df_flow, base_asset_name, new_name)
            duplicate_flows!(new_flow_commission, df_flow_commission, base_asset_name, new_name)
            duplicate_flows!(new_flow_milestone, df_flow_milestone, base_asset_name, new_name)

            # 4. Handle Relationships
            # FIX: eachrow() is already here, which is correct
            for rel_row in eachrow(df_flows_relationships)
                involves_asset = (rel_row.flow_1_from_asset == base_asset_name) ||
                                 (rel_row.flow_1_to_asset == base_asset_name) ||
                                 (rel_row.flow_2_from_asset == base_asset_name) ||
                                 (rel_row.flow_2_to_asset == base_asset_name)
                
                if involves_asset
                    changes = Dict{Symbol, Any}()
                    if rel_row.flow_1_from_asset == base_asset_name changes[:flow_1_from_asset] = new_name end
                    if rel_row.flow_1_to_asset == base_asset_name   changes[:flow_1_to_asset] = new_name end
                    if rel_row.flow_2_from_asset == base_asset_name changes[:flow_2_from_asset] = new_name end
                    if rel_row.flow_2_to_asset == base_asset_name   changes[:flow_2_to_asset] = new_name end
                    
                    push_modified_row!(new_flows_relationships, rel_row, changes)
                end
            end
        end

        # Cleanup original base asset flows
        filter!(r -> r.from_asset != base_asset_name && r.to_asset != base_asset_name, new_flow)
        filter!(r -> r.from_asset != base_asset_name && r.to_asset != base_asset_name, new_flow_commission)
        filter!(r -> r.from_asset != base_asset_name && r.to_asset != base_asset_name, new_flow_milestone)
        
        filter!(r -> r.flow_1_from_asset != base_asset_name && r.flow_1_to_asset != base_asset_name &&
                     r.flow_2_from_asset != base_asset_name && r.flow_2_to_asset != base_asset_name, new_flows_relationships)
    end

    return new_asset, new_asset_both, new_asset_commission, new_asset_milestone, new_flow, new_flow_commission, new_flow_milestone, new_flows_relationships
end

# ========================================================================================
# 4. EXECUTION
# ========================================================================================

println("Processing data...")
out_asset, out_both, out_comm, out_mile, out_flow, out_flow_comm, out_flow_mile, out_rel = generate_menu_tables(
    menu_config,
    df_asset, df_asset_both, df_asset_commission, df_asset_milestone,
    df_flow, df_flow_commission, df_flow_milestone, df_flows_relationships
)

# Output
println("Saving to: $output_folder")
mkpath(output_folder)

CSV.write(joinpath(output_folder, "asset.csv"), out_asset)
CSV.write(joinpath(output_folder, "asset-both.csv"), out_both)
CSV.write(joinpath(output_folder, "asset-commission.csv"), out_comm)
CSV.write(joinpath(output_folder, "asset-milestone.csv"), out_mile)
CSV.write(joinpath(output_folder, "flow.csv"), out_flow)
CSV.write(joinpath(output_folder, "flow-commission.csv"), out_flow_comm)
CSV.write(joinpath(output_folder, "flow-milestone.csv"), out_flow_mile)
CSV.write(joinpath(output_folder, "flows-relationships.csv"), out_rel)

println("Success! Menu options generated.")