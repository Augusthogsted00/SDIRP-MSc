# ============================================================
# Q-algo
# ============================================================
# ------------------------------------------------------------
# Hjælpefunktion
# ------------------------------------------------------------
function projected_stock(station::Station, tank_idx::Int, t::Int)

    if t <= 1
        return station.initial_stock[tank_idx]
    end

    return max(0.0, station.initial_stock[tank_idx] - sum(station.demands[tank_idx, 1:t-1])
    )
end


# ------------------------------------------------------------
# Beregn tankens ledige kapacitet før levering sker
#
# Headroom = max_stock - projected_stock
# Bruges som øvre grænse for levering.
# ------------------------------------------------------------
# Hjælpefunktion
# ------------------------------------------------------------
function tank_headroom_from_ps(station::Station, tank_idx::Int, ps::Float64)
    # Begræns til minimum 0
    return max(0.0, station.max_stock[tank_idx] - ps)
end


# ------------------------------------------------------------
# Min-max normalisering til intervallet [0,1]
#
# Hvis alle værdier er ens returneres 0.0,
# så division med 0 undgås.
# ------------------------------------------------------------
# Hjælpefunktion
# ------------------------------------------------------------
function minmax_normalize(x::Float64, xmin::Float64, xmax::Float64; eps_score::Float64 = 0.05)

    # Alle dualer er ens → ingen relativ information → alle vægtes lige
    if xmax - xmin <= 1e-9
        return 1.0
    end

    # Forskellige dualer → højeste får 1.0, laveste får eps_score
    return eps_score + (1.0 - eps_score) * ((x - xmin) / (xmax - xmin))
end


# ------------------------------------------------------------
# Beregn effektiv tank-score under top-ups
#
# Tanke som allerede har modtaget meget volumen får gradvist
# reduceret deres score via diminishing returns.
# ------------------------------------------------------------
# Hjælpefunktion - til tank fyldning
# ------------------------------------------------------------
function effective_topup_score(base_score::Float64, already_delivered::Float64, tank_headroom::Float64, params)

    # Andel af tankens headroom der allerede er dækket
    fill_ratio = already_delivered / max(1.0, tank_headroom)

    # Reducér score gradvist jo mere tanken har modtaget
    return base_score * exp(-params.diminishing_lambda * fill_ratio)
end


# ------------------------------------------------------------
# Beregn effektiv produktværdi på en rute ved compartment assignment
#
# Produkter som allerede har fået meget volumen tildelt får
# gradvist reduceret deres værdi via diminishing returns.
# ------------------------------------------------------------
# Hjælpefunktion til compartment assignment
# ------------------------------------------------------------
function effective_product_value(norm_score::Float64, assigned_volume::Float64, total_headroom::Float64, params)

    # Andel af produktets samlede headroom der allerede er dækket
    fill_ratio = assigned_volume / max(1.0, total_headroom)

    # Reducér produktværdi gradvist jo mere produktet har fået
    return norm_score * exp(-params.product_diminishing_lambda * fill_ratio)
end


# ------------------------------------------------------------
# Find unikke produkter på ruten
# ------------------------------------------------------------
# Hjælpefunktion til compartment assignment
# ------------------------------------------------------------
function route_products(route::Route, stations_dict::Dict{Int,Station})

    products = Int[]

    # Gennemgå alle stationer på ruten
    for sid in route.station_ids
        station = stations_dict[sid]

        # Tilføj produkterne fra stationens tanke
        append!(products, station.product_types[1:station.num_compartments])
    end

    # Returnér unikke produkter
    return unique(products)
end


