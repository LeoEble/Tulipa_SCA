# ==========================================
# Shared cost calculation (used by both plot functions below)
# Returns a DataFrame with columns:
#   asset, inv_power_ann, inv_energy_ann, opex_ann, total_annual_cost
# ==========================================
function _compute_annualized_costs(input_data)
    df_inv_power  = get_df(input_data, "var_assets_investment")
    df_inv_energy = get_df(input_data, "var_assets_investment_energy")
    df_flows      = get_df(input_data, "var_flow")

    df_asset      = get_df(input_data, "asset")
    df_commission = get_df(input_data, "asset_commission")
    df_flow_milestone = get_df(input_data, "flow_milestone")

    # CRF per asset
    asset_financials = select(df_asset, :asset, :discount_rate, :economic_lifetime)
    asset_financials[!, :crf] = [calc_crf(r, l) for (r, l) in zip(asset_financials.discount_rate, asset_financials.economic_lifetime)]
    df_crf = select(asset_financials, :asset, :crf)

    # Power CAPEX
    df_p = select(df_inv_power, :asset, :solution, :capacity, :milestone_year)
    df_p = leftjoin(df_p, df_crf, on = :asset, makeunique=true)
    df_p = leftjoin(df_p,
        select(df_commission, :asset, :commission_year, :investment_cost),
        on = [:asset, :milestone_year => :commission_year], makeunique=true)
    df_p[!, :inv_power_ann] = df_p.solution .* df_p.capacity .* coalesce.(df_p.investment_cost, 0.0) .* coalesce.(df_p.crf, 1.0)
    capex_power = combine(groupby(df_p, :asset), :inv_power_ann => sum => :inv_power_ann)

    # Energy CAPEX (storage)
    df_e = select(df_inv_energy, :asset, :solution, :capacity_storage_energy, :milestone_year)
    df_e = leftjoin(df_e, df_crf, on = :asset, makeunique=true)
    df_e = leftjoin(df_e,
        select(df_commission, :asset, :commission_year, :investment_cost_storage_energy),
        on = [:asset, :milestone_year => :commission_year], makeunique=true)
    df_e[!, :inv_energy_ann] = df_e.solution .* df_e.capacity_storage_energy .* coalesce.(df_e.investment_cost_storage_energy, 0.0) .* coalesce.(df_e.crf, 1.0)
    capex_energy = combine(groupby(df_e, :asset), :inv_energy_ann => sum => :inv_energy_ann)

    # Rep-period weights: sum of convex weights per (year, rep_period) → annualisation factor
    df_rep_map   = get_df(input_data, "rep_periods_mapping")
    df_rp_weights = combine(groupby(df_rep_map, [:year, :rep_period]),
                            :weight => sum => :rp_weight)

    # Variable OPEX (weighted by rep-period to give annual €/year)
    rp_col = "rep_period" in names(df_flows) ? [:rep_period] : Symbol[]
    df_f = select(df_flows, :from_asset, :to_asset, :year, rp_col..., :solution)
    if !isempty(rp_col)
        df_f = leftjoin(df_f, df_rp_weights, on = [:year, :rep_period])
    else
        df_f[!, :rp_weight] = ones(nrow(df_f))
    end
    df_f = leftjoin(df_f,
        select(df_flow_milestone, :from_asset, :to_asset, :milestone_year, :operational_cost),
        on = [:from_asset, :to_asset, :year => :milestone_year], makeunique=true)
    df_f[!, :opex_ann] = df_f.solution .* coalesce.(df_f.rp_weight, 1.0) .* coalesce.(df_f.operational_cost, 0.0)
    opex = combine(groupby(df_f, :from_asset), :opex_ann => sum => :opex_ann)
    rename!(opex, :from_asset => :asset)

    # Merge
    df_total = capex_power
    df_total = leftjoin(df_total, capex_energy, on = :asset, makeunique=true)
    df_total = leftjoin(df_total, opex,         on = :asset, makeunique=true)
    df_total.inv_energy_ann .= coalesce.(df_total.inv_energy_ann, 0.0)
    df_total.opex_ann       .= coalesce.(df_total.opex_ann, 0.0)
    df_total[!, :total_annual_cost] = coalesce.(df_total.inv_power_ann, 0.0) .+ df_total.inv_energy_ann .+ df_total.opex_ann

    return df_total, df_p, df_rp_weights   # also return df_p for capacity lookups in LCOx
