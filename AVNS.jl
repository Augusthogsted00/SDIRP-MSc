# ==============================================================================
# Adaptive Variable Neighborhood Search (AVNS) with Simulated Annealing (SA)
# This file handles the routing optimization by perturbing solutions (shaking),
# refining them (local search), and using SA to escape local optima.
# ==============================================================================

# Generates a quick, random baseline route to kick off the optimization process.
function init_solution(v_id::Int, s::ShiftSlot, params)
    vehicle = vehicle_dict[v_id]
    station_ids = vehicle.allowed_stations
    default_terminal = terminals.ID[1]

    route = nothing

    # Unbounded while loop: spins until a profitable/feasible route is found
    while true
        st_seq = Int[]

        # Always insert exactly two distinct stations
        s1 = rand(station_ids)
        s2 = rand(station_ids)
        while s1 == s2
            s2 = rand(station_ids)
        end
        push!(st_seq, s1, s2)

        nodes = [default_terminal; st_seq; default_terminal]

        # Utilizing your utility function
        drive_time = route_drive_time(nodes)

        route = Route(
            nodes, st_seq, drive_time, s.duration_min,
            0.0, 0.0, Dict{String,Float64}(),
            v_id, s.day, s.shift
        )

        build_q!(
            route, vehicle, stations_dict, product_dict, tank_lookup,
            terminal_ids, Times, time_index_map, shift_lookup; params=params
        )

        # Break the loop ONLY if the route is feasible (not returning Inf cost)
        if route.rc != Inf
            break
        end
    end

    return route
end

# Adjusts the probability of choosing specific shaking operators based on their recent success.
# Operators that find better solutions will be picked more frequently in the next segment.
function update_weights(am::AdaptiveManager)
    # 1. Calculate raw probabilities
    total_w = sum(am.weights)
    raw_p = am.weights ./ total_w

    # 2. Enforce the 10% floor for the plot history
    p_min = 0.10
    bounded_p = p_min .+ raw_p .* (1.0 - am.k_max * p_min)

    push!(am.history, bounded_p)

    # 3. In-place update of raw weights for the next segment
    for i in 1:am.k_max
        if am.usage[i] > 0
            am.weights[i] = am.weights[i] * (1 - am.η) + am.η * (am.scores[i] / am.usage[i])
        end
    end
    fill!(am.scores, 0.0)
    fill!(am.usage, 0)
end

# --- Adaptive Variable Neighborhood Search with Simulated Annealing ---
# Multithreaded wrapper that assigns separate optimization tasks for candidate routes.
function solve_subproblem(candidate_dict::Dict, pool_dict::Vector{Route},
    st_dict::Dict{Int,Station},
    v_dict::Dict{Int,Vehicle}, params, cg_iter::Int)

    R_discovered = Set{Route}()
    mutex = ReentrantLock()

    # Shared thread containers
    histories_to_plot = Dict{Int,Vector{Vector{Float64}}}()
    rc_plots_to_make = Dict{Int,Tuple{Vector{Float64},Vector{Int},Vector{Float64},Vector{Int},Vector{Float64},Vector{Int},Vector{Float64}}}()

    @threads for key in collect(keys(candidate_dict))
        shift_route_indices = candidate_dict[key]
        seed_route = pool_dict[argmin(idx -> pool_dict[idx].rc, shift_route_indices)]

        v_id = key[2]
        v_obj = v_dict[v_id]

        # Run the core AVNS algorithm on this specific route
        R_found, iter, history, rc_best, rc_eval_iters, rc_eval_vals, rc_shake_iters, rc_shake_vals, rc_acc_iters, rc_acc_vals = AVNS(seed_route, st_dict, v_obj, params)

        if !isempty(R_found)
            lock(mutex) do
                union!(R_discovered, R_found)
            end
        end

        # Capture histories safely via lock boundaries
        lock(mutex) do
            if !isempty(history)
                histories_to_plot[v_id] = history
            end
            rc_plots_to_make[v_id] = (rc_best, rc_eval_iters, rc_eval_vals, rc_shake_iters, rc_shake_vals, rc_acc_iters, rc_acc_vals)
        end
    end

    return collect(R_discovered)
