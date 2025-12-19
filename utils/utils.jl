# Auxiliary functions for Tulipa_SCA.jl
function plot_investments(connection; output_dir=nothing, file_name="assets_investment")
    investments = TIO.get_table(connection, "var_assets_investment")
    investments.solution .= investments.solution .* investments.capacity
    sorted_investments = sort(investments, :solution, rev=false)
    p = bar(
        sorted_investments.asset,
        sorted_investments.solution;
        permute=(:x, :y),
        xlabel="Asset",
        ylabel="Total Investment",
        title="Investment Results",
        legend=false,
        color=:royalblue,
    )
    if output_dir === nothing
        return p
    else
        savefig(p, joinpath(output_dir, "$(file_name).png"))
        display(p)
        return p
    end
end

function plot_total_flow(connection; output_dir=nothing, file_name="total_flow")
    total_flow = TIO.get_table(connection, "var_flow")
    total_flow.from_to_asset = string.(total_flow.from_asset, " -> ", total_flow.to_asset)
    total_flow.solution .= total_flow.solution ./ 1_000_000 # scaling the solution to Mega units
    grouped_flow = combine(groupby(total_flow, [:from_to_asset]), :solution => sum => :total_flow)
    sorted_flow = sort(grouped_flow, :total_flow, rev=false)
    p = bar(
        sorted_flow.from_to_asset,
        sorted_flow.total_flow;
        permute=(:x, :y),
        xlabel="Flow from to Asset",
        ylabel="Total Flow (Mega units)",
        title="Total Flow Results",
        legend=false,
        color=:darkorange,
    )
    if output_dir === nothing
        return p
    else
        savefig(p, joinpath(output_dir, "$(file_name).png"))
        display(p)
        return p
    end
end

function plot_storage(connection; output_dir=nothing, file_name="storage_level")
    storage_levels = TIO.get_table(connection, "var_storage_level_rep_period")
    p = plot(
        storage_levels.time_block_start,
        storage_levels.solution;
        group=storage_levels.asset,
        xlabel="Time",
        ylabel="Storage Level",
        title="Storage Level Over Time",
        legend=:topright,
    )
    if output_dir === nothing
        return p
    else
        savefig(p, joinpath(output_dir, "$(file_name).png"))
        display(p)
        return p
    end
end