# ------------------------------------------------------------
# Byg tank-metrics for ruten
#
# Formål:
# Samler de vigtigste tank-specifikke oplysninger, som Q-algo
# bruger til at prioritere leveringer på en given rute.
#
# For hver tank på ruten beregnes:
# - projected stock før levering
# - headroom, dvs. hvor meget tanken kan modtage
# - dualværdi ω fra masterproblemet
# - produkt-id
# - tank-score baseret på normaliseret ω
#
# Tank-scoren bruges senere både til at aggregere værdi på
# produktniveau og til at prioritere leveringer og top-ups.
# ------------------------------------------------------------
# Hjælpefunktion til tank scoring og prioritering af q-allokering og top-ups
# ------------------------------------------------------------
function build_tank_metric_maps(
    route::Route,
    stations_dict::Dict{Int,Station},
    params
)

    # Opslagstabeller pr. tank-id
    projected_stock_map = Dict{String,Float64}()
    headroom_map = Dict{String,Float64}()
    ω_map = Dict{String,Float64}()
    score_map = Dict{String,Float64}()
    product_map = Dict{String,Int}()

    # Beregn rå metrics for hver tank på ruten
    for sid in route.station_ids
        station = stations_dict[sid]

        for k in 1:station.num_compartments
            tk = station.id_tank[k]
            p = station.product_types[k]

            # Lager før levering og tankens modtagelige volumen
            ps = projected_stock(station, k, route.t)
            headroom = tank_headroom_from_ps(station, k, ps)

            # Dualværdi fra masterproblemet for denne tank og dag
            ω_val = get(station.ω, (tk, route.t), 0.0)

            projected_stock_map[tk] = ps
            headroom_map[tk] = headroom
            ω_map[tk] = ω_val
            product_map[tk] = p
        end
    end

    # Normalisér dualværdier relativt til tankene på samme rute
    ω_vals = collect(values(ω_map))
    ω_min, ω_max = minimum(ω_vals), maximum(ω_vals)

    # Beregn tank-score ud fra normaliseret dualværdi
    for tk in keys(ω_map)
        ω_norm = minmax_normalize(ω_map[tk], ω_min, ω_max)
        score_map[tk] = ω_norm
    end

    return projected_stock_map, headroom_map, score_map, product_map
end


# ------------------------------------------------------------
# Aggregér tank-data til produktniveau
#
# Samler tank-scorer og tank-headroom pr. produkt, så
# produkterne kan prioriteres under compartment assignment.
#
# For hvert produkt beregnes:
# - samlet produktscore
# - samlet remaining headroom
#
# Produktscoren repræsenterer den samlede attraktivitet af
# at levere produktet på ruten, mens product_headroom angiver
# hvor meget volumen der maksimalt kan leveres af produktet.
# ------------------------------------------------------------
# Hjælpefunktion til compartment assignment
# ------------------------------------------------------------
function aggregate_product_data(
    product_map::Dict{String,Int},
    score_map::Dict{String,Float64},
    headroom_map::Dict{String,Float64}
)

    # Samlet score og tank headroom pr. produkt
    product_score = Dict{Int,Float64}()
    product_headroom = Dict{Int,Float64}()

    # For hvert produkt - summer tank-score og tank-headroom 
    for (tk, p) in product_map
        product_score[p] = get(product_score, p, 0.0) + score_map[tk]
        product_headroom[p] = get(product_headroom, p, 0.0) + headroom_map[tk]
    end

    return product_score, product_headroom
end


