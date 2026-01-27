# Tulipa Supply Chain Analysis

A structured approach to **Supply Chain Analysis** for green hydrogen and e-methanol production using the [Tulipa](https://github.com/TulipaEnergy) energy modeling framework.

## 📋 Overview

This repository provides a complete example of using the **Tulipa Energy Model** to optimize investment and operational decisions for a Power-to-X (PtX) supply chain. The model determines the optimal capacity investments in renewable energy sources, storage systems, and conversion technologies to meet a methanol demand at minimum cost.

### What does this project do?

The main script ([Tulipa_SCA.jl](Tulipa_SCA.jl)) performs the following:

1. **Data Loading**: Reads input data from CSV files into a DuckDB database
2. **Profile Transformation**: Converts wide-format time series data to long format for the model
3. **Clustering Setup**: Prepares temporal data structures (uses dummy clustering for full year resolution)
4. **Optimization**: Runs an energy system optimization using the HiGHS solver to minimize total system costs
5. **Results Export**: Saves optimization results (flows, investments, storage levels, constraints) to CSV files
6. **Visualization**: Generates bar charts showing investment decisions, energy flows, and storage levels

---

## 🔬 Case Study Description

### Power-to-Methanol (PtX) Supply Chain

The case study models a **green methanol production system** projected to the year **2030**. This is relevant for decarbonizing shipping, aviation, and chemical industries.

#### System Components

| Asset Type | Description |
|------------|-------------|
| **Wind** | Onshore wind turbines providing variable renewable electricity |
| **Solar** | Photovoltaic panels with daily generation patterns |
| **Market** | Grid connection for backup electricity supply |
| **Battery** | Short-term electricity storage (Li-ion) with 90% round-trip efficiency |
| **Electrolyzer** | Converts electricity to hydrogen via water electrolysis |
| **H2 Storage** | Hydrogen buffer storage for flexible supply |
| **H2 Hub** | Distribution node for hydrogen flows |
| **CH3OH Synthesis** | Methanol reactor combining H₂ and CO₂ |
| **CO2 Source** | Carbon dioxide supply (captured or biogenic) |
| **CH3OH Storage** | Methanol buffer storage |
| **CH3OH Demand** | Final methanol demand |

#### Asset Flow Diagram

<img width="6345" height="1305" alt="Untitled diagram-2026-01-27-193016" src="https://github.com/user-attachments/assets/4c043964-d7e8-425e-aef5-25bd816129a6" />


#### How to view the topology diagram

1. Run the script to generate the `asset_flow_chart.md` file.
2. Install the **[Markdown Preview Mermaid Support](https://marketplace.visualstudio.com/items?itemName=bierner.markdown-mermaid)** extension in VSCode.
3. Open `asset_flow_chart.md` in VSCode.
4. Open the Markdown Preview (`Ctrl+Shift+V` or `Cmd+Shift+V`) to see the interactive flow and connection diagram.

#### Key Input Data

- **Temporal Resolution**: 8760 hourly timesteps (full year 2030)
- **Profiles**: Hourly availability factors for wind and solar, plus demand profiles
- **Investment Options**: Wind, Solar, Battery, Electrolyzer, H2 Storage, CH3OH Synthesis, CH3OH Storage.

---

## 🚀 Getting Started

### Prerequisites

- **Julia** (v1.9 or later recommended) — [Download Julia](https://julialang.org/downloads/)
- **Git** — [Download Git](https://git-scm.com/downloads)

### 1. Clone the Repository

Open a terminal and run:

```bash
git clone https://github.com/LeoEble/Tulipa_SCA.git
cd Tulipa_SCA
```

### 2. Instantiate the Julia Environment

Start Julia in the project directory and activate the environment:

```julia
# Start Julia from the project folder, then run:
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

This will download and install all required dependencies listed in `Project.toml`:
- `TulipaEnergyModel` (v0.19) — Core optimization model
- `TulipaIO` — Data input/output utilities
- `TulipaClustering` (v0.5) — Temporal clustering tools
- `DuckDB` — In-memory database
- `HiGHS` — Open-source linear programming solver
- `CairoMakie` — Visualization library
- `DataFrames` — Data manipulation

### 3. Run the Script

#### Option A: From Julia REPL

```julia
include("Tulipa_SCA.jl")
```

#### Option B: From Command Line

```bash
julia --project=. Tulipa_SCA.jl
```

#### Option C: With Increased Memory (for large problems)

```bash
julia --project=. --threads=auto Tulipa_SCA.jl
```

---

## 📁 Project Structure

```
Tulipa_SCA/
├── Tulipa_SCA.jl          # Main script
├── Project.toml           # Julia dependencies
├── sca_model.lp           # Exported LP model (after running)
├── data/
│   ├── raw/               # Input CSV files
│   │   ├── asset.csv              # Asset definitions (type, capacity)
│   │   ├── asset-milestone.csv    # Investment options per milestone year
│   │   ├── asset-commission.csv   # Costs and efficiencies
│   │   ├── asset-both.csv         # Initial units
│   │   ├── flow.csv               # Connection topology
│   │   ├── flow-*.csv             # Flow parameters
│   │   ├── flows-relationships.csv# Stoichiometric constraints (H₂:CO₂ ratio)
│   │   ├── profiles-wide.csv      # Time series (wind, solar, demand)
│   │   ├── year-data.csv          # Modeling horizon
│   │   └── model-parameters.toml  # Global parameters
│   └── db/                # DuckDB database files (generated)
├── outputs/               # Results (generated after running)
│   ├── var_assets_investment.csv
│   ├── var_flow.csv
│   ├── var_storage_level_rep_period.csv
│   ├── asset_flow_chart.md # Mermaid topology diagram
│   └── *.png              # Visualization plots
└── utils/
    └── utils.jl           # Plotting helper functions
```

---

## 📊 Output Files

After running the script, the `outputs/` folder contains:

| File | Description |
|------|-------------|
| `var_assets_investment.csv` | Optimal capacity investments per asset |
| `var_flow.csv` | Hourly energy/material flows between assets |
| `var_storage_level_rep_period.csv` | Storage state-of-charge over time |
| `cons_*.csv` | Constraint validation (balances, capacities) |
| `assets_investment.png` | Bar chart of investment decisions |
| `total_flow.png` | Bar chart of aggregated flows |
| `storage_level.png` | Storage level visualization |
| `flows.png` | A set of line charts that exhibit operations |
| `asset_flow_chart.md` | Mermaid diagram source for topological preview |

---

## 🔧 Customization

To adapt the model for your own case study:

1. **Modify asset definitions** in `data/raw/asset.csv` and related files
1. **Modify asset connections** in `data/raw/flow.csv` and related files
1. **Update profiles** in `data/raw/profiles-wide.csv` with your time series
1. **Adjust costs and efficiencies** in `data/raw/asset-commission.csv`
1. **Change the modeling horizon** in `data/raw/year-data.csv`

---

## 📚 Learn More

- [TulipaEnergyModel.jl Documentation](https://tulipaenergy.github.io/TulipaEnergyModel.jl/stable/)
- [Tulipa GitHub Organization](https://github.com/TulipaEnergy)
- [HiGHS Solver](https://highs.dev/)

---

## 📄 License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE.txt) file for details.
