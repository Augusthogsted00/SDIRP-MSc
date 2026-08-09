function master_problem(
    day,
    pool, # List of indices (Ints)
    current_invs,
    TP,
    demands_hat,
    empty_stocks,
    min_stocks,
    max_stocks,
    R_t,
    R_tks,
    params,
    is_relaxed::Bool,
    pool_dict::Vector{Route},
    forced_routes::Vector{Int}=Int[],
    forbidden_routes=Int[],
    ip_time_limit=Inf
)
    # Dynamic lookahead
    L = day:day+params.lookahead
    L_prev = (day-1):day+params.lookahead

    # --- IRP Optimization Model ---
    model = Model(Gurobi.Optimizer)

  

    #set_silent(model)
    if is_relaxed || ip_time_limit < Inf
        set_silent(model)
    else
        # Unsilenced: Gurobi's native logger will show gap evolution.
        # Set it to print updates every 10 seconds.
        set_optimizer_attribute(model, "DisplayInterval", 10)
    end
    # Decision Variables
    if is_relaxed
        @variable(model, 0 <= y[r in pool] <= 1)
    else
        @variable(model, y[r in pool], Bin)
    end

    @variable(model, I[tp in TP, t in L_prev])
    @variable(model, v_min[tp in TP, t in L] >= 0)
    @variable(model, v_empty[tp in TP, t in L] >= 0)
    @variable(model, v_max[tp in TP, t in L] >= 0)

    ### Objective Function ###
    @objective(model, Min,
        # ADD 'if r in pool' at the end of the generator here:
        sum(pool_dict[r].total_cost * y[r] for t in L for r in get(R_t, t, Int[]) if r in pool) +
        sum(params.rho_min * v_min[tp, t] + params.rho_empty * v_empty[tp, t] + params.rho_max * v_max[tp, t] for tp in TP, t in L)
    )

    # Initial inventory constraints for the first day
    for tp in TP
        JuMP.fix(I[tp, day-1], current_invs[tp]; force=true)
    end

    # Inventory balance constraints
    @constraint(model, inv_bal[tp in TP, t in L],
        # ADD 'if r in pool' at the end of the generator here:
        sum(get(pool_dict[r].q, tp[1], 0.0) * y[r] for r in get(R_t, t, Int[]) if r in pool) +
        I[tp, t-1] - I[tp, t] + v_empty[tp, t] - v_max[tp, t] == demands_hat[(tp..., t)]
    )

    # Inventory level constraints
    @constraint(model, empty_stock[tp in TP, t in L], I[tp, t] >= empty_stocks[tp])
    @constraint(model, min_p[tp in TP, t in L], I[tp, t] + v_min[tp, t] >= min_stocks[tp])
    @constraint(model, inv_max[tp in TP, t in L], I[tp, t] <= max_stocks[tp])

    # Vehicle availability
    @constraint(model, shift_limit[key in keys(R_tks)],
        sum(y[r] for r in R_tks[key] if r in pool) <= 1
    )


    # ==========================================
    # GUROBI SOLVER CONFIGURATION
    # ==========================================
    if !is_relaxed
        # --- INTEGER PROGRAMMING (IP) ---
        if ip_time_limit < Inf
            # SPEED-MODE (Til Bayesian Optimization)
            set_time_limit_sec(model, ip_time_limit)
            set_optimizer_attribute(model, "MIPFocus", 0)  # Fokus på gode løsninger (Incumbents)
            set_optimizer_attribute(model, "MIPGap", 1e-4) # Stop ved 5% gap
        else
            # EXACT-MODE (Til det endelige Resultat-Run)
            set_time_limit_sec(model, 10800.0)             # Fail-safe: 3 timer pr. IP
            set_optimizer_attribute(model, "MIPFocus", 0)  # Standard balance
            set_optimizer_attribute(model, "MIPGap", 1e-4) # Stop ved optimalitet (0.01%)
        end
    else
        # --- LINEAR PROGRAMMING (RMP Relaxering) ---
        # Sørg for at den stadig overholder en tidsgrænse, hvis en sådan er sat for LP'en
        if ip_time_limit < Inf
            set_time_limit_sec(model, ip_time_limit)
        end
    end


    JuMP.optimize!(model)

    # 1. Extract the raw JuMP status
    jump_status = termination_status(model)
    local_status = :Unknown
    if jump_status == MOI.OPTIMAL
        local_status = :Optimal
    elseif jump_status == MOI.TIME_LIMIT && has_values(model)
        local_status = :TimeLimit
    elseif jump_status == MOI.INFEASIBLE
        local_status = :Infeasible
    else
        local_status = :Failed
    end

    # ... [After optimize!(model) and getting jump_status] ...

    if local_status == :Optimal || local_status == :TimeLimit
        # 1. Extract basic results
        obj_val = objective_value(model)

        # Extract y_out early so we can count the active IP variables
        y_out = Dict(idx => value(y[idx]) for idx in pool)
        # ==========================================
        # NEW: Print Incumbent Objective
        # We only print if this is the Integer solve (!is_relaxed)
        # ==========================================
        if !is_relaxed
            mip_gap = 0.0
            try
                mip_gap = relative_gap(model)
            catch
                mip_gap = 0.0 
            end
            active_ip_columns = count(val -> val > 1e-4, values(y_out))
            gap_percentage = round(mip_gap * 100, digits=2)
            
            println("    ↳ IP Status: $local_status | IP Obj: $(round(obj_val, digits=2)) | Gap: $gap_percentage% | Ruter valgt: $active_ip_columns")
        end

        y_out = Dict(idx => value(y[idx]) for idx in pool)
        I_out = Dict((tp, t) => value(I[tp, t]) for tp in TP, t in L_prev)

        # 2. Reinserted Penalty Extractions
        v_empty_total = [sum(value(v_empty[tp, t]) for tp in TP) for t in L]
        v_min_total = [sum(value(v_min[tp, t]) for tp in TP) for t in L]
        v_max_total = [sum(value(v_max[tp, t]) for tp in TP) for t in L]
        # 3. Dual Extraction (LP Only)
        omega_out = Dict()
        pi_out = Dict()
        basis_statuses_out = Dict{Int, MOI.BasisStatusCode}() # <--- NYT: Initialiser basis status dict
        if is_relaxed 
            if has_duals(model) #splittet if statement
                omega_out = dual.(inv_bal)
                pi_out = dual.(shift_limit)
            end


            for idx in pool
                basis_statuses_out[idx] = MOI.get(model, MOI.VariableBasisStatus(), y[idx])
            end
        end

        return (
            status=local_status,
            obj=obj_val,
            y_values=y_out,
            I_values=I_out,
            v_empty_values=v_empty_total,
            v_min_values=v_min_total,
            v_max=v_max_total,
            duals=(omega_dual=omega_out, pi_dual=pi_out), 
            basis_statuses=basis_statuses_out # <--- NYT: Tilføjet til return statement
        )
    else
        # ==========================================
        # NEW: Print failure warning for Incumbent
        # ==========================================
        if !is_relaxed
            @warn "▶ Day $day | IP Incumbent Failed! Status: $jump_status"
        end

        return (
            status=local_status,
            obj=Inf,
            y_values=Dict{Int,Float64}(),
            I_values=Dict(),
            v_empty_values=Float64[],
            v_min_values=Float64[],
            duals=(omega_dual=Dict(), pi_dual=Dict()), 
            basis_statuses=Dict{Int, MOI.BasisStatusCode}() # <--- NYT: Tom dict ved fejl/IP
        )
    end
end