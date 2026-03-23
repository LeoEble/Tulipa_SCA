# src/tulipa_run.jl
# This file is included from Tulipa_SCA.jl and lives in the Tulipa_SCA namespace.
import Distances

"""
    tulipa_run(db_path, input_dir, output_dir; kwargs...) -> energy_problem

Run a full Tulipa optimization workflow:

1. Connect to DuckDB at `db_path`.
2. Read all CSVs in `input_dir` into DuckDB.
3. Transform profiles from wide to long.
4. Either:
   - use `TC.dummy_cluster!` for a single representative period (`num_rps == 1`), or
   - use `TC.cluster!` for `num_rps > 1` with hull clustering and blended weights.
5. Populate default parameters.
6. Run the TulipaEnergyModel scenario, storing outputs in `output_dir`.

All plotting and post-processing should be done outside this function.
"""
function tulipa_run(db_path::AbstractString,
                    input_dir::AbstractString,
                    output_dir::AbstractString;
                    optimizer = Gurobi.Optimizer,
                    optimizer_parameters = Dict(
                        "OutputFlag"   => 1,
                        "MIPGap"       => 0.03,
                        "Threads"      => 8,
                        "TimeLimit"    => 3600.0,
                        "Seed"         => 314159
                    ),
                    model_parameters_file::AbstractString = joinpath(input_dir, "model-parameters.toml"),
                    model_file_name::AbstractString = "sca_model.lp",
                    num_rps::Int = 1,
                    period_duration::Int = 24)

    # 1. Connect to DuckDB
    connection = DBInterface.connect(DuckDB.DB, db_path)

    try
        # 2. Read CSV folder into DuckDB
        @info "Reading input files from: $input_dir"
        TIO.read_csv_folder(connection, input_dir)

        # 3. Transform profiles_wide -> profiles (long)
        @info "Transforming profiles_wide -> profiles (long)"
        TC.transform_wide_to_long!(
            connection,
            "profiles_wide",
            "profiles";
        )

        # 4. Representative periods / clustering
        if num_rps <= 1
            @info "Using dummy representative period (TC.dummy_cluster!)"
            TC.dummy_cluster!(connection)
        else
            @info "Clustering profiles into $num_rps representative periods " *
                  "(period_duration = $period_duration, method = :convex_hull, weight_type = :convex)"
            # Hull clustering with blended representative periods, as in the docs
            TC.cluster!(connection,
                        period_duration,
                        num_rps;
                        method      = :convex_hull,
                        distance    = Distances.CosineDist(),
                        weight_type = :convex)
        end

        # 5. Populate default values
        @info "Populating defaults and running TulipaEnergyModel"
        TEM.populate_with_defaults!(connection)

        # 6. Run the energy model
        energy_problem = TEM.run_scenario(
            connection;
            output_folder        = output_dir,
            optimizer            = optimizer,
            optimizer_parameters = optimizer_parameters,
            model_parameters_file = model_parameters_file,
            model_file_name       = model_file_name,
        )


        return energy_problem

    finally
        # 7. Always close the connection
        DBInterface.close(connection)
        @info "Connection closed."
    end
end