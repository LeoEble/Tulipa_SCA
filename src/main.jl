#!/usr/bin/env julia

# 1. Setup
using Pkg
Pkg.activate(joinpath(@__DIR__, "..")) 

# 2. Load Script Dependencies (Explicitly)
using DBInterface
using DuckDB
using DataFrames

# 3. Load Module (As TSCA)
include(joinpath(@__DIR__, "Tulipa_SCA.jl"))
import .Tulipa_SCA as TSCA

"""
    main()

High-level workflow:

1. Define `db_path`, `input_dir`, and `output_dir`.
2. Call `tulipa_run(input_dir; db_path, output_dir)` to run the optimization.
3. Re-open the DuckDB connection.
4. Use `fetch_plotting_data` to build a data cache.
5. Call plotting functions:
   - plot_asset_flow
   - plot_investments
   - plot_total_flow
   - plot_storage
   - plot_operations_mass_balance
   - plot_lcox_analysis
6. Close the DB connection.
"""
function main()
    # --- Paths / scenario configuration --------------------------------------
    # db_path    = "data/db/sca_electrolysis.db"
    # input_dir  = "data/raw/electrolysis_v01/"
    # output_dir = "outputs"

    db_path    = "data/db/sca_methanol.db"
    input_dir  = "data/raw/methanol_v01/"
    output_dir = "outputs"

    representative_periods = 30
    representative_period_duration = 50

    if !isdir(output_dir)
        mkpath(output_dir)
    end

    @info "Starting Tulipa SCA run" db_path input_dir output_dir

    # # --- 1) Run optimization only (no plotting here) -------------------------
    # energy_problem = TSCA.tulipa_run(db_path,
    #                             input_dir,
    #                             output_dir;
    #                             num_rps    = representative_periods,
    #                             period_duration = representative_period_duration)

    # @info "Optimization finished" energy_problem

    # --- 2) Post-processing & plots ------------------------------------------
    connection = DBInterface.connect(DuckDB.DB, db_path)

    try
        # Topology / asset-flow chart
        TSCA.plot_asset_flow(connection;
                        output_dir = output_dir,
                        file_name  = "asset_flow_chart")

        # Fetch the raw data
        data_cache = TSCA.fetch_plotting_data(connection)

        # Add "Hourly" versions to the cache (without deleting the originals)
        # This uses the reconstruction math once and stores the result
        @info "Expanding results to hourly timeframe..."

        data_cache["var_flow_8760"] = TSCA.reconstruct_to_timeframe(data_cache, "var_flow")
        data_cache["var_storage_8760"] = TSCA.reconstruct_to_timeframe(data_cache, "var_storage_level_rep_period")

# Cost-related plots
        # TSCA.plot_investment_costs(data_cache;
        #                  output_dir = output_dir,
        #                  file_name  = "assets_investment")

        TSCA.plot_lcox_analysis(
            data_cache;
            demand_asset_name = "CH3OH_demand",
            demand_unit       = "tonnes CH3OH",
            gen_assets        = ["wind", "solar"],
            output_dir        = output_dir,
            file_name         = "lcox_analysis",
        )

        # Operations-related plots
        # TSCA.plot_total_flow(data_cache;
        #                 output_dir = output_dir,
        #                 file_name  = "total_flow")

        # TSCA.plot_storage(data_cache;
        #              output_dir = output_dir,
        #              file_name  = "storage_level")

        TSCA.plot_operations_mass_balance(
            data_cache;
            output_dir = output_dir,
            file_name  = "flows"
            # summerdays = [2, 3],
            # winterdays = [15, 16],
        )

        @info "Post-processing and plotting finished."

    finally
        DBInterface.close(connection)
    end
end

# Run when this file is executed as a script
main()