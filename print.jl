# ============================================================
# PRINTFUNKTIONER
# ============================================================

# ------------------------------------------------------------
# Hjælpefunktioner til mere sigende print
# ------------------------------------------------------------

# Beregn total vægt af q-løsningen
function total_loaded_weight(
    q::Dict{String,Float64},
    tank_lookup::Dict{String,Tuple{Int,Int}},
    stations_dict::Dict{Int,Station},
    product_dict::Dict{Int,Product}
)
    total_weight = 0.0

    for (tank_id, qty) in q
        sid, k = tank_lookup[tank_id]
        p = stations_dict[sid].product_types[k]
        total_weight += qty * product_density(p, product_dict)
    end

    return total_weight
end

# Find antal tanke med faktisk levering
function delivered_tank_count(q::Dict{String,Float64})
    return count(v -> v > 1e-6, values(q))
end

# Find antal stationer med faktisk levering
function delivered_station_count(station_volume::Dict{Int,Float64})
    return count(v -> v > 1e-6, values(station_volume))
end

# PASS / FAIL formattering
status_icon(ok::Bool) = ok ? "PASS" : "FAIL"

# Kort forklaring hvis ruten er infeasible
function infeasibility_reason(result, route::Route)
    if result.time_feasible
        return "None"
    end

    excess = result.total_time - route.shift_length
    return "Time limit exceeded by $(round(excess, digits=2)) min"
end

# Saml simple checks i én pakke
function build_route_checks(
    result,
    route::Route,
    vehicle::Vehicle,
    tank_lookup::Dict{String,Tuple{Int,Int}},
    stations_dict::Dict{Int,Station},
    product_dict::Dict{Int,Product};
    tol = 1e-6
)
    total_weight = total_loaded_weight(
        result.q,
        tank_lookup,
        stations_dict,
        product_dict
    )

    if hasproperty(result, :segment_results) && !isempty(result.segment_results)
        volume_ok = all(seg.total_loaded_volume <= vehicle.cap + tol for seg in result.segment_results)

        weight_ok = all(
            total_loaded_weight(seg.q, tank_lookup, stations_dict, product_dict) <= vehicle.weight + tol
            for seg in result.segment_results
        )
    else
        volume_ok = result.total_loaded_volume <= vehicle.cap + tol
        weight_ok = total_weight <= vehicle.weight + tol
    end

    time_ok = result.total_time <= route.shift_length + tol
    rc_ok   = result.time_feasible ? isfinite(result.reduced_cost) : !isfinite(result.reduced_cost)

    return (
        total_weight = total_weight,
        volume_ok = volume_ok,
        weight_ok = weight_ok,
        time_ok = time_ok,
        rc_ok = rc_ok
    )
end



