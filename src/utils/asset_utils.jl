# Helper for storage
function get_storage_level(df, asset_name)
    subset = filter(row -> row.asset == asset_name, df)
    if isempty(subset)
            return DataFrame(time_block_start = eltype(df.time_block_start)[], value = Float64[])
    end
    return select(subset, :time_block_start, :solution => :value)
end


"""
    get_regression_scope(start_assets, df_flow_struct;
                         except_assets = String[],
                         except_flows  = Pair{String,String}[])

Given a list of `start_assets`, returns three sets:

- assets_reg :: Set{String}
    = the regression assets: every start asset itself plus all assets upstream of it.

- flows_reg  :: Set{Pair{String,String}}
    = all flows in the upstream chain, i.e. all `(from => to)` such that there is a path
      `from -> ... -> start_asset`.

- flows_out  :: Set{Pair{String,String}}
    = all flows that start in any of the `start_assets`, i.e. all `(start => to)`.

The arguments `except_assets` and `except_flows` are used to prune both the upstream chain
and the outgoing flows.
"""
function get_regression_scope(start_assets::Vector{String},
                              df_flow_struct::DataFrame;
                              except_assets::Vector{String}=String[],
                              except_flows::Vector{Pair{String,String}}=Pair{String,String}[])

    # 1. Upstream closure (backward from sinks to sources)
    visited_assets = Set{String}(start_assets)
    visited_flows  = Set{Pair{String,String}}()

    frontier = collect(start_assets)

    while !isempty(frontier)
        current = pop!(frontier)

        incoming = subset(df_flow_struct, :to_asset => ByRow(==(current)))
        for row in eachrow(incoming)
            from = row.from_asset
            to   = row.to_asset
            pair = from => to

            # Skip explicitly excluded flows
            if pair in except_flows
                continue
            end

            push!(visited_flows, pair)

            if !(from in visited_assets) && !(from in except_assets)
                push!(visited_assets, from)
                push!(frontier, from)
            end
        end
    end

    # 2. Outgoing flows from *start assets* only
    flows_out = Set{Pair{String,String}}()
    for s in start_assets
        outgoing = subset(df_flow_struct, :from_asset => ByRow(==(s)))
        for row in eachrow(outgoing)
            p = row.from_asset => row.to_asset
            if (row.from_asset in except_assets) || (p in except_flows)
                continue
            end
            push!(flows_out, p)
        end
    end

    # 3. Apply exclusion filters to the upstream sets too
    for a in except_assets
        pop!(visited_assets, a, nothing)
    end
    for p in except_flows
        pop!(visited_flows, p, nothing)
    end

    return visited_assets, visited_flows, flows_out
end
