# Creating a struct to store data about option and later fit
# volatility smile
struct OptionData
    secid
	date
	exdate
	spot
	strikes
	impl_vol
    T
end

struct SVIParams
    m
    sigma
    rho
    a
    b
    obj
    opt_result
end

function interpolate_int_rate(date_obs, date_val, zcb)
    opt_days_maturity = Dates.value(date_val - date_obs)

    zcb_sub = zcb[zcb.date .== date_obs, :]
    x = zcb_sub[:days]
    y = zcb_sub[:rate]

    if opt_days_maturity < minimum(x)
        int_rate = minimum(x)
    else
        x1 = x[x .<= opt_days_maturity][end]
        y1 = y[x .<= opt_days_maturity][end]

        x2 = x[x .> opt_days_maturity][1]
        y2 = y[x .> opt_days_maturity][1]

        int_rate = y1 + (y2 - y1) * (opt_days_maturity - x1)/(x2-x1)
    end

    return int_rate/100
end

function fit_svi_bdbg_smile_grid(option::OptionData)
    log_moneyness = log.(option.strikes ./ option.spot)
    impl_var = option.impl_vol .^ 2
    # T = Dates.value(option.exdate - option.date)
    T = option.T

    # Performing grid search to find good starting values for
    # numerical optimization over (m, sigma)
    dim_m_grid = 30
    range_m_grid = LinRange(-1, 1, dim_m_grid)
    dim_sigma_grid = 30
    range_sigma_grid = LinRange(0.00001, 10, dim_sigma_grid)
    obj_grid = ones(dim_m_grid, dim_sigma_grid) .* Inf

    function to_minimize(x::Vector, grad::Vector)
        beta_opt, obj = obj_bdbg_fix_m_sigma(x[1], x[2], log_moneyness, impl_var, T)
        return obj
    end

    for i = 1:dim_m_grid
        for j = 1:dim_sigma_grid
            obj_grid[i,j] = to_minimize([range_m_grid[i], range_sigma_grid[j]], [0, 0])
        end
    end

    index_min = findmin(obj_grid)[2]
    i_min = index_min[1]
    j_min = index_min[2]

    m_start = range_m_grid[i_min]
    sigma_start = range_sigma_grid[j_min]
    x0 = [m_start, sigma_start]

    opt = Opt(:LN_COBYLA, 2)
    lower_bounds!(opt, [-1, 0.00001])
    upper_bounds!(opt, [1, Inf])
    ftol_abs!(opt, 1e-12)

    min_objective!(opt, to_minimize)
    (minf,minx,ret) = optimize(opt, x0)

    m_opt = minx[1]
    sigma_opt = minx[2]
    rho_opt = 0

    # Getting optimal values of a and b implied by m and sigma:
    beta_opt, obj = obj_bdbg_fix_m_sigma(m_opt, sigma_opt, log_moneyness, impl_var, T)
    a_opt = beta_opt[1]
    b_opt = beta_opt[2]/sigma_opt

    # Constructing SVIparams struct for outputting the result:
    return (m_opt, sigma_opt, rho_opt, a_opt, b_opt, minf, ret)
end

function fit_svi_bdbg_smile_global(option::OptionData)
    log_moneyness = log.(option.strikes ./ option.spot)
    impl_var = option.impl_vol .^ 2
    # T = Dates.value(option.exdate - option.date)
    T = option.T

    function to_minimize(x::Vector, grad::Vector)
        beta_opt, obj = obj_bdbg_fix_m_sigma(x[1], x[2], log_moneyness, impl_var, T)
        return obj
    end

    opt1 = Opt(:GN_DIRECT_L, 2)
    lower_bounds!(opt1, [-1, 0.00001])
    upper_bounds!(opt1, [1, 10])
    ftol_abs!(opt1, 1e-12)

    min_objective!(opt1, to_minimize)
    x0 = [-0.9, 2]
    (minf,minx,ret) = optimize(opt1, x0)

    opt2 = Opt(:LN_COBYLA, 2)
    lower_bounds!(opt2, [-1, 0.00001])
    upper_bounds!(opt2, [1, Inf])
    ftol_abs!(opt2, 1e-12)

    min_objective!(opt2, to_minimize)
    (minf,minx,ret) = optimize(opt2, minx)

    m_opt = minx[1]
    sigma_opt = minx[2]
    rho_opt = 0

    # Getting optimal values of a and b implied by m and sigma:
    beta_opt, obj = obj_bdbg_fix_m_sigma(m_opt, sigma_opt, log_moneyness, impl_var, T)
    a_opt = beta_opt[1]
    b_opt = beta_opt[2]/sigma_opt

    return (m_opt, sigma_opt, rho_opt, a_opt, b_opt, minf, ret)
