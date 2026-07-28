function _empty_plot()
    return _empty_plot(CairoMakieBackend())
end

function _empty_plot_plotly()
    return _empty_plot(PlotlyLightBackend())
end

function popkwargs(kwargs, kwarg)
    return Dict{Symbol, Any}((k, v) for (k, v) in kwargs if k ≠ kwarg)
end

# A CairoMakie plot is displayed through its `Figure`; a PlotlyLight plot is
# displayed directly. Dispatching keeps the backend split out of plot bodies.
_display_plot(::CairoMakieBackend, p) = display(p.figure)
_display_plot(::PlotlyLightBackend, p) = display(p)

################################### X AXIS #################################

# Plot x axes are normally `DateTime`, but the transform plots (duration curve,
# histogram) hand the recipes a plain numeric axis instead. Dispatching on the
# axis element type lets both backends share one code path while leaving the
# temporal behavior untouched.
_is_temporal(::AbstractVector{<:Dates.TimeType}) = true
_is_temporal(::AbstractVector) = false

_time_vector(time_range::DataFrames.DataFrame) = time_range[:, 1]
_time_vector(time_range) = collect(time_range)

# A temporal axis labels itself with the span it covers; a numeric axis has no
# such span and relies on the `x_label` kwarg.
function _x_axis_label(time_range::AbstractVector{<:Dates.TimeType}, x_label)
    span = IS.convert_compound_period(length(time_range) * (time_range[2] - time_range[1]))
    return something(x_label, "$span")
end
_x_axis_label(::AbstractVector, x_label) = something(x_label, "")

# Bar plots over time report energy, so per-timestep values are divided by the
# number of samples per hour. Off a time axis there is nothing to normalize by.
function _x_interval(time_range::AbstractVector{<:Dates.TimeType})
    return Dates.Millisecond(Dates.Hour(1)) /
           Dates.Millisecond(time_range[2] - time_range[1])
end
_x_interval(::AbstractVector) = 1.0

# CairoMakie needs float axes throughout (`band` rejects `DateTime`), so a
# temporal axis is converted to unix seconds.
_x_values(time_range::AbstractVector{<:Dates.TimeType}) = Dates.datetime2unix.(time_range)
_x_values(time_range::AbstractVector) = float.(time_range)

# Translation table for the user-facing `aggregate::String` kwarg of
# `plot_demand` to the typed `aggregation::Type` kwarg expected by
# `PowerAnalytics.get_load_data(::PSY.System; aggregation = …)`. The
# `IS.Results` branch of `get_load_data` ignores `aggregation` entirely, so
# the translation is a safe no-op there.
const _AGGREGATE_STRING_TO_TYPE =
    Dict("System" => PSY.System, "Bus" => PSY.ACBus, "PowerLoad" => PSY.PowerLoad)

function _aggregate_to_type(s::AbstractString)
    haskey(_AGGREGATE_STRING_TO_TYPE, s) || throw(
        ArgumentError(
            "Unknown `aggregate` value $(repr(s)). " *
            "Valid options: $(collect(keys(_AGGREGATE_STRING_TO_TYPE))).",
        ),
    )
    return _AGGREGATE_STRING_TO_TYPE[s]
end

# An already-typed `aggregate` (e.g. `PSY.ACBus`) is passed through unchanged.
_aggregate_to_type(t::Type) = t

# Translate `:aggregate => "System" | "Bus" | "PowerLoad"` (if present) into
# the typed `:aggregation` kwarg PowerAnalytics expects. Returns a fresh
# `Dict{Symbol,Any}` regardless so callers can keep mutating it.
function _translate_demand_aggregate(kwargs)
    out = Dict{Symbol, Any}(kwargs)
    (haskey(out, :aggregate) && !isnothing(out[:aggregate])) || return out
    out[:aggregation] = _aggregate_to_type(out[:aggregate])
    delete!(out, :aggregate)
    return out
end

"""
Pick a power unit and scaling divisor from the peak magnitude of the plotted
totals (values are assumed to be in MW): `< 1e3 → MW`, `[1e3, 1e6) → GW`,
`≥ 1e6 → TW`. Returns `(divisor, unit_string)`.
"""
function _auto_power_unit(peak::Real)
    a = abs(float(peak))
    if a >= 1.0e6
        return (1.0e6, "TW")
    elseif a >= 1.0e3
        return (1.0e3, "GW")
    else
        return (1.0, "MW")
    end
end

"""
Resolve the y-axis label and data-scaling divisor for a fuel/generation plot.
Honors an explicit `:y_label` or `:power_scale` kwarg; otherwise auto-detects
MW/GW/TW from the peak stacked total of `df`, unless `:auto_units => false` or
`:bar => true` (energy bar plots keep the existing MWh behavior).
"""
function _resolve_power_units(df::DataFrames.DataFrame, kwargs)
    bar = get(kwargs, :bar, false)
    user_scale = get(kwargs, :power_scale, nothing)
    user_ylabel = get(kwargs, :y_label, nothing)
    if bar || !get(kwargs, :auto_units, true) || !isnothing(user_scale)
        divisor = something(user_scale, 1.0)
        unit = bar ? "MWh" : "MW"
    else
        mat = Matrix(PA.no_datetime(df))
        peak = if isempty(mat)
            0.0
        else
            # stacked plots: peak is the largest per-timestep positive total;
            # also guard against a single dominant (possibly negative) series.
            max(
                maximum(sum(x -> max(x, 0.0), mat; dims = 2)),
                maximum(abs, mat),
            )
        end
        divisor, unit = _auto_power_unit(peak)
    end
    return (something(user_ylabel, unit), divisor)
