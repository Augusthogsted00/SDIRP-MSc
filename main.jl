include("import.jl")
include("AVNS.jl")
include("quantity_heuristic_allocation.jl")
include("master.jl")
include("print.jl")
include("overfill_correction_heuristic.jl")
include("excel_logging.jl")

#Random.seed!(60)

Threads.atomic_xchg!(q_time_total, 0.0)
Threads.atomic_xchg!(q_algo_count, 0)

# --- IRP Initialization ---
params = (
    T_start=1,
    T_max=7,
    lookahead=0,
    rho_min=1000,
    rho_empty=5000,
    rho_max=1e-6,
    τ_scale=0.00064,
    sol_improve=188,
    α=0.979375,
    k_max=3,
    l_max=6,
    η=0.7625,
    σ_1=10.0,
    σ_2=5.0,
    σ_3=2.0,
    segment_size=27,
    diminishing_lambda=7.66,
    product_diminishing_lambda=7.03,
    min_drop=1000,
    print_q_debug=false,
    print_tank_metrics=false,
    CG_iter=100,
    n_purged=5
)



# Opdateret
function station_id_from_tank(tank_id::String)
    return parse(Int, split(tank_id, "-")[1])
end



function run_simulation(params, run_id=1)
    # --- Reset Global Counters ---
    Threads.atomic_xchg!(q_time_total, 0.0)
    Threads.atomic_xchg!(q_algo_count, 0)

    # --- Initialize State for this Run ---
    markov_base = Route[]
    pool_dict = Route[]

    TP = [(tk, pr) for s in stations_struct for (tk, pr) in zip(s.id_tank, s.product_types)]

    current_invs = Dict((s.id_tank[idx], s.product_types[idx]) => s.initial_stock[idx]
                        for s in stations_struct for idx in 1:length(s.id_tank))

    empty_stocks = Dict((s.id_tank[idx], s.product_types[idx]) => s.empty_stock[idx]
                        for s in stations_struct for idx in 1:length(s.id_tank))

    min_stocks = Dict((s.id_tank[idx], s.product_types[idx]) => s.min_stock[idx]
                      for s in stations_struct for idx in 1:length(s.id_tank))

    max_stocks = Dict((s.id_tank[idx], s.product_types[idx]) => s.max_stock[idx]
                      for s in stations_struct for idx in 1:length(s.id_tank))

    demands_hat = Dict((s.id_tank[idx], s.product_types[idx], t) => s.demands[idx, t]
                       for s in stations_struct for idx in 1:length(s.id_tank) for t in 1:size(s.demands, 2))

    realized_demand = Dict(
        key => val * (0.90 + 0.2 * rand())
        for (key, val) in demands_hat
    )

    total_horizon = params.T_max + params.lookahead
    R_t = Dict(t => Int[] for t in 1:total_horizon)
    R_tks = Dict{Tuple{Int,Int,Int},Vector{Int}}()
    candidate_dict = Dict{Tuple{Int,Int,Int},Vector{Int}}()
    initial_route_indices = Set{Int}()

    st_dict = build_station_dict(stations_struct)
    v_dict = build_vehicle_dict(vehicles_struct)

    all_results = Dict{Int,Any}()

    logs = init_excel_logs() # Add this line at the very beginning of the function

    total_horizon_objective = 0.0

    for day in params.T_start:params.T_max
        t_day_start = time()

        L_current = day:(day+params.lookahead)

        empty!(pool_dict)
        empty!(R_t)
        empty!(R_tks)

        for t in L_current
            R_t[t] = Int[]
        end
        for s in shift_slots_struct
            if s.day in L_current
                init_r = init_solution(s.vehicle_id, s, params)
                #println(init_r)
                push!(pool_dict, init_r)
                new_idx = length(pool_dict)
                push!(initial_route_indices, new_idx)
                key = (s.day, s.vehicle_id, s.shift)
                push!(get!(R_tks, key, Int[]), new_idx)
                push!(R_t[s.day], new_idx)
            end
        end

        GG = 0
        new_routes_found = true
        max_cg_iterations = params.CG_iter
        rmp_results = nothing

        # dict som holder styr på antal af idle iterationer en rute i poolen har haft. 
        route_idle_iters = Dict{Int,Int}(idx => 0 for idx in 1:length(pool_dict))
        pool = collect(1:length(pool_dict))

        # Uddødelige ruter: Det er disse ruter som er blevet brugt i vores incumbent!!!
        immortal_routes = Set{Int}()

        while new_routes_found && GG < max_cg_iterations
            t_iter_start = time()
            GG += 1


            # ==========================================
            # RMP SOLVE
            # ==========================================
            rmp_time = @elapsed rmp_results = master_problem(
                day, pool, current_invs, TP, demands_hat, empty_stocks,
                min_stocks, max_stocks, R_t, R_tks, params, true, pool_dict, Int[], Int[]
            )

            if rmp_results.status != :Optimal
                @warn "RMP Infeasible at day $day (Iteration $GG)"
                break
            end
            active_rmp_columns = count(val -> val > 1e-4, values(rmp_results.y_values))
            # --- Diagnostik: Hvor fraktionel er vores løsning? ---
            num_integer = 0
            num_fractional = 0
            num_degenerate = 0

            for idx in pool
                y_val = get(rmp_results.y_values, idx, 0.0)
                basis_status = get(rmp_results.basis_statuses, idx, MOI.NONBASIC)

                if y_val > 0.99
                    num_integer += 1
                elseif y_val > 1e-4
                    num_fractional += 1
                elseif basis_status == MOI.BASIC && y_val <= 1e-4
                    num_degenerate += 1
                end
            end

            println("LP Diagnose | Heltal (~1): $num_integer | Fraktionel: $num_fractional | Degenereret (0 i basis): $num_degenerate")
            println("RMP_obj (Iter $GG): ", round(rmp_results.obj, digits=2), " | Total Columns in RMP: ", length(pool), " | Active in Basis: $active_rmp_columns")
            # ==========================================
            # 2. Update Column Ages!
            # ==========================================
            # ==========================================
            # 2. Update Column Ages! (Robust mod degenerering)
            # ==========================================
            for idx in pool
                route = pool_dict[idx]

                # Tjekker om kolonnen er en del af basis-matricen i RMP'en.
                # MOI.BASIC betyder, at solveren aktivt bruger den til at definere dual-værdierne, 
                # uanset om dens aktuelle primalværdi er presset ned på 0 af degenerering.
                is_basic = get(rmp_results.basis_statuses, idx, MOI.NONBASIC) == MOI.BASIC

                # Vi tjekker om den er i basis, om den er tom (sikrer feasibilitet), 
                # eller om den er en uddødelig rute brugt i en tidligere integer-løsning. 
                if is_basic || isempty(route.station_ids) || (idx in immortal_routes)
                    route_idle_iters[idx] = 0
                else
                    route_idle_iters[idx] += 1
                end
            end

            # NU kører vi vores purging logic: så vi vil ikke have ruter som har været inaktive mere end 10 iterationer, eller kolonner som har været med i incumbent. 
            # ==========================================
            # IP INCUMBENT DISCOVERY (Every 5th Iteration)
            # ==========================================
            if GG % 5 == 0
                println("▶ Iteration $GG: Running IP for Incumbent Discovery...")
                ip_time = @elapsed ip_result = master_problem(
                    day, pool, current_invs, TP, demands_hat, empty_stocks,
                    min_stocks, max_stocks, R_t, R_tks, params,
                    false, pool_dict, Int[], Int[], 300
                )

                if ip_result.status == :Optimal || ip_result.status == :TimeLimit
                    new_immortals = 0
                    incumbent_routes = Route[]

                    for (r_idx, val) in ip_result.y_values
                        if val > 0.5
                            push!(incumbent_routes, pool_dict[r_idx])
                            if !(r_idx in immortal_routes)
                                push!(immortal_routes, r_idx)
                                route_idle_iters[r_idx] = 0
                                new_immortals += 1
                            end
                        end
                    end

                    # LOG THE INCUMBENT
                    log_incumbent!(
                        logs;
                        day=day,
                        iteration=GG,
                        incumbent_objective=ip_result.obj,
                        selected_routes_today=count(r -> r.t == day, incumbent_routes),
                        selected_routes_day_and_lookahead=length(incumbent_routes),
                        total_delivered=sum(sum(values(r.q)) for r in incumbent_routes; init=0.0),
                        total_v_empty=sum(ip_result.v_empty_values),
                        total_v_min=sum(ip_result.v_min_values),
                        total_v_max=sum(ip_result.v_max),
                        pool_size=length(pool),
                        columns_made_immortal=new_immortals,
                        total_immortal_columns=length(immortal_routes),
                        immortal_route_ids=join(["V$(r.vehicle_id)-D$(r.t)-S$(r.shift)" for r in incumbent_routes], ", "),
                        solve_time=ip_time
                    )

                    println("  -> Incumbent Found (Obj: $(round(ip_result.obj, digits=2))). Added $new_immortals new routes to immortals.")
                else
                    println("  -> IP Incumbent search failed or timed out with no solution.")
                end
            end

            # ==========================================
            # PURGE STALE COLUMNS (Age > params.n_purged)
            # ==========================================
            # This removes indices from 'pool' if their age is > params.n_purged.
            # Since immortal routes have their age reset to 0 above, they are protected.
            original_pool_size = length(pool)
            filter!(idx -> route_idle_iters[idx] <= params.n_purged, pool)

            if length(pool) < original_pool_size
                println("  -> Purged $(original_pool_size - length(pool)) stale columns. Active pool size: $(length(pool))")
            end



            # Extract duals
            for s in stations_struct
                empty!(s.ω)
                for (i, tank_id) in enumerate(s.id_tank)
                    tp_key = (tank_id, s.product_types[i])
                    for t in L_current
                        s.ω[(tank_id, t)] = rmp_results.duals.omega_dual[tp_key, t]
                    end
                end
            end

            for slot in shift_slots_struct
                if slot.day in L_current
                    key = (slot.day, slot.vehicle_id, slot.shift)
                    slot.π = rmp_results.duals.pi_dual[key]
                else
                    slot.π = 0.0
                end
            end

            # AVNS Subproblem
            empty!(candidate_dict)
            for (key, route_indices) in R_tks
                # 1. Try to find routes for this shift that the RMP likes (y > 0)
                active_routes = [idx for idx in route_indices if idx in pool && rmp_results.y_values[idx] > 1e-4]
                if !isempty(active_routes)
                    candidate_dict[key] = active_routes
                else
                    # 2. FALLBACK: Use the explicitly saved initial route indices
                    fallback_routes = [idx for idx in route_indices if idx in initial_route_indices]
                    if !isempty(fallback_routes)
                        candidate_dict[key] = fallback_routes
                    end
                end
            end

            new_columns = solve_subproblem(candidate_dict, pool_dict, st_dict, v_dict, params, GG)
            evals_this_iter = Threads.atomic_xchg!(q_algo_count, 0)
            println("▶ Iteration $GG | Q-Algo Evaluations: $evals_this_iter")

            # ==========================================
            # Route Addition & DIVE LOGIC
            # ==========================================
            cg_converged = isempty(new_columns) || all(r -> r.rc >= -1e-6, new_columns)
            columns_added_this_iter = 0

            if cg_converged
                println("▶ Iteration $GG | Columns Added: 0 (No negative reduced cost routes found)")
            else
                for r in new_columns
                    existing_idx = findfirst(isequal(r), pool_dict)
                    if existing_idx === nothing
                        push!(pool_dict, r)
                        new_idx = length(pool_dict)
                        push!(get!(R_tks, (r.t, r.vehicle_id, r.shift), Int[]), new_idx)
                        push!(R_t[r.t], new_idx)

                        route_idle_iters[new_idx] = 0
                        push!(pool, new_idx)
                        columns_added_this_iter += 1
                    else
                        route_idle_iters[existing_idx] = 0
                        if !(existing_idx in pool)
                            push!(pool, existing_idx)
                        end
                    end
                end
                println("▶ Iteration $GG | Columns Added: $columns_added_this_iter unique routes")
            end

            if cg_converged
                println("▶ Iteration $GG | CG Converged: No negative reduced cost routes found. Stopping CG.")
                new_routes_found = false
            end

            iter_time = time() - t_iter_start

            log_rmp_iteration!(
                logs,
                day,
                GG,
                rmp_results,
                pool,
                active_rmp_columns,
                columns_added_this_iter,
                evals_this_iter,
                original_pool_size,           # Columns before purge
                original_pool_size - length(pool), # Columns purged
                length(pool),                 # Columns after purge
                false,                        # incumbent_updated (adjust logic if tracking here)
                0,                            # columns_made_immortal (from the IP step)
                immortal_routes,
                iter_time
            )
        end



        # ==========================================
        # PRE-IP PURGE: Identify routes to fix to 0
        # ==========================================
        forbidden_routes = [idx for idx in pool if length(pool_dict[idx].station_ids) <= 0]

        println("▶ Pre-IP Phase | Fixing $(length(forbidden_routes)) short routes (<= 2 stations) to 0.")
        # ==========================================

        # Add `forbidden_routes` as a new argument to your master_problem call
        ip_final_time = @elapsed results = master_problem(
            day, pool, current_invs,
            TP, demands_hat, empty_stocks, min_stocks, max_stocks, R_t, R_tks,
            params, false, pool_dict, Int[], forbidden_routes, Inf
        )
        all_results[day] = results

        # opdateret
        if results.status == :Optimal || results.status == :TimeLimit

            # ==========================================================
            # EXECUTE ONLY TODAY'S ROUTES
            #
            # The IP is solved over the full lookahead horizon,
            # but only routes belonging to the current day are
            # physically executed in the rolling-horizon framework.
            #
            # Future routes are only planning decisions and may
            # change when the model is re-optimized tomorrow.
            # ==========================================================

            # List of physically executed routes today
            executed_routes = Route[]
            # 1. Grab all selected routes (both today and lookahead)
            selected_all_routes = [pool_dict[idx] for idx in pool if get(results.y_values, idx, 0.0) > 0.5]

            # 2. Extract ONLY today's routes for execution and record their ORIGINAL quantities
            original_route_q = Dict{Route,Float64}()

            for selected_route in selected_all_routes
                if selected_route.t == day
                    push!(executed_routes, selected_route)
                    push!(markov_base, selected_route)

                    # Save the total Q BEFORE the overfill fix
                    original_route_q[selected_route] = sum(values(selected_route.q))

                    println("  > Executing: Vehicle $(selected_route.vehicle_id) | Stations: $(selected_route.station_ids) | Time:$(round(selected_route.total_cost, digits=2)) | Day: $(selected_route.t) | Shift: $(selected_route.shift)")
                end
            end

            # Calculate original IP delivered per product (for inventory logging)
            original_ip_delivered = Dict(tp => 0.0 for tp in TP)
            for r in executed_routes
                for (tank_id, qty) in r.q
                    for tp in TP
                        if tp[1] == tank_id
                            original_ip_delivered[tp] += qty
                            break
                        end
                    end
                end
            end

            # 3. RUN THE OVERFILL FIX
            overfill_fix_result = fix_overfill_after_ip!(
                executed_routes, current_invs, TP, demands_hat, max_stocks, min_stocks,
                empty_stocks, params, day, st_dict, tank_lookup, terminal_ids, Times, time_index_map
            )
            total_horizon_objective += overfill_fix_result.revised_day_obj
            println("  -> True Day $day Cost (After Fix): $(round(overfill_fix_result.revised_day_obj, digits=2))")

            # 4. LOG THE SHIFTS & SEGMENTS (Now that r.q is fixed)
            for r in executed_routes
                log_ip_shift!(logs, r, original_route_q[r], tank_lookup, terminal_ids)
                log_route_segments!(logs, r, params, st_dict, v_dict, product_dict, tank_lookup, terminal_ids)
            end

            overfill_adjustments = Dict(
                tp => (
                    original_ip_delivered=original_ip_delivered[tp],
                    fixed_delivered=overfill_fix_result.delivered_hat_fixed[tp],
                    delivery_diff=original_ip_delivered[tp] - overfill_fix_result.delivered_hat_fixed[tp]
                ) for tp in TP
            )

            # ==========================================================
            # LOG LOOKAHEAD SHIFTS & INVENTORY
            # ==========================================================
            for r in selected_all_routes
                log_lookahead_ip_shift!(logs, day, r, terminal_ids)
            end

            for t in L_current
                for tp in TP
                    # Find routes planned to deliver to this tank on day t
                    planned_routes_for_tp = [r for r in selected_all_routes if r.t == t && haskey(r.q, tp[1])]

                    planned_delivered = sum(r.q[tp[1]] for r in planned_routes_for_tp; init=0.0)
                    planned_demand = demands_hat[(tp..., t)]

                    # Get projected inventory directly from the IP I_values
                    proj_start = (t == day) ? current_invs[tp] : get(results.I_values, (tp, t - 1), 0.0)
                    proj_end = get(results.I_values, (tp, t), 0.0)

                    proj_overfill = max(0.0, proj_end - max_stocks[tp])
                    proj_below_empty = max(0.0, empty_stocks[tp] - proj_end)
                    proj_below_min = max(0.0, min_stocks[tp] - proj_end)

                    r_names = ["V$(r.vehicle_id)-D$(r.t)-S$(r.shift)" for r in planned_routes_for_tp]
                    r_quants = [r.q[tp[1]] for r in planned_routes_for_tp]

                    log_lookahead_inventory!(
                        logs;
                        solve_day=day, inventory_day=t,
                        station_id=station_id_from_tank(tp[1]), tank_id=tp[1], product_id=tp[2],
                        empty_level=empty_stocks[tp], min_level=min_stocks[tp], max_level=max_stocks[tp],
                        projected_start=proj_start, projected_end=proj_end,
                        projected_overfill=proj_overfill, projected_below_empty=proj_below_empty,
                        projected_below_min=proj_below_min, planned_delivered=planned_delivered,
                        planned_demand=planned_demand, route_names=r_names, route_quantities=r_quants
                    )
                end
            end

            # ==========================================================
            # CALCULATE TOTAL DELIVERED VOLUME TODAY
            #
            # Inventory is updated from physically executed deliveries,
            # NOT directly from the optimizer inventory variables.
            #
            # This makes the system behave like an MDP where:
            #
            # State      = inventory levels
            # Action     = executed routes today
            # Transition = physical inventory update
            # ==========================================================

            # TP - Vector containing all: (tank_id, product_id) combinations in the system
            #
            # Example:
            # ("10243-1", 1030841)
            #
            # where:
            # tp[1] = tank_id
            # tp[2] = product_id

            # delivered_today:
            # Stores total delivered quantity today
            # for each (tank, product) combination
            delivered_today = Dict(tp => 0.0 for tp in TP)

            # Sum all deliveries from executed routes
            for r in executed_routes

                # r.q is a Dictionary storing: tank_id => delivered quantity
                #
                # Example:
                # "10243-1" => 3000.0
                for (tank_id, qty) in r.q

                    # Find matching tank/product entry in TP
                    for tp in TP

                        # tp[1]:
                        # Tank ID for this inventory state
                        if tp[1] == tank_id

                            # Add delivered quantity
                            delivered_today[tp] += qty

                            break
                        end
                    end
                end
            end


            # ==========================================================
            # INVENTORY STATE TRANSITION + SIMULATION LOGGING
            #
            # Physical inventory update: I_{t+1} = I_t + deliveries - realized demand
            #
            # demands_hat: Forecast demand used INSIDE optimization
            #
            # realized_demand: Actual environment demand used AFTER execution
            #
            # The optimization therefore solves a deterministic
            # planning problem, while the inventory state is
            # updated using realized environment demand.
            #
            # In addition to updating the inventory state,
            # a simulation log is stored for every:
            # ==========================================================
            actual_overfill_today = 0.0 # Keep this outside the loop for the global warning

            for tp in TP
                station_id = station_id_from_tank(tp[1])
                start_inventory = current_invs[tp]
                delivered = delivered_today[tp]
                forecast_demand = demands_hat[(tp..., day)]
                actual_demand = realized_demand[(tp..., day)]

                end_inventory = max(0.0, start_inventory + delivered - actual_demand)

                # PER TANK OVERFILL (This is what was missing!)
                tank_overfill = max(0.0, end_inventory - max_stocks[tp])
                actual_overfill_today += tank_overfill

                route_names = String[]
                route_quantities = Float64[]

                for r in executed_routes
                    if haskey(r.q, tp[1])
                        push!(route_names, "V$(r.vehicle_id)-D$(r.t)-S$(r.shift)")
                        push!(route_quantities, r.q[tp[1]])
                    end
                end

                # SAVE ROW TO INVENTORY LOG
                log_inventory!(
                    logs;
                    day=day,
                    station_id=station_id,
                    tank_id=tp[1],
                    product_id=tp[2],
                    empty_level=empty_stocks[tp],
                    min_level=min_stocks[tp],
                    max_level=max_stocks[tp],
                    start_inventory=start_inventory,
                    end_inventory=end_inventory,
                    overfill=tank_overfill, # NOW USING PER-TANK OVERFILL
                    below_empty_before_clamp=max(0.0, empty_stocks[tp] - end_inventory),
                    below_min_before_clamp=max(0.0, min_stocks[tp] - end_inventory),
                    original_ip_delivered=get(overfill_adjustments[tp], :original_ip_delivered, delivered),
                    fixed_delivered=get(overfill_adjustments[tp], :fixed_delivered, delivered),
                    delivery_diff=get(overfill_adjustments[tp], :delivery_diff, 0.0),
                    forecast_demand=forecast_demand,
                    actual_demand=actual_demand,
                    route_names_str=join(route_names, " | "),
                    route_quantities_str=join(round.(route_quantities, digits=2), " | ")
                )

                current_invs[tp] = end_inventory
            end

            selected_routes_total = count(idx -> get(results.y_values, idx, 0.0) > 0.5, pool)

            day_total_time = time() - t_day_start

            log_model_summary!(
                logs,
                day,
                results,
                executed_routes,
                selected_routes_total,
                delivered_today,
                pool,
                day_total_time
            )

            total_returned_today = actual_overfill_today

            if total_returned_today > 1e-4
                println()
                println(
                    "  [!] LOGISTICS WARNING: " *
                    "$(round(total_returned_today, digits=2)) Liters of product returned to terminal."
                )
            end

            if haskey(results, :v_max)
                total_returned_today = results.v_max[1]
                if total_returned_today > 1e-4
                    println("  [!] LOGISTICS WARNING: $(round(total_returned_today, digits=2)) Liters of product returned to terminal.")
                end
            end

            println("Objective for Day $day: $(round(results.obj, digits=5))")
        else
            @error "Day $day failed to find an integer solution."
            break
        end
    end

    output_file = export_excel_logs!(logs, params)

    return total_horizon_objective
end

function run_multiple_simulations(num_runs, base_params)
    for lookahead_val in 0:3
        # Update parameters with the current lookahead value
        current_params = merge(base_params, (lookahead=lookahead_val,))

        println("\n*****************************************************")
        println("  STARTING EXPERIMENTS FOR LOOKAHEAD = $lookahead_val")
        println("*****************************************************")

        for run in 1:num_runs
            println("\n=====================================================")
            println("  STARTING SIMULATION RUN $run / $num_runs (Lookahead $lookahead_val)")
            println("=====================================================")

            final_cost = run_simulation(current_params, run)

            println("=====================================================")
            println("  FINISHED RUN $run (Lookahead $lookahead_val) | Total Cost: $(round(final_cost, digits=2))")
            println("=====================================================\n")
        end
    end
end

# Kør systemet X antal gange pr. lookahead
antal_koersler = 10
run_multiple_simulations(antal_koersler, params)