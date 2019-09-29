# initialize train_nodes
function grow_tree(bags::Vector{Vector{BitSet}},
    δ, δ², 𝑤,
    hist_δ, hist_δ², hist_𝑤,
    params::EvoTreeRegressor,
    train_nodes::Vector{TrainNode{T, I, J, S}},
    splits::Vector{SplitInfo{T, Int}},
    tracks::Vector{SplitTrack{T}},
    edges, X_bin) where {R<:Real, T<:AbstractFloat, I<:BitSet, J<:AbstractVector{Int}, S<:Int}

    active_id = ones(Int, 1)
    leaf_count = 1::Int
    tree_depth = 1::Int
    tree = Tree(Vector{TreeNode{Float64, Int, Bool}}())

    # grow while there are remaining active nodes
    while size(active_id, 1) > 0 && tree_depth <= params.max_depth
        next_active_id = ones(Int, 0)
        # grow nodes
        for id in active_id
            node = train_nodes[id]
            if tree_depth == params.max_depth || node.∑𝑤[1] <= params.min_weight
                push!(tree.nodes, TreeNode(pred_leaf(params.loss, node, params, δ²)))
            else
                @threads for feat in node.𝑗
                    # splits[feat] = SplitInfo{Float64, Int}(node.gain, SVector{params.K, Float64}(zeros(params.K)), SVector{params.K, Float64}(zeros(params.K)), SVector{1, Float64}(zeros(1)), SVector{params.K, Float64}(zeros(params.K)), SVector{params.K, Float64}(zeros(params.K)), SVector{1, Float64}(zeros(1)), -Inf, -Inf, 0, feat, 0.0)
                    splits[feat].gain = node.gain
                    # splits[feat].gainL = -Inf
                    # splits[feat].gainR = -Inf
                    # splits[feat].∑δL *= 0.0
                    # splits[feat].∑δ²L *= 0.0
                    # splits[feat].∑𝑤L *= 0.0
                    # splits[feat].∑δR *= 0.0
                    # splits[feat].∑δ²R *= 0.0
                    # splits[feat].∑𝑤R *= 0.0
                    # splits[feat].𝑖 = 0
                    # splits[feat].cond = 0.0
                    tracks[feat] = SplitTrack{Float64}(SVector{params.K, Float64}(zeros(params.K)), SVector{params.K, Float64}(zeros(params.K)), SVector{1, Float64}(zeros(1)), node.∑δ, node.∑δ², node.∑𝑤, -Inf, -Inf, -Inf)
                    find_split_static!(hist_δ[feat], hist_δ²[feat], hist_𝑤[feat], bags[feat], view(X_bin,:,feat), δ, δ², 𝑤, params, splits[feat], tracks[feat], edges[feat], node.𝑖)
                end
                # assign best split
                best = get_max_gain(splits)
                # grow node if best split improve gain
                if best.gain > node.gain + params.γ
                    # Node: depth, ∑δ, ∑δ², gain, 𝑖, 𝑗
                    train_nodes[leaf_count + 1] = TrainNode(node.depth + 1, best.∑δL, best.∑δ²L, best.∑𝑤L, best.gainL, intersect(node.𝑖, union(bags[best.feat][1:best.𝑖]...)), node.𝑗)
                    train_nodes[leaf_count + 2] = TrainNode(node.depth + 1, best.∑δR, best.∑δ²R, best.∑𝑤R, best.gainR, intersect!(node.𝑖, union(bags[best.feat][(best.𝑖+1):end]...)), node.𝑗)
                    # push split Node
                    push!(tree.nodes, TreeNode(leaf_count + 1, leaf_count + 2, best.feat, best.cond))
                    push!(next_active_id, leaf_count + 1)
                    push!(next_active_id, leaf_count + 2)
                    leaf_count += 2
                else
                    push!(tree.nodes, TreeNode(pred_leaf(params.loss, node, params, δ²)))
                end # end of single node split search
            end
        end # end of loop over active ids for a given depth
        active_id = next_active_id
        tree_depth += 1
    end # end of tree growth
    return tree
end

# extract the gain value from the vector of best splits and return the split info associated with best split
function get_max_gain(splits::Vector{SplitInfo{Float64,Int}})
    gains = (x -> x.gain).(splits)
    feat = findmax(gains)[2]
    best = splits[feat]
    # best.feat = feat
    return best
end

