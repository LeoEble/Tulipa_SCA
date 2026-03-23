function plot_asset_flow(connection; output_dir=nothing, file_name="asset_flow")
    df = TIO.get_table(connection, "flow")

    # Build a Mermaid graph markdown block
    lines = ["```mermaid", "graph LR;"]
    for row in eachrow(df)
        push!(lines, "    $(row.from_asset)-->$(row.to_asset);")
    end
    push!(lines, "```")

    mermaid_str = join(lines, "\n") * "\n"

    if output_dir !== nothing
        mkpath(output_dir)
        open(joinpath(output_dir, "$(file_name).md"), "w") do io
            write(io, mermaid_str)
        end
    end

    return mermaid_str
end
