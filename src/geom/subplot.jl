
# Subplot geometries


abstract SubplotGeometry <: Gadfly.GeometryElement


immutable SubplotLayer
    statistic::Gadfly.StatisticElement
    geom::Gadfly.GeometryElement

    function SubplotLayer(geom::Gadfly.GeometryElement=Geom.nil(),
                          statistic::Gadfly.StatisticElement=Stat.nil())
        new(statistic, geom)
    end
end


# Adding elements to subplots in a generic way.

function add_subplot_element(subplot::SubplotGeometry, arg::Function)
    add_subplot_element(subplot, arg())
end


function add_subplot_element(subplot::SubplotGeometry, arg::SubplotLayer)
    push!(subplot.layers, arg)
end


function add_subplot_element(subplot::SubplotGeometry, arg::Gadfly.GeometryElement)
    push!(subplot.layers, SubplotLayer(arg))
end


function add_subplot_element(subplot::SubplotGeometry, arg::Gadfly.StatisticElement)
    push!(subplot.statistics, arg)
end


function add_subplot_element(subplot::SubplotGeometry, arg::Gadfly.GuideElement)
    push!(subplot.guides, arg)
end


function add_subplot_element{T <: Gadfly.Element}(subplot::SubplotGeometry,
                                                  arg::Type{T})
    add_subplot_element(subplot, arg())
end


function add_subplot_element(subplot::SubplotGeometry, arg)
    error("Subplots do not support elements of type $(typeof(arg))")
end


immutable SubplotGrid <: SubplotGeometry
    layers::Vector{SubplotLayer}
    statistics::Vector{Gadfly.StatisticElement}
    guides::Vector{Gadfly.GuideElement}
    free_x_axis::Bool
    free_y_axis::Bool

    # Current plot has no way of passing existing aesthetics. It always produces
    # these using scales.
    function SubplotGrid(elements::Gadfly.ElementOrFunction...;
                         free_x_axis=false, free_y_axis=false)
        subplot = new(SubplotLayer[], Gadfly.StatisticElement[],
                      Gadfly.GuideElement[], free_x_axis, free_y_axis)

        for element in elements
            add_subplot_element(subplot, element)
        end

        # TODO: Handle default guides and statistics
        subplot
    end
end


const subplot_grid = SubplotGrid


function element_aesthetics(geom::SubplotGrid)
    vars = [:xgroup, :ygroup]
    for layer in geom.layers
        append!(vars, element_aesthetics(layer.geom))
    end
    vars
end