end

function fit_svi_var_rho_smile_grid(option::OptionData)
    log_moneyness = log.(option.strikes ./ option.spot)
    impl_var = option.impl_vol .^ 2
    # T = Dates.value(option.exdate - option.date)
    T = option.T

    # Performing grid search to find good starting values for
    # numerical optimization over (m, sigma)
    dim_m_grid = 30
    range_m_grid = LinRange(-1, 1, dim_m_grid)
    dim_sigma_grid = 30
    range_sigma_grid = LinRange(0.00001, 10, dim_sigma_grid)
    dim_rho_grid = 10
    range_rho_grid = LinRange(-1, 1, dim_rho_grid)
    obj_grid = ones(dim_m_grid, dim_sigma_grid, dim_rho_grid) .* Inf

    function to_minimize(x::Vector, grad::Vector)
        beta_opt, obj = obj_var_rho_fixed_m_sigma(x[1], x[2], x[3], log_moneyness, impl_var, T)
        return obj
    end

    for i = 1:dim_m_grid
        for j = 1:dim_sigma_grid
            for k = 1:dim_rho_grid
                obj_grid[i,j,k] = to_minimize([range_m_grid[i], range_sigma_grid[j], range_rho_grid[k]], [0, 0])
            end
        end
    end

    index_min = findmin(obj_grid)[2]
    i_min = index_min[1]
    j_min = index_min[2]
    k_min = index_min[3]

    m_start = range_m_grid[i_min]
    sigma_start = range_sigma_grid[j_min]
    rho_start = range_rho_grid[k_min]
    x0 = [m_start, sigma_start, rho_start]

    opt = Opt(:LN_COBYLA, 3)
    lower_bounds!(opt, [-1, 0.00001, -1])
    upper_bounds!(opt, [1, Inf, 1])
    ftol_abs!(opt, 1e-8)

    min_objective!(opt, to_minimize)
    (minf,minx,ret) = optimize(opt, x0)

    m_opt = minx[1]
    sigma_opt = minx[2]
    rho_opt = minx[3]

    # Getting optimal values of a and b implied by m and sigma:
    beta_opt, obj = obj_var_rho_fixed_m_sigma(m_opt, sigma_opt, rho_opt, log_moneyness, impl_var, T)
    a_opt = beta_opt[1]
    b_opt = beta_opt[2]

    return (m_opt, sigma_opt, rho_opt, a_opt, b_opt, minf, ret)
end

function fit_svi_var_rho_smile_global(option::OptionData)
    log_moneyness = log.(option.strikes ./ option.spot)
    impl_var = option.impl_vol .^ 2
    # T = Dates.value(option.exdate - option.date)
    T = option.T

    function to_minimize(x::Vector, grad::Vector)
        beta_opt, obj = obj_var_rho_fixed_m_sigma(x[1], x[2], x[3], log_moneyness, impl_var, T)
        return obj
    end

    opt1 = Opt(:GN_DIRECT_L, 3)
    lower_bounds!(opt1, [-1, 0.00001, -1])
    upper_bounds!(opt1, [1, 10, 1])
    ftol_abs!(opt1, 1e-8)

    min_objective!(opt1, to_minimize)
    x0 = [-0.9, 2, 0]
    (minf,minx,ret) = optimize(opt1, x0)

    opt2 = Opt(:LN_COBYLA, 3)
    lower_bounds!(opt2, [-1, 0.00001, -1])
    upper_bounds!(opt2, [1, Inf, 1])
    ftol_abs!(opt2, 1e-12)

    min_objective!(opt2, to_minimize)
    (minf,minx,ret) = optimize(opt2, minx)

    m_opt = minx[1]
    sigma_opt = minx[2]
    rho_opt = minx[3]

    # Getting optimal values of a and b implied by m and sigma:
    beta_opt, obj = obj_var_rho_fixed_m_sigma(m_opt, sigma_opt, rho_opt, log_moneyness, impl_var, T)
    a_opt = beta_opt[1]
    b_opt = beta_opt[2]

    return (m_opt, sigma_opt, rho_opt, a_opt, b_opt, minf, ret)
