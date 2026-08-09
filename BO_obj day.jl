include("import.jl")
include("AVNS.jl")
include("q_algo.jl")
include("Print.jl")
include("master.jl")
include("overfill_fix.jl") # Make sure to include this!

function BO_objective(
    τ_scale::Float64,
    sol_improve::Int,
    α::Float64,
    η::Float64,
    segment_size::Int,
    diminishing_lambda::Float64,
    product_diminishing_lambda::Float64,
    CG_iter::Int,
    n_purged::Int
)
    # 1. Reset Environment for deterministic BO evaluations
    Random.seed!(60)
    Threads.atomic_xchg!(q_time_total, 0.0)
    Threads.atomic_xchg!(q_algo_count, 0)

    # 2. Inject BO Parameters into the params tuple
    BO_params = (
        T_start=1,
        T_max=7,
        lookahead=3,
        rho_min=1000,
        rho_empty=5000,
        rho_max=1e-6,
        τ_scale=τ_scale,
        sol_improve=sol_improve,
        α=α,
        k_max=3,
        l_max=6,
        η=η,
        σ_1=10.0,
        σ_2=5.0,
        σ_3=2.0,
        segment_size=segment_size,
        diminishing_lambda=diminishing_lambda,
        product_diminishing_lambda=product_diminishing_lambda,
        min_drop=1000,
        print_q_debug=false,
        print_tank_metrics=false,
        CG_iter=CG_iter,
        n_purged=n_purged
    )

    # 3. Base Data Structures
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

    # Deterministic demand used for both planning and state transitions
    demands_hat = Dict((s.id_tank[idx], s.product_types[idx], t) => s.demands[idx, t]
                       for s in stations_struct for idx in 1:length(s.id_tank) for t in 1:size(s.demands, 2))

    total_horizon = BO_params.T_max + BO_params.lookahead
    R_t = Dict(t => Int[] for t in 1:total_horizon)
    R_tks = Dict{Tuple{Int,Int,Int},Vector{Int}}()
    candidate_dict = Dict{Tuple{Int,Int,Int},Vector{Int}}()
    initial_route_indices = Set{Int}()

    st_dict = build_station_dict(stations_struct)
    v_dict = build_vehicle_dict(vehicles_struct)

    # Metric to minimize
    total_objective = 0.0

    # 4. Rolling Horizon Loop
    for day in BO_params.T_start:BO_params.T_max
        L_current = day:(day+BO_params.lookahead)

        empty!(pool_dict)
        empty!(R_t)
        empty!(R_tks)

        for t in L_current
            R_t[t] = Int[]
        end

        for s in shift_slots_struct
            if s.day in L_current
                init_r = init_solution(s.vehicle_id, s, BO_params)
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
        max_cg_iterations = BO_params.CG_iter # Updated dynamically

        route_idle_iters = Dict{Int,Int}(idx => 0 for idx in 1:length(pool_dict))
        pool = collect(1:length(pool_dict))
        immortal_routes = Set{Int}()

        # Column Generation Loop
        while new_routes_found && GG < max_cg_iterations
            GG += 1

            rmp_results = master_problem(
                day, pool, current_invs, TP, demands_hat, empty_stocks,
                min_stocks, max_stocks, R_t, R_tks, BO_params, true, pool_dict, Int[], Int[]
            )

            if rmp_results.status != :Optimal
                return 1e9 # Return a severe penalty for BO if infeasible
            end

            for idx in pool
                route = pool_dict[idx]
                is_basic = get(rmp_results.basis_statuses, idx, MOI.NONBASIC) == MOI.BASIC
                if is_basic || isempty(route.station_ids) || (idx in immortal_routes)
                    route_idle_iters[idx] = 0
                else
                    route_idle_iters[idx] += 1
                end
            end

            if GG % 5 == 0
                ip_result = master_problem(
                    day, pool, current_invs, TP, demands_hat, empty_stocks,
                    min_stocks, max_stocks, R_t, R_tks, BO_params,
                    false, pool_dict, Int[], Int[], 60
                )

                if ip_result.status == :Optimal || ip_result.status == :TimeLimit
                    for (r_idx, val) in ip_result.y_values
                        if val > 0.5 && !(r_idx in immortal_routes)
                            push!(immortal_routes, r_idx)
                            route_idle_iters[r_idx] = 0
                        end
                    end
                end
            end

            # Updated dynamically based on BO_params
            filter!(idx -> route_idle_iters[idx] <= BO_params.n_purged, pool)

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

            empty!(candidate_dict)
            for (key, route_indices) in R_tks
                active_routes = [idx for idx in route_indices if idx in pool && rmp_results.y_values[idx] > 1e-4]
                if !isempty(active_routes)
                    candidate_dict[key] = active_routes
                else
                    fallback_routes = [idx for idx in route_indices if idx in initial_route_indices]
                    if !isempty(fallback_routes)
                        candidate_dict[key] = fallback_routes
                    end
                end
            end

            new_columns = solve_subproblem(candidate_dict, pool_dict, st_dict, v_dict, params, GG)

            cg_converged = isempty(new_columns) || all(r -> r.rc >= -1e-6, new_columns)

            if !cg_converged
                for r in new_columns
                    existing_idx = findfirst(isequal(r), pool_dict)
                    if existing_idx === nothing
                        push!(pool_dict, r)
                        new_idx = length(pool_dict)
                        push!(get!(R_tks, (r.t, r.vehicle_id, r.shift), Int[]), new_idx)
                        push!(R_t[r.t], new_idx)

                        route_idle_iters[new_idx] = 0
                        push!(pool, new_idx)
                    else
                        route_idle_iters[existing_idx] = 0
                        if !(existing_idx in pool)
                            push!(pool, existing_idx)
                        end
                    end
                end
            else
                new_routes_found = false
            end
        end

        # IP Execution Phase
        forbidden_routes = [idx for idx in pool if length(pool_dict[idx].station_ids) <= 0]

        results = master_problem(
            day, pool, current_invs,
            TP, demands_hat, empty_stocks, min_stocks, max_stocks, R_t, R_tks,
            BO_params, false, pool_dict, Int[], forbidden_routes, 60
        )

        if results.status == :Optimal || results.status == :TimeLimit
            executed_routes = Route[]

            for idx in pool
                if get(results.y_values, idx, 0.0) > 0.5
                    selected_route = pool_dict[idx]
                    if selected_route.t == day
                        push!(executed_routes, selected_route)
                    end
                end
            end

            # ==========================================
            # APPLY OVERFILL FIX & CALCULATE TRUE COST
            # ==========================================
            overfill_fix_result = fix_overfill_after_ip!(
                executed_routes,
                current_invs,
                TP,
                demands_hat,
                max_stocks,
                min_stocks,
                empty_stocks,
                BO_params,
                day,
                st_dict,
                tank_lookup,
                terminal_ids,
                Times,
                time_index_map
            )
            
            # Accumulate the true, corrected cost for this day
            total_objective += overfill_fix_result.revised_day_obj
            # ==========================================
            # TILFØJ DETTE PRINT:
            println("    ✓ Dag $day fuldført! Sand omkostning (efter fix): $(round(overfill_fix_result.revised_day_obj, digits=2))")
            # Update Physical Inventory based on the FIXED deliveries and estimated demand
            for tp in TP
                start_inventory = current_invs[tp]
                
                # Use the fixed delivery volume, not the optimistic IP volume
                delivered = overfill_fix_result.delivered_hat_fixed[tp]
                
                # Realized demand equals forecast in BO environment
                actual_demand = demands_hat[(tp..., day)]

                end_inventory = max(
                    0.0,
                    start_inventory + delivered - actual_demand
                )
                current_invs[tp] = end_inventory
            end
        else
            return 1e9 # Return severe penalty if integer solution fails
        end
    end

    return total_objective
end