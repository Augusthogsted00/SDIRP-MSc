using CSV, DataFrames, JuMP, Gurobi, LinearAlgebra, DataStructures, Statistics, XLSX, Plots, Random, Base.Threads, Distributions, GaussianProcesses, BayesianOptimization

if !@isdefined(q_algo_count)
    const q_algo_count = Threads.Atomic{Int}(0)
end
if !@isdefined(q_time_total)
    const q_time_total = Threads.Atomic{Float64}(0.0)
end

############################################################
# Time Matrix
############################################################
Times_raw = DataFrame(
    CSV.File("TimeMatrix.csv", delim=';', header=false)
)

# Labels
time_col_labels = string.(collect(Times_raw[1, 2:end]))
time_row_labels = string.(Times_raw[2:end, 1])

# Ren numerisk matrix
Times = parse.(Float64, replace.(string.(Matrix(Times_raw[2:end, 2:end])), "," => "."))

# Hurtigt opslag: label -> matrix index
time_index_map = Dict(label => idx for (idx, label) in enumerate(time_row_labels))

############################################################
# Locations
############################################################
Locations_df = CSV.read(
    "Locations.csv",
    DataFrame;
    missingstring=["", "N/A", "null"],
    normalizenames=true
)

# Keep rows where at least one value is NOT missing
Locations_df = filter(row -> !all(ismissing, row), Locations_df)

stations = filter(row -> row.Type == "Station", Locations_df)
n_stations = nrow(stations)

terminals = filter(row -> row.Type == "Terminal", Locations_df)
n_terminals = nrow(terminals)
terminal_ids = Set(Int.(terminals.ID))

rigid_stations = filter(
    r -> any(occursin.(["Rigid", "missing"], string(r.Qualification_Demands))),
    stations
)

semi_stations = filter(
    r -> any(occursin.(["Semi", "missing"], string(r.Qualification_Demands))),
    stations
)

drawbar_stations = filter(
    r -> any(occursin.(["Drawbar", "missing"], string(r.Qualification_Demands))),
    stations
)

# Mapping of vehicle qualifications to station IDs
qual_map = Dict(
    "Rigid" => collect(skipmissing(rigid_stations.ID)),
    "Semi" => collect(skipmissing(semi_stations.ID)),
    "Drawbar" => collect(skipmissing(drawbar_stations.ID))
)

############################################################
# Products
############################################################
Products_df = CSV.read(
    "Products.csv",
    DataFrame;
    missingstring=["", "N/A", "null"],
    normalizenames=true
)

# Keep rows where at least one value is NOT missing
Products_df = filter(row -> !all(ismissing, row), Products_df)
n_products = nrow(Products_df)

############################################################
# Stations and Tanks
############################################################
Stations_df = CSV.read(
    "Stations_and_Tanks.csv", DataFrame;
    missingstring=["", "N/A", "null"], # Treat these as missing
    normalizenames=true, types=Dict(:Tank_ID => String))               # Fixes messy column names automatically

# Keep rows where at least one value is NOT missing
Stations_df = filter(row -> !all(ismissing, row), Stations_df)

# Merge with Products to get Product Names and Densities
Stations_df = rename!(leftjoin(Stations_df, Products_df, on=:Product => :Name), :ID => :Product_ID)


############################################################
# Vehicles
############################################################
Vehicles_df = CSV.read(
    "Vehicles.csv",
    DataFrame;
    missingstring=["", "N/A", "null"],
    normalizenames=true
)

# Keep rows where at least one value is NOT missing
Vehicles_df = filter(row -> !all(ismissing, row), Vehicles_df)
n_vehicles = nrow(Vehicles_df)

############################################################
# Trips
############################################################
Trips_df = CSV.read(
    "Trips.csv",
    DataFrame;
    missingstring=["", "N/A", "null"],
    normalizenames=true
)

# Keep rows where at least one value is NOT missing
Trips_df = filter(row -> !all(ismissing, row), Trips_df)
#println("Trips_df columns: ", names(Trips_df))

############################################################
# Trips -> Shift slots
############################################################

const OP_DAY_START = 5 * 60   # 05:00

function time_to_minutes(t::AbstractString)
    h, m = split(strip(t), ":")
    return 60 * parse(Int, h) + parse(Int, m)
end

