function plot_investment_costs(input_data; output_dir=nothing, file_name="annualized_costs_breakdown")
    # --- STEP 1: Fetch Data ---
    # Variables
    df_inv_power  = get_df(input_data, "var_assets_investment")
    df_inv_energy = get_df(input_data, "var_assets_investment_energy")
    df_flows      = get_df(input_data, "var_flow")

    # Parameters
    df_asset      = get_df(input_data, "asset")
    df_commission = get_df(input_data, "asset-commission")
    df_milestone  = get_df(input_data, "flow-milestone")

    # --- STEP 2: Pre-calculate CRF per Asset ---
    # We create a lookup or join specific columns from 'asset' table
    asset_financials = select(df_asset, :asset, :discount_rate, :economic_lifetime)
    
    # Calculate CRF row-by-row
    asset_financials[!, :crf] = [calc_crf(r, l) for (r, l) in zip(asset_financials.discount_rate, asset_financials.economic_lifetime)]

    # --- STEP 3: Annualized Power CAPEX ---
    # 1. Join Asset details (Capacity) and Financials (CRF)
    df_p = leftjoin(df_inv_power, select(df_asset, :asset, :capacity), on = :asset)
    df_p = leftjoin(df_p, asset_financials, on = :asset)
    
    # 2. Join Commissioning Costs
    df_p = leftjoin(df_p, 
        select(df_commission, :asset, :commission_year, :investment_cost), 
        on = [:asset, :milestone_year => :commission_year]
    )

    # 3. Calculation: Solution * Capacity * Cost * CRF
    df_p[!, :inv_power_ann] = df_p.solution .* df_p.capacity .* coalesce.(df_p.investment_cost, 0.0) .* df_p.crf
    
    # Group by asset
    capex_power_grouped = combine(groupby(df_p, :asset), :inv_power_ann => sum => :inv_power_ann)

    # --- STEP 4: Annualized Energy CAPEX (Storage) ---
    # 1. Join Energy Capacity and Financials
    df_e = leftjoin(df_inv_energy, select(df_asset, :asset, :capacity_storage_energy), on = :asset)
    df_e = leftjoin(df_e, asset_financials, on = :asset)

    # 2. Join Commissioning Costs
    df_e = leftjoin(df_e, 
        select(df_commission, :asset, :commission_year, :investment_cost_storage_energy), 
        on = [:asset, :milestone_year => :commission_year]
    )

    # 3. Calculation
    df_e[!, :inv_energy_ann] = df_e.solution .* df_e.capacity_storage_energy .* coalesce.(df_e.investment_cost_storage_energy, 0.0) .* df_e.crf
    
    # Group by asset
    capex_energy_grouped = combine(groupby(df_e, :asset), :inv_energy_ann => sum => :inv_energy_ann)

    # --- STEP 5: Variable OPEX (Annual) ---
    # Join operational costs
    df_f = leftjoin(df_flows, 
        select(df_milestone, :from_asset, :to_asset, :milestone_year, :operational_cost),
        on = [:from_asset, :to_asset, :year => :milestone_year]
    )

    # Calculation: Solution * Operational Cost
    df_f[!, :opex_ann] = df_f.solution .* coalesce.(df_f.operational_cost, 0.0)

    # Group by Source Asset
    opex_grouped = combine(groupby(df_f, :from_asset), :opex_ann => sum => :opex_ann)
    rename!(opex_grouped, :from_asset => :asset)

    # --- STEP 6: Master Merge & Formatting ---
    # Base: All assets present in the power investment table
    df_total = capex_power_grouped

    # Merge Energy & OPEX
    df_total = leftjoin(df_total, capex_energy_grouped, on = :asset)
    df_total = leftjoin(df_total, opex_grouped, on = :asset)

    # Fill missings with 0.0
    df_total.inv_energy_ann .= coalesce.(df_total.inv_energy_ann, 0.0)
    df_total.opex_ann       .= coalesce.(df_total.opex_ann, 0.0)

    # Calculate Total for Sorting/Filtering
    df_total[!, :total_annual_cost] = df_total.inv_power_ann .+ df_total.inv_energy_ann .+ df_total.opex_ann

    # Filter negligible
    df_plot = filter(row -> row.total_annual_cost > 1.0, df_total)
    
    if nrow(df_plot) == 0
        @warn "No non-zero annualized costs found."
        return Figure()
    end

    # Sort by total cost
    sort!(df_plot, :total_annual_cost, rev=false)

    # --- STEP 7: Stacked Bar Plot ---
    
    fig = Figure(size=(900, max(600, nrow(df_plot) * 25))) 
    
    ax = Axis(fig[1,1], 
        title="Annualized Cost Breakdown (LCOx Components)",
        xlabel="Annual Cost (€/year)",
        ylabel="Asset",
        yticks = (1:nrow(df_plot), df_plot.asset)
    )

    # We manually stack them using the `offset` parameter in barplot!
    # Order: Power Inv (Base) -> Energy Inv -> OPEX (Top)
    
    # 1. Power Investment (Blue)
    barplot!(ax, 1:nrow(df_plot), df_plot.inv_power_ann, 
        direction=:x, color=:cornflowerblue, label="Inv. Power")

    # 2. Energy Investment (Orange) - Offset by Power
    barplot!(ax, 1:nrow(df_plot), df_plot.inv_energy_ann, 
        direction=:x, color=:orange, label="Inv. Energy",
        offset = df_plot.inv_power_ann)

    # 3. OPEX (Green) - Offset by Power + Energy
    barplot!(ax, 1:nrow(df_plot), df_plot.opex_ann, 
        direction=:x, color=:forestgreen, label="OPEX",
        offset = df_plot.inv_power_ann .+ df_plot.inv_energy_ann)

    axislegend(ax, position=:rb)
    ylims!(ax, 0.5, nrow(df_plot) + 0.5)

    if output_dir !== nothing
        mkpath(output_dir)
        save(joinpath(output_dir, "$(file_name).png"), fig)
    end
    
    return fig
