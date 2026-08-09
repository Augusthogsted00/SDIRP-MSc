# Dynamic Fuel Distribution Optimization: A Heuristic Column Generation Approach

[![Julia](https://img.shields.io/badge/Julia-1.9+-9558B2?logo=julia&logoColor=white)](https://julialang.org/)
[![Gurobi](https://img.shields.io/badge/Solver-Gurobi-red)](https://www.gurobi.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

This repository contains the official Julia implementation and model setup for the MSc. thesis titled **"Dynamic Fuel Distribution Optimization: A Heuristic Column Generation Approach"**, developed at the **Technical University of Denmark (DTU)** in collaboration with **AMCS Group**.

The project addresses the real-world operational challenges of large-scale fuel distribution in Denmark. By framing the problem as a **Stochastic Dynamic Inventory Routing Problem (SDIRP)**, the system optimizes both multi-compartment vehicle routing and multi-period fuel station inventory allocation under demand uncertainty.

---

## Abstract

This thesis addresses the operational complexity of fuel distribution by modeling it as
a Stochastic Dynamic Inventory Routing Problem (SDIRP). Developed in collaboration
with AMCS Group, the study investigates a real-world distribution network in Denmark
comprising a single central terminal, 59 fuel stations, 195 individual tanks, and a heterogeneous
fleet of multi-compartment vehicles delivering six distinct fuel products. To
manage demand uncertainty and dynamic time horizons, the problem is formulated as a
Markov Decision Process (MDP) that utilizes a Direct Lookahead Approximation (DLA)
within a rolling horizon framework. Given the combinatorial complexity of simultaneous
routing and multi-compartment inventory allocation, the solution employs a Dantzig-
Wolfe decomposition handled via a Heuristic Column Generation (HCG) approach. The
underlying subproblems are solved using an Adaptive Variable Neighborhood Search
(AVNS) metaheuristic paired with a specialized quantity allocation heuristic. Computational
experiments demonstrate that lookahead-based planning significantly reduces
realized safety stock violations compared to myopic policies by enabling proactive replenishment
decisions. Ultimately, the findings indicate that a moderate lookahead horizon
effectively balances inventory performance with computational efficiency, though the operational
benefits of anticipatory planning remain fundamentally bounded by available
fleet capacity.