end

################################################################################
# Supporting functions for fitting SVI smile with rho = 0
################################################################################

function svi_smile(k, m, sigma, rho, a, b)
	return a .+ b.*(rho.*(k.-m) .+ sqrt.((k .- m).^2 .+ sigma.^2))
end

function  satisfies_constraints(sigma, beta, max_v)
    a = beta[1]
    c = beta[2]

    satisfies = true
    if c < 0 || c > 4*sigma || a < -c || a > max_v
        satisfies = false
    end

    return satisfies
end

function constrained_opt(X, v, R = None, b = None)
    XX_inv = inv(X' * X)
    if isequal(R, missing) || isequal(b, missing)
        beta = XX_inv * X' * v
    else
        lambda_ = inv(R * XX_inv * R') * (b .- R * XX_inv * X' * v)
        beta = XX_inv * (X' * v + R' * lambda_)
    end

    return beta
end

function compare_and_update_beta(X, v, beta, min_obj, beta_opt)
    obj = sum((X * beta - v).^2)
    if obj < min_obj
        beta_opt = beta
        min_obj = obj
    end

    return beta_opt, min_obj
end

function calculate_and_update_beta(X, v, min_obj, beta_opt, sigma, max_v, R = missing, b = missing)
    beta = constrained_opt(X, v, R, b)
    if satisfies_constraints(sigma, beta, max_v)
        beta_opt, min_obj = compare_and_update_beta(X, v, beta, min_obj, beta_opt)
    end

    return beta_opt, min_obj
end

function obj_bdbg_fix_m_sigma(m, sigma, log_moneyness, impl_var, T)

    N = length(log_moneyness)
    y = (log_moneyness .- m)./sigma
    y_hyp = sqrt.(y.^2 .+ 1)
    v = impl_var
    v = hcat(v...)' # Transforming into 2-dim array

    min_obj = Inf
    beta_opt = zeros(2,1)

    ########################################################
    # 1. Looking for internal optimum
    # Minimizing the sum of squares (doing linear regression)
    # and checking if it satisfies no arbitrage constraints
    # on coefficients:
    X = ones(N,2)
    X[:, 2] = y_hyp
    max_v = maximum(v)

    beta_opt, min_obj = calculate_and_update_beta(X, v, min_obj, beta_opt, sigma, max_v)

    # If the value (and minimum of the objective) was not updated
    # it means that the solution to unconstrained LS problem doesn't
    # satisfy the constraints. Therefore, we need to continue to
    # check the sides vertices of the parameter space. If, on the
    # other hand, the objective was updated, it means that the
    # solution to unconstrained Ls problem satisfies constraints and
    # since the problem is convex it will be the global minimum.
    if isequal(min_obj, Inf)
        ########################################################
        # 2. Looking at sides of parallelepipid:
        # i. c = 0
        R = hcat([0,1]...)
        b = hcat([0]...)
        beta_opt, min_obj = calculate_and_update_beta(X, v, min_obj, beta_opt, sigma, max_v, R, b)

        # ii. c = 4\sigma
        R = hcat([0,1]...)
        b = hcat([4 * sigma]...)
        beta_opt, min_obj = calculate_and_update_beta(X, v, min_obj, beta_opt, sigma, max_v, R, b)

        # iii. a = -c => a + c = 0
        R = hcat([1, 1]...)
        b = hcat([0]...)
        beta_opt, min_obj = calculate_and_update_beta(X, v, min_obj, beta_opt, sigma, max_v, R, b)

        # iv. a = max_v
        R = hcat([1, 0]...)
        b = hcat([max_v]...)
        beta_opt, min_obj = calculate_and_update_beta(X, v, min_obj, beta_opt, sigma, max_v, R, b)

        ########################################################
        # 3. Calculating objective in vertices of the constraints
        # rectangle
        # i. a = 0, c = 0
        beta_vert_1 = hcat([0,0]...)'
        beta_opt, min_obj = compare_and_update_beta(X, v, beta_vert_1, min_obj, beta_opt)

        # ii. a = -4sigma, c = 4sigma
        beta_vert_2 = hcat([-4 * sigma,4 * sigma]...)'
        beta_opt, min_obj = compare_and_update_beta(X, v, beta_vert_2, min_obj, beta_opt)

        # iii. a = max_v, c = 0
        beta_vert_3 = hcat([max_v, 0]...)'
        beta_opt, min_obj = compare_and_update_beta(X, v, beta_vert_3, min_obj, beta_opt)

        # iv. a = max_v, c = 4sigma
        beta_vert_4 = hcat([max_v, 4 * sigma]...)'
        beta_opt, min_obj = compare_and_update_beta(X, v, beta_vert_4, min_obj, beta_opt)
    end

    return beta_opt, min_obj
end

############################################################
# Supporting functions for SVI fitting with variable rho
############################################################

function satisfies_constraints_var_rho(beta, sigma, rho, max_v)
    a = beta[1]
    c = beta[2]

    satisfies = true
    if c < 0 || c > 4/(1+abs(rho)) || a < -c*sigma*sqrt(1-rho^2) || a > max_v
        satisfies = false
    end

    return satisfies
end

function calculate_and_update_beta_var_rho(X, v, min_obj, beta_opt, sigma, rho, max_v, R = missing, b = missing)
    beta = constrained_opt(X, v, R, b)
    if satisfies_constraints_var_rho(beta, sigma, rho, max_v)
        beta_opt, min_obj = compare_and_update_beta(X, v, beta, min_obj, beta_opt)
    end

    return beta_opt, min_obj
end

function obj_var_rho_fixed_m_sigma(m, sigma, rho, log_moneyness, impl_var, T)
    N = length(log_moneyness)
    y = (log_moneyness .- m)./sigma
    y_hyp = rho .* sigma .* y .+ sigma .* sqrt.(y.^2 .+ 1)
    v = impl_var
    v = hcat(v...)' # Transforming into 2-dim array

    min_obj = Inf
    beta_opt = zeros(2,1)

    ########################################################
    # 1. Looking for internal optimum
    # Minimizing the sum of squares (doing linear regression)
    # and checking if it satisfies no arbitrage constraints
    # on coefficients:
    X = ones(N,2)
    X[:, 2] = y_hyp
    max_v = maximum(v)

    beta_opt, min_obj = calculate_and_update_beta_var_rho(X, v, min_obj, beta_opt, sigma, rho, max_v)

    if isequal(min_obj, Inf)
        ########################################################
        # 2. Looking at sides of parallelepipid:
        # i. c = 0
        R = hcat([0,1]...)
        b = hcat([0]...)
        beta_opt, min_obj = calculate_and_update_beta_var_rho(X, v, min_obj, beta_opt, sigma, rho, max_v, R, b)

        # ii. c = 4/(1+|rho|)
        R = hcat([0,1]...)
        b = hcat([4/(1 + abs(rho))]...)
        beta_opt, min_obj = calculate_and_update_beta_var_rho(X, v, min_obj, beta_opt, sigma, rho, max_v, R, b)

        # iii. a = -c*sigma*sqrt(1-rho^2) => a + c*sigma*sqrt(1-rho^2) = 0
        R = hcat([1, sigma*sqrt(1-rho^2)]...)
        b = hcat([0]...)
        beta_opt, min_obj = calculate_and_update_beta_var_rho(X, v, min_obj, beta_opt, sigma, rho, max_v, R, b)

        # iv. a = max_v
        R = hcat([1, 0]...)
        b = hcat([max_v]...)
        beta_opt, min_obj = calculate_and_update_beta_var_rho(X, v, min_obj, beta_opt, sigma, rho, max_v, R, b)

        ########################################################
        # 3. Calculating objective in vertices of the constraints
        # rectangle
        # i. a = 0, c = 0
        beta_vert_1 = hcat([0,0]...)'
        beta_opt, min_obj = compare_and_update_beta(X, v, beta_vert_1, min_obj, beta_opt)

        # ii. a = -4*sigma*sqrt(1-rho^2)/(1+|rho|), c = 4/(1+|rho|)
        beta_vert_2 = hcat([-4 * sigma * sqrt(1-rho^2)/(1+abs(rho)), 4/(1+abs(rho))]...)'
        beta_opt, min_obj = compare_and_update_beta(X, v, beta_vert_2, min_obj, beta_opt)

        # iii. a = max_v, c = 4*sigma/(1+|rho|)
        beta_vert_3 = hcat([max_v, 4*sigma/(1+abs(rho))]...)'
        beta_opt, min_obj = compare_and_update_beta(X, v, beta_vert_3, min_obj, beta_opt)

        # iv. a = max_v, c = 0
        beta_vert_4 = hcat([max_v, 0]...)'
        beta_opt, min_obj = compare_and_update_beta(X, v, beta_vert_4, min_obj, beta_opt)
    end

    return beta_opt, min_obj
end

################################################
# Functions for fitting cubic spline
################################################
struct CubicSplineParams
    x
    a
    b
    c
    d
    left_vol
    right_vol
end

# Proceeding to the actual fitting algorithm:
function fitCubicSpline(option::OptionData)
    x = log.(option.strikes ./ option.spot)
    n = length(x)
    h = x[2:n] .- x[1:(n-1)]
    sigma = option.impl_vol
    sigma_diff = sigma[2:n] .- sigma[1:(n-1)]

    diagA = zeros(n)
    diagA[1:(n-1)] = 2*h
    diagA[2:n] = diagA[2:n] + 2*h

    A = spdiagm(0 => diagA, 1 => h, -1 => h)

    y = zeros(n)
    y[1:(n-1)] = 6 * sigma_diff ./ h
    y[2:n] = y[2:n] - 6 * sigma_diff ./ h
    y = hcat(y...)'

    z = inv(Matrix(A)) * y

    # Calculating the actual coefficients:
    d = (z[2:n] - z[1:(n-1)])./(6 * h)
    c = z[1:(n-1)]./2
    b = -z[1:(n-1)] .* h / 3 - z[2:n] .* h/6 + sigma_diff ./h
    a = sigma[1:(n-1)]

    spline = CubicSplineParams(x, a, b, c, d, sigma[1], sigma[n])
end

# Calculate fitted value for cubic spline:
function calculateSplineVol(x, spline::CubicSplineParams)
    if x <= minimum(spline.x)
        return spline.left_vol
    elseif x >= maximum(spline.x)
        return spline.right_vol
    else
        ind_cur = findall(a -> x .< a, spline.x)[1] - 1
        x_i = spline.x[ind_cur]
        a_i = spline.a[ind_cur]
        b_i = spline.b[ind_cur]
        c_i = spline.c[ind_cur]
        d_i = spline.d[ind_cur]

        return a_i + b_i * (x - x_i) + c_i * (x - x_i)^2 + d_i * (x - x_i)^3
    end
end

############################################################
# Plotting the results
############################################################

function plot_vol_smile(option::OptionData, params::SVIParams,
                         label, ax = Missing)
    if isequal(ax, Missing)
        fig = figure("An example", figsize=(10,8));
        ax = fig[:add_subplot](1,1,1);
    end

    log_moneyness = log.(option.strikes/option.spot)
    impl_var = option.impl_vol.^2

    range_log_moneyness = log_moneyness[end] - log_moneyness[1]
    plot_range = LinRange(log_moneyness[1] - range_log_moneyness*0.05,
                          log_moneyness[end] + range_log_moneyness*0.05, 1000);

    ax[:scatter](log_moneyness, impl_var, alpha = 0.25, c = "b")
    ax[:plot](plot_range, svi_smile(plot_range, params.m,
                                    params.sigma, params.rho,
                                    params.a, params.b),
              c = "r", linewidth = 1)

    ax[:set_title](label)
    ax[:set_xlabel]("log(Strike/Spot)")
    ax[:set_ylabel]("Implied Variance")

    return ax
end

# This function has the same name but different type of parameter
# argumet. It will figure out on its own which one to use when
# I pass a particular type of parameters

function plot_vol_smile(option::OptionData, params::CubicSplineParams,
                         label, ax = Missing)
    if isequal(ax, Missing)
     fig = figure("An example", figsize=(10,8));
     ax = fig[:add_subplot](1,1,1);
    end

    # defining helper function
    function calculateSplineVolInstance(x)
        return calculateSplineVol(x, params)
    end

    fig = figure("An example", figsize=(10,8));
    ax = fig[:add_subplot](1,1,1);

    log_moneyness = log.(option.strikes/option.spot)
    range_log_moneyness = log_moneyness[end] - log_moneyness[1]

    plot_range = LinRange(log_moneyness[1] - range_log_moneyness*0.05,
                          log_moneyness[end] + range_log_moneyness*0.05, 1000);

    ax[:scatter](log_moneyness, option.impl_vol, alpha = 0.25, c = "b")
    ax[:plot](plot_range, map(calculateSplineVolInstance, plot_range), alpha = 0.25,
              c = "r", linewidth = 1)

    ax[:set_title]("Title")
    ax[:set_xlabel]("log(Strike/Spot)")
    ax[:set_ylabel]("Implied Variance")

    return ax
end



################################################################
# Functions to calculate Call/Put option prices for given strike
################################################################

function BS_call_price(S0, q, r, K, sigma, T)
    d1 = (log(S0/K) + (r - q + sigma^2/2)*T)/(sigma*sqrt(T))
    d2 = d1 - sigma*sqrt(T)

    p1 = exp(-q*T) * S0 * cdf.(Normal(), d1)
    p2 = exp(-r*T) * K * cdf.(Normal(), d2)

    return p1 - p2
end

# Calculating BS put price:
function BS_put_price(S0, q, r, K, sigma, T)
    d1 = (log(S0/K) + (r - q + sigma^2/2)*T)/(sigma*sqrt(T))
    d2 = d1 - sigma*sqrt(T)

    p1 = cdf.(Normal(), -d2) * K * exp(-r*T)
    p2 = cdf.(Normal(), -d1) * S0 * exp(-q*T)

    return p1 - p2
end

# Function to calculate interpolated implied volatility for a
# given OptionData and SVI interpolated volatility smile
function calc_interp_impl_vol(option::OptionData, interp_params::SVIParams, strike)
    spot = option.spot
    log_moneyness = log.(strike/spot) # SVI was interpolated as a function of
                                      # the log of the ratio of strike to
                                      # current spot price of the underlying asset

    m = interp_params.m
    sigma = interp_params.sigma
    rho = interp_params.rho
    a = interp_params.a
    b = interp_params.b

    interp_impl_var = svi_smile(log_moneyness, m, sigma, rho, a, b)

    # SVI is formulated with implie variance (sigma^2) as its value. Therefore,
    # we need to take a square root before squaring it
    return interp_impl_var .^ 0.5
end

# Function to calculate interpolated implied volatility for a
# given OptionData and Cubic Spline interpolated volatility smile
# it has the same name, but different argument type. Julia takes care of it
function calc_interp_impl_vol(option::OptionData, interp_params::CubicSplineParams, strike)
    log_moneyness = log.(strike/option.spot)

    return calculateSplineVol(log_moneyness, interp_params)
end

# Function to calculate Call (Put) option value given OptionData and
# an struct with interpolation parameters:
function calc_option_value(option::OptionData, interp_params, strike, option_type)
    # Getting implied vol for this particular strike given an interpolated
    # volatility smile
    impl_vol = calc_interp_impl_vol(option, interp_params, strike)

    # Calculating Call (Put) option price
    r = option.int_rate
    F = option.forward
    T = option.T

    if option_type == "Call"
        option_price = BS_call_price.(F * exp(-r*T), 0, r,
                                      strike, impl_vol, T)
    elseif option_type == "Put"
        option_price = BS_put_price.(F * exp(-r*T), 0, r,
                                     strike, impl_vol, T)
    else
        error("option_type should be Call or Put")
    end

    return option_price
end


# Function to calculate Risk-Neutral CDF and PDF:
function calc_RN_CDF_PDF(option::OptionData, interp_params, strike)
    spot = option.spot
    r = option.int_rate
    T = option.T

    # function to calculate call option price for a specific
    # option and interpolation parameters:
    calc_specific_option_put_value = K -> calc_option_value(option, interp_params, K, "Put")

    # First derivative of put(strike) function
    der_1_put = K -> ForwardDiff.derivative(calc_specific_option_put_value, K)

    # Second derivative of call(strike) function
    der_2_put = K -> ForwardDiff.derivative(der_1_put, K)

    # Calculaing CDF and PDF:
    cdf_value = exp(r * T) * der_1_put(strike)
    pdf_value = exp(r * T) * der_2_put(strike)

    return cdf_value, pdf_value
end