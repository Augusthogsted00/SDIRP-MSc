# First, ensure you have these packages installed:
# import Pkg; Pkg.add(["BayesianOptimization", "GaussianProcesses", "Distributions"])

# Include your stripped-down evaluation function
include("import.jl")
include("BO_obj day.jl") # Ensure your BO_objective inside this file accepts 9 arguments now.

# Initialize a global counter for the BO iterations
global bo_iteration_counter = 0

# 1. Define the wrapper function for the optimizer
function objective_wrapper(x)
    # Pull in the global counter and increment it
    global bo_iteration_counter
    bo_iteration_counter += 1

    # Unpack the parameters proposed by the BO algorithm
    τ_scale = x[1]
    sol_improve = round(Int, x[2]) # Must be integer
    α = x[3]
    η = x[4]
    segment_size = round(Int, x[5]) # Must be integer
    dim_lambda = x[6]
    prod_dim_lambda = x[7]
    
    n_purged = 5
    CG_iter_static = 15
    
    println("--------------------------------------------------")
    println(">>> BO Iteration: $bo_iteration_counter <<<")
    println("Testing Parameters: τ_scale=$τ_scale, sol_improve=$sol_improve, α=$α, η=$η, segment_size=$segment_size, CG_iter=$CG_iter_static, n_purged=$n_purged")

    # Run your IRP model 
    obj = BO_objective(
        τ_scale, sol_improve, α, η, segment_size, dim_lambda, prod_dim_lambda, CG_iter_static, n_purged
    )

    println("Resulting Objective: $obj")

    # Return the objective for minimization
    return obj
end

# 2. Define the lower and upper bounds for your search space
# Order: [τ_scale, sol_improve, α, η, segment_size, diminishing_lambda, product_diminishing_lambda, CG_iter, n_purged]
lowerbounds = [1e-6,  50.0, 0.95,  0.1,  5.0,  0.0,  0.0]
upperbounds = [0.001, 200.0, 0.99, 0.9, 50.0, 10.0, 10.0]

# 3. Setup the Gaussian Process surrogate model
# We use a standard Matern kernel for the Bayesian surrogate
model = ElasticGPE(
    length(lowerbounds),
    mean=GaussianProcesses.MeanConst(0.0),
    kernel=GaussianProcesses.Mat52Ard(zeros(length(lowerbounds)), 5.0),
    logNoise=-2.0
)

# 4. Configure the Bayesian Optimizer
optimizer = BOpt(
    objective_wrapper,
    model,
    ExpectedImprovement(),
    NoModelOptimizer(),
    lowerbounds,
    upperbounds,
    repetitions=1,
    maxiterations=35,
    sense=Min
)

# 5. RUN THE OPTIMIZATION!
println("Starting Bayesian Optimization...")

# Start uret
start_time = time()

result = boptimize!(optimizer)

# Stop uret
end_time = time()
total_seconds = end_time - start_time

# Omregn til timer, minutter og sekunder
hours = floor(Int, total_seconds / 3600)
minutes = floor(Int, (total_seconds % 3600) / 60)
seconds = round(Int, total_seconds % 60)

# 6. Print the optimal results
println("==================================================")
println("OPTIMIZATION COMPLETE")
println("Total Runtime: $hours timer, $minutes minutter og $seconds sekunder")
println("Best Objective Value Found: ", result.observed_optimum)
println("Best Parameters:")
println("  τ_scale: ", result.observed_optimizer[1])
println("  sol_improve: ", round(Int, result.observed_optimizer[2]))
println("  α: ", result.observed_optimizer[3])
println("  η: ", result.observed_optimizer[4])
println("  segment_size: ", round(Int, result.observed_optimizer[5]))
println("  diminishing_lambda: ", result.observed_optimizer[6])
println("  product_diminishing_lambda: ", result.observed_optimizer[7])
#println("  CG_iter: ", round(Int, result.observed_optimizer[8]))
#println("  n_purged: ", round(Int, result.observed_optimizer[8]))
println("===================================================")


# ==================================================
# VISUALIZING THE OPTIMIZATION
# ==================================================
println("Generating BO Plots...")

# 1. Extract data and FLIP THE SIGN to positive
eval_y = -model.y
eval_x = model.x
iters = 1:length(eval_y)

# Calculate a sensible maximum for the Y-axis to ignore extreme penalty outliers.
# This finds the median cost and caps the plot slightly above it.
using Statistics
median_cost = median(eval_y)
y_upper = median_cost * 1.5      # Cap the plot at 150% of the median
y_lower = minimum(eval_y) * 0.95 # Slight padding below the best found

# --------------------------------------------------
# PLOT 1: Convergence History
# --------------------------------------------------
best_y_so_far = [minimum(eval_y[1:i]) for i in iters]

