isdefined(Base, :__precompile__) && __precompile__()

module SMC
    using ModelConstructors, DSGE, Dates, Test, BenchmarkTools
    using Distributed, Distributions, FileIO, FredData, HDF5, JLD2, LinearAlgebra
    using Missings, Nullables, Printf, Random, RecipesBase, SparseArrays, SpecialFunctions
    using StateSpaceRoutines
    using CSV, DataFrames, DataStructures, OrderedCollections
    using DataStructures: SortedDict, insert!, ForwardOrdering
    using QuantEcon: solve_discrete_lyapunov
    using Roots: fzero, ConvergenceFailed
    using StatsBase: sample, Weights
    import Calculus
    import Base.isempty, Base.<, Base.min, Base.max
    import LinearAlgebra: rank
    import StateSpaceRoutines: KalmanFilter, augment_states_with_shocks
    export
        compute_parameter_covariance, prior, get_estimation_output_files,
        compute_moments, find_density_bands, mutation, resample, smc,
        mvnormal_mixture_draw, nearest_spd, marginal_data_density,
        initial_draw!, Cloud, get_cloud,

        # util
        @test_matrix_approx_eq, @test_matrix_approx_eq_eps

    const VERBOSITY = Dict(:none => 0, :low => 1, :high => 2)

    #include("benchmark/util.jl")
    #include("benchmark/benchmark.jl")
    #include("benchmark/io.jl")

    #include("estimate.jl")
    #include("nearest_spd.jl")
    include("particle.jl")
    include("initialization.jl")
    include("helpers.jl")
    include("util.jl")
    include("mutation.jl")
    include("resample.jl")
    include("smc.jl")
end