end

"""
Per-series `(lower, upper)` envelopes for a sign-aware stacked-area/line plot.
`data` is `time × series`. Positive values stack **upward** from 0, negative
values (e.g. storage charging or source input via `ActivePowerInVariable`) stack **downward**
from 0, so charging renders below the zero axis instead of being folded into the
positive generation stack. Returns `(lower, upper)` matrices the same size as
`data`; band `ix` is `[lower[:,ix], upper[:,ix]]`.
"""
function _signed_stack_bounds(data::AbstractMatrix)
    nt, ns = size(data)
    lower = zeros(eltype(data), nt, ns)
    upper = zeros(eltype(data), nt, ns)
    pos = zeros(eltype(data), nt)
    neg = zeros(eltype(data), nt)
    # Classify each *series* (not each value) by its net sign, matching the
    # PlotlyLight backend's `sign_group`. A positive-type series always stacks
    # on the positive baseline — even at timesteps where it is 0 (e.g. PV at
    # night) it keeps a zero-width band *in place* rather than jumping to the
    # negative baseline (which left whitespace holes / slash lines). Negative-
    # type series (e.g. storage charging, source input) always stack downward from 0.
    for ix in 1:ns
        series_negative = sum(@view data[:, ix]) < zero(eltype(data))
        for t in 1:nt
            v = data[t, ix]
            if series_negative
                upper[t, ix] = neg[t]
                lower[t, ix] = neg[t] + v
                neg[t] = lower[t, ix]
            else
                lower[t, ix] = pos[t]
                upper[t, ix] = pos[t] + v
                pos[t] = upper[t, ix]
            end
        end
    end
    return lower, upper
end

################################### DEMAND #################################

"""
    plot_demand(results)
    plot_demand(system)

Plots the demand in the system.

# Arguments

- `res::Union{`[`InfrastructureSystems.Results`](@extref)`, `[`PowerSystems.System`](@extref)`}`: 
    A `Results` object (e.g., [`PowerSimulations.SimulationProblemResults`](@extref))
    or [`PowerSystems.System`](@extref) to plot the demand from

# Example

```julia
res = PowerSimulations.solve_op_problem!(OpProblem)
plot = plot_demand(res)
```

# Accepted Key Words

- `linestyle::Symbol = :dash` : set line style
- `title::String`: Set a title for the plots
- `horizon::Int64`: To plot a shorter window of time than the full results
- `initial_time::DateTime`: To start the plot at a different time other than the results initial time
- `aggregate::String = "System", "PowerLoad", or "Bus"`: aggregate the demand other than by generator
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
- `filter_func::Function = `[`PowerSystems.get_available`](@extref PowerSystems InfrastructureSystems.get_available-Tuple{RenewableDispatch}): filter components included in plot
"""  # ^ temporary workaround for https://github.com/Sienna-Platform/PowerSystems.jl/issues/1598
function plot_demand(result::Union{IS.Results, PSY.System}; kwargs...)
    return plot_demand!(_empty_plot(), result; kwargs...)
end

@doc (@doc plot_demand) function plot_demand_plotly(
    result::Union{IS.Results, PSY.System};
    kwargs...,
)
    return plot_demand_plotly!(_empty_plot_plotly(), result; kwargs...)
end

function _plot_demand!(p, result::Union{IS.Results, PSY.System}, backend; kwargs...)
    set_display = get(kwargs, :set_display, true)
    save_fig = get(kwargs, :save, nothing)
    bar = get(kwargs, :bar, false)

    title = get(kwargs, :title, "Demand")
    y_label = get(kwargs, :y_label, bar ? "MWh" : "MW")
    palette = get(kwargs, :palette, PALETTE)

    # Translate the user-facing `aggregate::String` kwarg into PA's typed
    # `aggregation` kwarg before calling `get_load_data`.
    kwargs = _translate_demand_aggregate(kwargs)
    load = PA.get_load_data(result; kwargs...)
    # Build a mutable copy with defaults so we splat exactly once below.
    kwargs = popkwargs(kwargs, :filter_func)
    # Optional per-timestep load added to demand (e.g. storage charging or source
    # input, so the net-load line matches the top of the generation stack in `plot_fuel!`).
    extra_load = get(kwargs, :extra_load, nothing)
    kwargs = popkwargs(kwargs, :extra_load)
    linestyle = get(kwargs, :linestyle, :solid)
    kwargs[:linestyle] = Symbol(linestyle)
    kwargs[:line_dash] = string(linestyle)
    kwargs[:linewidth] = get(kwargs, :linewidth, 1)
    kwargs[:seriescolor] =
        get(kwargs, :seriescolor, get_palette_seriescolor(backend, palette))

    load_agg = PA.combine_categories(load.data)

    if isnothing(load_agg)
        throw(ErrorException("No load data found"))
    end

    if !isnothing(extra_load)
        el = collect(extra_load)
        for c in DataFrames.names(load_agg)
            length(el) == DataFrames.nrow(load_agg) || throw(
                DimensionMismatch(
                    "extra_load length $(length(el)) != demand rows $(DataFrames.nrow(load_agg))",
                ),
            )
            load_agg[!, c] = load_agg[!, c] .+ el
        end
    end

    p = _plot_dataframe!(
        p,
        load_agg,
        load.time,
        backend;
        y_label = y_label,
        set_display = false,
        title = title,
        kwargs...,
    )

    set_display && _display_plot(backend, p)
    if !isnothing(save_fig)
        title = replace(title, " " => "_")
        format = get(kwargs, :format, "png")
        save_plot(p, joinpath(save_fig, "$title.$format"), backend; kwargs...)
    end
    return p
