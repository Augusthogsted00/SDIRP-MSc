# ============================================================
# OverfillFix.jl
# ============================================================
function reduce_tank_deliveries_to_capacity(
    quantities::Vector{Float64},
    capacity::Float64,
    min_drop::Float64;
    tol::Float64=1e-6
)
    n = length(quantities)
    new_q = copy(quantities)

    total_q = sum(new_q)

    if total_q <= capacity + tol
        return new_q
    end

    if capacity <= tol
        fill!(new_q, 0.0)
        return new_q
    end

    # --------------------------------------------------------
    # Hvis alle aktive leveringer ikke kan være mindst min_drop,
    # beholdes kun så mange ruter som kapaciteten kan understøtte.
    # Resten sættes til 0.
    # --------------------------------------------------------
    max_active = floor(Int, capacity / min_drop)

    if max_active < n
        if max_active <= 0
            fill!(new_q, 0.0)
            return new_q
        end

        # Behold de største leveringer først.
        # Ved ens mængder beholdes de tidligste i input-listen.
        order = sortperm(1:n, by = i -> (-quantities[i], i))
        keep = Set(order[1:max_active])

        for i in 1:n
            if !(i in keep)
                new_q[i] = 0.0
            end
        end
    end

    # --------------------------------------------------------
    # Reducér de resterende aktive leveringer så lige som muligt,
    # men aldrig under min_drop.
    # --------------------------------------------------------
    active = [i for i in 1:n if new_q[i] > tol]
    target_total = min(capacity, sum(new_q))

    while sum(new_q) > target_total + tol && !isempty(active)
        excess = sum(new_q) - target_total
        reduction_each = excess / length(active)

        hit_min = Int[]

        for i in active
            reducible = max(0.0, new_q[i] - min_drop)
            reduction = min(reduction_each, reducible)
            new_q[i] -= reduction

            if new_q[i] <= min_drop + tol
                new_q[i] = min_drop
                push!(hit_min, i)
            end
        end

        if isempty(hit_min)
            break
        end

        active = [i for i in active if !(i in Set(hit_min))]

        # Hvis alle aktive har ramt min_drop, kan vi ikke reducere mere
        # uden at bryde min_drop-reglen.
        if isempty(active)
            break
        end
    end

    # Fjern leveringer under min_drop.
    # De må ikke blive fx 700 L.
    for i in 1:n
        if new_q[i] <= tol || new_q[i] < min_drop
            new_q[i] = 0.0
        end
    end

    return new_q
end


