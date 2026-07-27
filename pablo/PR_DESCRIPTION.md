# Migrate to the PowerAnalytics 1.0 metrics API

## What & why

Tackles the PowerAnalytics old-API deprecation: PowerAnalytics deprecated its pre-1.0
accessors (`get_generation_data`, `get_load_data`, `get_service_data`, `categorize_data`,
`PowerData`, ...) in favor of the 1.0 Metric/ComponentSelector API — see the
["Old PowerAnalytics" notice](https://sienna-platform.github.io/PowerAnalytics.jl/stable/reference/public/#Old-PowerAnalytics)
in its reference docs ("This interface predates the 1.0 version and will eventually be
deprecated") and the tracking issue
[Sienna-Platform/PowerAnalytics.jl#28](https://github.com/Sienna-Platform/PowerAnalytics.jl/issues/28).
This PR moves PowerGraphics' internals onto the new API without breaking any public
signature, so PowerGraphics is ready before the old interface is removed.

## Commits

1. `test: pin fuel stack and demand plot behavior` — behavior contract (column ordering,
   In/Out signs, curtailment/slack names, demand naming) pinned on the old implementation
   before touching anything.
2. `refactor: use PA.get_system instead of reaching through PA.PSI`.
3. `refactor: migrate plot_demand to the PowerAnalytics metrics API` — Results path on
   `calc_load_forecast`; column naming unchanged.
4. `refactor: migrate plot_fuel to the metrics/selectors API` — per-component metric
   evaluation with a variable → parameter → aux-variable fallback chain, storage/source
   In/Out split, curtailment, and slacks reassembled on the new API.
5. `refactor: reimplement plot_results internally; deprecate plot_powerdata(::PowerData)` —
   `plot_results` no longer constructs `PA.PowerData`; the `plot_powerdata` methods live in
   `src/deprecated.jl` as forwarding shims that warn.
6. `docs: update report template and document the migration`.

## Bug fixes along the way

- The `plot_fuel` net-load line now includes storage charging / source input, as its
  comment always claimed; previously the computed offset was dropped.
- `plot_results(...; combine_categories = false)` used to crash; it now plots one trace
  per stored column, and the docstrings state the actual default (`true`).

## Behavior notes

- Fuel categorization keeps the old first-match-wins semantics (most specific type, then
  prime mover, then fuel), so no component is double-counted across categories.
- Fixed two fuel-enum typos in the test mapping yaml (`AG_BYPRODUCT`, `WOOD_WASTE_SOLIDS`);
  the new parser validates enum names, the old one silently never matched them.
- Time windowing (`initial_time`/`horizon`, `start_time`/`len`) is applied locally by row
  slicing because `PowerAnalytics.compute` currently mishandles window kwargs on
  simulation results (TODO comment filed in code).

## Intentionally still on the old API

- `plot_demand(::PSY.System)` (`get_load_data(::System)` has no new-API equivalent),
  `no_datetime` on user-supplied DataFrames (copy semantics), and the deprecated
  `plot_powerdata(::PowerData)` shims. PowerAnalytics still exports and maintains the old
  API, so these keep working unchanged until a future breaking release.
- Upstream TODOs are marked in code comments: PowerAnalytics should export
  `calc_system_slack_down`, provide forecast metrics for the storage/source time-series
  parameters, and fix `compute`'s time-window kwargs.
