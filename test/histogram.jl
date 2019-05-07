using DataFrames
using CSV
using Statistics
using Base.Threads: @threads
using StatsBase: sample

using Revise
using BenchmarkTools
using EvoTrees
using EvoTrees: get_gain, get_max_gain, update_grads!, grow_tree, grow_gbtree, SplitInfo, Tree, TrainNode, TreeNode, Params, predict, predict!, find_split!, SplitTrack, update_track!, sigmoid

# prepare a dataset
features = rand(200_000, 300)
X = features
Y = rand(size(X, 1))
𝑖 = collect(1:size(X,1))
𝑗 = collect(1:size(X,2))

# train-eval split
𝑖_sample = sample(𝑖, size(𝑖, 1), replace = false)
train_size = 0.8
𝑖_train = 𝑖_sample[1:floor(Int, train_size * size(𝑖, 1))]
𝑖_eval = 𝑖_sample[floor(Int, train_size * size(𝑖, 1))+1:end]

X_train, X_eval = X[𝑖_train, :], X[𝑖_eval, :]
Y_train, Y_eval = Y[𝑖_train], Y[𝑖_eval]

# set parameters
loss = :linear
nrounds = 1
λ = 1.0
γ = 1e-15
η = 0.5
max_depth = 5
min_weight = 5.0
rowsample = 1.0
colsample = 1.0

# params1 = Params(nrounds, λ, γ, η, max_depth, min_weight, :linear)
params1 = Params(:linear, 1, λ, γ, 1.0, 5, min_weight, rowsample, colsample)

# initial info
δ, δ² = zeros(size(X, 1)), zeros(size(X, 1))
𝑤 = ones(size(X, 1))
pred = zeros(size(Y, 1))
# @time update_grads!(Val{params1.loss}(), pred, Y, δ, δ²)
update_grads!(Val{params1.loss}(), pred, Y, δ, δ², 𝑤)
∑δ, ∑δ², ∑𝑤 = sum(δ), sum(δ²), sum(𝑤)
gain = get_gain(∑δ, ∑δ², ∑𝑤, params1.λ)

# initialize train_nodes
train_nodes = Vector{TrainNode{Float64, Array{Int64,1}, Array{Int64, 1}, Int}}(undef, 2^params1.max_depth-1)
for feat in 1:2^params1.max_depth-1
    train_nodes[feat] = TrainNode(0, -Inf, -Inf, -Inf, -Inf, [0], [0])
end
# initializde node splits info and tracks - colsample size (𝑗)
splits = Vector{SplitInfo{Float64, Int}}(undef, size(𝑗, 1))
for feat in 1:size(𝑗, 1)
    splits[feat] = SplitInfo{Float64, Int}(-Inf, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -Inf, -Inf, 0, 0, 0.0)
end
tracks = Vector{SplitTrack{Float64}}(undef, size(𝑗, 1))
for feat in 1:size(𝑗, 1)
    tracks[feat] = SplitTrack{Float64}(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -Inf, -Inf, -Inf)
end

x = X[:, 5]
x_sortperm = sortperm(x)
x_sort = x[x_sortperm]
δ_sort = δ[x_sortperm]
δ²_sort = δ²[x_sortperm]

X_bin = convert(Array{UInt8}, round.(X*31))
X_train_bin = convert(Array{UInt8}, round.(X_train*31))
X_eval_bin = convert(Array{UInt8}, round.(X_eval*31))

x_bin = X_bin[:,1]
x_bin_sort = x_bin[x_sortperm]

@btime sortperm($x)
@btime sortperm($x_bin)

x_sort = view(x, x_sortperm)
δ_sort = view(δ, x_sortperm)
δ²_sort = view(δ², x_sortperm)
𝑤_sort = view(𝑤, x_sortperm)

@btime find_split!($x_sort, $δ_sort, $δ²_sort, $𝑤_sort, $∑δ, $∑δ², $∑𝑤, $params1.λ, $splits[1], $tracks[1])
@btime find_split!($x_bin_sort, $δ_sort, $δ²_sort, $𝑤_sort, $∑δ, $∑δ², $∑𝑤, $params1.λ, $splits[1], $tracks[1])

