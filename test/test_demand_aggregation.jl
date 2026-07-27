@testset "demand aggregation keyword" begin
    for (str, type) in
        ("System" => PSY.System, "Bus" => PSY.ACBus, "PowerLoad" => PSY.PowerLoad)
        translated = PG._translate_demand_aggregate(Dict(:aggregate => str))
        @test translated[:aggregation] === type
        @test !haskey(translated, :aggregate)
    end

    # Issue #126: a typed `aggregation` passed directly must reach PowerAnalytics untouched,
    # without disturbing the other keywords.
    passthrough =
        PG._translate_demand_aggregate(Dict(:aggregation => PSY.ACBus, :title => "demand"))
    @test passthrough[:aggregation] === PSY.ACBus
    @test passthrough[:title] == "demand"

    # A type given under the legacy `aggregate` name is forwarded, not stringified.
    @test PG._translate_demand_aggregate(Dict(:aggregate => PSY.ACBus))[:aggregation] ===
          PSY.ACBus

    # `aggregate = nothing` means "no aggregation": PowerAnalytics keeps its own default.
    @test !haskey(PG._translate_demand_aggregate(Dict(:aggregate => nothing)), :aggregation)

    @test_throws ArgumentError PG._translate_demand_aggregate(Dict(:aggregate => "bus"))

    # `PA.get_load_data(::PSY.System)` only aggregates over `PSY.System`, `PSY.ACBus`,
    # `StaticLoad` subtypes and `AggregationTopology` subtypes, so every type the table
    # maps to has to fall in that set. "System" and "Bus" are also covered end to end in
    # test_plot_creation.jl; this catches "PowerLoad" and any entry added later.
    @test all(
        t ->
            t in (PSY.System, PSY.ACBus) ||
                t <: Union{PSY.StaticLoad, PSY.AggregationTopology},
        values(PG._AGGREGATE_STRING_TO_TYPE),
    )
end
