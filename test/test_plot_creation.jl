file_path = TEST_OUTPUTS

# Width and height of a PNG, read straight out of the IHDR chunk (big-endian
# UInt32 at byte offsets 16 and 20), to avoid pulling in an image reader.
function png_size(filename::String)
    return open(filename, "r") do io
        seek(io, 16)
        width = ntoh(read(io, UInt32))
        height = ntoh(read(io, UInt32))
        (Int(width), Int(height))
    end
end

function test_plots(file_path::String; backend_pkg::String = "cairomakie")
    # Select plot functions based on backend
    if backend_pkg == "cairomakie"
        plot_dataframe_fn = plot_dataframe
        plot_dataframe_fn! = plot_dataframe!
        plot_demand_fn = plot_demand
        plot_powerdata_fn = PG.plot_powerdata
        plot_fuel_fn = plot_fuel
    elseif backend_pkg == "plotlylight"
        plot_dataframe_fn = plot_dataframe_plotly
        plot_dataframe_fn! = plot_dataframe_plotly!
        plot_demand_fn = plot_demand_plotly
        plot_powerdata_fn = PG.plot_powerdata_plotly
        plot_fuel_fn = plot_fuel_plotly
    else
        throw(error("$backend_pkg backend_pkg not supported"))
    end

    set_display = false
    cleanup = true
    @info("running tests with $backend_pkg with display $set_display and cleanup $cleanup")

    (results_uc, results_ed) = run_test_sim(TEST_RESULT_DIR, TEST_SIM_NAME)
    problem_results = run_test_prob()
    gen_uc = get_generation_data(results_uc)
    gen_ed = get_generation_data(results_ed)
    gen_pb = get_generation_data(problem_results)
    load_uc = get_load_data(results_uc)
    load_ed = get_load_data(results_ed)
    load_pb = get_load_data(problem_results)
    svc_uc = get_service_data(results_uc)
    svc_ed = get_service_data(results_ed)
    svc_pb = get_service_data(problem_results)

    @testset "test $backend_pkg plot production" begin
        out_path = joinpath(file_path, backend_pkg * "_plots")
        !isdir(out_path) && mkdir(out_path)
        plot_dataframe_fn(
            gen_uc.data[:ActivePowerVariable__RenewableDispatch],
            gen_uc.time;
            set_display = set_display,
            title = "df_line",
            save = out_path,
        )
        plot_dataframe_fn(
            gen_uc.data[:ActivePowerVariable__ThermalStandard],
            gen_uc.time;
            set_display = set_display,
            title = "df_stack",
            save = out_path,
            stack = true,
        )
        plot_dataframe_fn(
            gen_uc.data[:ActivePowerVariable__ThermalStandard],
            gen_uc.time;
            set_display = set_display,
            title = "df_stair",
            save = out_path,
            stair = true,
        )
        plot_dataframe_fn(
            gen_uc.data[:ActivePowerVariable__ThermalStandard],
            gen_uc.time;
            set_display = set_display,
            title = "df_bar",
            save = out_path,
            bar = true,
        )
        plot_dataframe_fn(
            gen_uc.data[:ActivePowerVariable__ThermalStandard],
            gen_uc.time;
            set_display = set_display,
            title = "df_bar_stack",
            save = out_path,
            bar = true,
            stack = true,
        )
        plot_dataframe_fn!(
            plot_dataframe_fn(
                gen_uc.data[:ActivePowerVariable__ThermalStandard],
                gen_uc.time;
                set_display = set_display,
                stack = true,
            ),
            no_datetime(load_uc.data[:Load]) .* -1,
            gen_uc.time;
            set_display = set_display,
            title = "df_gen_load",
            save = out_path,
        )

        list = readdir(out_path)
        # PlotlyLight only supports HTML export, CairoMakie supports PNG
        file_ext = backend_pkg == "plotlylight" ? ".html" : ".png"
        expected_files = [
            "df_line$file_ext",
            "df_stack$file_ext",
            "df_stair$file_ext",
            "df_bar$file_ext",
            "df_bar_stack$file_ext",
            "df_gen_load$file_ext",
        ]
        # expected results not created
        @test isempty(setdiff(expected_files, list))
        # extra results created
        @test isempty(setdiff(list, expected_files))

        @info("removing test files")
        cleanup && rm(out_path; recursive = true)
    end

    @testset "test $backend_pkg powerdata plot production" begin
        out_path = joinpath(file_path, backend_pkg * "_powerdata_plots")
        !isdir(out_path) && mkdir(out_path)

        plot_powerdata_fn(
            gen_uc;
            set_display = set_display,
            title = "pg_data",
            save = out_path,
            bar = false,
            stack = false,
        )
        plot_powerdata_fn(
            gen_uc;
            set_display = set_display,
            title = "pg_data_stack",
            save = out_path,
            bar = false,
            stack = true,
        )
        plot_powerdata_fn(
            gen_uc;
            set_display = set_display,
            title = "pg_data_bar",
            save = out_path,
            bar = true,
            stack = false,
        )
        plot_powerdata_fn(
            gen_uc;
            set_display = set_display,
            title = "pg_data_bar_stack",
            save = out_path,
            bar = true,
            stack = true,
        )

        list = readdir(out_path)
        # PlotlyLight only supports HTML export, CairoMakie supports PNG
        file_ext = backend_pkg == "plotlylight" ? ".html" : ".png"
        expected_files = [
            "pg_data$file_ext",
            "pg_data_stack$file_ext",
            "pg_data_bar$file_ext",
            "pg_data_bar_stack$file_ext",
        ]
        # expected results not created
        @test isempty(setdiff(expected_files, list))
        # extra results created
        @test isempty(setdiff(list, expected_files))

        @info("removing test files")
        cleanup && rm(out_path; recursive = true)
    end

    @testset "test $backend_pkg demand plot production" begin
        out_path = joinpath(file_path, backend_pkg * "_demand_plots")
        !isdir(out_path) && mkdir(out_path)
        plot_demand_fn(
            results_uc;
            set_display = set_display,
            title = "demand",
            save = out_path,
            bar = false,
            stack = false,
            nofill = false,
            filter_func = x -> get_name(get_bus(x)) == "bus2",
        )
        plot_demand_fn(
            results_uc;
            set_display = set_display,
            title = "demand_stack",
            save = out_path,
            bar = false,
            stack = true,
            nofill = false,
        )
        plot_demand_fn(
            results_uc;
            set_display = set_display,
            title = "demand_bar",
            save = out_path,
            bar = true,
            stack = false,
            nofill = false,
        )
        plot_demand_fn(
            results_uc;
            set_display = set_display,
            title = "demand_bar_stack",
            save = out_path,
            bar = true,
            stack = true,
            nofill = false,
        )
        plot_demand_fn(
            results_uc;
            set_display = set_display,
            title = "demand_nofill",
            save = out_path,
            bar = false,
            stack = false,
            nofill = true,
        )
        plot_demand_fn(
            results_uc;
            set_display = set_display,
            title = "demand_nofill_stack",
            save = out_path,
            bar = false,
            stack = true,
            nofill = true,
        )
        plot_demand_fn(
            results_uc;
            set_display = set_display,
            title = "demand_nofill_bar",
            save = out_path,
            bar = true,
            stack = false,
            nofill = true,
        )
        plot_demand_fn(
            results_uc;
            set_display = set_display,
            title = "demand_nofill_bar_stack",
            save = out_path,
            bar = true,
            stack = true,
            nofill = true,
        )

        # Use a freshly-built system rather than results_uc.system: PSI no longer
        # serializes load time series with simulation results, so the system
        # attached to simulation results lacks the forecasts that get_load_data needs.
        sys_with_ts = PSB.build_system(PSB.PSISystems, "5_bus_hydro_uc_sys")
        p = plot_demand_fn(
            sys_with_ts;
            set_display = set_display,
            title = "sysdemand",
            save = out_path,
            aggregate = "System",
        )
        plot_length = backend_pkg == "cairomakie" ? p.series_count : length(p.data)
        @test plot_length == 1

        p = plot_demand_fn(
            sys_with_ts;
            set_display = set_display,
            title = "sysdemand_bus",
            save = out_path,
            aggregate = "Bus",
        )
        plot_length = backend_pkg == "cairomakie" ? p.series_count : length(p.data)
        @test plot_length == 3

        list = readdir(out_path)
        # PlotlyLight only supports HTML export, CairoMakie supports PNG
        file_ext = backend_pkg == "plotlylight" ? ".html" : ".png"
        expected_files = [
            "demand$file_ext",
            "demand_stack$file_ext",
            "demand_bar$file_ext",
            "demand_bar_stack$file_ext",
            "demand_nofill$file_ext",
            "demand_nofill_stack$file_ext",
            "demand_nofill_bar$file_ext",
            "demand_nofill_bar_stack$file_ext",
            "sysdemand$file_ext",
            "sysdemand_bus$file_ext",
        ]
        # expected results not created
        @test isempty(setdiff(expected_files, list))
        # extra results created
        @test isempty(setdiff(list, expected_files))

        @info("removing test files")
        cleanup && rm(out_path; recursive = true)
    end

    @testset "test $backend_pkg fuel plot production" begin
        out_path = joinpath(file_path, backend_pkg * "_fuel_plots")
        !isdir(out_path) && mkdir(out_path)

        plot_fuel_fn(
            results_uc;
            set_display = set_display,
            title = "fuel",
            save = out_path,
            bar = false,
            stack = false,
            filter_func = x -> get_name(get_area(get_bus(x))) == "1",
        )
        plot_fuel_fn(
            results_uc;
            set_display = set_display,
            title = "fuel_stack",
            save = out_path,
            bar = false,
            stack = true,
        )
        plot_fuel_fn(
            results_uc;
            set_display = set_display,
            title = "fuel_bar",
            save = out_path,
            bar = true,
            stack = false,
        )
        plot_fuel_fn(
            results_uc;
            set_display = set_display,
            title = "fuel_bar_stack",
            save = out_path,
            bar = true,
            stack = true,
        )

        list = readdir(out_path)
        # PlotlyLight only supports HTML export, CairoMakie supports PNG
        file_ext = backend_pkg == "plotlylight" ? ".html" : ".png"
        expected_files = [
            "fuel$file_ext",
            "fuel_stack$file_ext",
            "fuel_bar$file_ext",
            "fuel_bar_stack$file_ext",
        ]
        # expected results not created
        @test isempty(setdiff(expected_files, list))
        # extra results created
        @test isempty(setdiff(list, expected_files))

        @info("removing test files")
        cleanup && rm(out_path; recursive = true)
    end

    @testset "test alternate mapping yamls" begin
        # Alternate color palette makes curtailment hot pink
        out_path = joinpath(file_path, backend_pkg * "_alternate_palette")
        !isdir(out_path) && mkdir(out_path)

        palette = PG.load_palette(joinpath(TEST_DIR, "test_yamls/color-palette.yaml"))

        plot_fuel_fn(
            results_uc;
            set_display = set_display,
            title = "fuel",
            save = out_path,
            bar = true,
            generator_mapping_file = joinpath(
                TEST_DIR,
                "test_yamls/generator_mapping.yaml",
            ),
            palette = palette,
        )
        list = readdir(out_path)
        # PlotlyLight only supports HTML export, CairoMakie supports PNG
        file_ext = backend_pkg == "plotlylight" ? ".html" : ".png"
        expected_files = ["fuel$file_ext"]
        @test isempty(setdiff(expected_files, list))
        @test isempty(setdiff(list, expected_files))

        @info "removing alternate test fuel outputs"
        cleanup && rm(out_path; recursive = true)
    end

    @testset "test $backend_pkg save sizing" begin
        out_path = joinpath(file_path, backend_pkg * "_save_sizing")
        !isdir(out_path) && mkdir(out_path)
        p = plot_dataframe_fn(
            gen_uc.data[:ActivePowerVariable__ThermalStandard],
            gen_uc.time;
            set_display = false,
            title = "sizing",
            stack = true,
        )

        if backend_pkg == "cairomakie"
            original_size = size(p.figure.scene)

            default_png = joinpath(out_path, "default.png")
            PG.save_plot(p, default_png)
            # The 1280x720 default figure at Makie's default px_per_unit of 2.
            @test png_size(default_png) == (2560, 1440)

            sized_png = joinpath(out_path, "sized.png")
            PG.save_plot(p, sized_png; width = 800, height = 600)
            @test png_size(sized_png) == (1600, 1200)

            scaled_png = joinpath(out_path, "scaled.png")
            PG.save_plot(p, scaled_png; width = 800, height = 600, scale = 2)
            @test png_size(scaled_png) == (3200, 2400)

            # Saving at a different size must never mutate the caller's figure.
            @test size(p.figure.scene) == original_size

            # Save-time sizing is independent of the plot-time `size` kwarg, which
            # `save_plot` must ignore even though `plot_*` forwards it here.
            ignores_size = joinpath(out_path, "ignores_size.png")
            PG.save_plot(p, ignores_size; size = (300, 200))
            @test png_size(ignores_size) == (2560, 1440)

            # `CairoMakie.save` resizes the scene before it writes, so a failure
            # mid-write must still leave the figure at its original size.
            @test_throws Exception PG.save_plot(
                p,
                joinpath(out_path, "missing_dir", "x.png");
                width = 321,
                height = 123,
            )
            @test size(p.figure.scene) == original_size

            for format in ("svg", "pdf")
                vector_file = joinpath(out_path, "vector.$format")
                PG.save_plot(p, vector_file; width = 400, height = 300, scale = 1.5)
                @test filesize(vector_file) > 0
            end
            @test size(p.figure.scene) == original_size

            @test_throws ArgumentError PG.save_plot(p, joinpath(out_path, "bad.html"))
            @test_throws ArgumentError PG.save_plot(
                p,
                joinpath(out_path, "bad.png");
                width = 0,
            )
            @test_throws ArgumentError PG.save_plot(
                p,
                joinpath(out_path, "bad.png");
                scale = -1,
            )
        else
            @test !haskey(p.layout, :width)

            sized_html = joinpath(out_path, "sized.html")
            PG.save_plot(p, sized_html; width = 640, height = 480)
            html = read(sized_html, String)
            @test occursin("\"width\":640", html)
            @test occursin("\"height\":480", html)
            # An unguarded `layout.width` read would serialize as `"width":{}`.
            @test !occursin("\"width\":{}", html)
            # The layout must be left exactly as it was found.
            @test !haskey(p.layout, :width)
            @test !haskey(p.layout, :height)

            # Keywords `show` cannot accept must be dropped, not forwarded.
            extra_html = joinpath(out_path, "extra.html")
            PG.save_plot(p, extra_html; full_html = true)
            @test filesize(extra_html) > 0

            @test_logs (:warn, r"scale") match_mode = :any PG.save_plot(
                p,
                joinpath(out_path, "scaled.html");
                scale = 2,
            )

            # Non-HTML requests fall back to HTML and report the name written.
            written = @test_logs (:warn, r"HTML") match_mode = :any PG.save_plot(
                p,
                joinpath(out_path, "raster.png"),
            )
            @test written == joinpath(out_path, "raster.html")
            @test isfile(written)

            # A failed write must still restore the layout it borrowed.
            @test_throws Exception PG.save_plot(
                p,
                joinpath(out_path, "missing_dir", "x.html");
                width = 640,
                height = 480,
            )
            @test !haskey(p.layout, :width)
            @test !haskey(p.layout, :height)
        end

        cleanup && rm(out_path; recursive = true)
    end

    # HTML saving only works with PlotlyLight backend
    if backend_pkg == "plotlylight"
        @testset "test html saving" begin
            plot_fuel_fn(
                results_ed;
                set_display = false,
                save = TEST_RESULT_DIR,
                title = "fuel_html_output",
                format = "html",
            )
            @test isfile(joinpath(TEST_RESULT_DIR, "fuel_html_output.html"))
        end
    end
end
try
    test_plots(file_path; backend_pkg = "cairomakie")
    @info("done with CairoMakie, starting plotlylight")
    test_plots(file_path; backend_pkg = "plotlylight")
finally
    nothing
end