# ------------------------------------------------------------
# Tildel bilens compartments til produkter
#
# Formål:
# Fylder compartments greedily ud fra produktscore,
# remaining headroom og vægtkapacitet.
#
# Produkter som allerede har fået meget volumen tildelt
# får reduceret deres effektive værdi via diminishing returns.
#
# Returnerer:
# - produktvalg pr. compartment
# - loaded volume pr. compartment
# ------------------------------------------------------------
# Hovedfunktion til compartment assignment
# ------------------------------------------------------------
function assign_compartments_to_products(vehicle::Vehicle, product_score::Dict{Int,Float64},
    product_headroom::Dict{Int,Float64}, product_dict::Dict{Int,Product}, params
)

    # Produkt valgt for hvert compartment
    compartment_product = Dict{Int,Int}()

    # Load i liter for hvert compartment
    compartment_load = Dict{Int,Float64}()

    # Resterende headroom pr. produkt
    remaining_headroom = copy(product_headroom)

    # Volumen allerede tildelt pr. produkt
    assigned_volume = Dict{Int,Float64}(p => 0.0 for p in keys(product_headroom))

    # Resterende vægtkapacitet på bilen
    remaining_weight = vehicle.weight

    # Produkter der findes på ruten
    products = collect(keys(product_headroom))

    # Hvis der ikke er produkter på ruten - stop, burde ikke ske
    if isempty(products)
        return compartment_product, compartment_load
    end

    # Normalisér produktscore til [0,1]
    max_score = maximum(values(product_score))

    norm_score = Dict(
        p => product_score[p] / max(1e-6, max_score)
        for p in keys(product_score)
    )

    # Fyld største compartments først
    # Sorter efter størrelse
    sorted_compartments = sortperm(vehicle.comp_caps, rev=true)

    # for hvert compartment, find capacity
    for cidx in sorted_compartments
        comp_cap = vehicle.comp_caps[cidx]

        best_product = nothing
        best_value = -Inf

        # Vælg produktet med højest effektiv værdi
        for p in products

            # Skip produkter hvor headroom = 0 
            if get(remaining_headroom, p, 0.0) <= 1e-6
                continue
            end

            # Find produktets værdi på ruten
            value = effective_product_value(
                get(norm_score, p, 0.0),
                get(assigned_volume, p, 0.0),
                get(product_headroom, p, 0.0),
                params
            )

            # Hvis værdien 
            if value > best_value
                best_value = value
                best_product = p
            end
        end

        # Stop hvis der ikke er en bedste rute - burde ikke ske
        if best_product === nothing
            break
        end

        # Vægtbegrænsning omregnet til liter via produktets density
        max_by_weight = remaining_weight / product_density(best_product, product_dict)

        # Faktisk load begrænses af compartment, vægt og resterende headroom,
        # Load begrænses typisk af compartment-kapacitet,
        # men kan senere bindes af vægt eller remaining headroom
        feasible_load = min(
            comp_cap,
            max_by_weight,
            remaining_headroom[best_product]
        )

        if feasible_load <= 1e-6
            continue
        end

        # Gem produkt og load for dette compartment
        compartment_product[cidx] = best_product
        compartment_load[cidx] = feasible_load

        # Opdater volumen og resterende headroom for produktet
        assigned_volume[best_product] += feasible_load
        remaining_headroom[best_product] = max(0.0, remaining_headroom[best_product] - feasible_load)

        # Opdater resterende vægtkapacitet
        remaining_weight -= feasible_load * product_density(best_product, product_dict)

        if remaining_weight <= 1e-6
            break
        end
    end

    return compartment_product, compartment_load
end


# ------------------------------------------------------------
# Split ruten i terminal-til-terminal segmenter
#
# Hvert segment svarer til én load → delivery → return cyklus.
# ------------------------------------------------------------
function split_route_into_segments(route::Route, terminal_ids::Set{Int})

    segments = Vector{Vector{Int}}()
    current_segment = Int[]

    # Gennemgå alle nodes i ruten
    for node in route.nodes
        push!(current_segment, node)

        # Afslut segment når vi rammer en terminal igen
        if node in terminal_ids && length(current_segment) > 1

            # Gem kun gyldige terminal-til-terminal segmenter
            if first(current_segment) in terminal_ids &&
               last(current_segment) in terminal_ids

                push!(segments, copy(current_segment))
            end

            # Start næste segment fra samme terminal
            current_segment = [node]
        end
    end

    return segments
end

# ------------------------------------------------------------
# Find stationer i et segment
#
# Terminaler filtreres fra.
# ------------------------------------------------------------
function segment_station_ids(seg_nodes::Vector{Int}, terminal_ids::Set{Int})

    return [
        n for n in seg_nodes
        if !(n in terminal_ids)
    ]
end

# ------------------------------------------------------------
# Beregn køretid for ét segment
# ------------------------------------------------------------
function compute_segment_drive_time(
    seg_nodes::Vector{Int},
    times_mat::Matrix{Float64},
    time_index_map::Dict{<:AbstractString,<:Integer},
    terminal_ids::Set{Int}
)

    total_time = 0.0

    # Gennemgå alle kanter i segmentet
    for i in 1:length(seg_nodes)-1
        from_id = seg_nodes[i]
        to_id = seg_nodes[i+1]

        # Terminaler bruger label "Terminal" i tidsmatricen
        from_label = from_id in terminal_ids ? "Terminal" : string(from_id)
        to_label = to_id in terminal_ids ? "Terminal" : string(to_id)

        # Slå matrix-indeks op
        ii = time_index_map[from_label]
        jj = time_index_map[to_label]

        # Tid konverteres fra sekunder til minutter
        total_time += times_mat[ii, jj] / 60
    end

    return total_time
