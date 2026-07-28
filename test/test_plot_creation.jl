file_path = TEST_OUTPUTS

function test_plots(file_path::String; backend_pkg::String = "cairomakie")
    # Select plot functions based on backend
    if backend_pkg == "cairomakie"
        plot_dataframe_fn = plot_dataframe
        plot_dataframe_fn! = plot_dataframe!
        plot_demand_fn = plot_demand
        plot_powerdata_fn = PG.plot_powerdata
        plot_fuel_fn = plot_fuel
        plot_duration_curve_fn = plot_duration_curve
        plot_histogram_fn = plot_histogram
        n_series = p -> p.series_count
        x_label_of = p -> p.axis.xlabel[]
        y_label_of = p -> p.axis.ylabel[]
        # Every CairoMakie series is stored as a `Point2` vector on the scene.
        series_xy = function (p, ix)
            points = p.axis.scene.plots[ix][1][]
            return (first.(points), last.(points))
        end
        series_y = (p, ix) -> last.(p.axis.scene.plots[ix][1][])
    elseif backend_pkg == "plotlylight"
        plot_dataframe_fn = plot_dataframe_plotly
        plot_dataframe_fn! = plot_dataframe_plotly!
        plot_demand_fn = plot_demand_plotly
        plot_powerdata_fn = PG.plot_powerdata_plotly
        plot_fuel_fn = plot_fuel_plotly
        plot_duration_curve_fn = plot_duration_curve_plotly
        plot_histogram_fn = plot_histogram_plotly
        n_series = p -> length(p.data)
        x_label_of = p -> p.layout.xaxis.title.text
        y_label_of = p -> p.layout.yaxis.title.text
        series_xy = (p, ix) -> (collect(p.data[ix].x), collect(p.data[ix].y))
        series_y = (p, ix) -> collect(p.data[ix].y)
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

    @testset "test $backend_pkg duration curve and histogram" begin
        df = gen_uc.data[:ActivePowerVariable__ThermalStandard]
        n_columns = ncol(no_datetime(df))
        n_rows = nrow(df)

        # Regression guard: the duration curve/histogram work generalized the
        # recipes' x axis, which every other plot also goes through.
        p = plot_dataframe_fn(df, gen_uc.time; set_display = set_display)
        @test n_series(p) == n_columns
        @test x_label_of(p) == string(
            IS.convert_compound_period(
                length(gen_uc.time) * (gen_uc.time[2] - gen_uc.time[1]),
            ),
        )

        # A bar plot over time still integrates to a single bar per series. If it
        # ever fell into the numeric-axis bar branch it would silently draw one
        # bar per timestep instead, which still renders and still saves a file.
        p = plot_dataframe_fn(df, gen_uc.time; set_display = set_display, bar = true)
        @test n_series(p) == n_columns
        for ix in 1:n_columns
            @test length(series_y(p, ix)) == 1
        end

        p = plot_duration_curve_fn(df, gen_uc.time; set_display = set_display)
        @test n_series(p) == n_columns
        @test x_label_of(p) == "Percent of time"
        for ix in 1:n_columns
            x, y = series_xy(p, ix)
            @test length(y) == n_rows
            @test issorted(y; rev = true)
            @test first(x) ≈ 0.0
            @test last(x) ≈ 100.0
        end

        elapsed_hours =
            Dates.value(Millisecond(last(gen_uc.time) - first(gen_uc.time))) / 3.6e6
        p = plot_duration_curve_fn(
            df,
            gen_uc.time;
            set_display = set_display,
            x_axis = :hours,
        )
        @test x_label_of(p) == "Hours"
        for ix in 1:n_columns
            x, y = series_xy(p, ix)
            @test issorted(y; rev = true)
            @test first(x) ≈ 0.0
            @test last(x) ≈ elapsed_hours
        end

        @test_throws ArgumentError plot_duration_curve_fn(
            df,
            gen_uc.time;
            set_display = set_display,
            x_axis = :not_a_mode,
        )

        default_bins = ceil(Int, log2(n_rows)) + 1
        p = plot_histogram_fn(df, gen_uc.time; set_display = set_display)
        @test n_series(p) == n_columns
        @test y_label_of(p) == "Count"
        for ix in 1:n_columns
            _, counts = series_xy(p, ix)
            @test length(counts) == default_bins
            # Nothing may fall outside the shared bin range.
            @test sum(counts) == n_rows
        end

        p = plot_histogram_fn(df, gen_uc.time; set_display = set_display, bins = 12)
        @test n_series(p) == n_columns
        for ix in 1:n_columns
            _, counts = series_xy(p, ix)
            @test length(counts) == 12
            @test sum(counts) == n_rows
        end
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