# ------------------------------------------------------------
# Bygger hele route-outputtet som én samlet tekststreng
# ------------------------------------------------------------
function route_candidate_string(
    result,
    route::Route,
    vehicle_dict::Dict{Int,Vehicle},
    stations_dict::Dict{Int,Station},
    product_dict::Dict{Int,Product},
    tank_lookup::Dict{String,Tuple{Int,Int}}
)
    io = IOBuffer()

    vehicle = vehicle_dict[route.vehicle_id]

    checks = build_route_checks(
        result,
        route,
        vehicle,
        tank_lookup,
        stations_dict,
        product_dict
    )

    total_weight = checks.total_weight
    time_util   = route.shift_length > 1e-6 ? result.total_time / route.shift_length : 0.0

    println(io, "================ ROUTE CANDIDATE ================")
    println(io, "Vehicle              : ", route.vehicle_id, " (", vehicle.type, ")")
    println(io, "Day                  : ", route.t)
    println(io, "Shift                : ", route.shift)
    println(io, "Nodes                : ", route.nodes)
    println(io, "Stations             : ", route.station_ids)
    println(io, "Driving time         : ", round(route.time, digits = 2), " min")
    println(io, "Shift length         : ", round(route.shift_length, digits = 2), " min")
    println(io, "Time feasible        : ", result.time_feasible)
    println(io, "Infeasibility reason : ", infeasibility_reason(result, route))

    println(io, "\n---------------- EXECUTIVE SUMMARY ----------------")
    println(io, "Delivered stations   : ", delivered_station_count(result.station_volume), " / ", length(route.station_ids))
    println(io, "Delivered tanks      : ", delivered_tank_count(result.q), " / ", length(keys(result.q)))
    println(io, "Total delivered vol. : ", round(result.total_loaded_volume, digits = 2), " L")
    println(io, "Total delivered wt.  : ", round(total_weight, digits = 2), " kg")
    println(io, "Total time           : ", round(result.total_time, digits = 2), " min / ",
            round(route.shift_length, digits = 2), " min  (util = ", round(100 * time_util, digits = 1), "%)")
    println(io, "Inventory dual value : ", round(result.inventory_dual_value, digits = 2))
    println(io, "Pi value             : ", round(result.pi_value, digits = 2))
    println(io, "Dual value           : ", round(result.dual_value, digits = 2))
    println(io, "Reduced cost         : ", isfinite(result.reduced_cost) ? string(round(result.reduced_cost, digits = 2)) : "Inf")

    println(io, "\n---------------- CONSISTENCY CHECKS ----------------")
    println(io, "[", status_icon(checks.volume_ok), "] Volume within vehicle capacity")
    println(io, "[", status_icon(checks.weight_ok), "] Weight within vehicle capacity")
    println(io, "[", status_icon(checks.time_ok), "] Total time within shift length")
    println(io, "[", status_icon(checks.rc_ok), "] Reduced cost consistent with feasibility")

    println(io, "\n---------------- SEGMENT DETAILS ----------------")
    if hasproperty(result, :segment_results) && !isempty(result.segment_results)

        for seg in result.segment_results
            seg_weight = total_loaded_weight(seg.q, tank_lookup, stations_dict, product_dict)

            # Loaded volume = faktisk loadet volumen, dvs. endelig q
            seg_loaded_volume = sum(values(seg.q))
            seg_loaded_util = vehicle.cap > 1e-6 ? seg_loaded_volume / vehicle.cap : 0.0

            seg_weight_util = vehicle.weight > 1e-6 ? seg_weight / vehicle.weight : 0.0

            seg_total_time = seg.driving_time + seg.terminal_time + seg.delivery_time
            seg_total_share = result.total_time > 1e-6 ? seg_total_time / result.total_time : 0.0

            println(io, "\nSegment ", seg.segment_index)
            println(io, "Nodes                : ", seg.nodes)
            println(io, "Stations             : ", seg.station_ids)
            println(io, "Loaded volume        : ", round(seg_loaded_volume, digits = 2), " L / ",
                    round(vehicle.cap, digits = 2), " L  (util = ", round(100 * seg_loaded_util, digits = 1), "%)")
            println(io, "Loaded weight        : ", round(seg_weight, digits = 2), " kg / ",
                    round(vehicle.weight, digits = 2), " kg  (util = ", round(100 * seg_weight_util, digits = 1), "%)")
            println(io, "Terminal time        : ", round(seg.terminal_time, digits = 2), " min")
            println(io, "Delivery time        : ", round(seg.delivery_time, digits = 2), " min")
            println(io, "Driving time         : ",  round(seg.driving_time, digits = 2), " min (",round(100 * seg_total_share, digits = 1),
                "% of total route time)")
            println(io, "Inventory dual value : ", round(seg.inventory_dual_value, digits = 2))

            println(io, "\n  INITIAL TANK PRIORITY")
            println(io, "  Sorted once by base score before allocation")
            println(io, "  ---------------------------------------------------")

            ordered_metric_tanks = sort(
                collect(keys(seg.score)),
                by = tk -> seg.score[tk],
                rev = true
            )

            for (rank, tk) in enumerate(ordered_metric_tanks)
                sid, _ = tank_lookup[tk]
                prod_id = seg.product_map[tk]
                prod_name = product_dict[prod_id].name

                ω_val = get(stations_dict[sid].ω, (tk, route.t), 0.0)

                println(io,
                    "  Rank ", rank,
                    " | Station=", sid,
                    " | Tank=", tk,
                    " | Product=", prod_name,
                    " | Stock=", round(seg.projected_stock[tk], digits = 1),
                    " | Headroom=", round(seg.headroom[tk], digits = 1),
                    #" | Urgency=", round(seg.urgency[tk], digits = 4),
                    " | ω=", round(ω_val, digits = 2),
                    " | Base score=", round(seg.score[tk], digits = 4)
                )
            end
            
            if result.config.print_q_debug
                println(io, "\n  TOP-UP ITERATIONS")
                println(io, "  Dynamic ranking after each top-up decision")
                println(io, "  ---------------------------------------------------")

                if !hasproperty(seg, :topup_iterations) || isempty(seg.topup_iterations)
                    println(io, "  No top-up iterations.")
                else
                    last_product = nothing

                    for it in seg.topup_iterations
                        pname = product_dict[it.product].name

                        if last_product !== it.product
                            println(io, "\n  ===================================================")
                            println(io, "  START PRODUCT TOP-UPS: ", pname)
                            println(io, "  ===================================================")
                            last_product = it.product
                        end

                        println(io, "\n  Top-up iteration=", it.iteration,
                            " | Product=", pname,
                            " | Remaining before=", round(it.remaining_before, digits = 2), " L"
                        )

                        for (rank, row) in enumerate(it.ranking)
                            println(io,
                                "    Rank ", rank,
                                " | Tank=", row.tank_id,
                                " | delivered before=", round(row.delivered_before, digits = 2), " L",
                                " | headroom=", round(row.headroom, digits = 2), " L",
                                " | fill=", round(100 * row.fill_ratio, digits = 1), "%",
                                " | base=", round(row.base_score, digits = 4),
                                " | effective=", round(row.effective_score, digits = 6)
                            )
                        end

                        if it.no_active_tanks
                            println(io,
                                "    -> STOP: no active tanks left for product ",
                                pname,
                                " | remaining stranded=", round(it.remaining_before, digits = 2), " L"
                            )
                        else
                            println(io,
                                "    -> chosen=", it.chosen_tank,
                                " | added=", round(it.added_volume, digits = 2), " L",
                                " | delivered after=", round(it.delivered_after, digits = 2), " L",
                                " | remaining after=", round(it.remaining_after, digits = 2), " L"
                            )

                            if it.tank_full
                                println(io,
                                    "    OBS!!! -> Tank ", it.chosen_tank,
                                    " is full and removed from later iterations"
                                )
                            end

                            if it.product_empty
                                println(io,
                                    "    OBS!!! -> Product ", pname,
                                    " exhausted on vehicle"
                                )
                            end
                        end
                    end
                end
            end
            
            println(io, "\n  COMPARTMENTS")
            if isempty(seg.compartment_product)
                println(io, "  No compartments assigned.")
            else
                for cidx in sort(collect(keys(seg.compartment_product)))
                    prod = seg.compartment_product[cidx]
                    pname = product_dict[prod].name
                    load = get(seg.compartment_load, cidx, 0.0)

                    fill_pct = vehicle.comp_caps[cidx] > 1e-6 ? 100 * load / vehicle.comp_caps[cidx] : 0.0

                    println(io,
                        "  Compartment ", cidx,
                        " | Capacity=", round(vehicle.comp_caps[cidx], digits = 2), " L",
                        " | Product=", pname,
                        " | Filled=", round(load, digits = 2), " L",
                        " | Fill%=", round(fill_pct, digits = 1)
                    )
                end
            end

            println(io, "\n  PRODUCT LOAD")
            if isempty(seg.product_load)
                println(io, "  No product load assigned.")
            else
                for p in sort(collect(keys(seg.product_load)))
                    pname = product_dict[p].name
                    println(io,
                        "  Product ", pname,
                        " - candidate product load = ",
                        round(seg.product_load[p], digits = 2),
                        " L"
                    )
                end
            end


            println(io, "\n  TANK DELIVERIES")
            if isempty(seg.q)
                println(io, "  No tank deliveries.")
            else
                ordered_tanks = sort(
                    collect(keys(seg.q)),
                    by = tk -> get(seg.score, tk, 0.0),
                    rev = true
                )

                for tk in ordered_tanks
                    qty = seg.q[tk]

                    sid, k = tank_lookup[tk]
                    station = stations_dict[sid]

                    prod_id   = get(seg.product_map, tk, -1)
                    prod_name = prod_id != -1 ? product_dict[prod_id].name : "Unknown"
                    ps        = get(seg.projected_stock, tk, 0.0)
                    headroom = get(seg.headroom, tk, 0.0)
                    #urgency = get(seg.urgency, tk, 0.0)
                    score    = get(seg.score, tk, 0.0)
                    fill_pct = headroom > 1e-6 ? 100 * qty / headroom : 0.0
                    ending   = ps + qty

                    println(io,
                        "  Tank ", tk,
                        " | Product=", prod_name,
                        " | Projected stock=", round(ps, digits = 2),
                        " | Headroom=", round(headroom, digits = 2),
                        #" | Urgency=", round(urgency, digits = 4),
                        " | Score=", round(score, digits = 4),
                        " | q=", round(qty, digits = 2), " L",
                        " | Fill of headroom=", round(fill_pct, digits = 1), "%",
                        " | Stock after delivery=", round(ending, digits = 2)
                    )
                end
            end
        end

    else
        println(io, "No segment details available.")
    end

    println(io, "\n---------------- STATION VOLUMES ----------------")
    if isempty(result.station_volume)
        println(io, "No station deliveries.")
    else
        for sid in sort(collect(keys(result.station_volume)))
            println(io,
                "Station ", sid,
                " - delivered = ",
                round(result.station_volume[sid], digits = 2),
                " L"
            )
        end
    end

    println(io, "\n---------------- TANK DELIVERIES ----------------")
    if isempty(result.q)
        println(io, "No tank deliveries.")
    else
        has_detail_metrics =
            hasproperty(result, :score) &&
            hasproperty(result, :product_map) &&
            hasproperty(result, :projected_stock) &&
            hasproperty(result, :headroom)
            #hasproperty(result, :urgency)

        if has_detail_metrics
            ordered_tanks = sort(
                collect(keys(result.q)),
                by = tk -> get(result.score, tk, 0.0),
                rev = true
            )
        else
            ordered_tanks = sort(collect(keys(result.q)))
        end

        for tk in ordered_tanks
            qty = result.q[tk]

            sid, k = tank_lookup[tk]
            station = stations_dict[sid]

            if has_detail_metrics
                prod_id   = get(result.product_map, tk, -1)
                prod_name = prod_id != -1 ? product_dict[prod_id].name : "Unknown"
                ps        = get(result.projected_stock, tk, 0.0)
                #urgency   = get(result.urgency, tk, 0.0)
                score     = get(result.score, tk, 0.0)
                headroom  = get(result.headroom, tk, 0.0)
                fill_pct = headroom > 1e-6 ? 100 * qty / headroom : 0.0
                ending   = ps + qty

                println(io,
                    "Tank ", tk,
                    " | Product=", prod_name,
                    " | Projected stock=", round(ps, digits = 2),
                    " | Headroom=", round(headroom, digits = 2),
                    #" | Urgency=", round(urgency, digits = 4),
                    " | Score=", round(score, digits = 4),
                    " | q=", round(qty, digits = 2), " L",
                    " | Fill of headroom=", round(fill_pct, digits = 1), "%",
                    " | Stock after delivery=", round(ending, digits = 2)
                )
            else
                p = station.product_types[k]
                pname = product_dict[p].name

                println(io,
                    "Tank ", tk,
                    " | Product=", pname,
                    " | q=", round(qty, digits = 2), " L"
                )
            end
        end
    end

    println(io, "\n---------------- TIME BREAKDOWN ----------------")
    println(io, "Driving time         : ", round(route.time, digits = 2), " min")
    println(io, "Terminal time        : ", round(result.terminal_time, digits = 2), " min")
    println(io, "Delivery time        : ", round(result.delivery_time, digits = 2), " min")
    println(io, "Total time           : ", round(result.total_time, digits = 2), " min")

    println(io, "\n---------------- INTERPRETATION ----------------")
    if result.time_feasible
        if result.reduced_cost < -1e-6
            println(io, "Route is feasible and attractive (negative reduced cost).")
        elseif abs(result.reduced_cost) <= 1e-6
            println(io, "Route is feasible and approximately break-even.")
        else
            println(io, "Route is feasible but not attractive at current dual values.")
        end
    else
        println(io, "Route is infeasible because service + loading + driving exceed the shift length.")
    end

    println(io, "=================================================")

    return String(take!(io))