end




# ------------------------------------------------------------
# Allokér leveringer og top-ups til tanke
#
# Formål:
# Fordeler loaded produktvolumen til tanke med samme produkt
# via én samlet greedy allocation-procedure.
#
# Alle kvalificerede tanke konkurrerer direkte om volumen.
#
# Logik:
# - Vælg tanken med højest effektiv score
# - Nye tanke får min_drop
# - Eksisterende tanke får top-ups op til 1000 L
# - Diminishing returns reducerer gradvist tankens score
#
# Ikke alle tanke får nødvendigvis levering.
# ------------------------------------------------------------
function allocate_topups!(
    route::Route,
    stations_dict::Dict{Int,Station},
    q::Dict{String,Float64},
    product_remaining_load::Dict{Int,Float64},
    score_map::Dict{String,Float64},
    headroom_map::Dict{String,Float64},
    params
)

    # Gem ekstra debug-information hvis print er slået til
    keep_debug = params.print_q_debug || params.print_tank_metrics

    # Gem detaljer om hver iteration af allokeringen
    topup_iterations = keep_debug ? NamedTuple[] : nothing

    # Find alle unikke produkter på ruten
    products = route_products(route, stations_dict)

    # Behandl ét produkt ad gangen
    for p in products

        # Kandidattanke som kan modtage produkt p
        selected = String[]

        # Find alle tanke med:
        # - korrekt produkt
        # - nok headroom til mindst ét minimum drop
        # Altså liste over potentielle tanke til produkt p
        for sid in route.station_ids
            station = stations_dict[sid]

            for k in 1:station.num_compartments
                tk = station.id_tank[k]

                if station.product_types[k] == p &&
                   get(headroom_map, tk, 0.0) >= params.min_drop

                    push!(selected, tk)
                end
            end
        end

        # Produktvolumen som endnu ikke er fordelt
        remaining = get(product_remaining_load, p, 0.0)

        # Bruges kun til debug-output
        topup_iter = 1

        # Fortsæt så længe der er volumen tilbage
        while remaining > 1e-6

            # Gem ranking af tanke hvis debug er slået til
            ranking = keep_debug ? NamedTuple[] : nothing

            # Bedste kandidat i denne iteration
            best_tk = nothing
            best_eff = -Inf

            # Evaluér alle kvalificerede tanke
            for tk in selected

                # Allerede leveret volumen til tanken
                delivered = get(q, tk, 0.0)

                # Maksimal modtagelig volumen
                headroom = headroom_map[tk]

                # Spring over hvis tanken allerede er fuld
                if delivered >= headroom - 1e-6
                    continue
                end

                # Hvis tanken endnu ikke har fået levering,
                # skal der stadig være nok load tilbage til
                # mindst ét minimum drop
                if delivered <= 1e-6

                    if remaining < params.min_drop ||
                       headroom < params.min_drop

                        continue
                    end
                end

                # Effektiv score reduceres gradvist jo mere
                # volumen tanken allerede har modtaget
                eff = effective_topup_score(
                    score_map[tk],
                    delivered,
                    headroom,
                    params
                )

                # Gem ranking-information til debug
                if keep_debug
                    push!(ranking, (
                        tank_id=tk,
                        delivered_before=delivered,
                        headroom=headroom,
                        fill_ratio=delivered / max(1.0, headroom),
                        base_score=score_map[tk],
                        effective_score=eff
                    ))
                end

                # Gem bedste tank i denne iteration
                if eff > best_eff
                    best_eff = eff
                    best_tk = tk
                end
            end

            # Stop hvis ingen tanke længere kan modtage volumen
            if best_tk === nothing
                break
            end

            # Sortér ranking efter effektiv score til debug
            if keep_debug
                sort!(ranking, by=row -> row.effective_score, rev=true)
            end

            # Allerede leveret volumen til valgt tank
            already = get(q, best_tk, 0.0)

            # Maksimal ekstra volumen tanken kan modtage
            max_extra = max(
                0.0,
                headroom_map[best_tk] - already
            )

            # Hvis tanken ikke tidligere har fået levering:
            # giv præcis minimum drop
            if already <= 1e-6

                extra = params.min_drop

            else

                # Hvis tanken allerede er aktiv:
                # giv mindre top-up trin
                extra = min(
                    1000.0,
                    max_extra,
                    remaining
                )
            end

            # Stop hvis ingen volumen kan leveres
            if extra <= 1e-6
                break
            end

            # Levering efter denne iteration
            delivered_after = already + extra

            # Resterende produktvolumen efter levering
            remaining_after = remaining - extra

            # Gem detaljer om iterationen til debug
            if keep_debug
                push!(topup_iterations, (
                    product=p,
                    iteration=topup_iter,
                    remaining_before=remaining,
                    remaining_after=remaining_after,
                    ranking=ranking,
                    chosen_tank=best_tk,
                    added_volume=extra,
                    delivered_before=already,
                    delivered_after=delivered_after,
                    tank_full=delivered_after >= headroom_map[best_tk] - 1e-6,
                    product_empty=remaining_after <= 1e-6,
                    no_active_tanks=false
                ))
            end

            # Opdater levering til valgt tank
            q[best_tk] = delivered_after

            # Opdater resterende produktvolumen
            remaining = remaining_after

            topup_iter += 1
        end

        # Gem resterende produkt-load efter allokering
        product_remaining_load[p] = remaining
    end

    return keep_debug ? topup_iterations : NamedTuple[]