# grow_gbtree
function grow_gbtree(X::AbstractArray{R, 2}, Y::AbstractVector{S}, params::EvoTreeRegressor;
    X_eval::AbstractArray{R, 2} = Array{R, 2}(undef, (0,0)), Y_eval::AbstractVector{S} = Vector{S}(undef, 0),
    early_stopping_rounds=Int(1e5), print_every_n=100, verbosity=1) where {R<:Real, S<:Real}

    seed!(params.seed)

    μ = zeros(params.K)
    μ .*= mean(Y)
    if typeof(params.loss) == Logistic
        μ = logit.(μ)
    elseif typeof(params.loss) == Poisson
        μ = log.(μ)
    elseif typeof(params.loss) == Softmax
        μ .*= 0.0
    end
    pred = ones(size(Y, 1), params.K) .* μ'

    # eval init
    if size(Y_eval, 1) > 0
        pred_eval = ones(size(Y_eval, 1), params.K) .* μ'
    end

    bias = Tree([TreeNode(SVector{1, Float64}(μ))])
    gbtree = GBTree([bias], params, Metric())

    X_size = size(X)
    𝑖_ = collect(1:X_size[1])
    𝑗_ = collect(1:X_size[2])

    # initialize gradients and weights
    δ, δ² = zeros(SVector{params.K, Float64}, X_size[1]), zeros(SVector{params.K, Float64}, X_size[1])
    𝑤 = zeros(SVector{1, Float64}, X_size[1]) .+ 1

    edges = get_edges(X, params.nbins)
    X_bin = binarize(X, edges)
    bags = Vector{Vector{BitSet}}(undef, size(𝑗_, 1))
    @threads for feat in 1:size(𝑗_, 1)
        bags[feat] = find_bags(X_bin[:,feat])
    end

    # initialize train nodes
    train_nodes = Vector{TrainNode{Float64, BitSet, Array{Int64, 1}, Int64}}(undef, 2^params.max_depth-1)
    for node in 1:2^params.max_depth-1
        train_nodes[node] = TrainNode(0, SVector{params.K, Float64}(fill(-Inf, params.K)), SVector{params.K, Float64}(fill(-Inf, params.K)), SVector{1, Float64}(fill(-Inf, 1)), -Inf, BitSet([0]), [0])
    end

    # initializde node splits info and tracks - colsample size (𝑗)
    splits = Vector{SplitInfo{Float64, Int64}}(undef, X_size[2])
    tracks = Vector{SplitTrack{Float64}}(undef, X_size[2])
    hist_δ = Vector{Vector{SVector{params.K, Float64}}}(undef, X_size[2])
    hist_δ² = Vector{Vector{SVector{params.K, Float64}}}(undef, X_size[2])
    hist_𝑤 = Vector{Vector{SVector{params.K, Float64}}}(undef, X_size[2])
    for feat in 𝑗_
        splits[feat] = SplitInfo{Float64, Int}(0.0, SVector{params.K, Float64}(zeros(params.K)), SVector{params.K, Float64}(zeros(params.K)), SVector{1, Float64}(zeros(1)), SVector{params.K, Float64}(zeros(params.K)), SVector{params.K, Float64}(zeros(params.K)), SVector{1, Float64}(zeros(1)), -Inf, -Inf, 0, feat, 0.0)
        tracks[feat] = SplitTrack{Float64}(SVector{params.K, Float64}(zeros(params.K)), SVector{params.K, Float64}(zeros(params.K)), SVector{1, Float64}(zeros(1)), SVector{params.K, Float64}(zeros(params.K)), SVector{params.K, Float64}(zeros(params.K)), SVector{1, Float64}(zeros(1)), -Inf, -Inf, -Inf)
        hist_δ[feat] = zeros(SVector{params.K, Float64}, length(bags[feat]))
        hist_δ²[feat] = zeros(SVector{params.K, Float64}, length(bags[feat]))
        hist_𝑤[feat] = zeros(SVector{1, Float64}, length(bags[feat]))
    end

    # initialize metric
    if params.metric != :none
        metric_track = Metric()
        metric_best = Metric()
        iter_since_best = 0
    end

    # loop over nrounds
    for i in 1:params.nrounds
        # select random rows and cols
        𝑖 = 𝑖_[sample(𝑖_, ceil(Int, params.rowsample * X_size[1]), replace = false)]
        𝑗 = 𝑗_[sample(𝑗_, ceil(Int, params.colsample * X_size[2]), replace = false)]

        # get gradients
        update_grads!(params.loss, params.α, pred, Y, δ, δ², 𝑤)
        ∑δ, ∑δ², ∑𝑤 = sum(δ), sum(δ²), sum(𝑤)
        gain = get_gain(params.loss, ∑δ, ∑δ², ∑𝑤, params.λ)

        # assign a root and grow tree
        train_nodes[1] = TrainNode(1, ∑δ, ∑δ², ∑𝑤, gain, BitSet(𝑖), 𝑗)
        tree = grow_tree(bags, δ, δ², 𝑤, hist_δ, hist_δ², hist_𝑤, params, train_nodes, splits, tracks, edges, X_bin)
        # push new tree to model
        push!(gbtree.trees, tree)
        # update predictions
        predict!(pred, tree, X)
        # eval predictions
        if size(Y_eval, 1) > 0
            predict!(pred_eval, tree, X_eval)
        end

        # callback function
        if params.metric != :none
            if size(Y_eval, 1) > 0
                metric_track.metric .= eval_metric(Val{params.metric}(), pred_eval, Y_eval, params.α)
            else
                metric_track.metric .= eval_metric(Val{params.metric}(), pred, Y, params.α)
            end

            if metric_track.metric < metric_best.metric
                metric_best.metric .=  metric_track.metric
                metric_best.iter .=  i
            else
                iter_since_best += 1
            end

            if mod(i, print_every_n) == 0 && verbosity > 0
                display(string("iter:", i, ", eval: ", metric_track.metric))
            end
            iter_since_best >= early_stopping_rounds ? break : nothing
        end # end of callback

    end #end of nrounds

    if params.metric != :none
        gbtree.metric.iter .= metric_best.iter
        gbtree.metric.metric .= metric_best.metric
    end
    return gbtree