end

# Escape HTML så specialtegn ikke ødelægger visningen
function html_escape(s::String)
    s = replace(s, "&" => "&amp;")
    s = replace(s, "<" => "&lt;")
    s = replace(s, ">" => "&gt;")
    return s
end

# Vis route-output i en scrollable boks i notebooken
function show_route_candidate_scrollable(
    result,
    route::Route,
    vehicle_dict::Dict{Int,Vehicle},
    stations_dict::Dict{Int,Station},
    product_dict::Dict{Int,Product},
    tank_lookup::Dict{String,Tuple{Int,Int}};
    height="500px"
)
    txt = html_escape(route_candidate_string(
        result,
        route,
        vehicle_dict,
        stations_dict,
        product_dict,
        tank_lookup
    ))

    try
        display("text/html", """
        <div style="
            max-height:$height;
            overflow-y:auto;
            overflow-x:auto;
            border:1px solid #ccc;
            padding:10px;
            font-family:monospace;
            white-space:pre;
            background-color:#ffffff;
            color:#000000;
        ">$txt</div>
        """)
    catch
        println(route_candidate_string(
            result,
            route,
            vehicle_dict,
            stations_dict,
            product_dict,
            tank_lookup
        ))
    end
end

# Almindelig print-version til hurtig debug
function print_route_candidate(
    result,
    route::Route,
    vehicle_dict::Dict{Int,Vehicle},
    stations_dict::Dict{Int,Station},
    product_dict::Dict{Int,Product},
    tank_lookup::Dict{String,Tuple{Int,Int}}
)
    println(route_candidate_string(
        result,
        route,
        vehicle_dict,
        stations_dict,
        product_dict,
        tank_lookup
    ))