function find_split_hist!(x::AbstractArray{T, 1}, δ::AbstractArray{Float64, 1}, δ²::AbstractArray{Float64, 1}, 𝑤::AbstractArray{Float64, 1}, ∑δ, ∑δ², ∑𝑤, λ, info::SplitInfo, track::SplitTrack) where T<:Real

    info.gain = (∑δ ^ 2 / (∑δ² + λ * ∑𝑤)) / 2.0

    track.∑δL = 0.0
    track.∑δ²L = 0.0
    track.∑𝑤L = 0.0
    track.∑δR = ∑δ
    track.∑δ²R = ∑δ²
    track.∑𝑤R = ∑𝑤

    vals = unique(x)

    # println(vals)

    @inbounds for i in vals

        ids = findall(x .== i)

        # for j in ids
            # track.∑δ²L += sum(view(δ, ids))
            # track.∑δ²L += sum(view(δ², ids))
            # track.∑𝑤L += sum(view(𝑤, ids))
            # track.∑δR -= sum(view(δ, ids))
            # track.∑δ²R -= sum(view(δ², ids))
            # track.∑𝑤R -= sum(view(𝑤, ids))

            # track.∑δL += δ[j]
            # track.∑δ²L += δ²[j]
            # track.∑𝑤L += 𝑤[j]
            # track.∑δR -= δ[j]
            # track.∑δ²R -= δ²[j]
            # track.∑𝑤R -= 𝑤[j]
        # end

        # update_track!(track, λ)
        # if track.gain > info.gain
        #     info.gain = track.gain
        #     info.gainL = track.gainL
        #     info.gainR = track.gainR
        #     info.∑δL = track.∑δL
        #     info.∑δ²L = track.∑δ²L
        #     info.∑𝑤L = track.∑𝑤L
        #     info.∑δR = track.∑δR
        #     info.∑δ²R = track.∑δ²R
        #     info.∑𝑤R = track.∑𝑤R
        #     info.cond = i
        #     info.𝑖 = i
        # end
    end
end

@btime find_split_hist!($x, $δ_sort, $δ²_sort, $𝑤, $∑δ, $∑δ², $∑𝑤, $params1.λ, $splits[1], $tracks[1])
@btime find_split_hist!($x_bin, $δ_sort, $δ²_sort, $𝑤, $∑δ, $∑δ², $∑𝑤, $params1.λ, $splits[1], $tracks[1])


function histogram(x::AbstractArray{T, 1}, δ::AbstractArray{Float64, 1}, δ²::AbstractArray{Float64, 1}, 𝑤::AbstractArray{Float64, 1}, ∑δ, ∑δ², ∑𝑤, λ, info::SplitInfo, track::SplitTrack) where T<:Real

    info.gain = (∑δ ^ 2 / (∑δ² + λ * ∑𝑤)) / 2.0

    log2_nbins = 5

    track.∑δL = 0.0
    track.∑δ²L = 0.0
    track.∑𝑤L = 0.0
    track.∑δR = ∑δ
    track.∑δ²R = ∑δ²
    track.∑𝑤R = ∑𝑤

    log2_nbins = 5
    nbins = 2^log2_nbins

    # boundaries = linspace(minimum(x[bag]), maximum(x[bag]), nbins + 1) |> collect
    # boundaries = linspace(minimum(x), maximum(x), nbins + 1) |> collect
    boundaries = range(minimum(x), stop=maximum(x), length=nbins+1) #|> collect

    vals = unique(x)
    bin = Vector{Vector{Int}}(undef, size(vals,1))

    for k in 1:nbins
        bin[k] = Int[]
    end

    for i in 1:length(x)
        k = 1 # initialize bin number
        for power in reverse(0:(log2_nbins - 1))
            δk = 2^power
            if x[i] >= boundaries[k + δk]
                k += δk
            end
        end
        push!(bin[k], i)
    end
    return bin
end

@time histogram(x, δ_sort, δ²_sort, 𝑤, ∑δ, ∑δ², ∑𝑤, params1.λ, splits[1], tracks[1])

@btime histogram(x, δ_sort, δ²_sort, 𝑤, ∑δ, ∑δ², ∑𝑤, params1.λ, splits[1], tracks[1])
@btime histogram(x_bin, δ_sort, δ²_sort, 𝑤, ∑δ, ∑δ², ∑𝑤, params1.λ, splits[1], tracks[1])


function find_bags(x::AbstractArray{T, 1}) where T<:Real

    vals = sort(unique(x))

    bags = Vector{Vector{Int}}(undef, length(vals))

    for i in 1:length(vals)
        bags[i] = findall(x .== vals[i])
    end
    return bags
end

@btime bags = find_bags($x_bin)

function histogram_2(bags, x::AbstractArray{T, 1}, δ::AbstractArray{Float64, 1}, δ²::AbstractArray{Float64, 1}, 𝑤::AbstractArray{Float64, 1}, ∑δ, ∑δ², ∑𝑤, λ, info::SplitInfo, track::SplitTrack) where T<:Real

    ∑δ = Float64[]
    for bag in bags
        intersect(bag, 𝑖)
    end
end

@btime histogram_2($bags, $x_bin, $δ_sort, $δ²_sort, $𝑤, $∑δ, $∑δ², $∑𝑤, $params1.λ, $splits[1], $tracks[1])


function set_1(x, y)
    intersect!(x, y)
    return x
end


x = rand(UInt32, 100000)
y = rand(x, 1000)

x_set = Set(x)
y_set = Set(y)

@btime set_1(x, y)
@btime set_1(x_set, y)


x = rand([1,2,3,4,5], 1000)
x = rand(1000)
x_edges = quantile(x, (0:8)/8)
x_edges = unique(x_edges)
x_edges = x_edges[2:(end-1)]

function binindices(edges, data)
    searchsortedlast.(Ref(edges), data) .+ 1
end

x_bin = binindices(x_edges, x)

binindices(x_edges, 10)

using StatsBase
x_map = countmap(x_bin)

x_edges[1]