# Parse én shift-streng som fx "05:00 - 15:30"
function parse_shift_window(shift_str::AbstractString)
    parts = split(strip(shift_str), "-")

    if length(parts) != 2
        error("Invalid shift format: '$shift_str'")
    end

    start_str = strip(parts[1])
    end_str = strip(parts[2])

    start_min = time_to_minutes(start_str)
    end_min = time_to_minutes(end_str)

    duration =
        end_min >= start_min ? (end_min - start_min) :
        (24 * 60 - start_min + end_min)

    return start_min, end_min, duration
end

# Parse celle med evt. flere shifts, fx:
# "05:00 - 15:30 + 17:00 - 02:30"
function parse_daily_shifts(cell)
    if ismissing(cell)
        return NamedTuple[]
    end

    txt = strip(string(cell))

    # Skip hvis det ikke ligner et shift
    if isempty(txt) || !occursin(":", txt)
        return NamedTuple[]
    end

    shift_strings = split(txt, "+")
    shifts = NamedTuple[]

    for (s_idx, sh) in enumerate(shift_strings)
        start_min, end_min, duration = parse_shift_window(strip(sh))
        push!(shifts, (
            shift=s_idx,
            start_min=start_min,
            end_min=end_min,
            duration_min=duration
        ))
    end

    return shifts
end

# Find dag-kolonnerne (alt efter Vehicle_ID)
trip_day_cols = filter(c -> c != "Vehicle_ID", names(Trips_df))

shift_rows = DataFrame(
    Vehicle_ID=Int[],
    Day=Int[],
    Shift=Int[],
    Start_Min=Int[],
    End_Min=Int[],
    Duration_Min=Int[]
)

for row in eachrow(Trips_df)
    vehicle_id = Int(row.Vehicle_ID)

    for (day_idx, col) in enumerate(trip_day_cols)
        shifts = parse_daily_shifts(row[col])

        for sh in shifts
            op_day = sh.start_min < OP_DAY_START ? day_idx - 1 : day_idx

            # Undgå dag 0
            if op_day < 1
                continue
            end

            push!(shift_rows, (
                vehicle_id,
                op_day,
                sh.shift,
                sh.start_min,
                sh.end_min,
                sh.duration_min
            ))
        end
    end
end

ShiftSlots_df = shift_rows


############################################################
# Data Structures
############################################################
mutable struct Route
    nodes::Vector{Int}
    station_ids::Vector{Int}
    time::Float64
    shift_length::Float64
    total_cost::Float64
    rc::Float64
    q::Dict{String,Float64}
    vehicle_id::Int
    t::Int
    shift::Int
end

struct Vehicle
    id::Int
    name::String
    type::String
    cap::Float64
    weight::Float64
    comp_caps::Vector{Float64}
    allowed_stations::Vector{Int}
end

mutable struct Station
    id::Int
    id_tank::Vector{String}
    name::String
    num_compartments::Int
    product_types::Vector{Int}
    capacity::Vector{Float64}
    max_stock::Vector{Float64}
    min_stock::Vector{Float64}
    empty_stock::Vector{Float64}
    initial_stock::Vector{Float64}
    demands::Matrix{Float64}
    ω::Dict{Tuple{String,Int},Float64}
end

struct Product
    id::Int
    name::String
    density::Float64
end


mutable struct ShiftSlot
    vehicle_id::Int
    day::Int
    shift::Int
    start_min::Int
    end_min::Int
    duration_min::Int
    π::Float64
end


############################################################
# Data Mappings
############################################################
# Vehicles
vehicles_struct = [Vehicle(
    v.ID, v.Name, v.Qualifications, v.Total_Vol_Cap_L_, v.Total_Weight_Cap_kg_,
    parse.(Float64, split(v.Compartment_Volumes_L_, ", ")), # Convert string to Vector
    qual_map[v.Qualifications]                                   # Look up allowed stations
) for v in eachrow(Vehicles_df)]

# Stations
day_cols = [Symbol("Day_$i") for i in 1:35]
stations_struct = [
    begin
        # It replaces "," with "" and parses as Float64
        f(x) = parse(Float64, replace(string(x), "," => ""))
        Station(
            sdf[1, :Station_ID],
            Vector{String}(string.(sdf.Tank_ID)),
            sdf[1, :Station_Name],
            nrow(sdf),
            Vector(sdf.Product_ID),
            f.(sdf.Capacity_L_),
            f.(sdf.Max_Stock_Level_L_),
            f.(sdf.Min_Stock_Level_L_),
            f.(sdf.Empty_Level_L_),
            f.(sdf.Known_Stock_Level_L_),
            f.(Matrix(sdf[:, day_cols])),
            Dict{Tuple{String,Int},Float64}()          # ω dual pr. tank
        )
    end for sdf in groupby(Stations_df, :Station_ID)
]