end


# ------------------------------------------------------------
# Ryd op i q-løsningen
#
# Sikrer at leveringer ikke overstiger headroom,
# og fjerner leveringer under min_drop.
# ------------------------------------------------------------
function cleanup_q!(
    route::Route,
    stations_dict::Dict{Int,Station},
    q::Dict{String,Float64},
    projected_stock_map::Dict{String,Float64},
    params
)

    # Gennemgå alle tanke på ruten
    for sid in route.station_ids
        station = stations_dict[sid]

        for k in 1:station.num_compartments
            tk = station.id_tank[k]

            # Skip tanke uden levering
            if !haskey(q, tk)
                continue
            end

            # Maksimal levering uden overflow
            headroom = tank_headroom_from_ps(
                station,
                k,
                projected_stock_map[tk]
            )

            # Begræns levering til tankens headroom
            q[tk] = min(q[tk], headroom)

            # Fjern små leveringer under minimum drop
            if q[tk] > 1e-6 && q[tk] < params.min_drop
                q[tk] = 0.0
            end
        end
    end

    return nothing
end



# ------------------------------------------------------------
# Beregn samlet leveret volumen pr. station
#
# Summerer tankleveringer op til stationsniveau.
# ------------------------------------------------------------
function station_delivered_volume(
    route::Route,
    q::Dict{String,Float64},
    tank_lookup::Dict{String,Tuple{Int,Int}}
)

    # Samlet leveret volumen pr. station
    station_volume = Dict{Int,Float64}()

    # Initialisér stationer på ruten med 0
    for sid in route.station_ids
        station_volume[sid] = 0.0
    end

    # Summer leveringer fra tankniveau til stationsniveau
    for (tank_id, qty) in q
        sid, _ = tank_lookup[tank_id]

        station_volume[sid] = get(station_volume, sid, 0.0) + qty
    end

    return station_volume
end