# Render a subplot grid geometry, which consists of rendering and arranging
# many smaller plots.
function render(geom::SubplotGrid, theme::Gadfly.Theme,
                superplot_aes::Gadfly.Aesthetics)
    if superplot_aes.xgroup === nothing && superplot_aes.ygroup === nothing
        error("Geom.subplot_grid requires \"xgroup\" and/or \"ygroup\" to be bound.")
    end

    # partition the each aesthetic into a matrix of aesthetics
    aes_grid = Gadfly.aes_by_xy_group(superplot_aes)
    n, m = size(aes_grid)

    coord = Coord.cartesian()
    scales = Dict{Symbol, Gadfly.ScaleElement}()
    plot_stats = Gadfly.StatisticElement[stat for stat in geom.statistics]
    layer_stats = Gadfly.StatisticElement[typeof(layer.statistic) == Stat.nil ?
                       Geom.default_statistic(layer.geom) : layer.statistic
                   for layer in geom.layers]

    layer_aes_grid = Array(Array{Gadfly.Aesthetics, 1}, n, m)
    for i in 1:n, j in 1:m
        layer_aes = fill(copy(aes_grid[i, j]), length(geom.layers))

        for (layer_stat, aes) in zip(layer_stats, layer_aes)
            Stat.apply_statistics(Gadfly.StatisticElement[layer_stat],
                                  scales, coord, aes)
        end

        plot_aes = cat(layer_aes...)
        Stat.apply_statistics(plot_stats, scales, coord, plot_aes)

        aes_grid[i, j] = plot_aes
        layer_aes_grid[i, j] = layer_aes
    end

    # apply geom-wide statistics
    geom_aes = cat(aes_grid...)
    geom_stats = Gadfly.StatisticElement[]

    if !geom.free_x_axis
        push!(geom_stats, Stat.xticks())
    end

    if !geom.free_y_axis
        push!(geom_stats, Stat.yticks())
    end

    Stat.apply_statistics(geom_stats, scales, coord, geom_aes)

    # if either axis is on a free scale, we need to apply row/column-wise
    # tick statistics.
    if (geom.free_x_axis)
        for j in 1:m
            col_aes = cat([aes_grid[i, j] for i in 1:n]...)
            Stat.apply_statistic(Stat.xticks(), scales, coord, col_aes)
            for i in 1:n
                aes_grid[i, j] = cat(aes_grid[i, j], col_aes)
            end
        end
    end

    if (geom.free_y_axis)
        for i in 1:n
            row_aes = cat([aes_grid[i, j] for j in 1:m]...)
            Stat.apply_statistic(Stat.yticks(), scales, coord, row_aes)
            for j in 1:m
                aes_grid[i, j] = cat(aes_grid[i, j], row_aes)
            end
        end
    end

    for i in 1:n, j in 1:m
        Gadfly.inherit!(aes_grid[i, j], geom_aes)
    end

    # TODO: this assumed a rather ridged layout
    tbl = table(n + 2, m + 2, 1:n, 3:m+2,
                x_prop=ones(m), y_prop=ones(n),
                fixed_configs={
                    [(i, 1) for i in 1:n],
                    [(i, 2) for i in 1:n],
                    [(n+1, j) for j in 3:m+2],
                    [(n+2, j) for j in 3:m+2]})

    xtitle = "x"
    for v in [:x, :xmin, :xmax]
        if haskey(superplot_aes.titles, v)
            xtitle = superplot_aes.titles[v]
            break
        end
    end

    ytitle = "y"
    for v in [:y, :ymin, :ymax]
        if haskey(superplot_aes.titles, v)
            ytitle = superplot_aes.titles[v]
            break
        end
    end

    xlabels = superplot_aes.xgroup_label(1.0:m)
    ylabels = superplot_aes.ygroup_label(1.0:n)
    subplot_padding = 2mm

    for i in 1:n, j in 1:m
        p = Plot()
        p.theme = theme
        for layer in geom.layers
            plot_layer = Gadfly.Layer()
            plot_layer.statistic = layer.statistic
            plot_layer.geom = layer.geom
            push!(p.layers, plot_layer)
        end
        guides = Gadfly.GuideElement[guide for guide in geom.guides]

        # default guides
        push!(guides, Guide.background())

        if i == n
            push!(guides, Guide.xticks())
            if !is(superplot_aes.xgroup, nothing)
                push!(guides, Guide.xlabel(xlabels[j]))
            end
        else
            push!(guides, Guide.xticks(label=false))
        end

        joff = 0
        if j == 1
            joff += 1
            push!(guides, Guide.yticks())
            if !is(superplot_aes.ygroup, nothing)
                joff += 1
                push!(guides, Guide.ylabel(ylabels[i]))
            end
        else
            push!(guides, Guide.yticks(label=false))
        end

        subtbl = Gadfly.render_prepared(
                            p, aes_grid[i, j], layer_aes_grid[i, j],
                            layer_stats,
                            Dict{Symbol, Gadfly.ScaleElement}(),
                            plot_stats,
                            guides,
                            table_only=true)

        # copy over the correct units, since we are reparenting the children
        #for u in 1:size(subtbl, 1), v in 1:size(subtbl, 2)
            #for child in subtbl[u, v]
                #if child.units == Compose.nil_unit_box
                    #child.units = subtbl.units
                #end
            #end
        #end

        tbl[i, 2 + j] = pad(subtbl[1, 1 + joff], subplot_padding)

        # bottom guides
        for k in 2:size(subtbl, 1)
            tbl[i + k - 1, 2 + j] =
                pad(subtbl[k, 1 + joff], subplot_padding, 0mm)
        end

        # left guides
        for k in 1:(size(subtbl, 2)-1)
            tbl[i, k] =
                pad(subtbl[1, k], 0mm, subplot_padding)
        end
    end

    return compose!(context(), tbl)
end