# ------------------------------------------------------------
# Genberegn cost for en IP-rute efter q er ændret.
# Ruten ændres ikke sekvensmæssigt ud over at stationer uden
# levering fjernes.
# ------------------------------------------------------------
function recompute_route_after_q_fix!(
    route::Route,
    tank_lookup::Dict{String,Tuple{Int,Int}},
    terminal_ids::Set{Int},
    times_mat::Matrix{Float64},
    time_index_map::Dict{<:AbstractString,<:Integer},
    params
)
    # Fjern 0-leveringer fra q
    route.q = Dict(tk => qty for (tk, qty) in route.q if qty > 1e-6)

    # Q-algo-format før vi arbejder:
    # nodes       = fuld rute inkl. terminaler
    # station_ids = kun rigtige stationer
    route.station_ids = segment_station_ids(route.nodes, terminal_ids)

    # Fjern stationer der ikke længere får levering
    route_is_nonempty = remove_undelivered_stations_from_route!(
        route,
        route.q,
        tank_lookup,
        terminal_ids,
        times_mat,
        time_index_map,
        params
    )

    if !route_is_nonempty
        route.total_cost = Inf
        restore_route_for_avns!(route, terminal_ids)
        return false
    end

    # ============================================================
    # Samme cost-logik som q_algo
    # ============================================================

    # 1) Drive time på den opdaterede rute
    route.time = compute_segment_drive_time(
        route.nodes,
        times_mat,
        time_index_map,
        terminal_ids
    )

    # 2) Terminal loading time og delivery time segment-for-segment
    terminal_time_total = 0.0
    delivery_time_total = 0.0

    segments = split_route_into_segments(route, terminal_ids)

    for seg_nodes in segments
        seg_station_ids = segment_station_ids(seg_nodes, terminal_ids)
        isempty(seg_station_ids) && continue

        seg_station_set = Set(seg_station_ids)

        # q for dette segment
        seg_q = Dict{String,Float64}()

        for (tank_id, qty) in route.q
            sid, _ = tank_lookup[tank_id]

            if sid in seg_station_set && qty > 1e-6
                seg_q[tank_id] = qty
            end
        end

        # Samlet volume i segmentet
        total_volume = sum(values(seg_q))

        # Terminal loading time som i q_algo
        terminal_time =
            total_volume <= 1e-6 ? 0.0 :
            15.0 + total_volume / 1800.0

        terminal_time_total += terminal_time

        # Station delivery time som i q_algo
        station_volume = Dict{Int,Float64}()

        for (tank_id, qty) in seg_q
            sid, _ = tank_lookup[tank_id]
            station_volume[sid] = get(station_volume, sid, 0.0) + qty
        end

        for (_, vol) in station_volume
            if vol > 1e-6
                delivery_time_total += 10.0 + vol / 900.0
            end
        end
    end

    # 3) Total cost som i q_algo
    total_time = route.time + terminal_time_total + delivery_time_total
    
    println(
    "[OVERFILL DEBUG] ",
    "old_total_cost=", route.total_cost,
    ", new_drive=", route.time,
    ", terminal=", terminal_time_total,
    ", delivery=", delivery_time_total,
    ", new_total=", total_time,
    ", shift=", route.shift_length,
    ", q=", sum(values(route.q)),
    ", nodes=", route.nodes
)
    # 4) Feasibility som IP-rute
    if total_time <= route.shift_length + 1e-6 &&
       sum(values(route.q)) > 1e-6 &&
       !isempty(route.station_ids) &&
       isfinite(total_time)

        route.total_cost = total_time
        restore_route_for_avns!(route, terminal_ids)
        return true
    else
        route.total_cost = Inf
        restore_route_for_avns!(route, terminal_ids)
        return false
    end
end

