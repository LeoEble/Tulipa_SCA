# Tulipa Supply Chain Analysis

A structured approach to **Supply Chain Analysis** for green hydrogen and e-methanol production using the [Tulipa](https://github.com/TulipaEnergy) energy modeling framework.

## Overview

This repository provides a complete example of using the **Tulipa Energy Model** to optimize investment and operational decisions for a Power-to-X (PtX) supply chain. The model determines the optimal capacity investments in renewable energy sources, storage systems, and conversion technologies to meet a methanol demand at minimum cost.

### What does this project do?

The main script ([src/main.jl](src/main.jl)) performs the following:

1. **Data Loading**: Reads input CSV files into a DuckDB in-memory database
2. **Profile Transformation**: Converts wide-format time series to long format
3. **Clustering**: Configures temporal representative periods (dummy or convex-hull clustering)
4. **Optimization**: Runs the energy system model via HiGHS or Gurobi to minimize total system cost
5. **Results Export**: Saves optimization outputs (flows, investments, storage levels, duals) to CSV
6. **Visualization**: Generates topology diagrams, investment charts, operations mass-balance plots, and LCOX analysis

---

## Case Study: Power-to-Methanol (PtX) Supply Chain

The case study models a **green methanol production system** projected to the year **2030**, relevant for decarbonizing shipping, aviation, and chemical industries.

### System Components

| Asset Type | Description |
|------------|-------------|
| **Wind** | Onshore wind turbines providing variable renewable electricity |
| **Solar** | Photovoltaic panels with daily generation patterns |
| **Market** | Grid connection for backup electricity supply |
| **Battery** | Short-term electricity storage (Li-ion) with ~90% round-trip efficiency |
| **Electrolyzer** | Converts electricity to hydrogen via water electrolysis |
| **H2 Storage** | Hydrogen buffer storage for flexible supply |
| **H2 Hub** | Distribution node for hydrogen flows |
| **CH3OH Synthesis** | Methanol reactor combining H₂ and CO₂ |
| **CO2 Source** | Carbon dioxide supply (captured or biogenic) |
| **CH3OH Storage** | Methanol buffer storage |
| **CH3OH Demand** | Final methanol demand node |

### Asset Flow Diagram

<img width="6345" height="1305" alt="Untitled diagram-2026-01-27-193016" src="https://github.com/user-attachments/assets/4c043964-d7e8-425e-aef5-25bd816129a6" />

#### How to view the topology diagram

1. Run the script to generate `outputs/asset_flow_chart.md`.
2. Install the **[Markdown Preview Mermaid Support](https://marketplace.visualstudio.com/items?itemName=bierner.markdown-mermaid)** extension in VSCode.
3. Open `outputs/asset_flow_chart.md` in VSCode and press `Ctrl+Shift+V` to preview.

### Key Input Data

- **Temporal Resolution**: 8760 hourly timesteps (full year 2030), optionally clustered into representative periods
- **Profiles**: Hourly availability factors for wind and solar, plus demand profiles
- **Investment Options**: Wind, Solar, Battery, Electrolyzer, H2 Storage, CH3OH Synthesis, CH3OH Storage

---

## Getting Started

### Prerequisites

- **Julia** v1.10 or later — [Download Julia](https://julialang.org/downloads/)
- **Git** — [Download Git](https://git-scm.com/downloads)

### 1. Clone the Repository

```bash
git clone https://github.com/LeoEble/Tulipa_SCA.git
cd Tulipa_SCA
```

### 2. Instantiate the Julia Environment

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
```

This installs all dependencies from `Project.toml`:

| Package | Purpose |
|---------|---------|
| `TulipaEnergyModel` v0.20 | Core JuMP-based optimization model |
| `TulipaIO` | CSV / DuckDB data input and output |
| `TulipaClustering` v0.5 | Temporal clustering for representative periods |
| `DuckDB` | In-process analytical database |
| `HiGHS` | Open-source LP/MIP solver (default) |
| `Gurobi` | Commercial solver (optional, requires licence) |
| `CairoMakie` | Publication-quality visualization |
| `DataFrames` | Tabular data manipulation |
| `Distances` | Distance metrics used in convex-hull clustering |

### 3. Run the Script

#### From the Julia REPL

```julia
include("src/main.jl")
```

#### From the command line

```bash
julia --project=. src/main.jl
```

#### With multi-threading (recommended for large problems)

```bash
julia --project=. --threads=auto src/main.jl
```

---

## Project Structure

```
Tulipa_SCA/
├── src/
│   ├── main.jl                  # Entry point — configure paths, call run & plot
│   ├── Tulipa_SCA.jl            # Module definition (loads all sub-files)
│   ├── tulipa_run.jl            # Full optimization workflow (DuckDB → HiGHS → CSV)
│   ├── utils/
│   │   ├── core_utils.jl        # DuckDB queries, data caching, hourly reconstruction
│   │   ├── asset_utils.jl       # Asset-level data helpers
│   │   ├── flow_utils.jl        # Flow aggregation helpers
│   │   ├── cost_utils.jl        # LCOX / CRF cost calculation utilities
│   │   └── menu_utils.jl        # Interactive menu-driven scenario setup
│   └── plots/
│       ├── topology_plots.jl    # Mermaid asset-flow chart generation
│       ├── operations_plots.jl  # Flow, storage, and mass-balance plots
│       └── cost_plots.jl        # Investment cost and LCOX analysis plots
├── data/
│   └── raw/
│       └── Methanol_V01/        # Main PtX case study input data
│           ├── asset.csv                  # Asset definitions (type, capacity)
│           ├── asset-milestone.csv        # Investment options per milestone year
│           ├── asset-commission.csv       # Costs and efficiencies per commission year
│           ├── asset-both.csv             # Initial installed units
│           ├── flow.csv                   # Network topology (asset connections)
│           ├── flows-relationships.csv    # Stoichiometric flow ratios (H₂:CO₂)
│           ├── profiles-wide.csv          # Time series (wind, solar, demand)
│           ├── year-data.csv              # Modelling horizon
│           └── model-parameters.toml      # Global solver and model settings
├── outputs/                     # Generated after running (gitignored)
│   ├── var_assets_investment.csv
│   ├── var_flow.csv
│   ├── var_storage_level_rep_period.csv
│   ├── cons_*.csv               # Dual values / constraint validation
│   ├── asset_flow_chart.md      # Mermaid topology source
│   ├── lcox_analysis.png        # LCOX waterfall / breakdown chart
│   ├── flows.png                # Operations mass-balance line charts
│   ├── total_flow.png           # Aggregated flow bar chart
│   └── storage_level.png        # Storage state-of-charge over time
├── Project.toml                 # Julia dependency manifest
└── utils.jl                     # Legacy monolithic script (superseded by src/)
```

---

## Output Files

| File | Description |
|------|-------------|
| `var_assets_investment.csv` | Optimal invested capacity per asset and milestone year |
| `var_flow.csv` | Energy/material flows per timestep and representative period |
| `var_storage_level_rep_period.csv` | Storage state-of-charge per representative period |
| `cons_balance_*.csv` | Shadow prices for energy/material balance constraints |
| `cons_capacity_*.csv` | Shadow prices for capacity constraints |
| `asset_flow_chart.md` | Mermaid diagram source for interactive topology preview |
| `lcox_analysis.png` | Levelized Cost of X (LCOX) breakdown by cost component |
| `flows.png` | Mass-balance line charts for key assets (summer/winter days) |
| `total_flow.png` | Aggregated annual flows per asset connection |
| `storage_level.png` | Storage level trajectories over representative periods |

---

## Representative Periods

The model supports two temporal configurations, set via `num_rps` in `src/main.jl`:

| Mode | `num_rps` | Description |
|------|-----------|-------------|
| Full year | `1` | `TC.dummy_cluster!` — one period covering all 8760 hours |
| Clustered | `> 1` | `TC.cluster!` with convex-hull method and cosine distance |

Results from clustered runs are automatically reconstructed to the full 8760-hour timeframe for plotting via `reconstruct_to_timeframe`.

---

## Customization

To adapt the model for your own case study:

1. Copy one of the folders under `data/raw/` and modify the CSVs for your assets and network.
2. Update `db_path`, `input_dir`, and `output_dir` in `src/main.jl`.
3. Adjust `num_rps` and `period_duration` for your desired temporal resolution.
4. Add or remove plot calls in `src/main.jl` as needed.

---

## Learn More

- [TulipaEnergyModel.jl Documentation](https://tulipaenergy.github.io/TulipaEnergyModel.jl/stable/)
- [Tulipa GitHub Organization](https://github.com/TulipaEnergy)
- [HiGHS Solver](https://highs.dev/)

---

## License

This project is licensed under the Apache License 2.0 — see the [LICENSE](LICENSE.txt) file for details.