p_conv = plot(iters, best_y_so_far,
    label="Best Found (Incumbent)",
    linewidth=3,
    color=:blue,
    xlabel="Iteration",
    ylabel="Total IRP Cost",
    title="Bayesian Optimization Convergence",
    legend=:topright,
    ylims=(y_lower, y_upper), # Apply the zoom here
    dpi=300
)

scatter!(p_conv, iters, eval_y,
    label="Evaluated Configurations",
    color=:orange,
    alpha=0.7,
    marker=:circle
)

display(p_conv)
savefig(p_conv, "BO_Convergence.png")

# --------------------------------------------------
# PLOT 2: Parameter Trajectories
# --------------------------------------------------
param_names = [
    "τ_scale", "sol_improve", "α", "η",
    "segment_size", "dim_lambda", "prod_dim_lambda",
    "n_purged"
]

# Create a 9-row layout for the parameters (increased height to fit)
p_params = plot(layout=(7, 1), size=(800, 1500), legend=false)

for i in 1:7
    plot!(p_params[i], iters, eval_x[i, :],
        title=param_names[i],
        titlefontsize=9,
        ylabel="Value",
        color=:purple,
        linewidth=1.5,
        marker=:circle,
        markersize=3
    )
end

# Add an x-label only to the bottom plot to keep it clean
plot!(p_params[7], xlabel="Iteration")

display(p_params)
savefig(p_params, "BO_Parameter_Trajectories.png")

# --------------------------------------------------
# PLOT 3: Parameter Sensitivity Scatter
# --------------------------------------------------
p_scatter = plot(layout=(7, 1), size=(1000, 1200), legend=false)

for i in 1:7
    scatter!(p_scatter[i], eval_x[i, :], eval_y,
        title="$(param_names[i]) vs Cost",
        titlefontsize=10,
        xlabel=param_names[i],
        ylabel="Total Cost",
        color=:steelblue,
        alpha=0.7,
        marker=:circle,
        ylims=(y_lower, y_upper) # Apply the zoom here too!
    )
end

display(p_scatter)
savefig(p_scatter, "BO_Parameter_Sensitivity.png")



# ==================================================
# EXPORTING TO EXCEL
# ==================================================
println("Exporting BO results to Excel...")

# Ensure these packages are loaded at the top of your script:
# using DataFrames, XLSX

# 1. Prepare the Iteration History Data
# eval_x is a 9 x N matrix, so we extract each row for the DataFrame
history_df = DataFrame(
    Iteration = iters,
    Evaluated_Cost = eval_y,               # The positive cost of this specific run
    Best_Cost_So_Far = best_y_so_far,      # The incumbent for convergence tracking
    Tau_Scale = eval_x[1, :],
    Sol_Improve = round.(Int, eval_x[2, :]), # Cast integers back to Int
    Alpha = eval_x[3, :],
    Eta = eval_x[4, :],
    Segment_Size = round.(Int, eval_x[5, :]),
    Dim_Lambda = eval_x[6, :],
    Prod_Dim_Lambda = eval_x[7, :]
    #CG_Iter = round.(Int, eval_x[8, :]),
    #N_Purged = round.(Int, eval_x[8, :])
)

# 2. Prepare the Final Optimal Results Data
best_df = DataFrame(
    Parameter = [
        "Best_Cost", 
        "Total_Runtime_Seconds",
        "Tau_Scale", 
        "Sol_Improve", 
        "Alpha", 
        "Eta", 
        "Segment_Size", 
        "Dim_Lambda", 
        "Prod_Dim_Lambda" 
        #"CG_Iter", 
        #"N_Purged"
    ],
    Value = [
        result.observed_optimum,    # Remember to flip the sign back to positive!
        total_seconds,       
        result.observed_optimizer[1],
        round(Int, result.observed_optimizer[2]),
        result.observed_optimizer[3],
        result.observed_optimizer[4],
        round(Int, result.observed_optimizer[5]),
        result.observed_optimizer[6],
        result.observed_optimizer[7]
        #round(Int, result.observed_optimizer[8]),
        #round(Int, result.observed_optimizer[9])
    ]
)

# 3. Write DataFrames to an Excel file
export_filename = "Bayesian_Optimization_Results.xlsx"

XLSX.openxlsx(export_filename, mode="w") do xf
    # Sheet 1: Iteration History
    sheet1 = xf[1]
    XLSX.rename!(sheet1, "Iteration_History")
    XLSX.writetable!(sheet1, history_df)
    
    # Sheet 2: Optimal Result
    sheet2 = XLSX.addsheet!(xf, "Optimal_Result")
    XLSX.writetable!(sheet2, best_df)
end

println("Export complete! Saved to $export_filename")