# ------------------------------------------------------------
# Hovedfunktion:
# Fjerner overfill for alle eksekverede ruter på én dag.
# ------------------------------------------------------------
function fix_overfill_after_ip!(
    executed_routes::Vector{Route},
    current_invs::Dict,
    TP,
    demands_hat::Dict,
    max_stocks::Dict,
    min_stocks::Dict,
    empty_stocks::Dict,
    params,
    day::Int,
    stations_dict::Dict{Int,Station},
    tank_lookup::Dict{String,Tuple{Int,Int}},
    terminal_ids::Set{Int},
    times_mat::Matrix{Float64},
    time_index_map::Dict{<:AbstractString,<:Integer}
)
    min_drop = Float64(params.min_drop)

    # Gem gammel route cost til diagnose.
    old_route_cost = sum(r.total_cost for r in executed_routes if isfinite(r.total_cost))

    # --------------------------------------------------------
    # 1) Find alle ruteleveringer pr. tank.
    # --------------------------------------------------------
    tank_to_route_entries = Dict{String,Vector{Tuple{Int,Float64}}}()

    for (ridx, r) in enumerate(executed_routes)
        for (tank_id, qty) in r.q
            if qty > 1e-6
                if !haskey(tank_to_route_entries, tank_id)
                    tank_to_route_entries[tank_id] = Tuple{Int,Float64}[]
                end
                push!(tank_to_route_entries[tank_id], (ridx, qty))
            end
        end
    end

    total_removed = 0.0

    # --------------------------------------------------------
    # 2) For hver tank: beregn max tilladt levering ud fra
    #    demand_hat, dvs. før realized_demand bruges.
    #
    #    Forecast end inventory:
    #       I_end_hat = I_start + delivered - demand_hat
    #
    #    Derfor er max allowed delivery:
    #       max_stock - I_start + demand_hat
    # --------------------------------------------------------
    for tp in TP
        tank_id = tp[1]

        if !haskey(tank_to_route_entries, tank_id)
            continue
        end

        entries = tank_to_route_entries[tank_id]
        old_quantities = [qty for (_, qty) in entries]

        start_inventory = current_invs[tp]
        forecast_demand = demands_hat[(tp..., day)]
        max_stock = max_stocks[tp]

        allowed_delivery = max(0.0, max_stock - start_inventory + forecast_demand)

        old_total = sum(old_quantities)

        if old_total <= allowed_delivery + 1e-6
            continue
        end

        new_quantities = reduce_tank_deliveries_to_capacity(
            old_quantities,
            allowed_delivery,
            min_drop
        )

        for (j, (ridx, _)) in enumerate(entries)
            r = executed_routes[ridx]
            old_qty = get(r.q, tank_id, 0.0)
            new_qty = new_quantities[j]

            if new_qty <= 1e-6
                delete!(r.q, tank_id)
            else
                r.q[tank_id] = new_qty
            end

            total_removed += max(0.0, old_qty - new_qty)
        end
    end

    # --------------------------------------------------------
    # 3) Genberegn stationer, q og cost for hver IP-rute.
    # --------------------------------------------------------
    kept_routes = Route[]
    removed_empty_routes = 0

    for r in executed_routes
        ok = recompute_route_after_q_fix!(
            r,
            tank_lookup,
            terminal_ids,
            times_mat,
            time_index_map,
            params
        )

        if ok
            push!(kept_routes, r)
        elseif isempty(r.q) || sum(values(r.q)) <= 1e-6
            removed_empty_routes += 1
        else
            error(
                "Overfill fix made a non-empty IP route infeasible. " *
                "Vehicle=$(r.vehicle_id), Day=$(r.t), Shift=$(r.shift), " *
                "Total q=$(sum(values(r.q))), Nodes=$(r.nodes), " *
                "Cost=$(r.total_cost), Shift length=$(r.shift_length)"
            )
        end
    end

    empty!(executed_routes)
    append!(executed_routes, kept_routes)

    # --------------------------------------------------------
    # 4) Genberegn leveret volumen efter fix.
    # --------------------------------------------------------
    delivered_hat_fixed = Dict(tp => 0.0 for tp in TP)

    for r in executed_routes
        for (tank_id, qty) in r.q
            for tp in TP
                if tp[1] == tank_id
                    delivered_hat_fixed[tp] += qty
                    break
                end
            end
        end
    end

    # --------------------------------------------------------
    # 5) Genberegn dagsobjective på den fysiske plan efter fix.
    #    v_max bør nu være 0 bortset fra numerisk afrunding eller
    #    hvis min_drop-reglen gør perfekt kapacitetsudnyttelse umulig.
    # --------------------------------------------------------
    total_v_empty = 0.0
    total_v_min = 0.0
    total_v_max = 0.0

    for tp in TP
        forecast_end_inventory =
            current_invs[tp] + delivered_hat_fixed[tp] - demands_hat[(tp..., day)]

        total_v_empty += max(0.0, empty_stocks[tp] - forecast_end_inventory)
        total_v_min += max(0.0, min_stocks[tp] - forecast_end_inventory)
        total_v_max += max(0.0, forecast_end_inventory - max_stocks[tp])
    end

    new_route_cost = sum(r.total_cost for r in executed_routes if isfinite(r.total_cost))

    revised_day_obj =
        new_route_cost +
        params.rho_empty * total_v_empty +
        params.rho_min * total_v_min

    return (
        total_removed = total_removed,
        old_route_cost = old_route_cost,
        new_route_cost = new_route_cost,
        removed_empty_routes = removed_empty_routes,
        delivered_hat_fixed = delivered_hat_fixed,
        total_v_empty = total_v_empty,
        total_v_min = total_v_min,
        total_v_max = total_v_max,
        revised_day_obj = revised_day_obj
    )
end
