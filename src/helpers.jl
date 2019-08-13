"""
`prior(parameters::ParameterVector{T}) where {T<:Number}`

Calculates log joint prior density of m.parameters.
"""
prior(parameters::ParameterVector{T}) where {T<:Number}
    free_params = Base.filter(θ -> !θ.fixed, parameters)
    logpdfs = map(logpdf, free_params)
    return sum(logpdfs)
end

"""
```
function solve_adaptive_ϕ(cloud::Cloud, proposed_fixed_schedule::Vector{Float64},
                          i::Int64, j::Int64, ϕ_prop::Float64, ϕ_n1::Float64,
                          tempering_target::Float64, resampled_last_period::Bool)
```
Solves for next Φ. Returns ϕ_n, resampled_last_period, j, ϕ_prop.
"""
function solve_adaptive_ϕ(cloud::Cloud, proposed_fixed_schedule::Vector{Float64},
                          i::Int64, j::Int64, ϕ_prop::Float64, ϕ_n1::Float64,
                          tempering_target::Float64, resampled_last_period::Bool)
    n_Φ = length(proposed_fixed_schedule)

    if resampled_last_period
        # The ESS_bar is reset to target an evenly weighted particle population
        ESS_bar = tempering_target * length(cloud)
        resampled_last_period = false
    else
        ESS_bar = tempering_target*cloud.ESS[i-1]
    end

    # Setting up the optimal ϕ solving function for endogenizing the tempering schedule
    optimal_ϕ_function(ϕ) = compute_ESS(get_loglh(cloud), get_weights(cloud), ϕ, ϕ_n1,
                                        old_loglh = get_old_loglh(cloud)) - ESS_bar

    # Find ϕ_prop s.t. optimal ϕ_n lies between ϕ_n1 and ϕ_prop --
    # do so by iterating through proposed_fixed_schedule and finding the first
    # ϕ_prop s.t. the ESS falls by more than the targeted amount, ESS_bar
    while optimal_ϕ_function(ϕ_prop) >= 0 && j <= n_Φ
        ϕ_prop = proposed_fixed_schedule[j]
        j += 1
    end

    # Note: optimal_ϕ_function(ϕ_n1) > 0, since ESS_{t-1} always positive.
    # When ϕ_prop != 1.0, there are still ϕ increments strictly below 1 that
    # give the optimal ϕ step, ϕ_n.

    # When ϕ_prop == 1.0 but optimal_ϕ_function(ϕ_prop) < 0, there still exists
    # an optimal ϕ step, ϕ_n, that does not equal 1.
    # Thus the interval [optimal_ϕ_function(ϕ_n1), optimal_ϕ_function(ϕ_prop)] always
    # contains a 0 by construction.

    # Modification makes it such that ϕ_n is the minimum of ϕ_prop (the fixed schedule)
    # at a given stage or the root-solved ϕ such that the ESS drops by the target amount.
    # Thus the adaptive ϕ_schedule is strictly bounded above by the fixed schedule
    # i.e. the adaptive ϕ schedule should not outpace the fixed schedule at the end
    # (when the fixed schedule tends to drop by less than 5% per iteration)
    if ϕ_prop != 1. || optimal_ϕ_function(ϕ_prop) < 0
        ϕ_n = fzero(optimal_ϕ_function, [ϕ_n1, ϕ_prop], xtol = 0.)
        push!(cloud.tempering_schedule, ϕ_n)
    else
        ϕ_n = 1.
        push!(cloud.tempering_schedule, ϕ_n)
    end
    return ϕ_n, resampled_last_period, j, ϕ_prop
end

