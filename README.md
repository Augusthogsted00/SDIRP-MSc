# Dynamic Fuel Distribution Optimization: A Heuristic Column Generation Approach

[![Julia](https://img.shields.io/badge/Julia-1.9+-9558B2?logo=julia&logoColor=white)](https://julialang.org/)
[![Gurobi](https://img.shields.io/badge/Solver-Gurobi-red)](https://www.gurobi.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

This repository contains the official Julia implementation and model setup for the MSc. thesis titled **"Dynamic Fuel Distribution Optimization: A Heuristic Column Generation Approach"**, developed at the **Technical University of Denmark (DTU)** in collaboration with **AMCS Group**.

The project addresses the real-world operational challenges of large-scale fuel distribution in Denmark. By framing the problem as a **Stochastic Dynamic Inventory Routing Problem (SDIRP)**, the system optimizes both multi-compartment vehicle routing and multi-period fuel station inventory allocation under demand uncertainty.

### Key Case Study Features
* **Network Scope**: 1 central terminal (Aarhus C) supplying 59 fuel stations and 195 individual tanks across Jutland, Denmark.
* **Products**: 6 distinct fuel grades (e.g., INGO 92/95/Diesel, MILES 92/95/Diesel).
* **Fleet**: Heterogeneous fleet of multi-compartment tank trucks and trailers.
* **Planning Horizon**: Discretized rolling horizon framework evaluating cyclic daily demand patterns[cite: 1].

---

## Methodological Framework

The combinatorial complexity of solving simultaneous routing and inventory decisions under stochastic demand requires a decomposed, heuristic optimization framework[cite: 1]:
