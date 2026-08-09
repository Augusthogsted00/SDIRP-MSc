# Udtræk station_id fra tank_id, fx "10443-1" -> 10443
function station_id_from_tank(tank_id::String)
    return parse(Int, split(tank_id, "-")[1])
end

# Læsbart route-ID
function route_vds(r::Route)

    # Format: V{vehicle}-D{day}-S{shift}
    return "V$(r.vehicle_id)-D$(r.t)-S$(r.shift)"
end

# Formatér tankleveringer som tekst
#Example: Dict("10443-1" => 3000.0, "10443-2" => 5000.0) # 
# Output: "10443-1:3000.0, 10443-2:5000.0"
function format_tank_deliveries(q::Dict{String,Float64})

    # Behold kun positive leveringer
    positive_q = [(tk, qty) for (tk, qty) in q if qty > 1e-6]

    # Sortér efter tank_id
    sort!(positive_q, by = x -> x[1])

    # Konvertér til tekst
    return join(
        ["$(tk):$(round(qty, digits=2))" for (tk, qty) in positive_q],
        ", "
    )
end

# Formatér alle leveringer til én tank
function format_route_deliveries_for_tank(routes::Vector{Route}, tank_id::String)

    # Route-ID'er
    route_names = String[]

    # Leverede mængder
    route_quantities = Float64[]

    # Find ruter der leverer til tanken
    for r in routes

        # Behold kun positive leveringer
        if haskey(r.q, tank_id) && r.q[tank_id] > 1e-6
            push!(route_names, route_vds(r))
            push!(route_quantities, r.q[tank_id])
        end
    end

    # Returnér route-ID'er og leveringer som tekst
    return (
        join(route_names, " | "),
        join(round.(route_quantities, digits=2), " | ")
    )
end


# Beregn route time-komponenter
function route_time_breakdown(r::Route, tank_lookup, terminal_ids)

    # Samlet leveret volume
    total_q = sum(values(r.q))

    # Terminal loading time
    load_time = total_q <= 1e-6 ? 0.0 : 15.0 + total_q / 1800.0

    # Levering samlet pr. station
    station_volume = station_delivered_volume(r, r.q, tank_lookup)

    # Station service time
    service_time = 0.0

    # Beregn unloading time pr. station
    for (_, vol) in station_volume

        # Kun stationer med levering
        if vol > 1e-6

            # Fast stop time + unloading time
            service_time += 10.0 + vol / 900.0
        end
    end

    # Pure driving time is already stored in the route.
    drive_time = r.time

    # Total operational time for the route.
    total_time = drive_time + load_time + service_time

    return drive_time, load_time, service_time, total_time
end


# Log segment-information for en rute
function log_route_segments!(
    logs,
    r::Route,
    params,
    st_dict,
    v_dict,
    product_dict,
    tank_lookup,
    terminal_ids
)

    # Split ruten i terminal-terminal segmenter
    segments = split_route_into_segments(r, terminal_ids)

    # Køretøjet der bruges på ruten
    vehicle = v_dict[r.vehicle_id]

    # Gennemgå hvert segment
    for (seg_no, seg_nodes) in enumerate(segments)

        # Stationer i segmentet
        seg_stations = segment_station_ids(seg_nodes, terminal_ids)

        # Spring tomme segmenter over
        isempty(seg_stations) && continue

        # Leveringer i segmentet
        seg_q = Dict{String,Float64}()

        # Find tankleveringer i segmentet
        for (tank_id, qty) in r.q

            # Ignorér 0-leveringer
            qty <= 1e-6 && continue

            # Station som tanken tilhører
            sid, _ = tank_lookup[tank_id]

            # Behold kun leveringer i dette segment
            if sid in seg_stations
                seg_q[tank_id] = qty
            end
        end

        # Samlet leveret volume i segmentet
        segment_q_total = sum(values(seg_q))

        # Midlertidig segment-rute til compartment logging
        seg_route = Route(
            copy(seg_nodes),
            copy(seg_stations),
            0.0,
            r.shift_length,
            0.0,
            0.0,
            Dict{String,Float64}(),
            r.vehicle_id,
            r.t,
            r.shift
        )

        # Genberegn compartment assignment til logging
        seg_result = build_q_for_segment!(
            seg_route,
            vehicle,
            st_dict,
            product_dict,
            tank_lookup;
            params = params,
            segment_index = seg_no
        )

        # Compartment entries som tekst
        comp_entries = String[]

        # Produkter loadet i segmentet
        loaded_products = Set{Int}()

        # Gennemgå compartment assignments
        for cidx in sort(collect(keys(seg_result.compartment_product)))

            # Produkt i compartment
            p = seg_result.compartment_product[cidx]

            # Volume i compartment
            load = get(seg_result.compartment_load, cidx, 0.0)

            # Gem loaded produkt
            push!(loaded_products, p)

            # Gem compartment-info som tekst
            push!(
                comp_entries,
                "C$(cidx):P$(p)($(round(load, digits=2)))"
            )
        end

        # Tilføj segment til log
        push!(logs.ip_route_segments, (
            r.t,
            r.vehicle_id,
            r.shift,
            route_vds(r),

            seg_no,
            join(seg_nodes, " -> "),
            join(seg_stations, " -> "),

            round(segment_q_total, digits=2),
            format_tank_deliveries(seg_q),
            join(sort(collect(loaded_products)), ", "),
            join(comp_entries, ", ")
        ))
    end
end



# Inventory log til Excel-output
inventory_log = DataFrame(
    Day=Int[],
    Station_ID=Int[],
    Tank_ID=String[],
    Product_ID=Int[],

    # Lagergrænser
    Empty_Level=Float64[],
    Min_Level=Float64[],
    Max_Level=Float64[],

    # Inventory før og efter dagens demand
    Start_Inventory=Float64[],
    End_Inventory=Float64[],

    # Violations før clamping til 0
    Overfill=Float64[],
    Below_Empty_Before_Clamp=Float64[],
    Below_Min_Before_Clamp=Float64[],

    # Levering før og efter overfill-fix
    Original_IP_Delivered=Float64[],
    Fixed_Delivered=Float64[],
    Delivery_Diff=Float64[],

    # Forecast og realiseret demand
    Demand_Hat=Float64[],
    Realized_Demand=Float64[],

    # Ruter der leverer til tanken
    Delivering_Routes=String[],
    Route_Deliveries=String[]
)

# Lookahead inventory-log fra RMP/IP-planen
lookahead_inventory_log = DataFrame(
    Solve_Day=Int[],
    Inventory_Day=Int[],
    Station_ID=Int[],
    Tank_ID=String[],
    Product_ID=Int[],

    # Lagergrænser
    Empty_Level=Float64[],
    Min_Level=Float64[],
    Max_Level=Float64[],

    # Forecast inventory i lookahead
    Projected_Start_Inventory=Float64[],
    Projected_End_Inventory=Float64[],

    # Forecast violations
    Projected_Overfill=Float64[],
    Projected_Below_Empty=Float64[],
    Projected_Below_Min=Float64[],

    # Planlagt levering og demand
    Planned_Delivered=Float64[],
    Planned_Demand=Float64[],

    # Ruter der planlægges at levere
    Delivering_Routes=String[],
    Route_Deliveries=String[]
)

# Dagligt model-summary for IP
model_summary_log = DataFrame(
    Day=Int[],
    Solve_Time=Float64[],

    # IP solve-status
    IP_Status=String[],

    # IP objective value
    IP_Objective=Float64[],

    # Valgte ruter på den aktuelle dag
    Selected_Routes_Today=Int[],

    # Valgte ruter inkl. lookahead
    Selected_Routes_day_and_lookahead=Int[],

    # Samlet leveret volume
    Total_Delivered=Float64[],

    # Inventory violations
    IP_Lookahead_Total_v_empty=Float64[],
    IP_Lookahead_Total_v_min=Float64[],
    IP_Lookahead_Total_v_max=Float64[],

    # Antal ruter i route pool
    Pool_Size=Int[]
)