end

# grow_gbtree - continue training
function grow_gbtree!(model::GBTree, X::AbstractArray{R, 2}, Y::AbstractVector{S};
    X_eval::AbstractArray{R, 2} = Array{R, 2}(undef, (0,0)), Y_eval::AbstractVector{S} = Array{Float64, 1}(undef, 0),
    early_stopping_rounds=Int(1e5), print_every_n=100, verbosity=1) where {R<:Real, S<:Real}

    params = model.params
    seed!(params.seed)

    # initialize gradients and weights
    δ, δ² = zeros(Float64, size(Y, 1)), zeros(Float64, size(Y, 1))
    𝑤 = ones(Float64, size(Y, 1))

    pred = predict(model, X)
    # eval init
    if size(Y_eval, 1) > 0
        pred_eval = predict(model, X_eval)
    end

    X_size = size(X)
    𝑖_ = collect(1:X_size[1])
    𝑗_ = collect(1:X_size[2])

    edges = get_edges(X, params.nbins)
    X_bin = binarize(X, edges)
    bags = Vector{Vector{BitSet}}(undef, size(𝑗_, 1))
    @threads for feat in 1:size(𝑗_, 1)
        bags[feat] = find_bags(X_bin[:,feat])
    end

    # initialize train nodes
    train_nodes = Vector{TrainNode{Float64, BitSet, Array{Int64, 1}, Int64}}(undef, 2^params.max_depth-1)
    for feat in 1:2^params.max_depth-1
        train_nodes[feat] = TrainNode(0, -Inf, -Inf, -Inf, -Inf, BitSet([0]), [0])
    end

    # initialize metric
    if params.metric != :none
        metric_track = model.metric
        metric_best = model.metric
        iter_since_best = 0
    end

    # loop over nrounds
    for i in 1:params.nrounds
        # select random rows and cols
        𝑖 = 𝑖_[sample(𝑖_, ceil(Int, params.rowsample * X_size[1]), replace = false)]
        𝑗 = 𝑗_[sample(𝑗_, ceil(Int, params.colsample * X_size[2]), replace = false)]

        # get gradients
        update_grads!(params.loss, params.α, pred, Y, δ, δ², 𝑤)
        ∑δ, ∑δ², ∑𝑤 = sum(δ[𝑖]), sum(δ²[𝑖]), sum(𝑤[𝑖])
        gain = get_gain(params.loss, ∑δ, ∑δ², ∑𝑤, params.λ)

        # initializde node splits info and tracks - colsample size (𝑗)
        splits = Vector{SplitInfo{Float64, Int64}}(undef, X_size[2])
        for feat in 𝑗_
            splits[feat] = SplitInfo{Float64, Int64}(-Inf, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -Inf, -Inf, 0, feat, 0.0)
        end
        tracks = Vector{SplitTrack{Float64}}(undef, X_size[2])
        for feat in 𝑗_
            tracks[feat] = SplitTrack{Float64}(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -Inf, -Inf, -Inf)
        end

        # assign a root and grow tree
        train_nodes[1] = TrainNode(1, ∑δ, ∑δ², ∑𝑤, gain, BitSet(𝑖), 𝑗)
        tree = grow_tree(bags, δ, δ², 𝑤, params, train_nodes, splits, tracks, edges, X_bin)
        # update push tree to model
        push!(model.trees, tree)

        # get update predictions
        predict!(pred, tree, X)
        # eval predictions
        if size(Y_eval, 1) > 0
            predict!(pred_eval, tree, X_eval)
        end

        # callback function
        if params.metric != :none

            if size(Y_eval, 1) > 0
                metric_track.metric .= eval_metric(Val{params.metric}(), pred_eval, Y_eval, params.α)
            else
                metric_track.metric .= eval_metric(Val{params.metric}(), pred, Y, params.α)
            end

            if metric_track.metric < metric_best.metric
                metric_best.metric .=  metric_track.metric
                metric_best.iter .=  i
            else
                iter_since_best += 1
            end

            if mod(i, print_every_n) == 0 && verbosity > 0
                display(string("iter:", i, ", eval: ", metric_track.metric))
            end
            iter_since_best >= early_stopping_rounds ? break : nothing
        end
    end #end of nrounds

    if params.metric != :none
        model.metric.iter .= metric_best.iter
        model.metric.metric .= metric_best.metric
    end
    return model
end
