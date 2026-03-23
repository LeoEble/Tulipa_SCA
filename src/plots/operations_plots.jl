# ==========================================
# Operations plotting functions
# ==========================================

function plot_total_flow(input_data; output_dir=nothing, file_name="total_flow")
    df_flow = if input_data isa DataFrame
        input_data
    elseif input_data isa Dict
        input_data["var_flow"]
    else
        TIO.get_table(input_data, "var_flow")
    end

    df_active = filter(row -> row.solution > 1e-6, df_flow)
    df_active.from_to = string.(df_active.from_asset, " -> ", df_active.to_asset)

    grouped = combine(groupby(df_active, :from_to), :solution => sum => :total_val)
    grouped.total_val ./= 1_000_000
    sort!(grouped, :total_val, rev=false)

    fig = Figure(size=(1000, max(600, nrow(grouped) * 20)))
    ax = Axis(fig[1,1],
        title  = "Total Flow Results",
        xlabel = "Total Flow (Mega units)",
        ylabel = "Connection",
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
        input_data["var_storage_level_rep_period"]
    else
        TIO.get_table(input_data, "var_storage_level_rep_period")
    end

    # Resolve time column — handle both raw (:time_block_start) and reconstructed (:timestep) data
    time_col = "timestep" in names(storage_levels) ? :timestep : :time_block_start

    wide_df = unstack(storage_levels, time_col, :asset, :solution, fill=0.0)
    sort!(wide_df, time_col)

    times         = wide_df[!, time_col]
    matrix_values = Matrix(wide_df[:, 2:end])
    asset_names   = names(wide_df)[2:end]

    fig = Figure(size=(1000, 600))
    ax = Axis(fig[1,1],
        title  = "Storage Level Over Time",
        xlabel = "Time",
        ylabel = "Storage Level"
    )

    series!(ax, times, transpose(matrix_values), labels=asset_names)

    if length(asset_names) <= 20
        Legend(fig[1,2], ax)
    end

    if output_dir !== nothing
        mkpath(output_dir)
        save(joinpath(output_dir, "$(file_name).png"), fig)
    end
    return fig
end

"""
    plot_operations_mass_balance(input_data; kwargs...)

Plot a 3×2 grid of summer/winter operational timeseries.

The `flow_map` and `storage_map` keyword arguments define which asset
connections map to which plot variables, making this function reusable
across scenarios. Defaults are set for the methanol SCA scenario.
"""
function plot_operations_mass_balance(input_data;
    output_dir  = nothing,
    file_name   = "operations_mass_balance",
    summerdays  = [164, 165],
    winterdays  = [345, 346],
    year        = nothing,
    flow_map    = Dict(
        "e_res"               => [("wind", "battery"), ("wind", "E_hub"), ("solar", "battery"), ("solar", "E_hub")],
        "e_battery"           => [("battery", "E_hub")],
        "e_grid_buy"          => [("market", "battery"), ("market", "E_hub")],
        "e_electrolyzer"      => [("E_hub", "electrolyzer")],
        "e_DAC"               => [("E_hub", "DAC")],
        "e_methanol"          => [("E_hub", "CH3OH_synthesis")],
        "h_electrolyzer_out"  => [("electrolyzer", "H2_storage"), ("electrolyzer", "H2_hub")],
        "h_demand_feed"       => [("H2_hub", "CH3OH_synthesis")],
        "co2_dac_out"         => [("DAC", "CO2_hub"), ("DAC", "CO2_storage")],
        "m_methanol_out"      => [("CH3OH_synthesis", "CH3OH_demand"), ("CH3OH_synthesis", "CH3OH_storage")],
        "m_co2_in"            => [("CO2_hub", "CH3OH_synthesis")],
        "m_demand"            => [("CH3OH_synthesis", "CH3OH_demand"), ("CH3OH_storage", "CH3OH_demand")]
    ),
    storage_map = Dict(
        "h_storage_soc" => "H2_storage",
        "m_storage_soc" => "CH3OH_storage",
        "b_storage_soc" => "battery"
    )
)

    # ==========================================
    # 1. DATA ACCESS
    # ==========================================
    df_flows_long = if haskey(input_data, "var_flow_8760")
        input_data["var_flow_8760"]
    else
        reconstruct_to_timeframe(input_data, "var_flow"; year=year)
    end

    df_storage_long = if haskey(input_data, "var_storage_8760")
        input_data["var_storage_8760"]
    elseif haskey(input_data, "var_storage_level_clustered_year")
        reconstruct_to_timeframe(input_data, "var_storage_level_clustered_year"; year=year)
    else
        reconstruct_to_timeframe(input_data, "var_storage_level_rep_period"; year=year)
    end

    # ==========================================
    # 2. DATA CONSOLIDATION
    # ==========================================
    all_timesteps = unique(vcat(df_flows_long.timestep, df_storage_long.timestep))
    combined_data = DataFrame(timestep = sort(all_timesteps))
    combined_data.real_datetime = DateTime(2024,1,1) .+ Hour.(combined_data.timestep .- 1)

    function get_agg_flow(name, edges)
        sub = subset(df_flows_long, [:from_asset, :to_asset] => ByRow((u, v) -> (u, v) in edges))
        if isempty(sub)
            return DataFrame(:timestep => combined_data.timestep, Symbol(name) => zeros(length(combined_data.timestep)))
        end
        gdf = groupby(sub, :timestep)
        return combine(gdf, :solution => sum => Symbol(name))
    end

    for (var_name, edges) in flow_map
        agg_df = get_agg_flow(var_name, edges)
        leftjoin!(combined_data, agg_df, on=:timestep)
    end

    for (var_name, asset_id) in storage_map
        # For seasonal storage, reconstruct intra-period SOC by integrating hourly net flows
        # anchored at the period-boundary values. Falls back to df_storage_long for
        # rep-period storage (e.g. battery) which is not in var_storage_level_clustered_year.
        soc_df = reconstruct_soc_from_flows(input_data, asset_id)
        if !isempty(soc_df)
            rename!(soc_df, :solution => Symbol(var_name))
            leftjoin!(combined_data, soc_df, on = :timestep)
        else
            sub = filter(row -> row.asset == asset_id, df_storage_long)
            if !isempty(sub)
                sub_to_join = sub[!, [:timestep, :solution]]
                rename!(sub_to_join, :solution => Symbol(var_name))
                leftjoin!(combined_data, sub_to_join, on = :timestep)
            else
                combined_data[!, Symbol(var_name)] .= 0.0
            end
        end
    end

    for col in names(combined_data)
        if col ∉ ["timestep", "real_datetime"]
            combined_data[!, col] = Float64.(coalesce.(combined_data[!, col], 0.0))
        end
    end

    # ==========================================
    # 3. PLOTTING
    # ==========================================
    summerdata = filter(row -> dayofyear(row.real_datetime) in summerdays, combined_data)
    winterdata = filter(row -> dayofyear(row.real_datetime) in winterdays, combined_data)

    # Pre-compute unix timestamps once (reused across all three row-pairs)
    x_summer = isempty(summerdata) ? Float64[] : datetime2unix.(summerdata.real_datetime)
    x_winter = isempty(winterdata) ? Float64[] : datetime2unix.(winterdata.real_datetime)

    fig = Figure(size=(1400, 1100))

    # --- AXIS CREATION ---
    ax_a_main = Axis(fig[1,1], ylabel="Power [MW]",        title="Summer Operation")
    ax_a_dual = Axis(fig[1,1], yaxisposition=:right,        ylabel="Battery SOC [MWh]")

    ax_b_main = Axis(fig[1,2],                              title="Winter Operation")
    ax_b_dual = Axis(fig[1,2], yaxisposition=:right,        ylabel="Battery SOC [MWh]")

    ax_c_main = Axis(fig[2,1], ylabel="Flow [t/h]")
    ax_c_dual = Axis(fig[2,1], yaxisposition=:right,        ylabel="H2 / CO2 SOC [t]")

    ax_d_main = Axis(fig[2,2])
    ax_d_dual = Axis(fig[2,2], yaxisposition=:right,        ylabel="H2 / CO2 SOC [t]")

    ax_e_main = Axis(fig[3,1], ylabel="Flow [t/h]")
    ax_e_dual = Axis(fig[3,1], yaxisposition=:right,        ylabel="MeOH SOC [t]")

    ax_f_main = Axis(fig[3,2])
    ax_f_dual = Axis(fig[3,2], yaxisposition=:right,        ylabel="MeOH SOC [t]")

    # --- AXIS LINKING ---
    linkxaxes!(ax_a_main, ax_c_main, ax_e_main)
    linkxaxes!(ax_b_main, ax_d_main, ax_f_main)

    linkyaxes!(ax_a_main, ax_b_main)
    linkyaxes!(ax_a_dual, ax_b_dual)

    linkyaxes!(ax_c_main, ax_d_main)
    linkyaxes!(ax_c_dual, ax_d_dual)

    linkyaxes!(ax_e_main, ax_f_main)
    linkyaxes!(ax_e_dual, ax_f_dual)

    # --- HIDE DECORATIONS ON INTERNAL AXES ---
    for ax in [ax_a_main, ax_b_main, ax_c_main, ax_d_main] hidexdecorations!(ax, grid=false, ticks=false) end
    for ax in [ax_b_main, ax_d_main, ax_f_main]            hideydecorations!(ax, grid=false, ticks=false) end
    for ax in [ax_a_dual, ax_c_dual, ax_e_dual]            hideydecorations!(ax, grid=false, ticks=false) end
    for ax in [ax_a_dual, ax_b_dual, ax_c_dual, ax_d_dual, ax_e_dual, ax_f_dual] hidexdecorations!(ax) end

    colortwin = :black

    # --- ROW 1: Electricity balance + battery SOC ---
    cols1   = ["e_res", "e_battery", "e_grid_buy", "e_electrolyzer", "e_DAC", "e_methanol"]
    labels1 = ["RES", "Battery Output", "Grid Buy", "Electrolyzer In", "DAC In", "MeOH Synthesis In"]
    colors1 = [:gold, :orange, :firebrick, :dodgerblue3, :mediumpurple, :mediumseagreen]

    if !isempty(summerdata)
        series!(ax_a_main, x_summer, Matrix{Float64}(summerdata[:, cols1])', labels=labels1, color=colors1)
        lines!(ax_a_dual,  x_summer, summerdata.b_storage_soc, label="Battery SOC", color=colortwin, linestyle=:dash)
    end
    if !isempty(winterdata)
        series!(ax_b_main, x_winter, Matrix{Float64}(winterdata[:, cols1])', labels=labels1, color=colors1)
        lines!(ax_b_dual,  x_winter, winterdata.b_storage_soc, label="Battery SOC", color=colortwin, linestyle=:dash)
    end
    leg1_grid = GridLayout(fig[1,3])
    Legend(leg1_grid[1,1], ax_a_main)
    Legend(leg1_grid[2,1], ax_a_dual)

    # --- ROW 2: H2 + CO2 flows + storage SOC ---
    cols2   = ["h_electrolyzer_out", "h_demand_feed", "co2_dac_out"]
    labels2 = ["Electrolyzer Out", "H2 Feed", "DAC CO2 Out"]
    colors2 = [:dodgerblue3, :mediumseagreen, :sienna]

    has_co2_soc = "co2_storage_soc" in names(combined_data)

    if !isempty(summerdata)
        series!(ax_c_main, x_summer, Matrix{Float64}(summerdata[:, cols2])', labels=labels2, color=colors2)
        lines!(ax_c_dual,  x_summer, summerdata.h_storage_soc,  label="H2 SOC",  color=colortwin,  linestyle=:dash)
        has_co2_soc && lines!(ax_c_dual, x_summer, summerdata.co2_storage_soc, label="CO2 SOC", color=:sienna, linestyle=:dot)
    end
    if !isempty(winterdata)
        series!(ax_d_main, x_winter, Matrix{Float64}(winterdata[:, cols2])', labels=labels2, color=colors2)
        lines!(ax_d_dual,  x_winter, winterdata.h_storage_soc,  label="H2 SOC",  color=colortwin,  linestyle=:dash)
        has_co2_soc && lines!(ax_d_dual, x_winter, winterdata.co2_storage_soc, label="CO2 SOC", color=:sienna, linestyle=:dot)
    end
    leg2_grid = GridLayout(fig[2,3])
    Legend(leg2_grid[1,1], ax_c_main)
    Legend(leg2_grid[2,1], ax_c_dual)

    # --- ROW 3: MeOH synthesis flows + MeOH SOC ---
    cols3   = ["m_methanol_out", "m_co2_in", "h_demand_feed", "m_demand"]
    labels3 = ["MeOH Out", "CO2 In", "H2 In", "MeOH Demand"]
    colors3 = [:purple, :grey, :mediumseagreen, :darkorange]

    if !isempty(summerdata)
        series!(ax_e_main, x_summer, Matrix{Float64}(summerdata[:, cols3])', labels=labels3, color=colors3)
        lines!(ax_e_dual,  x_summer, summerdata.m_storage_soc, label="MeOH SOC", color=colortwin, linestyle=:dash)
    end
    if !isempty(winterdata)
        series!(ax_f_main, x_winter, Matrix{Float64}(winterdata[:, cols3])', labels=labels3, color=colors3)
        lines!(ax_f_dual,  x_winter, winterdata.m_storage_soc, label="MeOH SOC", color=colortwin, linestyle=:dash)
    end
    leg3_grid = GridLayout(fig[3,3])
    Legend(leg3_grid[1,1], ax_e_main)
    Legend(leg3_grid[2,1], ax_e_dual)

    # --- DATE FORMATTING ---
    for (data_segment, ax) in [(summerdata, ax_e_main), (winterdata, ax_f_main)]
        if !isempty(data_segment)
            all_days = unique(Date.(data_segment.real_datetime))
            sort!(all_days)
            push!(all_days, all_days[end] + Day(1))

            midnights    = DateTime.(all_days)
            tick_values  = Vector{Float64}(datetime2unix.(midnights))
            tick_labels  = Vector{String}(Dates.format.(midnights, "dd-mm"))
            ax.xticks    = (tick_values, tick_labels)
        end
    end

    # --- PANEL LABELS ---
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