# Log af hver RMP-iteration
rmp_iteration_log = DataFrame(
    Day=Int[],
    Iteration=Int[],
    Solve_Time=Float64[],

    # RMP solve-status og objective
    RMP_Status=String[],
    RMP_Objective=Float64[],

    # Column generation statistik
    Pool_Size=Int[],
    Active_RMP_Columns=Int[],
    Columns_Added=Int[],
    Q_Algo_Evaluations=Int[],

    # Column purge statistik
    Columns_Before_Purge=Int[],
    Columns_Purged=Int[],
    Columns_After_Purge=Int[],

    # Incumbent/immortal columns
    Incumbent_Updated=Bool[],
    Columns_Made_Immortal=Int[],
    Total_Immortal_Columns=Int[],

    # Inventory violations
    Total_v_empty=Float64[],
    Total_v_min=Float64[],
    Total_v_max=Float64[]
)

# Log af incumbent-løsninger
incumbent_log = DataFrame(
    Day=Int[],
    Iteration=Int[],
    Solve_Time=Float64[],

    # Incumbent objective
    Incumbent_Objective=Float64[],

    # Valgte ruter
    Selected_Routes_Today=Int[],
    Selected_Routes_day_and_lookahead=Int[],

    # Samlet leveret volume
    Total_Delivered=Float64[],

    # Inventory violations
    Total_v_empty=Float64[],
    Total_v_min=Float64[],
    Total_v_max=Float64[],

    # Route pool statistik
    Pool_Size=Int[],

    # Immortal columns
    Columns_Made_Immortal=Int[],
    Total_Immortal_Columns=Int[],
    Immortal_Route_IDs=String[]
)

# Log af eksekverede IP-ruter
ip_shift_log = DataFrame(
    Day=Int[],
    Vehicle_ID=Int[],
    Shift=Int[],
    VDS=String[],

    # Route struktur
    Route_Nodes=String[],
    Visited_Stations=String[],
    Segment_Count=Int[],

    # Leveringer
    Executed_Q=Float64[],
    IP_Delivery=Float64[],
    Actual_Delivery=Float64[],
    Delivery_Diff=Float64[],

    # Route time/cost
    Total_Cost=Float64[],
    Drive_Time=Float64[],
    Load_Time=Float64[],
    Service_Time=Float64[],
    Total_Time=Float64[],

    # Route status
    Status=String[]
)

# Lookahead-ruter fra IP-løsningen
lookahead_ip_shifts = DataFrame(
    Solve_Day=Int[],
    Route_Day=Int[],
    Vehicle_ID=Int[],
    Shift=Int[],
    VDS=String[],

    # Route struktur
    Route_Nodes=String[],
    Visited_Stations=String[],
    Segment_Count=Int[],

    # Planlagt levering og cost
    Planned_Q=Float64[],
    Total_Cost=Float64[],

    # Om ruten blev valgt/eksekveret
    Selected_In_IP=Bool[],
    Executed_Today=Bool[],
    Status=String[]
)

# Segment-log for IP-ruter
ip_route_segments = DataFrame(
    Day=Int[],
    Vehicle_ID=Int[],
    Shift=Int[],
    VDS=String[],

    # Segment information
    Segment_No=Int[],
    Segment_Nodes=String[],
    Segment_Stations=String[],

    # Segment deliveries/load
    Segment_Q_Total=Float64[],
    Tank_Deliveries=String[],
    Loaded_Products=String[],
    Compartment_Products=String[]
)
# ==========================================================
# INITIALIZE ALL EXCEL LOGS
# ==========================================================

function init_excel_logs()

    return (
        inventory_log = deepcopy(inventory_log),
        lookahead_inventory_log = deepcopy(lookahead_inventory_log),
        model_summary_log = deepcopy(model_summary_log),
        rmp_iteration_log = deepcopy(rmp_iteration_log),
        incumbent_log = deepcopy(incumbent_log),
        ip_shift_log = deepcopy(ip_shift_log),
        lookahead_ip_shifts = deepcopy(lookahead_ip_shifts),
        ip_route_segments = deepcopy(ip_route_segments)
    )