end

# Bygger RAW Q som tekst
function raw_q_string(result)
    io = IOBuffer()

    println(io, "================ RAW Q ================")

    if isempty(result.q)
        println(io, "No q values.")
    else
        for (tk, val) in sort(collect(result.q))
            println(io, "Tank ", tk, " - ", round(val, digits = 2))
        end
    end

    println(io, "======================================")

    return String(take!(io))
end

# Vis RAW Q i en scrollable boks
function show_raw_q_scrollable(result; height="250px")
    txt = html_escape(raw_q_string(result))

    try
        display("text/html", """
        <div style="
            max-height:$height;
            overflow-y:auto;
            overflow-x:auto;
            border:1px solid #ccc;
            padding:10px;
            font-family:monospace;
            white-space:pre;
            background-color:#ffffff;
            color:#000000;
        ">$txt</div>
        """)
    catch
        println(raw_q_string(result))
    end
end

# ------------------------------------------------------------
# Test-opsummering
# ------------------------------------------------------------
function summarize_test_case(
    label::String,
    result,
    route::Route,
    vehicle::Vehicle,
    stations_dict::Dict{Int,Station},
    product_dict::Dict{Int,Product},
    tank_lookup::Dict{String,Tuple{Int,Int}}
)
    println("\n===================================================")
    println("TEST CASE: ", label)
    println("===================================================")

    checks = build_route_checks(
        result,
        route,
        vehicle,
        tank_lookup,
        stations_dict,
        product_dict
    )

    println("Result summary:")
    println("  Day                : ", route.t)
    println("  Shift              : ", route.shift)
    println("  Time feasible      : ", result.time_feasible)
    println("  Total time         : ", round(result.total_time, digits=2), " / ", round(route.shift_length, digits=2), " min")
    println("  Total volume       : ", round(result.total_loaded_volume, digits=2), " / ", round(vehicle.cap, digits=2), " L")
    println("  Total weight       : ", round(checks.total_weight, digits=2), " / ", round(vehicle.weight, digits=2), " kg")
    println("  Reduced cost       : ", hasproperty(result, :reduced_cost) ? (isfinite(result.reduced_cost) ? round(result.reduced_cost, digits=2) : Inf) : "N/A")
    println("  Inventory dual     : ", round(result.inventory_dual_value, digits=2))
    println("  Pi value           : ", hasproperty(result, :pi_value) ? round(result.pi_value, digits=2) : "N/A")
    println("  Dual value         : ", hasproperty(result, :dual_value) ? round(result.dual_value, digits=2) : "N/A")
    println("  Delivered tanks    : ", delivered_tank_count(result.q))
    println("  Delivered stations : ", delivered_station_count(result.station_volume))

    println("\nChecks:")
    println("  [", status_icon(checks.volume_ok), "] Volume capacity respected")
    println("  [", status_icon(checks.weight_ok), "] Weight capacity respected")
    println("  [", status_icon(checks.time_ok), "] Shift length respected")
    println("  [", status_icon(checks.rc_ok), "] Reduced cost consistent with feasibility")



    println("===================================================\n")
