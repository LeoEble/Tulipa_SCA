# Auxiliary functions for Tulipa_SCA.jl

# ==========================================
# 0. HELPER FUNCTIONS
# ==========================================
function fetch_plotting_data(connection)
    return Dict(
        :investments => TIO.get_table(connection, "var_assets_investment"),
        :flows       => TIO.get_table(connection, "var_flow"),
        :storage     => TIO.get_table(connection, "var_storage_level_rep_period")
    )
end

# Helper function to sum flows for a list of edges
function get_aggregated_flow(df, edges)
        subset = filter(row -> any((row.from_asset == u && row.to_asset == v) for (u, v) in edges), df)
        if isempty(subset)
            return DataFrame(time_block_start = eltype(df.time_block_start)[], value = Float64[])
        end
        gdf = groupby(subset, :time_block_start)
        return combine(gdf, :solution => sum => :value)
    end

# Helper for storage
function get_storage_level(df, asset_name)
    subset = filter(row -> row.asset == asset_name, df)
    if isempty(subset)
            return DataFrame(time_block_start = eltype(df.time_block_start)[], value = Float64[])
    end
    return select(subset, :time_block_start, :solution => :value)
end

function plot_asset_flow(connection; output_dir=nothing, file_name="asset_flow")
    # 1. Fetch data directly from DuckDB using your TIO wrapper
    #    (Assuming the table in DuckDB is named "flow" or "flows")
    df = TIO.get_table(connection, "flow") 

    # 2. Build the Mermaid String
    mermaid_str = "graph LR\n"
    
    # Iterate through the DataFrame rows
    for row in eachrow(df)
        # Using string interpolation to create connections
        # Clean names if necessary (e.g. replace spaces with underscores)
        u = row.from_asset
        v = row.to_asset
        mermaid_str *= "    $u --> $v\n"
    end

    open("flow_chart.md", "w") do io
        write(io, mermaid_str)
    end
end

# ==========================================
# Plotting functions
# ==========================================

function plot_investments(input_data; output_dir=nothing, file_name="assets_investment")
    # Determine if input is a direct DataFrame, a cache Dict, or a DB connection
    investments = if input_data isa DataFrame
        input_data
    elseif input_data isa Dict
        input_data[:investments]
    else
        TIO.get_table(input_data, "var_assets_investment")
    end
    
    # Filter out negligible investments to keep the plot clean
    df_plot = filter(row -> row.solution * row.capacity > 1e-3, investments)
    
    if nrow(df_plot) == 0
        @warn "No non-zero investments found."
        return Figure()
    end

    # Calculate total investment and sort for the bar chart
    df_plot[!, :total_inv] = df_plot.solution .* df_plot.capacity
    sort!(df_plot, :total_inv, rev=false)
    
    # Dynamically size the figure height based on the number of assets
    fig = Figure(size=(800, max(600, nrow(df_plot) * 20))) 
    
    ax = Axis(fig[1,1], 
        title="Investment Results",
        xlabel="Total Investment",
        ylabel="Asset",
        yticks = (1:nrow(df_plot), df_plot.asset)
    )

    barplot!(ax, 1:nrow(df_plot), df_plot.total_inv, direction=:x, color=:royalblue)
    ylims!(ax, 0.5, nrow(df_plot) + 0.5)

    if output_dir !== nothing
        mkpath(output_dir)
        save(joinpath(output_dir, "$(file_name).png"), fig)
    end
    return fig
end

function plot_total_flow(input_data; output_dir=nothing, file_name="total_flow")
    df_flow = if input_data isa DataFrame
        input_data
    elseif input_data isa Dict
        input_data[:flows]
    else
        TIO.get_table(input_data, "var_flow")
    end
    
    # Filter for active flows and create readable labels
    df_active = filter(row -> row.solution > 1e-6, df_flow)
    df_active.from_to = string.(df_active.from_asset, " -> ", df_active.to_asset)
    
    # Aggregate flows between same assets and convert to Mega units
    grouped = combine(groupby(df_active, :from_to), :solution => sum => :total_val)
    grouped.total_val ./= 1_000_000 
    sort!(grouped, :total_val, rev=false)

    fig = Figure(size=(1000, max(600, nrow(grouped) * 20)))
    ax = Axis(fig[1,1], 
        title="Total Flow Results",
        xlabel="Total Flow (Mega units)",
        ylabel="Connection",
        yticks = (1:nrow(grouped), grouped.from_to)
    )

    if nrow(grouped) > 0
        barplot!(ax, 1:nrow(grouped), grouped.total_val, direction=:x, color=:darkorange)
        ylims!(ax, 0.5, nrow(grouped) + 0.5)
    end

    if output_dir !== nothing
        mkpath(output_dir)
        save(joinpath(output_dir, "$(file_name).png"), fig)
    end
    return fig
