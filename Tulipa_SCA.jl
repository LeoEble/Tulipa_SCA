# 1. Import packages
import TulipaIO as TIO
import TulipaEnergyModel as TEM
import TulipaClustering as TC
using DuckDB
using DataFrames
using Markdown
using CairoMakie
using HiGHS
using Gurobi
using Dates

include("utils/utils.jl") # include auxiliary functions 

# 2. Set up the connection and read the data and create the database
connection = DBInterface.connect(DuckDB.DB, "data/db/sca.db")
input_dir = "data/raw/methanol_v01"
output_dir = "outputs"
#rm(output_dir; force=true, recursive=true) # remove existing output directory (to ensure delete old results)
#mkdir(output_dir)                          # create output directory
TIO.read_csv_folder(connection, input_dir)

# Plot the asset flow chart
plot_asset_flow(connection; output_dir, file_name="asset_flow_chart")

# 3. Transform the profiles data from wide to long
profiles_wide_df = TIO.get_table(connection, "profiles_wide")
TC.transform_wide_to_long!(
    connection,
    "profiles_wide",
    "profiles";
)

# 4. Dummy clustering to create the tables for Tulipa
TC.dummy_cluster!(connection)

# 5. Populate default values and run the energy model
TEM.populate_with_defaults!(connection)

# optimizer = HiGHS.Optimizer
# parameters = Dict(
#     "output_flag" => true,
#     "user_objective_scale" => -5,
#     "mip_rel_gap" => 0.01,
# )

optimizer = Gurobi.Optimizer
parameters = Dict(
    "OutputFlag" => 1,
    "MIPGap" => 0.01,
)

energy_problem = TEM.run_scenario(connection;
    output_folder=output_dir,
    optimizer=optimizer,
    optimizer_parameters=parameters,
    model_parameters_file=joinpath(@__DIR__, input_dir, "model-parameters.toml"),
    model_file_name="sca_model.lp",
)

# 6. Plot results
data_cache = fetch_plotting_data(connection)

plot_investments(data_cache; output_dir, file_name="assets_investment")
plot_total_flow(data_cache; output_dir, file_name="total_flow")
plot_storage(data_cache; output_dir, file_name="storage_level")
plot_operations_mass_balance(data_cache; output_dir, file_name="flows")

# Close the connection
DBInterface.close(connection)