end

function log_rmp_iteration!(
    logs,
    day,
    GG,
    rmp_results,
    pool,
    active_rmp_columns,
    columns_added_this_iter,
    evals_this_iter,
    columns_before_purge,
    columns_purged,
    columns_after_purge,
    incumbent_updated,
    columns_made_immortal,
    immortal_routes,
    solve_time
)

    push!(logs.rmp_iteration_log, (
        day,
        GG,
        solve_time,
        string(rmp_results.status),
        round(rmp_results.obj, digits=2),

        length(pool),
        active_rmp_columns,
        columns_added_this_iter,
        evals_this_iter,

        columns_before_purge,
        columns_purged,
        columns_after_purge,

        incumbent_updated,
        columns_made_immortal,
        length(immortal_routes),

        sum(rmp_results.v_empty_values),
        sum(rmp_results.v_min_values),
        sum(rmp_results.v_max)
    ))
end

function log_incumbent!(
    logs;
    day,
    iteration,
    incumbent_objective,
    selected_routes_today,
    selected_routes_day_and_lookahead,
    total_delivered,
    total_v_empty,
    total_v_min,
    total_v_max,
    pool_size,
    columns_made_immortal,
    total_immortal_columns,
    immortal_route_ids,
    solve_time
)
    push!(logs.incumbent_log, (
        day,
        iteration,
        solve_time,
        incumbent_objective,
        selected_routes_today,
        selected_routes_day_and_lookahead,
        total_delivered,
        total_v_empty,
        total_v_min,
        total_v_max,
        pool_size,
        columns_made_immortal,
        total_immortal_columns,
        immortal_route_ids
    ))
end


function log_lookahead_inventory!(
    logs;
    solve_day,
    inventory_day,
    station_id,
    tank_id,
    product_id,
    empty_level,
    min_level,
    max_level,
    projected_start,
    projected_end,
    projected_overfill,
    projected_below_empty,
    projected_below_min,
    planned_delivered,
    planned_demand,
    route_names,
    route_quantities
)
    push!(logs.lookahead_inventory_log, (
        solve_day,
        inventory_day,
        station_id,
        tank_id,
        product_id,
        empty_level,
        min_level,
        max_level,
        round(projected_start, digits=2),
        round(projected_end, digits=2),
        round(projected_overfill, digits=2),
        round(projected_below_empty, digits=2),
        round(projected_below_min, digits=2),
        round(planned_delivered, digits=2),
        round(planned_demand, digits=2),
        join(route_names, " | "),
        join(round.(route_quantities, digits=2), " | ")
    ))
end


function log_lookahead_ip_shift!(logs, solve_day, r::Route, terminal_ids)
    push!(logs.lookahead_ip_shifts, (
        solve_day,
        r.t,
        r.vehicle_id,
        r.shift,
        route_vds(r),
        join(r.nodes, " -> "),
        join(r.station_ids, " -> "),
        length(split_route_into_segments(r, terminal_ids)),
        round(sum(values(r.q)), digits=2),
        round(r.total_cost, digits=2),
        true,
        r.t == solve_day,
        r.t == solve_day ? "executed_today" : "planned_lookahead"
    ))
end


function log_ip_shift!(
    logs,
    r::Route,
    original_q,
    tank_lookup,
    terminal_ids
)
    drive_time, load_time, service_time, total_time =
        route_time_breakdown(r, tank_lookup, terminal_ids)

    actual_q = sum(values(r.q))

    push!(logs.ip_shift_log, (
        r.t,
        r.vehicle_id,
        r.shift,
        route_vds(r),
        join(r.nodes, " -> "),
        join(r.station_ids, " -> "),
        length(split_route_into_segments(r, terminal_ids)),
        round(actual_q, digits=2),
        round(original_q, digits=2),
        round(actual_q, digits=2),
        round(original_q - actual_q, digits=2),
        round(r.total_cost, digits=2),
        round(drive_time, digits=2),
        round(load_time, digits=2),
        round(service_time, digits=2),
        round(total_time, digits=2),
        "executed_after_fix"
    ))
