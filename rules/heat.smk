
rule annual_heat_demand:
    message: "Calculate national heat demand for household and commercial sectors"
    input:
        hh_end_use = "data/automatic/eurostat-hh-end-use.tsv.gz",
        ch_end_use = "data/automatic/ch-end-use.xlsx",
        energy_balance = rules.annual_energy_balances.output[0],
        commercial_demand = "build/data/jrc-idees/heat/commercial/jrc_idees_processed_energy.csv",
        carrier_names = "config/energy-balances/energy-balance-carrier-names.csv"
    params:
        heat_tech_params = config["parameters"]["heat-end-use"],
        countries = config["scope"]["spatial"]["countries"],
    conda: "../envs/default.yaml"
    output:
        demand=temp("build/data/heat/annual-heat-demand-twh.csv"),
        electricity=temp("build/data/heat/annual-heat-electricity-consumption-twh.csv"),
    script: "../scripts/heat/annual_heat_demand.py"

rule rescale_annual_heat_demand_to_resolution:
    message: "Re-scale national heat demand at {wildcards.resolution} for household and commercial sectors"
    input:
        annual_demand = rules.annual_heat_demand.output["demand"],
        electricity = rules.annual_heat_demand.output["electricity"],
        locations = "build/data/regional/units.csv",
        populations = "build/data/regional/population.csv"
    conda: "../envs/default.yaml"
    output:
        demand = "build/data/heat/{resolution}/annual-heat-demand-twh.csv",
        electricity = "build/data/heat/{resolution}/annual-heat-electricity-consumption-twh.csv",
    script: "../scripts/heat/rescale.py"

rule create_heat_demand_timeseries: # TODO have realistic and separate heat demand profiles for each end-use
    message: "Create heat demand timeseries at {wildcards.resolution} for household and commercial sectors"
    input:
        annual_demand = rules.rescale_annual_heat_demand_to_resolution.output["demand"],
    params:
        first_year = config["scope"]["temporal"]["first-year"],
        final_year = config["scope"]["temporal"]["final-year"],
        historic = False,
        power_scaling_factor = config["scaling-factors"]["power"],
    conda: "../envs/default.yaml"
    output:
        "build/models/{resolution}/timeseries/demand/electrified-heat-demand.csv",
    script: "../scripts/heat/create_timeseries.py"

use rule create_heat_demand_timeseries as create_heat_demand_timeseries_historic_electrification with:
    message: "Create timeseries for historic electrified heat demand"
    input:
        annual_demand = rules.rescale_annual_heat_demand_to_resolution.output["electricity"],
    params:
        first_year = config["scope"]["temporal"]["first-year"],
        final_year = config["scope"]["temporal"]["final-year"],
        historic = True,
        power_scaling_factor = config["scaling-factors"]["power"],
    output:
        "build/models/{resolution}/timeseries/demand/heat-demand-historic-electrification.csv",
