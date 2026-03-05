module Tulipa_SCA

    # 1. Internal Dependencies (Things the module code needs to run)
    using DuckDB
    using DataFrames
    using CairoMakie
    using Distances
    using Dates
    using Gurobi
    using HiGHS
    
    import TulipaIO as TIO
    import TulipaEnergyModel as TEM
    import TulipaClustering as TC

    # 2. Load Source Files (Order: Utils -> Core -> Plots)
    include(joinpath(@__DIR__, "utils", "core_utils.jl"))
    include(joinpath(@__DIR__, "utils", "flow_utils.jl"))
    include(joinpath(@__DIR__, "utils", "asset_utils.jl"))
    include(joinpath(@__DIR__, "utils", "cost_utils.jl"))

    include(joinpath(@__DIR__, "tulipa_run.jl")) 

    include(joinpath(@__DIR__, "plots", "topology_plots.jl"))
    include(joinpath(@__DIR__, "plots", "operations_plots.jl"))
    include(joinpath(@__DIR__, "plots", "cost_plots.jl"))

    # No exports needed. Everything is accessible via TSCA.function_name

end # module