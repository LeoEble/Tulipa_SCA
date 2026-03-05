function plot_asset_flow(connection; output_dir=nothing, file_name="asset_flow")
    # 1. Fetch data directly from DuckDB using TIO wrapper
    #    (Assuming the table in DuckDB is named "flow" or "flows")
    df = TIO.get_table(connection, "flow") 

    # 2. Build the Mermaid String
    mermaid_str = ":::mermaid\ngraph LR;\n"
    
    # Iterate through the DataFrame rows
    for row in eachrow(df)
        # Using string interpolation to create connections
        # Clean names if necessary (e.g. replace spaces with underscores)
        u = row.from_asset
        v = row.to_asset
        mermaid_str *= "    $u-->$v;\n"
    end

    mermaid_str *= ":::\n"

    if output_dir !== nothing
        mkpath(output_dir)
        open(joinpath(output_dir, "$(file_name).md"), "w") do io
            write(io, mermaid_str)
        end
    end
end
