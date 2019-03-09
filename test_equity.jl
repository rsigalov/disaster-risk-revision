using Distributed

print("\nNumber of processors ")
print(nprocs())
print("\n")

print("\n ---- Loading libraries ----\n")

using DataFrames # self explanatory
@everywhere using NLopt # Package to perform numerical optiimization
@everywhere using LinearAlgebra # Package with some useful functions
@everywhere using Distributions # Package for normal CDF
@everywhere using HCubature # Package to numerically integrate
@everywhere using ForwardDiff # Package to numerically differentiate
@everywhere using Dierckx # Package for interpolation
@everywhere include("funcs.jl")

using CSV
using Dates

print("\n--- Loading Data ----\n")

index_to_append = ARGS[1]

# Loading data on options:
opt_data_filepath = string("data/opt_data_", index_to_append, ".csv")
df = CSV.read(opt_data_filepath; datarow = 2, delim = ",")

# Calculating number of options per secid, observation date and expiration date
df_unique_N = by(df, [:secid, :date, :exdate], number = :cp_flag => length)

# If don't have at least 5 observations throw this option out since
# we need to minimize over 4 variables:
df_unique = df_unique_N[df_unique_N[:number] .>= 5, :][:, [:secid,:date,:exdate]]
num_options = size(df_unique)[1]
# num_options = 1000

print(string("\nHave ", num_options, " smiles in total to fit\n"))

# Loading data on dividend distribution:
dist_data_filepath = string("data/dist_data_", index_to_append, ".csv")
dist_hist = CSV.read(dist_data_filepath; datarow = 2, delim = ",")

# Loading data on interest rate to interpolate cont-compounded rate:
zcb = CSV.read("data/zcb_data.csv"; datarow = 2, delim = ",")
zcb = sort(zcb, [:date, :days])

print("\n--- Generating array with options ----\n")
option_arr = Array{OptionData, 1}(undef, num_options)
i_option = 0

for subdf in groupby(df[1:100000,:], [:secid, :date, :exdate])
    if i_option % 2500 == 0
        print(string("Preparing option smile ", i_option, " out of ", num_options, "\n"))
    end
    if size(subdf)[1] >= 5 # include only smiles with at least 5 observations:

        obs_date = subdf.date[1]
        exp_date = subdf.exdate[1]
        secid = subdf.secid[1]
        # print(string(obs_date," ",exp_date, " ", "\n"))

        spot = subdf.under_price[1]
        opt_days_maturity = Dates.value(exp_date - obs_date)
        T = (opt_days_maturity - 1)/365

        subzcb = zcb[zcb.date .== obs_date,:]
        if size(subzcb)[1] == 0
            subzcb = zcb[zcb.date .<= obs_date,:]
            prev_obs_date = subzcb.date[end]
            subzcb = zcb[zcb.date .== prev_obs_date,:]
        end
        x = subzcb.days
        y = subzcb.rate
        interp_rate = Spline1D(x, y, k = 1) # creating linear interpolation object
                                            # that we can use later as well

        int_rate = interp_rate(opt_days_maturity - 1)./100

        index_before = (dist_hist.secid .== secid) .& (dist_hist.ex_date .<= exp_date) .& (dist_hist.ex_date .>= obs_date)
        if count(index_before) == 0
            dist_pvs = [0.0]
        else
            dist_days = Dates.value.(dist_hist[index_before, :].ex_date .- obs_date) .- 1
            dist_amounts = dist_hist[index_before, :].amount

            dist_rates = map(days -> interp_rate(days), dist_days)./100

            dist_pvs = exp.(-dist_rates .* dist_days/365) .* dist_amounts
        end

        forward = (spot - sum(dist_pvs))/exp(-int_rate .* T)

        ############################################################
        ### Additional filter related to present value of strike and dividends:
        ### Other filters are implemented in SQL query directly
        # For call options we should have C >= max{0, spot - PV(K) - PV(dividends)}
        # For Put options we should have P >= max{0, PV(K) + PV(dividends) - spot}
        # If options for certain strikes violate these conditions we should remove
        # them from the set of strikes
        strikes_put = subdf[subdf.cp_flag .== "P",:strike_price]./1000
        strikes_call = subdf[subdf.cp_flag .== "C", :strike_price]./1000
        call_min = max.(0, spot .- strikes_call .* exp(-int_rate * T) .- sum(dist_pvs))
        put_min = max.(0, strikes_put .* exp(-int_rate*T) .+ sum(dist_pvs) .- spot)

        df_filter = subdf[subdf.mid_price .>= [put_min; call_min],:]
        strikes = df_filter.strike_price./1000
        impl_vol = df_filter.impl_volatility
        if length(strikes) >= 5
            global i_option += 1
            option_arr[i_option] = OptionData(secid, obs_date, exp_date, spot, strikes,
                                              impl_vol, T, int_rate, forward)
        end
    end
end

option_arr = option_arr[1:i_option]
num_options = length(option_arr) # Updating number of smiles to count only those
                                 # that have at least 5 options available after
                                 # additional present value filter

print("\n--- Doing stuff ---")
print("\n--- Fitting SVI Volatility Smile ---\n")
print("\n--- First Pass ---\n")
@time tmp = pmap(fit_svi_zero_rho_global, option_arr[1:2])
print("\n--- Second Pass ---\n")
@time svi_arr = pmap(fit_svi_zero_rho_global, option_arr)

print("\n--- Estimating parameters ---\n")
print("\n--- First Pass ---\n")
@time tmp = pmap(estimate_parameters, option_arr[1:2], svi_arr[1:2])
print("\n--- Second Pass ---\n")
@time ests = pmap(estimate_parameters, option_arr[1:1000], svi_arr[1:1000])

print("\n--- Outputting Data ---\n")
df_out = DataFrame(secid = map(x -> x.secid, option_arr),
                   date = map(x -> x.date, option_arr),
                   T = map(x -> x.T, option_arr),
                   V = map(x -> x[1], ests),
                   IV = map(x -> x[2], ests),
                   V_in_sample = map(x -> x[3], ests),
                   IV_in_sample = map(x -> x[4], ests),
                   V_5_5 = map(x -> x[5], ests),
                   IV_5_5 = map(x -> x[6], ests),
                   V_otm = map(x -> x[7], ests),
                   IV_otm = map(x -> x[8], ests),
                   V_otm_in_sample = map(x -> x[9], ests),
                   IV_otm_in_sample = map(x -> x[10], ests),
                   V_otm_5_5 = map(x -> x[11], ests),
                   IV_otm_5_5 = map(x -> x[12], ests),
                   V_otm1 = map(x -> x[13], ests),
                   IV_otm1 = map(x -> x[14], ests),
                   V_otm1_in_sample = map(x -> x[15], ests),
                   IV_otm1_in_sample = map(x -> x[16], ests),
                   V_otm1_5_5 = map(x -> x[17], ests),
                   IV_otm1_5_5 = map(x -> x[18], ests),
                   rn_prob_2sigma = map(x -> x[19], ests),
                   rn_prob_40ann = map(x -> x[20], ests))

CSV.write(string("output/var_ests_", index_to_append, ".csv"), df_out)

print("\n--- Done ---\n")



################################################################################
# Testing stuff
################################################################################

plot_vol_smile(option::OptionData, params::SVIParams,
                         label, ax = Missing, col_scatter = "b", col_line = "r")