end

function print_route(route::Route)
    println("--------------------------------------------------")
    println("Stations      : ", route.station_ids)
    println("Drive time    : ", round(route.time, digits=1), " min")
    println("Shift length  : ", route.shift_length, " min")
    println("Total cost    : ", round(route.total_cost, digits=2))
    println("Reduced cost  : ", round(route.rc, digits=2))
    println("Vehicle       : ", route.vehicle_id)
    println("Day / Shift   : ", route.t, " / ", route.shift)

    println("Deliveries (q):")
    for (tank_id, qty) in sort(collect(route.q), by = x -> x[1])
        println("   ", tank_id, " => ", round(qty, digits=1))
    end
end


function print_avns_result(res; max_routes=5)
    println("\n================ AVNS RESULT ================\n")
    println("Vehicle      : ", res.vehicle_id)
    println("Day          : ", res.day)
    println("Shift        : ", res.shift)
    println("Iterations   : ", res.iterations)
    println("Best RC      : ", round(res.best_rc, digits=2))
    println("Saved routes : ", length(res.saved_routes))

    println("\n===== BEST ROUTE =====")
    if res.best_route === nothing
        println("No best route found")
    else
        print_route(res.best_route)
    end

    println("\n===== SAVED ROUTES (top $(min(max_routes, length(res.saved_routes)))) =====")
    for (i, r) in enumerate(res.saved_routes[1:min(end, max_routes)])
        println("\nRoute #", i)
        print_route(r)
    end
end