end

function plot_storage(input_data; output_dir=nothing, file_name="storage_level")
    storage_levels = if input_data isa DataFrame
        input_data
    elseif input_data isa Dict
        input_data[:storage]
    else
        TIO.get_table(input_data, "var_storage_level_rep_period")
    end
    
    # Pivot data to wide format (time x assets) for efficient plotting
    wide_df = unstack(storage_levels, :time_block_start, :asset, :solution, fill=0.0)
    sort!(wide_df, :time_block_start)
    
    # Extract plotting arrays
    times = wide_df.time_block_start
    matrix_values = Matrix(wide_df[:, 2:end]) 
    asset_names   = names(wide_df)[2:end]

    fig = Figure(size=(1000, 600))
    ax = Axis(fig[1,1], 
        title="Storage Level Over Time",
        xlabel="Time",
        ylabel="Storage Level"
    )

    # series! handles multiple lines efficiently in a single call
    series!(ax, times, transpose(matrix_values), labels=asset_names)

    # Only show legend if the number of assets is manageable
    if length(asset_names) <= 20
        Legend(fig[1,2], ax)
    end

    if output_dir !== nothing
        mkpath(output_dir)
        save(joinpath(output_dir, "$(file_name).png"), fig)
    end
    return fig
end

function plot_operations_mass_balance(input_data; output_dir=nothing, file_name="operations_mass_balance")

    # ==========================================
    # 1. DATA UNPACKING
    # ==========================================
    if input_data isa Dict
        df_flows   = input_data[:flows]
        df_storage = input_data[:storage]
    else
        df_flows   = TIO.get_table(input_data, "var_flow")
        df_storage = TIO.get_table(input_data, "var_storage_level_rep_period")
    end

    # ==========================================
    # 2. MAPPING
    # ==========================================
    flow_map = Dict(
        "e_res" => [("wind", "battery"), ("wind", "electrolyzer"), ("solar", "battery"), ("solar", "electrolyzer")],
        "e_battery" => [("battery", "electrolyzer")], 
        "e_grid_buy" => [("market", "battery"), ("market", "electrolyzer")],
        "e_electrolyzer" => [("wind", "electrolyzer"), ("solar", "electrolyzer"), ("market", "electrolyzer"), ("battery", "electrolyzer")], 
        "h_electrolyzer_out" => [("electrolyzer", "H2_storage"), ("electrolyzer", "H2_hub")],
        "h_demand_feed" => [("H2_hub", "CH3OH_synthesis")],
        "m_methanol_out" => [("CH3OH_synthesis", "CH3OH_demand"), ("CH3OH_synthesis", "CH3OH_storage")],
        "m_co2_in" => [("CO2", "CH3OH_synthesis")],
        "m_demand" => [("CH3OH_synthesis", "CH3OH_demand"), ("CH3OH_storage", "CH3OH_demand")]
    )

    storage_map = Dict(
        "h_storage_soc" => "H2_storage",
        "m_storage_soc" => "CH3OH_storage",
        "b_storage_soc" => "battery"
    )

    # ==========================================
    # 3. DATA PROCESSING
    # ==========================================
    
    # Handle Time Column
    time_col = df_flows.time_block_start
    unique_times = unique(time_col)
    combined_data = DataFrame(datetime = unique_times)

    # Create explicit DateTime objects (Reference Year 2024)
    if eltype(unique_times) <: Integer
        combined_data.real_datetime = DateTime(2024,1,1) .+ Hour.(combined_data.datetime .- 1)
    else
        combined_data.real_datetime = combined_data.datetime
    end

    # Merge Flows
    for (var_name, edges) in flow_map
        agg_df = get_aggregated_flow(df_flows, edges)
        rename!(agg_df, :value => Symbol(var_name))
        combined_data = leftjoin(combined_data, agg_df, on=:datetime => :time_block_start)
    end

    # Merge Storage
    for (var_name, asset) in storage_map
        st_df = get_storage_level(df_storage, asset)
        rename!(st_df, :value => Symbol(var_name))
        combined_data = leftjoin(combined_data, st_df, on=:datetime => :time_block_start)
    end

    # Fill Missing
    for col in names(combined_data)
        if col ∉ ["datetime", "real_datetime"]
            combined_data[!, col] = coalesce.(combined_data[!, col], 0.0)
        end
    end
    sort!(combined_data, :datetime)

    # ==========================================
    # 4. PLOTTING
    # ==========================================
    
    summerdays = [164, 165]
    winterdays = [345, 346]
    
    summerdata = filter(row -> dayofyear(row.real_datetime) in summerdays, combined_data)
    winterdata = filter(row -> dayofyear(row.real_datetime) in winterdays, combined_data)

    fig = Figure(size=(1400, 1000))

    # --- AXIS CREATION ---
    ax_a_main = Axis(fig[1,1], ylabel="Power [MW]", title="Summer Operation")
    ax_a_dual = Axis(fig[1,1], yaxisposition=:right, ylabel="Battery SOC [MWh]")
    
    ax_b_main = Axis(fig[1,2], title="Winter Operation")
    ax_b_dual = Axis(fig[1,2], yaxisposition=:right, ylabel="Battery SOC [MWh]")
    
    ax_c_main = Axis(fig[2,1], ylabel="H2 Flow [kg/h]")
    ax_c_dual = Axis(fig[2,1], yaxisposition=:right)
    
    ax_d_main = Axis(fig[2,2])
    ax_d_dual = Axis(fig[2,2], yaxisposition=:right, ylabel="H2 SOC [kg]")
    
    ax_e_main = Axis(fig[3,1], ylabel="Mass Flow [kg/h]")
    ax_e_dual = Axis(fig[3,1], yaxisposition=:right)
    
    ax_f_main = Axis(fig[3,2])
    ax_f_dual = Axis(fig[3,2], yaxisposition=:right, ylabel="MeOH SOC [kg]")

    # Linking
    linkxaxes!(ax_a_main, ax_c_main, ax_e_main)
    linkxaxes!(ax_b_main, ax_d_main, ax_f_main)
    linkyaxes!(ax_a_main, ax_b_main)
    linkyaxes!(ax_a_dual, ax_b_dual) 
    linkyaxes!(ax_c_main, ax_d_main)
    linkyaxes!(ax_c_dual, ax_d_dual) 
    linkyaxes!(ax_e_main, ax_f_main)
    linkyaxes!(ax_e_dual, ax_f_dual) 

    # Cleanup Decorations
    for ax in [ax_a_main, ax_b_main, ax_c_main, ax_d_main] hidexdecorations!(ax, grid=false, ticks=false) end
    for ax in [ax_b_main, ax_d_main, ax_f_main] hideydecorations!(ax, grid=false, ticks=false) end
    for ax in [ax_a_dual, ax_c_dual, ax_e_dual] hideydecorations!(ax, grid=false, ticks=false) end
    for ax in [ax_a_dual, ax_b_dual, ax_c_dual, ax_d_dual, ax_e_dual, ax_f_dual] hidexdecorations!(ax) end

    colortwin = :black

    # --- PLOTTING ROW 1 ---
    # Added "e_battery" to cols1 as per your update
    cols1   = ["e_res", "e_battery", "e_electrolyzer", "e_grid_buy"] 
    labels1 = ["RES", "Battery Output", "Electrolyzer In", "Grid Buy"]
    colors1 = [:gold, :orange, :dodgerblue3, :firebrick] # Added orange for battery

    if !isempty(summerdata)
        x_summer = datetime2unix.(summerdata.real_datetime)
        # Explicit Matrix{Float64} conversion for robustness
        data1 = Matrix{Float64}(summerdata[:, cols1])' 
        
        series!(ax_a_main, x_summer, data1, labels=labels1, color=colors1)
        lines!(ax_a_dual, x_summer, summerdata.b_storage_soc, label="Battery SOC", color=colortwin, linestyle=:dash)
    end
    if !isempty(winterdata)
        x_winter = datetime2unix.(winterdata.real_datetime)
        data1 = Matrix{Float64}(winterdata[:, cols1])'
        
        series!(ax_b_main, x_winter, data1, labels=labels1, color=colors1)
        lines!(ax_b_dual, x_winter, winterdata.b_storage_soc, label="Battery SOC", color=colortwin, linestyle=:dash)
    end
    Legend(fig[1,3], ax_a_main, valign=:top)
    Legend(fig[1,3], ax_a_dual, valign=:bottom)

    # --- PLOTTING ROW 2 ---
    cols2   = ["h_electrolyzer_out", "h_demand_feed"]
    labels2 = ["Electrolyzer Out", "H2 Feed"]
    colors2 = [:dodgerblue3, :mediumseagreen]

    if !isempty(summerdata)
        x_summer = datetime2unix.(summerdata.real_datetime)
        data2 = Matrix{Float64}(summerdata[:, cols2])'
        
        series!(ax_c_main, x_summer, data2, labels=labels2, color=colors2)
        lines!(ax_c_dual, x_summer, summerdata.h_storage_soc, label="H2 SOC", color=colortwin, linestyle=:dash)
    end
    if !isempty(winterdata)
        x_winter = datetime2unix.(winterdata.real_datetime)
        data2 = Matrix{Float64}(winterdata[:, cols2])'
        
        series!(ax_d_main, x_winter, data2, labels=labels2, color=colors2)
        lines!(ax_d_dual, x_winter, winterdata.h_storage_soc, label="H2 SOC", color=colortwin, linestyle=:dash)
    end
    Legend(fig[2,3], ax_c_main, valign=:top)
    Legend(fig[2,3], ax_c_dual, valign=:bottom)

    # --- PLOTTING ROW 3 ---
    cols3   = ["m_methanol_out", "m_co2_in", "h_demand_feed"]
    labels3 = ["MeOH Out", "CO2 In", "H2 In"]
    colors3 = [:purple, :grey, :mediumseagreen]

    if !isempty(summerdata)
        x_summer = datetime2unix.(summerdata.real_datetime)
        data3 = Matrix{Float64}(summerdata[:, cols3])'
        
        series!(ax_e_main, x_summer, data3, labels=labels3, color=colors3)
        lines!(ax_e_dual, x_summer, summerdata.m_storage_soc, label="MeOH SOC", color=colortwin, linestyle=:dash)
    end
    if !isempty(winterdata)
        x_winter = datetime2unix.(winterdata.real_datetime)
        data3 = Matrix{Float64}(winterdata[:, cols3])'
        
        series!(ax_f_main, x_winter, data3, labels=labels3, color=colors3)
        lines!(ax_f_dual, x_winter, winterdata.m_storage_soc, label="MeOH SOC", color=colortwin, linestyle=:dash)
    end
    Legend(fig[3,3], ax_e_main, valign=:top)
    Legend(fig[3,3], ax_e_dual, valign=:bottom)

    # --- DATE FORMATTING ---
    for (data_segment, ax) in [(summerdata, ax_e_main), (winterdata, ax_f_main)]
        if !isempty(data_segment)
            # find_unique days
            all_days = unique(Date.(data_segment.real_datetime))
            sort!(all_days)

            # Add the "next" day to create a symmetrical end tick
            if !isempty(all_days)
                push!(all_days, all_days[end] + Day(1))
            end

            midnights = DateTime.(all_days) 
            
            # Explicitly convert to Vector{Float64} and Vector{String} to avoid conversion errors
            tick_values = Vector{Float64}(datetime2unix.(midnights))
            tick_labels = Vector{String}(Dates.format.(midnights, "dd-mm"))
            
            ax.xticks = (tick_values, tick_labels)
        end
    end

    # Large Labels
    Label(fig[1,1,TopLeft()], "A", fontsize=26, font=:bold, padding=(0,5,5,0), halign=:right)
    Label(fig[1,2,TopLeft()], "B", fontsize=26, font=:bold, padding=(0,5,5,0), halign=:right)
    Label(fig[2,1,TopLeft()], "C", fontsize=26, font=:bold, padding=(0,5,5,0), halign=:right)
    Label(fig[2,2,TopLeft()], "D", fontsize=26, font=:bold, padding=(0,5,5,0), halign=:right)
    Label(fig[3,1,TopLeft()], "E", fontsize=26, font=:bold, padding=(0,5,5,0), halign=:right)
    Label(fig[3,2,TopLeft()], "F", fontsize=26, font=:bold, padding=(0,5,5,0), halign=:right)

    if output_dir !== nothing
        mkpath(output_dir)
        save(joinpath(output_dir, "$(file_name).png"), fig)
    end

    return fig
end