"""
```
mvnormal_mixture_draw(θ_old, σ; cc, α, θ_prop) where {T<:AbstractFloat}
```

Create a `DegenerateMvNormal` distribution object, `d`, from a parameter vector, `p`, and a
standard deviation matrix (obtained from SVD), `σ`.

Generate a draw from the mixture distribution of:
1. A `DegenerateMvNormal` centered at θ_old with the standard deviation matrix `σ`, scaled by `cc^2` and with mixture proportion `α`.
2. A `DegenerateMvNormal` centered at the same mean, but with a standard deviation matrix of the diagonal entries of `σ` scaled by `cc^2` with mixture proportion `(1 - α)/2`.
3. A `DegenerateMvNormal`  with the same standard deviation matrix `σ` but centered at the new proposed mean, `θ_prop`, scaled by `cc^2`, and with mixture proportion `(1 - α)/2`.

If no `θ_prop` is given, but an `α` is specified, then the mixture will consist of `α` of
the standard distribution and `(1 - α)` of the diagonalized distribution.

### Arguments
- `θ_old::Vector{T}`: The mean of the desired distribution
- `σ::Matrix{T}`: The standard deviation matrix of the desired distribution

### Keyword Arguments
- `cc::T`: The standard deviation matrix scaling factor
- `α::T`: The mixing proportion
- `θ_prop::Vector{T}`: The proposed parameter vector to be used as part of the mixture distribution, set by default to be the weighted mean of the particles, prior to mutation.

### Outputs
- `θ_new::Vector{T}`: The draw from the mixture distribution to be used as the MH proposed step
- `new mixture_density::T`: The mixture density conditional on θ_old evaluated at `θ_new` to be used in calculating the MH move probability
- `old mixture_density::T`: The mixture density conditional on θ_new evaluated at `θ_old` to be used in calculating the MH move probability

"""
function mvnormal_mixture_draw(θ_old::Vector{T}, d_prop::Distribution;
                               c::T = 1.0, α::T = 1.0) where T<:AbstractFloat
    @assert 0 <= α <= 1
    d_bar = MvNormal(d_prop.μ, c^2 * d_prop.Σ)

    # Create mixture distribution conditional on the previous parameter value, θ_old
    d_old      = MvNormal(θ_old, c^2 * d_prop.Σ)
    d_diag_old = MvNormal(θ_old, diagm(0 => diag(c^2 * d_prop.Σ)))
    d_mix_old  = MixtureModel(MvNormal[d_old, d_diag_old, d_bar], [α, (1 - α)/2, (1 - α)/2])

    θ_new = rand(d_mix_old)

    # Create mixture distribution conditional on the new parameter value, θ_new
    d_new      = MvNormal(θ_new, c^2 * d_prop.Σ)
    d_diag_new = MvNormal(θ_new, diagm(0 => diag(c^2 * d_prop.Σ)))
    d_mix_new  = MixtureModel(MvNormal[d_new, d_diag_new, d_bar], [α, (1 - α)/2, (1 - α)/2])

    # The density of θ_new | θ_old and the density of θ_old | θ_new
    # taken with respect to their respective mixture densities
    new_mix_density = logpdf(d_mix_old, θ_new)
    old_mix_density = logpdf(d_mix_new, θ_old)

    return θ_new, new_mix_density, old_mix_density
end

"""
```
function compute_ESS(loglh::Vector{T}, current_weights::Vector{T}, ϕ_n::T, ϕ_n1::T;
                     old_loglh::Vector{T} = zeros(length(loglh))) where {T<:AbstractFloat}
```
Compute ESS given log likelihood, current weights, ϕ_n, ϕ_{n-1}, and old log likelihood.
"""
function compute_ESS(loglh::Vector{T}, current_weights::Vector{T}, ϕ_n::T, ϕ_n1::T;
                     old_loglh::Vector{T} = zeros(length(loglh))) where T<:AbstractFloat
    inc_weights  = exp.((ϕ_n1 - ϕ_n) * old_loglh + (ϕ_n - ϕ_n1) * loglh)
    new_weights  = current_weights .* inc_weights
    norm_weights = new_weights / sum(new_weights)
    ESS          = 1 / sum(norm_weights .^ 2)
    return ESS
end

"""
```
function generate_free_blocks(n_free_para, n_blocks)
```

Return a Vector{Vector{Int64}} where each internal Vector{Int64} contains a subset of the range
1:n_free_para of randomly permuted indices. This is used to index out random blocks of free
parameters from the covariance matrix for the mutation step.
"""
function generate_free_blocks(n_free_para::Int64, n_blocks::Int64)
    rand_inds = shuffle(1:n_free_para)

    subset_length     = cld(n_free_para, n_blocks) # ceiling division
    last_block_length = n_free_para - subset_length*(n_blocks - 1)

    blocks_free = Vector{Vector{Int64}}(undef, n_blocks)
    for i in 1:n_blocks
        if i < n_blocks
            blocks_free[i] = rand_inds[((i-1)*subset_length + 1):(i*subset_length)]
        else
            # To account for the fact that the last block may be smaller than the others
            blocks_free[i] = rand_inds[end-last_block_length+1:end]
        end
    end
    return blocks_free
end

"""
```
function generate_all_blocks(blocks_free, free_para_inds)
```

Return a Vector{Vector{Int64}} where each internal Vector{Int64} contains indices
corresponding to those in `blocks_free` but mapping to `1:n_para` (as opposed to
`1:n_free_para`). These blocks are used to reconstruct the particle vector by
inserting the mutated free parameters into the size `n_para,` particle vector,
which also contains fixed parameters.
"""
function generate_all_blocks(blocks_free::Vector{Vector{Int64}}, free_para_inds::Vector{Int64})
    n_free_para = length(free_para_inds)
    ind_mappings = Dict{Int64, Int64}()

    for (k, v) in zip(1:n_free_para, free_para_inds)
        ind_mappings[k] = v
    end

    blocks_all = similar(blocks_free)
    for (i, block) in enumerate(blocks_free)
        blocks_all[i] = similar(block)
        for (j, b) in enumerate(block)
            blocks_all[i][j] = ind_mappings[b]
        end
    end
    return blocks_all
end