end

# Utility function: Cleans up invalid terminal placements (e.g., duplicate terminals or empty runs)
function clean_route_ids!(ids::Vector{Int}, term_id::Int)
    # Fjern KUN back-to-back dubletter (f.eks. [10, 10] -> [10])
    clean_ids = Int[]
    for id in ids
        if isempty(clean_ids) || id != clean_ids[end]
            push!(clean_ids, id)
        end
    end

    # Fjern terminaler i start og slut (AVNS format)
    while !isempty(clean_ids) && clean_ids[1] == term_id
        popfirst!(clean_ids)
    end
    while !isempty(clean_ids) && clean_ids[end] == term_id
        pop!(clean_ids)
    end
    return clean_ids
end

# Utility function: Calculates total traversal time for a sequence of nodes
function route_drive_time(nodes::Vector{Int})
    total = 0.0

    for i in 1:(length(nodes)-1)
        total += get_time(nodes[i], nodes[i+1])
    end

    return total
end

# DIVERSIFICATION STEP: Randomly perturbs the route to escape local optima.
# The 'k' parameter determines which structural change to apply.
function shaking(x::Route, k::Int, v::Vehicle)
    x_new = deepcopy(x)
    term_id = terminals.ID[1]

    allowed = v.allowed_stations
    in_route = x_new.station_ids
    out_route = filter(id -> id != term_id && !(id in in_route), allowed)

    if k == 1 # Random Insertion: Drops a random unvisited station into a random spot
        if !isempty(out_route)
            rand_st = rand(out_route)
            nodes = [term_id; in_route; term_id]
            best_pos = rand(1:length(nodes)-1) # Purely random for shaking
            insert!(in_route, best_pos, rand_st)
        end

    elseif k == 2 # Random Removal: Deletes a random station from the current route
        if !isempty(in_route)
            deleteat!(in_route, rand(1:length(in_route)))
        end

    elseif k == 3 # Random Terminal Insertion: Forces a mid-route return to the depot
        if length(in_route) >= 2
            insert!(in_route, rand(2:length(in_route)), term_id)
        end
    end

    in_route = clean_route_ids!(in_route, term_id)

    # Rebuild the final mutated route
    x_new.station_ids = in_route
    x_new.nodes = [term_id; in_route; term_id]
    x_new.time = route_drive_time(x_new.nodes)

    return x_new
end

