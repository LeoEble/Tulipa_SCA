# 1. Import packages
import TulipaIO as TIO
import TulipaEnergyModel as TEM
import TulipaClustering as TC
using DuckDB
using DataFrames
using Plots
using Distances

# 2. Set up the connection and read the data
connection = DBInterface.connect(DuckDB.DB)
input_dir = r"data\raw4"
TIO.read_csv_folder(connection, input_dir)

# 3. Transform the profiles data from wide to long
profiles_wide_df = TIO.get_table(connection, "profiles_wide")
TC.transform_wide_to_long!(
    connection,
    "profiles_wide",
    "profiles";
)

# 4. Hull Clustering with Blended Representative Periods
period_duration = 24
num_rps = 4
clusters = TC.cluster!(connection,
                    period_duration,
                    num_rps;
                    method = :convex_hull,
                    distance = Distances.CosineDist(),
                    weight_type = :convex
                    )

# 5. plot the representative periods
df = TIO.get_table(connection, "profiles_rep_periods")
rep_periods = unique(df.rep_period)
plots = []
for rp in rep_periods
    df_rp = filter(row -> row.rep_period == rp, df)
    p = plot(size=(400, 300), title="Hull Clustering RP $rp")

    for group in groupby(df_rp, :profile_name)
        name = group.profile_name[1]
        plot!(p, group.timestep, group.value, label=name)
    end

    show_legend = (rp == rep_periods[1])
    plot!(p,
          xlabel="Timestep",
          ylabel="Value",
          xticks=0:2:period_duration,
          xlim=(1, period_duration),
          ylim=(0, 1),
          legend=show_legend ? :topleft : false,
          legendfontsize=6
         )
    push!(plots, p)
end
plot(plots..., layout=(2, 2), size=(800, 600))