function remove_undelivered_stations_from_route!(
    route::Route,
    q_total::Dict{String,Float64},
    tank_lookup::Dict{String,Tuple{Int,Int}},
    terminal_ids::Set{Int},
    times_mat::Matrix{Float64},
    time_index_map::Dict{<:AbstractString,<:Integer},
    params
)

    # Find stationer der faktisk får levering, og gem dem i et Set
    delivered_stations = Set{Int}()

    for (tk, qty) in q_total
        if qty > 1e-6
            sid, _ = tank_lookup[tk]
            push!(delivered_stations, sid)
        end
    end

    # Hvis ingen stationer får levering, er ruten tom
    if isempty(delivered_stations)
        route.station_ids = Int[]
        route.nodes = Int[]
        route.time = Inf
        return false
    end

    # Hvis alle stationer får levering, behøver ruten ikke ændres
    if length(delivered_stations) == length(route.station_ids)
        return true
    end

    # Behold kun terminaler og stationer med levering
    cleaned_nodes = Int[]

    for node in route.nodes
        if node in terminal_ids || node in delivered_stations
            push!(cleaned_nodes, node)
        end
    end

    # Fjern terminaler i træk
    compact_nodes = Int[]

    # Fjern terminaler som ligger direkte efter hinanden
    for node in cleaned_nodes
        if !isempty(compact_nodes) &&
           node in terminal_ids &&
           last(compact_nodes) in terminal_ids
            continue
        end

        push!(compact_nodes, node)
    end

    # Hvis ruten er blevet ugyldig efter oprydning
    if length(compact_nodes) < 2
        route.station_ids = Int[]
        route.nodes = Int[]
        route.time = Inf
        return false
    end

    # Opdater route
    route.nodes = compact_nodes
    route.station_ids = [
        n for n in compact_nodes
        if !(n in terminal_ids)
    ]

    # Genberegn køretid efter stationer er fjernet
    route.time = compute_segment_drive_time(
        route.nodes,
        times_mat,
        time_index_map,
        terminal_ids
    )

    return true
end

## ------------------------------------------------------------
# Beregn samlet inventory dual value
#
# Summerer ω * q for alle tanke med levering.
# ------------------------------------------------------------
function compute_inventory_dual_value(
    route::Route,
    q::Dict{String,Float64},
    stations_dict::Dict{Int,Station},
    tank_lookup::Dict{String,Tuple{Int,Int}}
)

    inventory_dual_value = 0.0

    # Summer dualbidrag fra alle leverede tanke
    for (tk, qty) in q
        if qty <= 1e-6
            continue
        end

        # Find stationen som tanken tilhører
        sid, _ = tank_lookup[tk]
        station = stations_dict[sid]

        # Tilføj dualværdi for tanken på rutens dag
        inventory_dual_value += get(station.ω, (tk, route.t), 0.0) * qty
    end

    return inventory_dual_value
end

# ------------------------------------------------------------
# Byg q for ét terminal-til-terminal segment
#
# Segmentet håndteres som én load → delivery → return cyklus.
# Reduced cost beregnes først i den ydre build_q!.
# ------------------------------------------------------------
function build_q_for_segment!(
    route::Route,
    vehicle::Vehicle,
    stations_dict::Dict{Int,Station},
    product_dict::Dict{Int,Product},
    tank_lookup::Dict{String,Tuple{Int,Int}};
    params,
    segment_index::Int=1
)

    # Leveret mængde pr. tank
    q = Dict{String,Float64}()

    # Beregn tank-metrics for segmentet
    projected_stock_map, headroom_map, score_map, product_map =
        build_tank_metric_maps(route, stations_dict, params)

    # Initialisér alle tanke med 0 levering
    for tk in keys(product_map)
        q[tk] = 0.0
    end

    # Aggregér tank-score og tank-headroom til produktniveau
    product_score, product_headroom = aggregate_product_data(
        product_map,
        score_map,
        headroom_map
    )

    # Tildel compartments til produkter
    compartment_product, compartment_load = assign_compartments_to_products(
        vehicle,
        product_score,
        product_headroom,
        product_dict,
        params
    )

    # Summer load pr. produkt
    product_load = Dict{Int,Float64}()

    for (cidx, p) in compartment_product
        product_load[p] = get(product_load, p, 0.0) +
                          get(compartment_load, cidx, 0.0)
    end

    # Load som endnu ikke er fordelt til tanke
    product_remaining_load = copy(product_load)


    # Fordel loaded produktvolumen til tanke
    topup_iterations = allocate_topups!(
        route,
        stations_dict,
        q,
        product_remaining_load,
        score_map,
        headroom_map,
        params
    )

    # Ryd op i q-løsningen
    cleanup_q!(
        route,
        stations_dict,
        q,
        projected_stock_map,
        params
    )

    # Beregn samlet vægt af leveringer
    total_weight = 0.0

    for (tank_id, qty) in q
        sid, k = tank_lookup[tank_id]
        p = stations_dict[sid].product_types[k]

        total_weight += qty * product_density(p, product_dict)
    end

    # Safety check: skaler ned hvis vægtgrænsen overskrides
    if total_weight > vehicle.weight + 1e-6
        scale = vehicle.weight / total_weight

        for tk in keys(q)
            q[tk] *= scale
        end

        cleanup_q!(
            route,
            stations_dict,
            q,
            projected_stock_map,
            params
        )
    end

    # Gem segmentets q på segment-ruten
    route.q = q

    # Summer leveret volumen pr. station
    station_volume = station_delivered_volume(route, q, tank_lookup)

    # Samlet leveret volumen på segmentet
    total_volume = sum(values(q))

    # Terminal loading time
    terminal_time = total_volume <= 1e-6 ? 0.0 : 15.0 + total_volume / 1800.0

    # Station delivery time
    delivery_time = 0.0

    for (_, vol) in station_volume
        if vol > 1e-6
            delivery_time += 10.0 + vol / 900.0
        end
    end

    # Dualværdi fra leveringer på segmentet
    inventory_dual_value = compute_inventory_dual_value(
        route,
        q,
        stations_dict,
        tank_lookup
    )

    return (
        q=q,
        compartment_product=compartment_product,
        compartment_load=compartment_load,
        projected_stock=projected_stock_map,
        headroom=headroom_map,
        score=score_map,
        product_map=product_map,
        product_load=product_load,
        topup_iterations=topup_iterations,
        station_volume=station_volume,
        total_loaded_volume=total_volume,
        terminal_time=terminal_time,
        delivery_time=delivery_time,
        inventory_dual_value=inventory_dual_value,
        config=params
    )