# INTENSIFICATION STEP: Variable Neighborhood Descent (VND).
# Iteratively applies local improvement operators to find the local optimum.
function local_search(x_prime::Route, l::Int, st_dict::Dict{Int,Station}, v::Vehicle, am::AdaptiveManager, params)
    x_test = deepcopy(x_prime)
    term_id = terminals.ID[1]

    # Helper: Determines how badly a station needs a delivery
    function get_station_urgency(st_id, t_curr)
        st_id == term_id && return 0.0
        st = st_dict[st_id]
        return sum(st.ω[(tk_id, t_curr)] for tk_id in st.id_tank)
    end

    # Helper: Fast evaluator for route modifications
    function q_algo(ids::Vector{Int}; ignore_cache=false)
        # --- Time Registration ---
        t_q_start = time()
        Threads.atomic_add!(q_algo_count, 1)

        clean_ids = Int[]
        for id in ids
            (isempty(clean_ids) || id != clean_ids[end]) && push!(clean_ids, id)
        end

        while !isempty(clean_ids) && clean_ids[1] == term_id
            popfirst!(clean_ids)
        end

        while !isempty(clean_ids) && clean_ids[end] == term_id
            pop!(clean_ids)
        end

        # --- Duplicate Checker ---
        # Prevent re-evaluating routes we've already calculated
        route_h = hash((x_test.vehicle_id, x_test.t, x_test.shift, Tuple(clean_ids)))

        if !ignore_cache
            if route_h in am.visited_solutions
                Threads.atomic_add!(q_time_total, time() - t_q_start)
                return Inf
            end
            push!(am.visited_solutions, route_h)
        end

        x_test.station_ids = clean_ids
        x_test.nodes = [term_id; clean_ids; term_id]
        x_test.time = route_drive_time(x_test.nodes)

        build_q!(x_test, v, st_dict, product_dict, tank_lookup,
            terminal_ids, Times, time_index_map, shift_lookup, ; params=params)

        ret_val = x_test.rc

        # --- Time Registration End ---
        Threads.atomic_add!(q_time_total, time() - t_q_start)
        return ret_val
    end

    best_ids = copy(x_test.station_ids)
    best_rc = q_algo(best_ids, ignore_cache=true)
    n = length(best_ids)


    if l == 1 && n >= 1 # Neighborhood 5: Best-Improvement Terminal Removal (Removes inefficient depot returns)
        term_indices = findall(==(term_id), best_ids)
        best_candidate_rc, best_candidate_ids = best_rc, best_ids
        for idx in term_indices
            test_ids = deleteat!(copy(best_ids), idx)
            test_rc = q_algo(test_ids)
            if test_rc < best_candidate_rc - 1e-4
                best_candidate_rc, best_candidate_ids = test_rc, test_ids
            end
        end
        if best_candidate_rc < best_rc - 1e-4
            best_rc, best_ids = best_candidate_rc, best_candidate_ids
            @goto end_ls
        end

    elseif l == 2 && n >= 1 # Geographic Removal (Max Detour)
        current_nodes = [term_id; best_ids; term_id]

        # Identify the node causing the largest detour
        idx = argmax(2:length(current_nodes)-1) do i
            get_time(current_nodes[i-1], current_nodes[i]) +
            get_time(current_nodes[i], current_nodes[i+1]) -
            get_time(current_nodes[i-1], current_nodes[i+1])
        end

        # Test the route without this node
        test_ids = copy(best_ids)
        deleteat!(test_ids, idx - 1) # -1 because current_nodes is offset by term_id

        if q_algo(test_ids) < best_rc - 1e-4
            best_rc, best_ids = x_test.rc, copy(x_test.station_ids)
            @goto end_ls
        end

    elseif l == 3 && n >= 1 # Neighborhood 4: Greedy Dual Removal (Drops the least urgent station)
        target_id = argmin(id -> get_station_urgency(id, x_test.t), best_ids)
        test_ids = filter(id -> id != target_id, best_ids)
        if q_algo(test_ids) < best_rc - 1e-4
            best_rc, best_ids = x_test.rc, copy(x_test.station_ids)
            @goto end_ls
        end

    elseif l == 4 && n >= 2 # Neighborhood 2: Or-Opt (Relocates a single station to a new position)
        for i in 1:n
            ids_temp = copy(best_ids)
            target = splice!(ids_temp, i)
            for p in 1:length(ids_temp)+1
                test_ids = copy(ids_temp)
                insert!(test_ids, p, target)
                if q_algo(test_ids) < best_rc - 1e-4
                    best_rc, best_ids = x_test.rc, copy(x_test.station_ids)
                    @goto end_ls
                end
            end
        end

    elseif l == 5 && n >= 2 # Neighborhood 1: 2-Opt (Reverses subsections to uncross paths)
        for i in 1:n-1, j in i+1:n
            test_ids = copy(best_ids)
            reverse!(test_ids, i, j)
            if q_algo(test_ids) < best_rc - 1e-4
                best_rc, best_ids = x_test.rc, copy(x_test.station_ids)
                @goto end_ls
            end
        end

    elseif l == 6 # Neighborhood 3: Greedy Dual Insertion (Adds the most urgent unvisited station)
        out_route = filter(id -> id != term_id && !(id in best_ids), v.allowed_stations)
        if !isempty(out_route)
            best_st = argmax(id -> get_station_urgency(id, x_test.t), out_route)
            for p in 1:n+1
                test_ids = copy(best_ids)
                insert!(test_ids, p, best_st)
                if q_algo(test_ids) < best_rc - 1e-4
                    best_rc, best_ids = x_test.rc, copy(x_test.station_ids)
                    @goto end_ls
                end
            end
        end
    end

    @label end_ls

    # Finalize the local search result
    x_test.station_ids = best_ids
    x_test.nodes = [term_id; best_ids; term_id]
    x_test.time = route_drive_time(x_test.nodes)

    # Final eval to lock in state & precise RC
    q_algo(best_ids, ignore_cache=true)

    return x_test