end


function log_inventory!(
    logs;
    day,
    station_id,
    tank_id,
    product_id,
    empty_level,
    min_level,
    max_level,
    start_inventory,
    end_inventory,
    overfill,
    below_empty_before_clamp,
    below_min_before_clamp,
    original_ip_delivered,
    fixed_delivered,
    delivery_diff,
    forecast_demand,
    actual_demand,
    route_names_str,
    route_quantities_str
)
    push!(logs.inventory_log, (
        day,
        station_id,
        tank_id,
        product_id,
        empty_level,
        min_level,
        max_level,
        round(start_inventory, digits=2),
        round(end_inventory, digits=2),
        round(overfill, digits=2),
        round(below_empty_before_clamp, digits=2),
        round(below_min_before_clamp, digits=2),
        round(original_ip_delivered, digits=2),
        round(fixed_delivered, digits=2),
        round(delivery_diff, digits=2),
        round(forecast_demand, digits=2),
        round(actual_demand, digits=2),
        route_names_str,
        route_quantities_str
    ))
end


function log_model_summary!(
    logs,
    day,
    results,
    executed_routes,
    selected_routes_total,
    delivered_today,
    pool,
    solve_time
)
    push!(logs.model_summary_log, (
        day,
        solve_time,
        string(results.status),
        results.obj,
        length(executed_routes),
        selected_routes_total,
        sum(values(delivered_today)),
        sum(results.v_empty_values),
        sum(results.v_min_values),
        sum(results.v_max),
        length(pool)
    ))
end


function export_excel_logs!(logs, params)

    sort!(logs.inventory_log, [:Day, :Station_ID, :Tank_ID])
    sort!(logs.lookahead_inventory_log, [:Solve_Day, :Inventory_Day, :Station_ID, :Tank_ID])
    sort!(logs.lookahead_ip_shifts, [:Solve_Day, :Route_Day, :Vehicle_ID, :Shift])
    sort!(logs.ip_shift_log, [:Day, :Vehicle_ID, :Shift])
    sort!(logs.ip_route_segments, [:Day, :Vehicle_ID, :Shift, :Segment_No])
    sort!(logs.model_summary_log, [:Day])
    sort!(logs.rmp_iteration_log, [:Day, :Iteration])
    sort!(logs.incumbent_log, [:Day, :Iteration])

    output_dir = "inventory_experiments"

    if !isdir(output_dir)
        mkdir(output_dir)
    end

    existing_files = filter(
        f -> occursin(r"^inventory_log_exp\d+\.xlsx$", f),
        readdir(output_dir)
    )

    experiment_numbers = Int[]

    for f in existing_files
        match_result = match(r"inventory_log_exp(\d+)\.xlsx", f)

        if match_result !== nothing
            push!(experiment_numbers, parse(Int, match_result.captures[1]))
        end
    end

    next_experiment =
        isempty(experiment_numbers) ? 1 : maximum(experiment_numbers) + 1

    output_file = joinpath(
        output_dir,
        "inventory_log_exp$(next_experiment).xlsx"
    )

    params_df = DataFrame(
        Parameter=String[],
        Value=String[]
    )

    for (k, v) in pairs(params)
        push!(params_df, (string(k), string(v)))
    end

    XLSX.writetable(output_file,
        "Inventory_Log" => logs.inventory_log,
        "Lookahead_Inventory" => logs.lookahead_inventory_log,
        "Lookahead_IP_Shifts" => logs.lookahead_ip_shifts,
        "IP_Shift_Log" => logs.ip_shift_log,
        "IP_Route_Segments" => logs.ip_route_segments,
        "Model_Summary" => logs.model_summary_log,
        "RMP_Iterations" => logs.rmp_iteration_log,
        "Incumbents" => logs.incumbent_log,
        "Parameters" => params_df
    )

    println("Inventory log saved to $output_file")

    return output_file
end