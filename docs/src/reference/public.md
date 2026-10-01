# [Public API Reference](@id api)

```@autodocs
Modules = [PowerGraphics]
Public = true
Private = false
Filter = t -> !(
    startswith(string(nameof(t)), "plot_powerdata") ||
    occursin("_plotly", string(nameof(t)))
)
```

## Deprecated

These functions still work but emit a deprecation warning and will be removed in
a future breaking release.

  - `_plotly`-suffixed functions: use the un-suffixed function with
    `backend = PlotlyLightBackend()`, e.g. [`plot_fuel`](@ref)`(res; backend = PlotlyLightBackend())`.
  - `plot_powerdata` family: use [`plot_results`](@ref) with a
    `Dict{String, DataFrame}` (or [`plot_dataframe`](@ref) for a single `DataFrame`).

```@autodocs
Modules = [PowerGraphics]
Public = true
Private = false
Filter = t -> (
    startswith(string(nameof(t)), "plot_powerdata") ||
    occursin("_plotly", string(nameof(t)))
)
```