end

# Calculates the starting temperature for Simulated Annealing.
# It samples a few random moves to gauge the average "worsening" delta,
# ensuring the initial SA acceptance probability matches `target_p`.
function calculate_relative_temperature(seed_route::Route, v::Vehicle, st_dict::Dict{Int,Station}, params, am::AdaptiveManager; sample_size::Int=20, target_p::Float64=0.5)
    delta_sum = 0.0
    worse_moves = 0

    # We need a quick way to evaluate RC without mutating the seed route permanently
    function quick_eval_rc(test_route)
        clean_ids = clean_route_ids!(copy(test_route.station_ids), terminals.ID[1])
        test_route.station_ids = clean_ids
        test_route.nodes = [terminals.ID[1]; clean_ids; terminals.ID[1]]

        build_q!(test_route, v, st_dict, product_dict, tank_lookup, terminal_ids, Times, time_index_map, shift_lookup, params=params)
        return test_route.rc
    end

    # 1. Sanitize the baseline! If it's Inf (like an empty route), treat it as 0.0
    baseline_rc = isinf(seed_route.rc) ? 0.0 : seed_route.rc

    for _ in 1:sample_size
        k = rand(1:params.k_max)
        x_shake = shaking(seed_route, k, v)
        shaken_rc = quick_eval_rc(x_shake)

        # 2. Compare against our sanitized baseline
        Δ = shaken_rc - baseline_rc

        # 3. Only count it if it's a valid worsening move AND it didn't return Inf (time infeasible)
        if Δ > 1e-4 && !isinf(shaken_rc)
            delta_sum += Δ
            worse_moves += 1
        end
    end

    # 4. Safe fallback that guarantees a finite Float64
    if worse_moves == 0
        safe_rc = isinf(baseline_rc) ? 1000.0 : baseline_rc
        return max(100.0, abs(safe_rc) * 0.1) # Default to at least 50.0
    end

    delta_avg = delta_sum / worse_moves
    τ_0 = -delta_avg / log(target_p)

    return τ_0
end

