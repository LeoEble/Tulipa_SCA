using JuMP

function add_exclusive_investments!(energy_problem::TEM.EnergyProblem, assets_base_name::String)
    # unpack for readability
    variables = energy_problem.variables
    model = energy_problem.model
    var_investment = variables[:assets_investment].container
    indices = variables[:assets_investment].indices |> DataFrame

    # filter the dataframe to only include rows where the asset column matches the given assets_base_name
    filtered_indices = filter(row -> occursin(assets_base_name, row.asset), indices)

    # group the filtered indices by customer and exclusive_group
    filtered_ids = filtered_indices.id

    # if there is only one or none assets, there is no need to further constrain
    if length(filtered_ids) <= 1
        return nothing
    end

    # add the exclusive constraint to the model 
    # i.e., the sum of the investment variables for the filtered ids must be less than or equal to 1
    JuMP.@constraint(
        model,
        sum(var_investment[id] for id in filtered_ids) <= 1,
        base_name = "exclusive_investment_group[$(assets_base_name),]",
    )

    return nothing
end