end

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

function plot_lcox_analysis(input_data; 
                            demand_asset_name::String, 
                            demand_unit="unit", 
                            gen_assets=["wind", "solar"], 
                            output_dir=nothing, 
                            file_name="lcox_analysis")

    

    # --- HELPER 2: Financials ---
    function calc_crf(rate, lifetime)
        if ismissing(rate) || ismissing(lifetime) || lifetime <= 0; return 1.0; end
        if rate <= 1e-6; return 1.0 / lifetime; end
        return (rate * (1 + rate)^lifetime) / ((1 + rate)^lifetime - 1)
    end

    # --- HELPER 3: Profile Integration ---
    function get_profile_sum(asset_name, df_assets_profiles, df_profiles_wide)
        row = filter(r -> r.asset == asset_name, df_assets_profiles)
        if nrow(row) == 0
            return nrow(df_profiles_wide) * 1.0 
        end
        prof_name = row[1, :profile_name]
        if prof_name in names(df_profiles_wide)
            return sum(df_profiles_wide[!, prof_name])
        else
            return 0.0
        end
    end

    # =================================================================================
    # STEP 1: Calculate Total Annualized Costs
    # =================================================================================
    
    # 1. Fetch Raw Data
    df_inv_power   = get_df(input_data, "var_assets_investment")
    df_inv_energy  = get_df(input_data, "var_assets_investment_energy")
    df_flows       = get_df(input_data, "var_flow")
    
    df_asset            = get_df(input_data, "asset")
    df_commission       = get_df(input_data, "asset_commission")
    df_flow_milestone   = get_df(input_data, "flow_milestone")

    # 2. Prepare Financial Parameters (Clean Selection)
    # We explicitly select ONLY these 3 columns to prevent 'capacity' collision
    asset_financials = select(df_asset, :asset, :discount_rate, :economic_lifetime)
    asset_financials[!, :crf] = [calc_crf(r, l) for (r, l) in zip(asset_financials.discount_rate, asset_financials.economic_lifetime)]
    # Keep only asset and crf for the join
    df_crf_clean = select(asset_financials, :asset, :crf)

    # 3. Calculate Power CAPEX
    # We take only what we need from the variable table
    # This prevents hidden columns from colliding later
    df_p = select(df_inv_power, :asset, :solution, :capacity, :milestone_year)
    
    # Join CRF (Safe: df_crf_clean only has :asset, :crf)
    df_p = leftjoin(df_p, df_crf_clean, on = :asset, makeunique=true)
    
    # Join Investment Cost
    # Safe: We select ONLY cost columns from commission table
    df_comm_clean = select(df_commission, :asset, :commission_year, :investment_cost)
    df_p = leftjoin(df_p, df_comm_clean, on = [:asset, :milestone_year => :commission_year], makeunique=true)
                    
    # Calculate
    df_p[!, :inv_power_ann] = df_p.solution .* df_p.capacity .* coalesce.(df_p.investment_cost, 0.0) .* df_p.crf
    capex_power_grouped = combine(groupby(df_p, :asset), :inv_power_ann => sum => :inv_power_ann)

    # 4. Calculate Energy CAPEX
    # Select only needed columns
    df_e = select(df_inv_energy, :asset, :solution, :capacity_storage_energy, :milestone_year)
    
    # Join CRF
    df_e = leftjoin(df_e, df_crf_clean, on = :asset, makeunique=true)
    
    # Join Investment Cost (Energy)
    df_comm_energy_clean = select(df_commission, :asset, :commission_year, :investment_cost_storage_energy)
    df_e = leftjoin(df_e, df_comm_energy_clean, on = [:asset, :milestone_year => :commission_year], makeunique=true)
                    
    # Calculate
    df_e[!, :inv_energy_ann] = df_e.solution .* df_e.capacity_storage_energy .* coalesce.(df_e.investment_cost_storage_energy, 0.0) .* df_e.crf
    capex_energy_grouped = combine(groupby(df_e, :asset), :inv_energy_ann => sum => :inv_energy_ann)

    # 5. Calculate OPEX
    df_f = select(df_flows, :from_asset, :to_asset, :year, :solution)
    df_milestone_clean = select(df_flow_milestone, :from_asset, :to_asset, :milestone_year, :operational_cost)
    
    df_f = leftjoin(df_f, df_milestone_clean, on = [:from_asset, :to_asset, :year => :milestone_year], makeunique=true)
                    
    df_f[!, :opex_ann] = df_f.solution .* coalesce.(df_f.operational_cost, 0.0)
    opex_grouped = combine(groupby(df_f, :from_asset), :opex_ann => sum => :opex_ann)
    rename!(opex_grouped, :from_asset => :asset)

    # 6. Master Merge
    df_total = capex_power_grouped
    df_total = leftjoin(df_total, capex_energy_grouped, on = :asset, makeunique=true)
    df_total = leftjoin(df_total, opex_grouped, on = :asset, makeunique=true)
    
    df_total.inv_energy_ann .= coalesce.(df_total.inv_energy_ann, 0.0)
    df_total.opex_ann       .= coalesce.(df_total.opex_ann, 0.0)
    df_total[!, :total_annual_cost] = df_total.inv_power_ann .+ df_total.inv_energy_ann .+ df_total.opex_ann

    # =================================================================================
    # STEP 2: LCOE Calculation
    # =================================================================================
    
    df_assets_profiles = get_df(input_data, "assets_profiles")
    df_profiles_wide = get_df(input_data, "profiles_wide")
    
    df_lcoe = filter(row -> any(occursin.(gen_assets, row.asset)), df_total)
    
    if nrow(df_lcoe) > 0
        # Re-fetch Installed Capacity (Power)
        # Safe: df_p only has the columns we explicitly selected earlier
        df_caps = combine(groupby(df_p, :asset), [:solution, :capacity] => ((s, c) -> sum(s .* c)) => :installed_capacity_mw)
        
        df_lcoe = leftjoin(df_lcoe, df_caps, on=:asset, makeunique=true)

        df_lcoe[!, :total_generation] = [
            row.installed_capacity_mw * get_profile_sum(row.asset, df_assets_profiles, df_profiles_wide) 
            for row in eachrow(df_lcoe)
        ]
        
        df_lcoe[!, :lcoe] = df_lcoe.total_annual_cost ./ max.(1.0, df_lcoe.total_generation)
    end

    # =================================================================================
    # STEP 3: LCOx Calculation
    # =================================================================================

    df_asset_milestone = get_df(input_data, "asset_milestone")
    demand_row = filter(row -> row.asset == demand_asset_name, df_asset_milestone)
    
    if nrow(demand_row) == 0
        error("Demand asset '$demand_asset_name' not found in asset_milestone table.")
    end

    peak_demand = demand_row[1, :peak_demand]
    profile_integral = get_profile_sum(demand_asset_name, df_assets_profiles, df_profiles_wide)
    total_demand_units = peak_demand * profile_integral

    if total_demand_units <= 1e-3
        total_demand_units = 1.0
    end

    df_lcox = copy(df_total)
    df_lcox[!, :unit_cost_power]  = df_lcox.inv_power_ann ./ total_demand_units
    df_lcox[!, :unit_cost_energy] = df_lcox.inv_energy_ann ./ total_demand_units
    df_lcox[!, :unit_cost_opex]   = df_lcox.opex_ann ./ total_demand_units
    df_lcox[!, :unit_cost_total]  = df_lcox.total_annual_cost ./ total_demand_units
    
    sort!(df_lcox, :unit_cost_total, rev=false)
    df_lcox = filter(row -> row.unit_cost_total > 1e-4, df_lcox)

    # =================================================================================
    # STEP 4: Visualization
    # =================================================================================

    fig = Figure(size=(1200, 700))

    if nrow(df_lcoe) > 0
        ax_lcoe = Axis(fig[1,1], title = "Generation LCOE", xlabel = "Cost (€/MWh)", ylabel = "Asset", yticks = (1:nrow(df_lcoe), df_lcoe.asset))
        barplot!(ax_lcoe, 1:nrow(df_lcoe), df_lcoe.lcoe, direction=:x, color=:teal)
        text!(ax_lcoe, df_lcoe.lcoe, 1:nrow(df_lcoe), text = [string(round(v, digits=1)) for v in df_lcoe.lcoe], align = (:left, :center), offset = (5, 0))
        xlims!(ax_lcoe, 0, maximum(df_lcoe.lcoe) * 1.3)
    end

    ax_lcox = Axis(fig[1,2], title = "Final Product LCOx ($demand_asset_name)", xlabel = "Cost Contribution (€/$demand_unit)", ylabel = "", yticks = (1:nrow(df_lcox), df_lcox.asset))

    barplot!(ax_lcox, 1:nrow(df_lcox), df_lcox.unit_cost_power, direction=:x, color=:cornflowerblue, label="Inv. Power")
    barplot!(ax_lcox, 1:nrow(df_lcox), df_lcox.unit_cost_energy, direction=:x, color=:orange, label="Inv. Energy", offset = df_lcox.unit_cost_power)
    barplot!(ax_lcox, 1:nrow(df_lcox), df_lcox.unit_cost_opex, direction=:x, color=:forestgreen, label="OPEX", offset = df_lcox.unit_cost_power .+ df_lcox.unit_cost_energy)

    axislegend(ax_lcox, position=:rb)
    Label(fig[0, :], "Total LCOx: $(round(sum(df_lcox.unit_cost_total), digits=2)) €/$demand_unit", fontsize=24, font=:bold)

    if output_dir !== nothing
        mkpath(output_dir)
        save(joinpath(output_dir, "$(file_name).png"), fig)
    end

    return fig
end