# --- CORE ALGORITHM: AVNS Orchestrator ---
# Manages the Shaking -> Local Search -> SA Acceptance loop.
function AVNS(seed_route::Route, st_dict::Dict{Int,Station}, v::Vehicle, params)
    R_discovered = Set{Route}()
    discovered_hashes = Set{UInt64}()

    x_best = deepcopy(seed_route)

    build_q!(x_best, v, st_dict, product_dict, tank_lookup,
        terminal_ids, Times, time_index_map, shift_lookup; params=params)

    x = deepcopy(x_best)

    am = AdaptiveManager(params)

    # --- NEW: Convergence Tracking Containers ---
    rc_best_history = Float64[]
    rc_eval_iters = Int[]
    rc_eval_vals = Float64[]
    rc_shake_iters = Int[]
    rc_shake_vals = Float64[]
    rc_acc_iters = Int[]
    rc_acc_vals = Float64[]

    τ_curr = calculate_relative_temperature(seed_route, v, st_dict, params, am, sample_size=20, target_p=0.5)
    τ_min = τ_curr * params.τ_scale

    iter = 0
    iters_since_last_found = 0
    current_found_count = 0

    # Main Metaheuristic Loop
    while τ_curr > τ_min
        iter += 1
        raw_p = am.weights ./ sum(am.weights)
        p_min = 0.10
        p = p_min .+ raw_p .* (1.0 - am.k_max * p_min)

        k = rand(Categorical(p))
        am.usage[k] += 1

        # --- PHASE 1: Shaking (Diversification) ---
        x_prime = shaking(x, k, v)
        build_q!(x_prime, v, st_dict, product_dict, tank_lookup, terminal_ids, Times, time_index_map, shift_lookup; params=params)

        # Evaluate the shaken solution for visualization
        x_shake_eval = deepcopy(x_prime)
        build_q!(x_shake_eval, v, st_dict, product_dict, tank_lookup, terminal_ids, Times, time_index_map, shift_lookup; params=params)
        if !isinf(x_shake_eval.rc) && x_shake_eval.rc < 1e5
            push!(rc_shake_iters, iter)
            push!(rc_shake_vals, x_shake_eval.rc)
        end

        # --- PHASE 2: Intensification (Variable Neighborhood Descent) ---
        l = 1
        x_vnd_best = deepcopy(x_prime)

        while l <= params.l_max
            x_double_prime = local_search(x_vnd_best, l, st_dict, v, am, params)

            if !isinf(x_double_prime.rc) && x_double_prime.rc < 1e5
                push!(rc_eval_iters, iter)
                push!(rc_eval_vals, x_double_prime.rc)
            end

            if x_double_prime.rc - x_vnd_best.rc < -1e-4
                x_vnd_best = x_double_prime
                l = 1
            else
                l += 1
            end
        end

        # --- PHASE 3: Simulated Annealing Acceptance ---
        sol_hash = hash((x_vnd_best.vehicle_id, x_vnd_best.t, x_vnd_best.shift, Tuple(x_vnd_best.station_ids)))
        is_new = !(sol_hash in am.visited_solutions)

        if is_new
            push!(am.visited_solutions, sol_hash)
        end

        Δ = x_vnd_best.rc - x.rc
        accepted = false

        if Δ < -1e-4
            x = x_vnd_best
            accepted = true

            if x.rc < x_best.rc
                x_best = deepcopy(x)
                am.scores[k] += am.σ_1
            else
                am.scores[k] += am.σ_2
            end

        elseif Δ > 1e-4 && rand() < exp(-Δ / τ_curr)
            x = x_vnd_best
            accepted = true
            am.scores[k] += am.σ_3
        end

        # Log accepted iterations
        if accepted && !isinf(x.rc) && x.rc < 1e5
            push!(rc_acc_iters, iter)
            push!(rc_acc_vals, x.rc)
        end

        # --- PHASE 4: Route Collection ---
        if x.rc < -1e-4
            h_val = hash((x.vehicle_id, x.t, x.shift, Tuple(x.station_ids)))
            if !(h_val in discovered_hashes)
                push!(R_discovered, deepcopy(x))
                push!(discovered_hashes, h_val)
            end
        end

        # --- Stagnation Checks ---
        new_found_count = length(R_discovered)
        if new_found_count > current_found_count
            iters_since_last_found = 0
            current_found_count = new_found_count
        else
            iters_since_last_found += 1
        end

        if iters_since_last_found > params.sol_improve
            break
        end

        # --- PHASE 5: Epoch Updates ---
        if iter % am.segment_size == 0
            update_weights(am)
            #empty!(am.visited_solutions)
        end

        push!(rc_best_history, x_best.rc)

        τ_curr *= params.α
    end

    return R_discovered, iter, am.history, rc_best_history, rc_eval_iters, rc_eval_vals, rc_shake_iters, rc_shake_vals, rc_acc_iters, rc_acc_vals
end