end



function restore_route_for_avns!(
    route::Route,
    terminal_ids::Set{Int}
)
    # AVNS-format:
    # station_ids = route-sequence inkl. interne terminaler,
    # men uden start- og slut-terminal.
    if length(route.nodes) <= 2
        route.station_ids = Int[]
    else
        route.station_ids = copy(route.nodes[2:end-1])
    end

    return nothing
end



# ------------------------------------------------------------
# Byg q for en hel rute
#
# Ruter med terminalbesøg undervejs splittes i segmenter.
# Hvert segment får sin egen loading og q-allokering.
# ------------------------------------------------------------
function build_q!(
    route::Route,
    vehicle::Vehicle,
    stations_dict::Dict{Int,Station},
    product_dict::Dict{Int,Product},
    tank_lookup::Dict{String,Tuple{Int,Int}},
    terminal_ids::Set{Int},
    times_mat::Matrix{Float64},
    time_index_map::Dict{<:AbstractString,<:Integer},
    shift_lookup;
    params,
)

    # Q-algo-format:
    # nodes       = fuld rute inkl. start/slut-terminal og evt. interne terminaler
    # station_ids = kun rigtige stationer
    route.station_ids = segment_station_ids(route.nodes, terminal_ids)

    # Samlet q for hele ruten
    q_total = Dict{String,Float64}()

    # Split ruten i terminal-til-terminal segmenter
    segments = split_route_into_segments(route, terminal_ids)

    # Debug-data gemmes kun hvis det er slået til
    keep_debug = params.print_q_debug || params.print_tank_metrics
    segment_results = NamedTuple[]

    # Samlede værdier over alle segmenter
    station_volume_total = Dict{Int,Float64}()
    total_volume_all = 0.0
    terminal_time_total = 0.0
    delivery_time_total = 0.0
    inventory_dual_value_all = 0.0

    # Byg q segment for segment
    for (seg_idx, seg_nodes) in enumerate(segments)

        # Stationer i dette segment
        seg_station_ids = segment_station_ids(seg_nodes, terminal_ids)

        # Skip segmenter uden leveringsstationer
        isempty(seg_station_ids) && continue

        # Midlertidig route for segmentet
        # Køretid håndteres på hel-rute niveau via route.time
        seg_route = Route(
            seg_nodes,
            seg_station_ids,
            0.0,
            route.shift_length,
            0.0,
            0.0,
            Dict{String,Float64}(),
            route.vehicle_id,
            route.t,
            route.shift
        )

        # Byg q for segmentet
        seg_result = build_q_for_segment!(
            seg_route,
            vehicle,
            stations_dict,
            product_dict,
            tank_lookup;
            params=params,
            segment_index=seg_idx
        )

        # Aggregér segmentets værdier
        total_volume_all += seg_result.total_loaded_volume
        terminal_time_total += seg_result.terminal_time
        delivery_time_total += seg_result.delivery_time

        # Inventory_dual_value kommer fra build_q_for_segment!
        # Her summeres de for hele ruten - det er kun omega her
        inventory_dual_value_all += seg_result.inventory_dual_value

        # Aggregér leveret volumen pr. station
        for (sid, vol) in seg_result.station_volume
            station_volume_total[sid] = get(station_volume_total, sid, 0.0) + vol
        end

        # Gem segmentdetaljer til debug / print
        if keep_debug
            seg_driving_time = compute_segment_drive_time(
                seg_nodes,
                times_mat,
                time_index_map,
                terminal_ids
            )

            push!(segment_results, (
                segment_index=seg_idx,
                nodes=copy(seg_nodes),
                station_ids=copy(seg_station_ids),
                q=copy(seg_result.q),
                compartment_product=copy(seg_result.compartment_product),
                compartment_load=copy(seg_result.compartment_load),
                product_load=copy(seg_result.product_load),
                topup_iterations=copy(seg_result.topup_iterations),
                projected_stock=copy(seg_result.projected_stock),
                headroom=copy(seg_result.headroom),
                score=copy(seg_result.score),
                product_map=copy(seg_result.product_map),
                station_volume=copy(seg_result.station_volume),
                total_loaded_volume=seg_result.total_loaded_volume,
                driving_time=seg_driving_time,
                terminal_time=seg_result.terminal_time,
                delivery_time=seg_result.delivery_time,
                inventory_dual_value=seg_result.inventory_dual_value
            ))
        end

        # Summér q over segmenter
        for (tk, qty) in seg_result.q
            q_total[tk] = get(q_total, tk, 0.0) + qty
        end
    end

    # Gem samlet q på ruten
    route.q = q_total

    # Fjern stationer som ikke modtager levering
    route_is_nonempty = remove_undelivered_stations_from_route!(
        route,
        q_total,
        tank_lookup,
        terminal_ids,
        times_mat,
        time_index_map,
        params
    )

    # Hvis ruten ikke leverer noget, skal den ikke bruges
    if !route_is_nonempty
        route.total_cost = Inf
        route.rc = Inf

        # Rute på avns-format
        restore_route_for_avns!(route, terminal_ids)

        return (
            q=q_total,
            station_volume=station_volume_total,
            total_loaded_volume=total_volume_all,
            terminal_time=terminal_time_total,
            delivery_time=delivery_time_total,
            total_time=Inf,
            inventory_dual_value=inventory_dual_value_all,
            pi_value=0.0,
            dual_value=0.0,
            reduced_cost=route.rc,
            time_feasible=false,
            #clones=Route[],
            segment_results=segment_results,
            config=params
        )
    end

    # Samlet ruteomkostning i tid
    total_time = route.time + terminal_time_total + delivery_time_total

    # Hent π-dual for rutens vehicle-day-shift
    shift_key = (route.vehicle_id, route.t, route.shift)

    if !haskey(shift_lookup, shift_key)
        error("Missing shift slot for key: $shift_key")
    end

    pi_value = shift_lookup[shift_key].π

    # Samlet dualværdi
    # π og ω bruges med sit rå fortegn
    dual_value = inventory_dual_value_all + pi_value

    time_feasible = total_time <= route.shift_length + 1e-6

    if time_feasible &&
       total_volume_all > 1e-6 &&
       !isempty(route.station_ids) &&
       isfinite(total_time)

        reduced_cost = total_time - dual_value
    else
        reduced_cost = Inf
    end

    # Gem cost og reduced cost på ruten
    route.total_cost = total_time
    route.rc = reduced_cost

    # Rute på avns-format
    restore_route_for_avns!(route, terminal_ids)

    return (
        q=q_total,
        station_volume=station_volume_total,
        total_loaded_volume=total_volume_all,
        terminal_time=terminal_time_total,
        delivery_time=delivery_time_total,
        total_time=total_time,
        inventory_dual_value=inventory_dual_value_all,
        pi_value=pi_value,
        dual_value=dual_value,
        reduced_cost=reduced_cost,
        time_feasible=time_feasible,
        #clones=clones,
        segment_results=segment_results,
        config=params
    )
end