end

# ==========================================
# Cost breakdown bar chart (per asset, stacked CAPEX + OPEX)
# ==========================================
function plot_investment_costs(input_data; output_dir=nothing, file_name="annualized_costs_breakdown")
    df_total, _, _ = _compute_annualized_costs(input_data)

    df_plot = filter(row -> !ismissing(row.total_annual_cost) && row.total_annual_cost > 1.0, df_total)

    if nrow(df_plot) == 0
        @warn "No non-zero annualized costs found."
        return Figure()
    end

    sort!(df_plot, :total_annual_cost, rev=false)

    fig = Figure(size=(900, max(600, nrow(df_plot) * 25)))
    ax = Axis(fig[1,1],
        title  = "Annualized Cost Breakdown (LCOx Components)",
        xlabel = "Annual Cost (€/year)",
        ylabel = "Asset",
        yticks = (1:nrow(df_plot), df_plot.asset)
    )

    barplot!(ax, 1:nrow(df_plot), df_plot.inv_power_ann,
        direction=:x, color=:cornflowerblue, label="Inv. Power")
    barplot!(ax, 1:nrow(df_plot), df_plot.inv_energy_ann,
        direction=:x, color=:orange, label="Inv. Energy",
        offset = df_plot.inv_power_ann)
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

# ==========================================
# Simple investment bar chart
# ==========================================
function plot_investments(input_data; output_dir=nothing, file_name="assets_investment")
    investments = if input_data isa DataFrame
        input_data
    elseif input_data isa Dict
        input_data["var_assets_investment"]
    else
        TIO.get_table(input_data, "var_assets_investment")
    end

    df_plot = filter(row -> row.solution * row.capacity > 1e-3, investments)

    if nrow(df_plot) == 0
        @warn "No non-zero investments found."
        return Figure()
    end

    df_plot[!, :total_inv] = df_plot.solution .* df_plot.capacity
    sort!(df_plot, :total_inv, rev=false)

    fig = Figure(size=(800, max(600, nrow(df_plot) * 20)))
    ax = Axis(fig[1,1],
        title  = "Investment Results",
        xlabel = "Total Investment",
        ylabel = "Asset",
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

# ==========================================
# LCOx analysis (LCOE per generator + LCOx per product unit)
# ==========================================
function plot_lcox_analysis(input_data;
                            demand_asset_name::String,
                            demand_unit="unit",
                            gen_assets=["wind", "solar"],
                            output_dir=nothing,
                            file_name="lcox_analysis")


    # =================================================================================
    # STEP 1: Annualized costs (shared helper)
    # =================================================================================
    df_total, df_p, df_rp_weights = _compute_annualized_costs(input_data)

    # =================================================================================
    # STEP 2: LCOE per generation asset
    # =================================================================================
    df_lcoe = filter(row -> any(occursin.(gen_assets, row.asset)), df_total)

    if nrow(df_lcoe) > 0
        df_caps = combine(groupby(df_p, :asset),
            [:solution, :capacity] => ((s, c) -> sum(s .* c)) => :installed_capacity_mw)

        df_lcoe = leftjoin(df_lcoe, df_caps, on=:asset, makeunique=true)

        # Weighted annual generation from var_flow (consistent with annualised OPEX)
        df_flows_raw = get_df(input_data, "var_flow")
        rp_col_gen   = "rep_period" in names(df_flows_raw) ? [:rep_period] : Symbol[]
        df_gen = select(df_flows_raw, :from_asset, :year, rp_col_gen..., :solution)
        if !isempty(rp_col_gen)
            df_gen = leftjoin(df_gen, df_rp_weights, on = [:year, :rep_period])
        else
            df_gen[!, :rp_weight] = ones(nrow(df_gen))
        end
        df_gen[!, :weighted_flow] = df_gen.solution .* coalesce.(df_gen.rp_weight, 1.0)
        df_gen_by_asset = combine(groupby(df_gen, :from_asset),
                                  :weighted_flow => sum => :total_generation)
        rename!(df_gen_by_asset, :from_asset => :asset)

        df_lcoe = leftjoin(df_lcoe, df_gen_by_asset, on=:asset, makeunique=true)
        df_lcoe[!, :lcoe] = df_lcoe.total_annual_cost ./ max.(1.0, coalesce.(df_lcoe.total_generation, 0.0))
    end

    # =================================================================================
    # STEP 3: LCOx per unit of demand product
    # =================================================================================
    df_asset_milestone = get_df(input_data, "asset_milestone")
    demand_row = filter(row -> row.asset == demand_asset_name, df_asset_milestone)

    if nrow(demand_row) == 0
        error("Demand asset '$demand_asset_name' not found in asset_milestone table.")
    end

    # Total annual production = sum of weighted flows INTO the demand asset
    df_flows_raw_lcox = get_df(input_data, "var_flow")
    rp_col_d = "rep_period" in names(df_flows_raw_lcox) ? [:rep_period] : Symbol[]
    df_dem = filter(r -> r.to_asset == demand_asset_name, df_flows_raw_lcox)
    df_dem = select(df_dem, :year, rp_col_d..., :solution)
    if !isempty(rp_col_d)
        df_dem = leftjoin(df_dem, df_rp_weights, on = [:year, :rep_period])
    else
        df_dem[!, :rp_weight] = ones(nrow(df_dem))
    end
    total_demand_units = sum(df_dem.solution .* coalesce.(df_dem.rp_weight, 1.0))

    if total_demand_units <= 1e-3
        total_demand_units = 1.0
    end

    df_lcox = copy(df_total)
    df_lcox[!, :unit_cost_power]  = df_lcox.inv_power_ann  ./ total_demand_units
    df_lcox[!, :unit_cost_energy] = df_lcox.inv_energy_ann ./ total_demand_units
    df_lcox[!, :unit_cost_opex]   = df_lcox.opex_ann       ./ total_demand_units
    df_lcox[!, :unit_cost_total]  = df_lcox.total_annual_cost ./ total_demand_units

    sort!(df_lcox, :unit_cost_total, rev=false)
    df_lcox = filter(row -> !ismissing(row.unit_cost_total) && row.unit_cost_total > 1e-4, df_lcox)

    # =================================================================================
    # STEP 4: Visualization
    # =================================================================================
    fig = Figure(size=(1200, 700))

    if nrow(df_lcoe) > 0
        ax_lcoe = Axis(fig[1,1],
            title  = "Generation LCOE",
            xlabel = "Cost (€/MWh)",
            ylabel = "Asset",
            yticks = (1:nrow(df_lcoe), df_lcoe.asset))
        barplot!(ax_lcoe, 1:nrow(df_lcoe), df_lcoe.lcoe, direction=:x, color=:teal)
        text!(ax_lcoe, df_lcoe.lcoe, 1:nrow(df_lcoe),
            text   = [string(round(v, digits=1)) for v in df_lcoe.lcoe],
            align  = (:left, :center),
            offset = (5, 0))
        xlims!(ax_lcoe, 0, maximum(df_lcoe.lcoe) * 1.3)
    end

    ax_lcox = Axis(fig[1,2],
        title  = "Final Product LCOx ($demand_asset_name)",
        xlabel = "Cost Contribution (€/$demand_unit)",
        ylabel = "",
        yticks = (1:nrow(df_lcox), df_lcox.asset))

    barplot!(ax_lcox, 1:nrow(df_lcox), df_lcox.unit_cost_power,
        direction=:x, color=:cornflowerblue, label="Inv. Power")
    barplot!(ax_lcox, 1:nrow(df_lcox), df_lcox.unit_cost_energy,
        direction=:x, color=:orange, label="Inv. Energy",
        offset = df_lcox.unit_cost_power)
    barplot!(ax_lcox, 1:nrow(df_lcox), df_lcox.unit_cost_opex,
        direction=:x, color=:forestgreen, label="OPEX",
        offset = df_lcox.unit_cost_power .+ df_lcox.unit_cost_energy)

    axislegend(ax_lcox, position=:rb)
    Label(fig[0, :], "Total LCOx: $(round(sum(df_lcox.unit_cost_total), digits=2)) €/$demand_unit",
        fontsize=24, font=:bold)

    if output_dir !== nothing
        mkpath(output_dir)
        save(joinpath(output_dir, "$(file_name).png"), fig)
    end

    return fig
end