# Products
products_struct = [Product(
    p.ID,
    p.Name,
    Float64(p.Density_kg_L_)
) for p in eachrow(Products_df)]

# Shifts
shift_slots_struct = [ShiftSlot(
    r.Vehicle_ID,
    r.Day,
    r.Shift,
    r.Start_Min,
    r.End_Min,
    r.Duration_Min,
    0.0                      # π dual
) for r in eachrow(ShiftSlots_df)]





############################################################
# Lookups
############################################################
# Retunerer tid imellem 2 lokationer i minutter, konverteret fra sekunder i input-data
function get_time(from_id::Int, to_id::Int)
    from_label = (from_id == terminals.ID[1]) ? "Terminal" : string(from_id)
    to_label = (to_id == terminals.ID[1]) ? "Terminal" : string(to_id)

    i = time_index_map[from_label]
    j = time_index_map[to_label]

    return Times[i, j] / 60.0
end

# Hurtigt opslag: station_id til Station struct
function build_station_dict(stations_struct::Vector{Station})
    return Dict(s.id => s for s in stations_struct)
end

# Hurtigt opslag: vehicle_id - Vehicle struct
function build_vehicle_dict(vehicles_struct::Vector{Vehicle})
    return Dict(v.id => v for v in vehicles_struct)
end


# tager vehicle id og dag og returnerer shift slots for denne vehicle og dag
function build_shift_dict(shift_slots_struct::Vector{ShiftSlot})
    d = Dict{Tuple{Int,Int},Vector{ShiftSlot}}()
    for sh in shift_slots_struct
        key = (sh.vehicle_id, sh.day)
        if !haskey(d, key)
            d[key] = ShiftSlot[]
        end
        push!(d[key], sh)
    end
    return d
end

# Slå densitet op via products-data
function product_density(product_id::Int, product_dict)
    return product_dict[product_id].density
end

# retunerer (station_id, compartment_index) for en given tank_id
function build_tank_lookup(stations_struct::Vector{Station})
    tank_lookup = Dict{String,Tuple{Int,Int}}()
    for s in stations_struct
        for k in 1:s.num_compartments
            tank_lookup[s.id_tank[k]] = (s.id, k)
        end
    end
    return tank_lookup
end

# (vehicle_id, day, shift) -> ShiftSlot bruges i Q_algo til at hente én specifik π for (vehicle_id, day, shift)
function build_shift_lookup(shift_slots_struct::Vector{ShiftSlot})
    return Dict(
        (sh.vehicle_id, sh.day, sh.shift) => sh
        for sh in shift_slots_struct
    )
end


# Hurtigt opslag:
product_dict = Dict(p.id => p for p in products_struct)
vehicle_dict = build_vehicle_dict(vehicles_struct)
stations_dict = build_station_dict(stations_struct)
tank_lookup = build_tank_lookup(stations_struct)

# Shift-opslag:
shift_dict = build_shift_dict(shift_slots_struct)    # (vehicle_id, day) -> alle shifts, bruges i RMP
shift_lookup = build_shift_lookup(shift_slots_struct)  # (vehicle_id, day, shift) -> én shift, bruges i Q_algo til π




############################################################
# AVNS Weights Manager
############################################################
mutable struct AdaptiveManager
    k_max::Int
    weights::Vector{Float64}
    scores::Vector{Float64}
    usage::Vector{Int}
    visited_solutions::Set{UInt64}

    # Parameters extracted from params
    η::Float64
    σ_1::Float64
    σ_2::Float64
    σ_3::Float64
    segment_size::Int

    history::Vector{Vector{Float64}}

    # Constructor that pulls from your global params
    function AdaptiveManager(params)
        new(
            params.k_max,
            ones(params.k_max),
            zeros(params.k_max),
            zeros(Int, params.k_max),
            Set{UInt64}(),
            params.η,
            params.σ_1,
            params.σ_2,
            params.σ_3,
            params.segment_size,
            Vector{Vector{Float64}}()
        )
    end
end