end

"""
    plot_demand!(plot, result)
    plot_demand!(plot, system)
    plot_demand_plotly!(plot, result)
    plot_demand_plotly!(plot, system)

Plots the demand in the system onto an existing plot handle. The `!`-form mutates
or extends `plot`; the `_plotly` variants render with the PlotlyLight backend
instead of CairoMakie.

# Arguments

- `plot`: existing plot handle returned by a previous PowerGraphics plot call such as [`plot_demand`](@ref PowerGraphics.plot_demand)
- `res::Union{`[`InfrastructureSystems.Results`](@extref)`, `[`PowerSystems.System`](@extref)`}`:
    A `Results` object (e.g., [`PowerSimulations.SimulationProblemResults`](@extref))
    or [`PowerSystems.System`](@extref) to plot the demand from

# Accepted Key Words

- `linestyle::Symbol = :dash` : set line style
- `title::String`: Set a title for the plots
- `horizon::Int64`: To plot a shorter window of time than the full results
- `initial_time::DateTime`: To start the plot at a different time other than the results initial time
- `aggregate::String = "System", "PowerLoad", or "Bus"`: aggregate the demand by
    [`PowerSystems.System`](@extref), [`PowerSystems.PowerLoad`](@extref), or [`PowerSystems.Bus`](@extref),
    rather than by generator
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
- `filter_func::Function = `[`PowerSystems.get_available`](@extref PowerSystems InfrastructureSystems.get_available-Tuple{RenewableDispatch}): filter components included in plot
- `palette` : color palette from [`load_palette`](@ref)
"""
function plot_demand!(p, result::Union{IS.Results, PSY.System}; kwargs...)
    return _plot_demand!(p, result, CairoMakieBackend(); kwargs...)
end

@doc (@doc plot_demand!) function plot_demand_plotly!(
    p,
    result::Union{IS.Results, PSY.System};
    kwargs...,
)
    return _plot_demand!(p, result, PlotlyLightBackend(); kwargs...)
end

################################# Plotting a Single DataFrame ##########################

"""
    plot_dataframe(df)
    plot_dataframe(df, time_range)

Plots data from a [`DataFrames.DataFrame`](@extref) where each row represents a time period
and each column represents a trace

# Arguments

- `df::DataFrames.DataFrame`: `DataFrame` where each row represents a time period and each column represents a trace.
If only the `DataFrame` is provided, it must have a column of `DateTime` values.
- `time_range::Union{DataFrames.DataFrame, Array, StepRange}`: The time periods of the data

# Example

```julia
var_name = :P__ThermalStandard
df = PowerSimulations.read_variables_with_keys(results, names = [var_name])[var_name]
time_range = PowerSimulations.get_realized_timestamps(results)
plot = plot_dataframe(df, time_range)
```

# Accepted Key Words
- `curtailment::Bool`: plot the curtailment with the variable
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_dataframe(df::DataFrames.DataFrame; kwargs...)
    return plot_dataframe!(_empty_plot(), PA.no_datetime(df), df.DateTime; kwargs...)
end
function plot_dataframe(
    df::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return plot_dataframe!(_empty_plot(), df, time_range; kwargs...)
end

@doc (@doc plot_dataframe) function plot_dataframe_plotly(
    df::DataFrames.DataFrame;
    kwargs...,
)
    return plot_dataframe_plotly!(
        _empty_plot_plotly(),
        PA.no_datetime(df),
        df.DateTime;
        kwargs...,
    )
end
function plot_dataframe_plotly(
    df::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return plot_dataframe_plotly!(_empty_plot_plotly(), df, time_range; kwargs...)
end

function _plot_dataframe!(
    p,
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange},
    backend;
    kwargs...,
)
    return _dataframe_plots_internal(
        p,
        variable,
        _time_vector(time_range),
        backend;
        kwargs...,
    )
end

"""
    plot_dataframe!(plot, df)
    plot_dataframe!(plot, df, time_range)
    plot_dataframe_plotly!(plot, df)
    plot_dataframe_plotly!(plot, df, time_range)

Plots data from a [`DataFrames.DataFrame`](@extref) where each row represents a time
period and each column represents a trace, onto an existing plot handle. The
`_plotly` variants render with the PlotlyLight backend instead of CairoMakie.

# Arguments

- `plot`: existing plot handle returned by a previous PowerGraphics plot call (e.g. [`plot_dataframe`](@ref))
- `df::DataFrames.DataFrame`: `DataFrame` where each row represents a time period and each column represents a trace.
If only the `DataFrame` is provided, it must have a column of `DateTime` values.
- `time_range::Union{DataFrames.DataFrame, Array, StepRange}`: The time periods of the data

# Accepted Key Words
- `curtailment::Bool`: plot the curtailment with the variable
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_dataframe!(p, df::DataFrames.DataFrame; kwargs...)
    return _plot_dataframe!(
        p,
        PA.no_datetime(df),
        df.DateTime,
        CairoMakieBackend();
        kwargs...,
    )
end

function plot_dataframe!(
    p,
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return _plot_dataframe!(p, variable, time_range, CairoMakieBackend(); kwargs...)
end

@doc (@doc plot_dataframe!) function plot_dataframe_plotly!(
    p,
    df::DataFrames.DataFrame;
    kwargs...,
)
    return _plot_dataframe!(
        p,
        PA.no_datetime(df),
        df.DateTime,
        PlotlyLightBackend();
        kwargs...,
    )
end

function plot_dataframe_plotly!(
    p,
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return _plot_dataframe!(p, variable, time_range, PlotlyLightBackend(); kwargs...)
end

################################# Duration Curve ##############################

# Elapsed hours since the first sample. A non-temporal axis has no clock to read
# from, so the sample index stands in for it.
function _elapsed_hours(time_range::AbstractVector{<:Dates.TimeType})
    t0 = first(time_range)
    return [Dates.value(Dates.Millisecond(t - t0)) / 3.6e6 for t in time_range]
end
_elapsed_hours(time_range::AbstractVector) = collect(0.0:(length(time_range) - 1))

"""
X values and default x label for a duration curve, given the `x_axis` mode and
the time axis the data was sampled on.
"""
function _duration_curve_x(x_axis::Symbol, time_range::AbstractVector)
    if x_axis === :percent
        # `range` rejects `length = 1` between distinct endpoints, so a degenerate
        # axis (a single sample, or none) gets its percentages directly.
        n = length(time_range)
        percent = n > 1 ? collect(range(0.0, 100.0; length = n)) : zeros(n)
        return (percent, "Percent of time")
    elseif x_axis === :hours
        return (_elapsed_hours(time_range), "Hours")
    else
        throw(
            ArgumentError(
                "Unknown `x_axis` value $(repr(x_axis)). Valid options: :percent, :hours.",
            ),
        )
    end
end

"""
    plot_duration_curve(df)
    plot_duration_curve(df, time_range)

Plots a duration curve from a [`DataFrames.DataFrame`](@extref): each column is sorted
descending on its own and drawn against the fraction of time (or the number of hours)
its value is met or exceeded.

# Arguments

- `df::DataFrames.DataFrame`: `DataFrame` where each row represents a time period and each column represents a trace.
If only the `DataFrame` is provided, it must have a column of `DateTime` values.
- `time_range::Union{DataFrames.DataFrame, Array, StepRange}`: The time periods of the data

# Example

```julia
var_name = :ActivePowerVariable__ThermalStandard
df = PowerSimulations.read_realized_variable(results, var_name)
plot = plot_duration_curve(df; x_axis = :hours)
```

# Accepted Key Words
- `x_axis::Symbol = :percent`: `:percent` for 0–100% of the time span, or `:hours` for elapsed hours
- `x_label::String`: override the x-axis label (defaults to `"Percent of time"` or `"Hours"`)
- `y_label::String`: label for the y axis
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `palette` : color palette from [`load_palette`](@ref)
- `title::String = "Title"`: Set a title for the plots
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_duration_curve(df::DataFrames.DataFrame; kwargs...)
    return plot_duration_curve!(_empty_plot(), PA.no_datetime(df), df.DateTime; kwargs...)
end

function plot_duration_curve(
    df::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return plot_duration_curve!(_empty_plot(), df, time_range; kwargs...)
end

@doc (@doc plot_duration_curve) function plot_duration_curve_plotly(
    df::DataFrames.DataFrame;
    kwargs...,
)
    return plot_duration_curve_plotly!(
        _empty_plot_plotly(),
        PA.no_datetime(df),
        df.DateTime;
        kwargs...,
    )
end

function plot_duration_curve_plotly(
    df::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return plot_duration_curve_plotly!(_empty_plot_plotly(), df, time_range; kwargs...)
end

function _plot_duration_curve!(
    p,
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange},
    backend;
    kwargs...,
)
    ndf = PA.no_datetime(variable)
    # Each column is ranked independently: a duration curve answers "how often is
    # *this* series above a level", not "what did the system look like at time t".
    sorted = DataFrames.DataFrame([
        name => sort(ndf[!, name]; rev = true) for name in DataFrames.names(ndf)
    ])
    x, default_x_label =
        _duration_curve_x(get(kwargs, :x_axis, :percent), _time_vector(time_range))
    x_label = get(kwargs, :x_label, default_x_label)
    kwargs = popkwargs(popkwargs(kwargs, :x_axis), :x_label)
    return _plot_dataframe!(p, sorted, x, backend; x_label = x_label, kwargs...)
end

"""
    plot_duration_curve!(plot, df)
    plot_duration_curve!(plot, df, time_range)
    plot_duration_curve_plotly!(plot, df)
    plot_duration_curve_plotly!(plot, df, time_range)

Plots a duration curve from a [`DataFrames.DataFrame`](@extref) onto an existing plot
handle. The `_plotly` variants render with the PlotlyLight backend instead of CairoMakie.

# Arguments

- `plot`: existing plot handle returned by a previous PowerGraphics plot call (e.g. [`plot_duration_curve`](@ref))
- `df::DataFrames.DataFrame`: `DataFrame` where each row represents a time period and each column represents a trace.
If only the `DataFrame` is provided, it must have a column of `DateTime` values.
- `time_range::Union{DataFrames.DataFrame, Array, StepRange}`: The time periods of the data

# Accepted Key Words
- `x_axis::Symbol = :percent`: `:percent` for 0–100% of the time span, or `:hours` for elapsed hours
- `x_label::String`: override the x-axis label (defaults to `"Percent of time"` or `"Hours"`)
- `y_label::String`: label for the y axis
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `palette` : color palette from [`load_palette`](@ref)
- `title::String = "Title"`: Set a title for the plots
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_duration_curve!(p, df::DataFrames.DataFrame; kwargs...)
    return _plot_duration_curve!(
        p,
        PA.no_datetime(df),
        df.DateTime,
        CairoMakieBackend();
        kwargs...,
    )
end

function plot_duration_curve!(
    p,
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return _plot_duration_curve!(p, variable, time_range, CairoMakieBackend(); kwargs...)
end

@doc (@doc plot_duration_curve!) function plot_duration_curve_plotly!(
    p,
    df::DataFrames.DataFrame;
    kwargs...,
)
    return _plot_duration_curve!(
        p,
        PA.no_datetime(df),
        df.DateTime,
        PlotlyLightBackend();
        kwargs...,
    )
end

function plot_duration_curve_plotly!(
    p,
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return _plot_duration_curve!(p, variable, time_range, PlotlyLightBackend(); kwargs...)
end

#################################### Histogram ################################

# Sturges' rule, the default bin count.
_sturges(n::Integer) = ceil(Int, log2(max(n, 1))) + 1

"""
Bin every column of `data` over one common edge range so the overlaid series stay
comparable. Returns `(centers, counts)`, where `counts` is `bins × series`.
"""
function _histogram_bins(data::AbstractMatrix, bins::Int)
    bins > 0 || throw(ArgumentError("`bins` must be positive, got $bins."))
    lo, hi = float(minimum(data)), float(maximum(data))
    # A degenerate range (every sample identical) would give zero-width bins.
    if lo == hi
        lo -= 0.5
        hi += 0.5
    end
    width = (hi - lo) / bins
    centers = [lo + (ix - 0.5) * width for ix in 1:bins]
    counts = zeros(Int, bins, size(data, 2))
    for col in 1:size(data, 2), value in view(data, :, col)
        # The top bin is closed on the right so the maximum sample is not dropped.
        counts[min(floor(Int, (value - lo) / width) + 1, bins), col] += 1
    end
    return centers, counts
end

"""
    plot_histogram(df)
    plot_histogram(df, time_range)

Plots the value distribution of each column of a [`DataFrames.DataFrame`](@extref) as an
overlaid histogram. All columns share one set of bin edges so their distributions can be
compared directly.

# Arguments

- `df::DataFrames.DataFrame`: `DataFrame` where each row represents a time period and each column represents a trace.
If only the `DataFrame` is provided, it must have a column of `DateTime` values.
- `time_range::Union{DataFrames.DataFrame, Array, StepRange}`: The time periods of the data. Ignored except to
identify the `DateTime` column, since a histogram has no time axis.

# Example

```julia
var_name = :ActivePowerVariable__ThermalStandard
df = PowerSimulations.read_realized_variable(results, var_name)
plot = plot_histogram(df; bins = 20)
```

# Accepted Key Words
- `bins::Int`: number of bins; defaults to Sturges' rule, `ceil(Int, log2(n)) + 1`
- `x_label::String`: label for the x axis; defaults to the column label when there is only one series
- `y_label::String = "Count"`: label for the y axis
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `palette` : color palette from [`load_palette`](@ref)
- `title::String = "Title"`: Set a title for the plots
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_histogram(df::DataFrames.DataFrame; kwargs...)
    return plot_histogram!(_empty_plot(), PA.no_datetime(df); kwargs...)
end

function plot_histogram(
    df::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return plot_histogram!(_empty_plot(), df, time_range; kwargs...)
end

@doc (@doc plot_histogram) function plot_histogram_plotly(
    df::DataFrames.DataFrame;
    kwargs...,
)
    return plot_histogram_plotly!(_empty_plot_plotly(), PA.no_datetime(df); kwargs...)
end

function plot_histogram_plotly(
    df::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return plot_histogram_plotly!(_empty_plot_plotly(), df, time_range; kwargs...)
end

function _plot_histogram!(p, variable::DataFrames.DataFrame, backend; kwargs...)
    ndf = PA.no_datetime(variable)
    column_names = DataFrames.names(ndf)
    data = Matrix(ndf)
    centers, counts =
        _histogram_bins(data, get(kwargs, :bins, _sturges(DataFrames.nrow(ndf))))
    label_fn = get(kwargs, :label_fn, label_short)
    default_x_label = length(column_names) == 1 ? label_fn(only(column_names)) : "Value"
    x_label = get(kwargs, :x_label, default_x_label)
    y_label = get(kwargs, :y_label, "Count")
    kwargs = Dict{Symbol, Any}(
        (k, v) for (k, v) in kwargs if k ∉ [:bins, :x_label, :y_label, :bar]
    )
    return _plot_dataframe!(
        p,
        DataFrames.DataFrame(counts, column_names),
        centers,
        backend;
        bar = true,
        x_label = x_label,
        y_label = y_label,
        kwargs...,
    )
end

"""
    plot_histogram!(plot, df)
    plot_histogram!(plot, df, time_range)
    plot_histogram_plotly!(plot, df)
    plot_histogram_plotly!(plot, df, time_range)

Plots the value distribution of each column of a [`DataFrames.DataFrame`](@extref) as an
overlaid histogram, onto an existing plot handle. The `_plotly` variants render with the
PlotlyLight backend instead of CairoMakie.

# Arguments

- `plot`: existing plot handle returned by a previous PowerGraphics plot call (e.g. [`plot_histogram`](@ref))
- `df::DataFrames.DataFrame`: `DataFrame` where each row represents a time period and each column represents a trace.
If only the `DataFrame` is provided, it must have a column of `DateTime` values.
- `time_range::Union{DataFrames.DataFrame, Array, StepRange}`: The time periods of the data. Ignored except to
identify the `DateTime` column, since a histogram has no time axis.

# Accepted Key Words
- `bins::Int`: number of bins; defaults to Sturges' rule, `ceil(Int, log2(n)) + 1`
- `x_label::String`: label for the x axis; defaults to the column label when there is only one series
- `y_label::String = "Count"`: label for the y axis
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `palette` : color palette from [`load_palette`](@ref)
- `title::String = "Title"`: Set a title for the plots
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_histogram!(p, df::DataFrames.DataFrame; kwargs...)
    return _plot_histogram!(p, PA.no_datetime(df), CairoMakieBackend(); kwargs...)
end

function plot_histogram!(
    p,
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return _plot_histogram!(p, variable, CairoMakieBackend(); kwargs...)
end

@doc (@doc plot_histogram!) function plot_histogram_plotly!(
    p,
    df::DataFrames.DataFrame;
    kwargs...,
)
    return _plot_histogram!(p, PA.no_datetime(df), PlotlyLightBackend(); kwargs...)
end

function plot_histogram_plotly!(
    p,
    variable::DataFrames.DataFrame,
    time_range::Union{DataFrames.DataFrame, Array, StepRange};
    kwargs...,
)
    return _plot_histogram!(p, variable, PlotlyLightBackend(); kwargs...)
end

################################# Plotting PowerData ##########################

"""
    plot_powerdata(powerdata)

Makes a plot from a `PowerAnalytics.PowerData` object, such as the result of
`PowerAnalytics.get_generation_data`

# Arguments

- `powerdata::PowerAnalytics.PowerData`: The `PowerData` object to be plotted

# Accepted Key Words
- `combine_categories::Bool = false` : plot category values or each value in a category
- `curtailment::Bool`: plot the curtailment with the variable
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_powerdata(powerdata::PA.PowerData; kwargs...)
    return plot_powerdata!(_empty_plot(), powerdata; kwargs...)
end

@doc (@doc plot_powerdata) function plot_powerdata_plotly(
    powerdata::PA.PowerData;
    kwargs...,
)
    return plot_powerdata_plotly!(_empty_plot_plotly(), powerdata; kwargs...)
end

function _plot_powerdata!(p, powerdata::PA.PowerData, backend; kwargs...)
    title = get(kwargs, :title, "")
    set_display = get(kwargs, :set_display, true)
    save_fig = get(kwargs, :save, nothing)

    if get(kwargs, :combine_categories, true)
        aggregate = get(kwargs, :aggregate, nothing)
        names = get(kwargs, :names, nothing)
        data = PA.combine_categories(powerdata.data; names = names, aggregate = aggregate)
    else
        data = powerdata.data
    end
    kwargs =
        Dict{Symbol, Any}((k, v) for (k, v) in kwargs if k ∉ [:title, :save, :set_display])

    p = _plot_dataframe!(p, data, powerdata.time, backend; set_display = false, kwargs...)

    set_display && _display_plot(backend, p)
    if !isnothing(save_fig)
        title = replace(title, " " => "_")
        format = get(kwargs, :format, "png")
        save_plot(p, joinpath(save_fig, "$title.$format"), backend; kwargs...)
    end
    return p
end

"""
    plot_powerdata!(plot, powerdata)
    plot_powerdata_plotly!(plot, powerdata)

Makes a plot from a `PowerAnalytics.PowerData` object, such as the result of
`PowerAnalytics.get_generation_data`, onto an existing plot handle. The `_plotly`
variant renders with the PlotlyLight backend instead of CairoMakie.

# Arguments

- `plot`: existing plot handle returned by a previous PowerGraphics plot call (optional; e.g. [`plot_powerdata`](@ref))
- `powerdata::PowerAnalytics.PowerData`: The `PowerData` object to be plotted

# Accepted Key Words
- `combine_categories::Bool = false` : plot category values or each value in a category
- `curtailment::Bool`: plot the curtailment with the variable
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_powerdata!(p, powerdata::PA.PowerData; kwargs...)
    return _plot_powerdata!(p, powerdata, CairoMakieBackend(); kwargs...)
end

@doc (@doc plot_powerdata!) function plot_powerdata_plotly!(
    p,
    powerdata::PA.PowerData;
    kwargs...,
)
    return _plot_powerdata!(p, powerdata, PlotlyLightBackend(); kwargs...)
end

"""
    plot_results(results)

Makes a plot from a results dictionary object

# Arguments

- `results::Dict{String, DataFrame`: The results to be plotted

# Accepted Key Words
- `combine_categories::Bool = false` : plot category values or each value in a category
- `curtailment::Bool`: plot the curtailment with the variable
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_results(results::Dict{String, DataFrames.DataFrame}; kwargs...)
    return plot_powerdata!(_empty_plot(), PA.PowerData(results); kwargs...)
end

@doc (@doc plot_results) function plot_results_plotly(
    results::Dict{String, DataFrames.DataFrame};
    kwargs...,
)
    return plot_powerdata_plotly!(_empty_plot_plotly(), PA.PowerData(results); kwargs...)
end

"""
    plot_results!(plot, results)

Makes a plot from a results dictionary

# Arguments

- `plot`: existing plot handle returned by a previous PowerGraphics plot call (optional; e.g. [`plot_results`](@ref))
- `results::Dict{String, DataFrame}`: The results to be plotted

# Accepted Key Words
- `combine_categories::Bool = false` : plot category values or each value in a category
- `curtailment::Bool`: plot the curtailment with the variable
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
"""
function plot_results!(p, results::Dict{String, DataFrames.DataFrame}; kwargs...)
    return plot_powerdata!(p, PA.PowerData(results); kwargs...)
end

@doc (@doc plot_results!) function plot_results_plotly!(
    p,
    results::Dict{String, DataFrames.DataFrame};
    kwargs...,
)
    return plot_powerdata_plotly!(p, PA.PowerData(results); kwargs...)
end

################################# Plotting Fuel Plot of Results ##########################
"""
    plot_fuel(results)

Plots a stack plot of the results by fuel type
and assigns each fuel type a specific color.

# Arguments

- `res::`[`InfrastructureSystems.Results`](@extref): 
    A `Results` object (e.g., [`PowerSimulations.SimulationProblemResults`](@extref))
    to be plotted

    # Example

```julia
res = solve_op_problem!(OpProblem)
plot = plot_fuel(res)
```

# Accepted Key Words
- `generator_mapping_file` = "file_path" : file path to yaml defining generator category by fuel and primemover
- `variables::Union{Nothing, Vector{Symbol}}` = nothing : specific variables to plot
- `slacks::Bool = true` : display slack variables
- `load::Bool = true` : display load line
- `curtailment::Bool = true`: To plot the curtailment in the stack plot
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
- `filter_func::Function = `[`PowerSystems.get_available`](@extref PowerSystems InfrastructureSystems.get_available-Tuple{RenewableDispatch}): filter components included in plot
"""
function plot_fuel(result::IS.Results; kwargs...)
    return plot_fuel!(_empty_plot(), result; kwargs...)
end

@doc (@doc plot_fuel) function plot_fuel_plotly(result::IS.Results; kwargs...)
    return plot_fuel_plotly!(_empty_plot_plotly(), result; kwargs...)
end

# Backend-dispatched entry point for the Weave report template so the template
# stays backend-agnostic instead of branching on the backend type.
_report_plot_fuel(::CairoMakieBackend, result; kwargs...) =
    plot_fuel(result; kwargs...)
_report_plot_fuel(::PlotlyLightBackend, result; kwargs...) =
    plot_fuel_plotly(result; kwargs...)

function _plot_fuel!(p, result::IS.Results, backend; kwargs...)
    set_display = get(kwargs, :set_display, true)
    save_fig = get(kwargs, :save, nothing)
    curtailment = get(kwargs, :curtailment, true)
    slacks = get(kwargs, :slacks, true)
    load = get(kwargs, :load, true)
    title = get(kwargs, :title, "Fuel")
    stack = get(kwargs, :stack, true)
    bar = get(kwargs, :bar, false)
    palette = get(kwargs, :palette, PALETTE)
    kwargs =
        Dict{Symbol, Any}((k, v) for (k, v) in kwargs if k ∉ [:title, :save, :set_display])

    # Generation stack
    gen = PA.get_generation_data(result; kwargs...)
    sys = PA.PSI.get_system(result)
    if sys === nothing
        throw(
            ArgumentError("No System data present: please run `set_system!(results, sys)`"),
        )
    end
    cat = PA.make_fuel_dictionary(sys; kwargs...)
    fuel = PA.categorize_data(gen.data, cat; curtailment = curtailment, slacks = slacks)

    filter_func = get(kwargs, :filter_func, PSY.get_available)
    kwargs = popkwargs(kwargs, :filter_func)

    # passing names here enforces order; append any fuel categories not in the palette
    palette_categories = get_palette_category(palette)
    matched = intersect(palette_categories, keys(fuel))
    unmatched = setdiff(keys(fuel), palette_categories)
    fuel_agg = PA.combine_categories(fuel; names = vcat(matched, sort(collect(unmatched))))
    y_label, power_scale = _resolve_power_units(fuel_agg, kwargs)
    kwargs = popkwargs(popkwargs(popkwargs(kwargs, :y_label), :power_scale), :auto_units)

    seriescolor = get(
        kwargs,
        :seriescolor,
        match_fuel_colors(fuel_agg, backend; palette = palette),
    )
    p = _plot_dataframe!(
        p,
        fuel_agg,
        gen.time,
        backend;
        stack = stack,
        seriescolor = seriescolor,
        y_label = y_label,
        power_scale = power_scale,
        title = title,
        set_display = false,
        kwargs...,
    )

    kwargs = popkwargs(popkwargs(kwargs, :nofill), :seriescolor)

    kwargs[:linestyle] = get(kwargs, :linestyle, :dash)
    kwargs[:linewidth] = get(kwargs, :linewidth, 3)
    kwargs[:filter_func] = filter_func

    if load
        # Net-load line = demand + storage charging + source input, so it coincides
        # with the top of the generation stack (both are drawn as negative bands by
        # the sign-aware stacker; only curtailment sits above the line).
        charge = nothing
        charge_cols = [k for k in keys(fuel) if endswith(k, " In")]
        if !isempty(charge_cols)
            nrows = length(gen.time)
            charge = zeros(nrows)
            for k in charge_cols
                m = Matrix(PA.no_datetime(fuel[k]))   # negative (charging)
                charge .+= -vec(sum(m; dims = 2))     # -> positive load
            end
        end
        p = _plot_demand!(
            p,
            result,
            backend;
            nofill = true,
            title = title,
            y_label = y_label,
            power_scale = power_scale,
            set_display = false,
            stack = stack,
            seriescolor = ["black"],
            kwargs...,
        )
    end

    # service stack
    # TODO: how to display this?

    set_display && _display_plot(backend, p)
    if !isnothing(save_fig)
        title = replace(title, " " => "_")
        format = get(kwargs, :format, "png")
        save_plot(p, joinpath(save_fig, "$title.$format"), backend; kwargs...)
    end
    return p
end

"""
    plot_fuel!(plot, results)
    plot_fuel_plotly!(plot, results)

Plots a stack plot of the results by fuel type onto an existing plot handle and
assigns each fuel type a specific color. The `_plotly` variant renders with the
PlotlyLight backend instead of CairoMakie.

# Arguments

- `plot`: existing plot handle returned by a previous PowerGraphics plot call (optional; e.g. [`plot_fuel`](@ref))
- `res::`[`InfrastructureSystems.Results`](@extref):
    A `Results` object (e.g., [`PowerSimulations.SimulationProblemResults`](@extref))
    to be plotted

# Accepted Key Words
- `generator_mapping_file` = "file_path" : file path to yaml defining generator category by fuel and primemover
- `variables::Union{Nothing, Vector{Symbol}}` = nothing : specific variables to plot
- `slacks::Bool = true` : display slack variables
- `load::Bool = true` : display load line
- `curtailment::Bool = true`: To plot the curtailment in the stack plot
- `set_display::Bool = true`: set to false to prevent the plots from displaying
- `save::String = "file_path"`: set a file path to save the plots
- `format::String = "png"`: file extension for saved plots. CairoMakie supports `"png"`, `"pdf"`, `"svg"`. PlotlyLight only supports `"html"` (other values are written as `.html` with a warning).
- `seriescolor::Array`: Set different colors for the plots
- `title::String = "Title"`: Set a title for the plots
- `stack::Bool = true`: stack plot traces
- `bar::Bool` : create bar plot
- `nofill::Bool` : force empty area fill
- `stair::Bool`: Make a stair plot instead of a stack plot
- `label_fn::Function = label_short`: function applied to legend labels (typically the raw `Variable__Component` strings produced by PowerAnalytics). Built-in options: `label_short`, `label_component`, `label_variable`, `label_acronym`, `label_first_word`, `label_truncate(n)`. Note that when `combine_categories = true` (the default for `plot_powerdata`, `plot_results`, and `plot_fuel`), columns are aggregated to category names *before* `label_fn` runs — those names don't contain `__`, so the default `label_short` is a no-op. Pass `combine_categories = false` to see the effect of `label_fn` on the raw labels.
- `legend_position::Symbol = :right`: legend placement, `:right` or `:bottom`
- `legend_font_size::Number`: override the legend label font size
- `filter_func::Function = `[`PowerSystems.get_available`](@extref PowerSystems InfrastructureSystems.get_available-Tuple{RenewableDispatch}): filter components included in plot
- `palette` : Color palette as from [`load_palette`](@ref).
"""
function plot_fuel!(p, result::IS.Results; kwargs...)
    return _plot_fuel!(p, result, CairoMakieBackend(); kwargs...)
end

@doc (@doc plot_fuel!) function plot_fuel_plotly!(p, result::IS.Results; kwargs...)
    return _plot_fuel!(p, result, PlotlyLightBackend(); kwargs...)
end

"""
    save_plot(plot, filename)

Saves a plot to the specified filename. The backend is chosen from the plot
object's type: CairoMakie plots dispatch to the CairoMakie writer (png/pdf/svg),
PlotlyLight plots dispatch to the PlotlyLight writer (html).

# Arguments

- `plot`: plot object returned by a `plot_*` function
- `filename::String` : path to save to

# Example

```julia
res = solve_op_problem!(OpProblem)
plot = plot_fuel(res)
save_plot(plot, "my_plot.png")               # CairoMakie
plot = plot_fuel_plotly(res)
save_plot(plot, "my_plot.html")               # PlotlyLight
```

# Accepted Key Words (PlotlyLight backend only; CairoMakie ignores them)
- `width::Union{Nothing,Int}=nothing`
- `height::Union{Nothing,Int}=nothing`
- `scale::Union{Nothing,Real}=nothing`
"""
# The 2-arg `save_plot(plot, filename)` form is defined per-backend via type
# dispatch — see `ext/plot_recipes.jl` (CairoMakie) and `ext/plotly_recipes.jl`
# (PlotlyLight).
function save_plot end
