import glob
from pathlib import Path

from snakemake.utils import validate

ALL_WIND_AND_SOLAR_TECHNOLOGIES = [
    "wind-onshore", "wind-offshore", "open-field-pv",
    "rooftop-pv", "rooftop-pv-n", "rooftop-pv-e-w", "rooftop-pv-s-flat"
]
BIOFUEL_FEEDSTOCKS = [
    "forestry-energy-residues",
    "landscape-care-residues",
    "manure",
    "municipal-waste",
    "primary-agricultural-residues",
    "roundwood-chips",
    "roundwood-fuelwood",
    "secondary-forestry-residues-sawdust",
    "secondary-forestry-residues-woodchips",
    "sludge"
]


include: "./rules/shapes.smk"
include: "./rules/hydro.smk"
include: "./rules/sync.smk"
localrules: all, download_raw_load, model, clean, parameterise_template, download_potentials, download_eurocalliope_dataset
localrules: download_capacity_factors_wind_and_solar, download_entsoe_tyndp_zip
configfile: "config/default.yaml"
validate(config, "config/schema.yaml")
wildcard_constraints:
        resolution = "((continental)|(national)|(regional))"

root_dir = config["root-directory"] + "/" if config["root-directory"] not in ["", "."] else ""
__version__ = open(f"{root_dir}VERSION").readlines()[0].strip()
script_dir = f"{root_dir}scripts/"
template_dir = f"{root_dir}templates/"
test_dir = f"{root_dir}tests/"
model_test_dir = f"{test_dir}model"

onstart:
    shell("mkdir -p build/logs")
onsuccess:
     if "email" in config.keys():
         shell("echo "" | mail -s 'euro-calliope succeeded' {config[email]}")
onerror:
     if "email" in config.keys():
         shell("echo "" | mail -s 'euro-calliope failed' {config[email]}")


rule all:
    message: "Generate euro-calliope pre-built models and run tests."
    input:
        "build/logs/continental/model.done",
        "build/logs/national/model.done",
        "build/logs/regional/model.done",
        "build/logs/continental/test-report.html",
        "build/logs/national/test-report.html",


rule download_potentials:
    message: "Download potential data."
    params: url = config["data-sources"]["potentials"]
    output: protected("data/automatic/raw-potentials.zip")
    conda: "envs/shell.yaml"
    shell: "curl -sLo {output} '{params.url}'"


rule potentials:
    message: "Unzip potentials."
    input: rules.download_potentials.output[0]
    shadow: "minimal"
    output:
        land_eligibility_km2 = "build/data/{{resolution}}/{scenario}/areas.csv".format(
            scenario=config["parameters"]["wind-and-solar-potential-scenario"]
        ),
        shared_coast = "build/data/{resolution}/shared-coast.csv",
        demand = "build/data/{resolution}/demand.csv",
        population = "build/data/{resolution}/population.csv",
        land_cover = "build/data/{resolution}/land-cover.csv"
    conda: "envs/shell.yaml"
    shell: "unzip -o {input} -d build/data"


rule parameterise_template:
    message: "Apply config parameters to file {wildcards.template} from templates."
    input:
        script = script_dir + "parameterise_templates.py",
        template = template_dir + "{template}",
        biofuel_cost = "build/data/regional/biofuel/{scenario}/costs-eur-per-mwh.csv".format(
            scenario=config["parameters"]["jrc-biofuel"]["scenario"]
        )
    params:
        scaling_factors = config["scaling-factors"],
        capacity_factors = config["capacity-factors"]["average"],
        max_power_density = config["parameters"]["maximum-installable-power-density"],
        biofuel_efficiency = config["parameters"]["biofuel-efficiency"]
    output: "build/model/{template}"
    wildcard_constraints:
        template = "((link-techs.yaml)|(storage-techs.yaml)|(demand-techs.yaml)|(renewable-techs.yaml)|(README.md)|(environment.yaml)|(interest-rate.yaml)|(tech-costs.yaml))"
    conda: "envs/default.yaml"
    script: "scripts/parameterise_templates.py"


rule hydro_capacities:
    message: "Determine hydro capacities on {wildcards.resolution} resolution."
    input:
        script = script_dir + "hydro_capacities.py",
        locations = rules.units.output[0],
        plants = rules.preprocess_hydro_stations.output[0]
    output: "build/data/{resolution}/hydro-capacities-mw.csv"
    conda: "envs/geo.yaml"
    script: "scripts/hydro_capacities.py"


rule biofuels:
    message: "Determine biofuels potential on {wildcards.resolution} resolution for scenario {wildcards.scenario}."
    input:
        script = script_dir + "biofuels.py",
        units = rules.units.output[0],
        land_cover = rules.potentials.output.land_cover,
        population = rules.potentials.output.population,
        national_potentials = expand(config["data-sources"]["biofuel-potentials"], feedstock=BIOFUEL_FEEDSTOCKS),
        costs = expand(config["data-sources"]["biofuel-costs"], feedstock=BIOFUEL_FEEDSTOCKS)
    params:
        potential_year = config["parameters"]["jrc-biofuel"]["potential-year"],
        cost_year = config["parameters"]["jrc-biofuel"]["cost-year"]
    output:
        potentials = "build/data/{resolution}/biofuel/{scenario}/potential-mwh-per-year.csv",
        costs = "build/data/{resolution}/biofuel/{scenario}/costs-eur-per-mwh.csv" # not actually resolution dependent
    conda: "envs/geo.yaml"
    wildcard_constraints:
        scenario = "((low)|(medium)|(high))"
    script: "scripts/biofuels.py"


rule locations:
    message: "Generate locations for {wildcards.resolution} resolution."
    input:
        script = script_dir + "locations.py",
        shapes = rules.units.output[0],
        land_eligibility_km2 = rules.potentials.output.land_eligibility_km2,
        hydro_capacities = rules.hydro_capacities.output[0],
        biofuel = "build/data/{{resolution}}/biofuel/{scenario}/potential-mwh-per-year.csv".format(scenario=config["parameters"]["jrc-biofuel"]["scenario"])
    params:
        flat_roof_share = config["parameters"]["roof-share"]["flat"],
        maximum_installable_power_density = config["parameters"]["maximum-installable-power-density"],
        scaling_factors = config["scaling-factors"],
        biofuel_efficiency = config["parameters"]["biofuel-efficiency"]
    output:
        yaml = "build/model/{resolution}/locations.yaml",
        csv = "build/model/{resolution}/locations.csv"
    conda: "envs/geo.yaml"
    script: "scripts/locations.py"


rule directional_rooftop_pv:
    message: "Generate override for directional rooftop PV in {wildcards.resolution} resolution."
    input:
        script = script_dir + "directional_rooftop.py",
        units = rules.units_without_shape.output[0],
        land_eligibility_km2 = rules.potentials.output.land_eligibility_km2,
    params:
        roof_shares = config["parameters"]["roof-share"],
        maximum_installable_power_density = config["parameters"]["maximum-installable-power-density"],
        scaling_factors = config["scaling-factors"],
    output: "build/model/{resolution}/directional-rooftop.yaml"
    conda: "envs/default.yaml"
    script: "scripts/directional_rooftop.py"


rule load_shedding:
    message: "Generate override allowing load shedding."
    input:
        script = script_dir + "load_shedding.py",
        units = rules.units_without_shape.output[0]
    output: "build/model/{resolution}/load-shedding.yaml"
    conda: "envs/default.yaml"
    script: "scripts/load_shedding.py"


rule download_capacity_factors_wind_and_solar:
    message: "Download data/automatic/capacityfactors/{wildcards.filename}."
    params: url = lambda wildcards: config["data-sources"]["capacity-factors"].format(filename=wildcards.filename)
    output: protected("data/automatic/capacityfactors/{filename}")
    conda: "envs/shell.yaml"
    shell: "curl -sLo {output} '{params.url}'"


rule capacity_factors_onshore_wind_and_solar:
    message: "Generate capacityfactor time series disaggregated by location on "
             "{wildcards.resolution} resolution for {wildcards.technology}."
    input:
        script = script_dir + "capacityfactors.py",
        locations = rules.units.output[0],
        timeseries = ancient("data/automatic/capacityfactors/{technology}-timeseries.nc"),
        coordinates = ancient("data/automatic/capacityfactors/wind-onshore-timeseries.nc")
    params:
        threshold = config["capacity-factors"]["min"],
        year = config["year"],
        trim_ts = config["capacity-factors"]["trim-ninja-timeseries"]
    wildcard_constraints:
        technology = "((wind-onshore)|(rooftop-pv)|(open-field-pv)|(rooftop-pv-n)|(rooftop-pv-e-w)|(rooftop-pv-s-flat))"
    output: "build/model/{resolution}/capacityfactors-{technology}.csv"
    conda: "envs/geo.yaml"
    script: "scripts/capacityfactors.py"


rule capacity_factors_offshore:
    message: "Generate capacityfactor time series disaggregated by location on "
             "{wildcards.resolution} resolution for wind-offshore."
    input:
        script = script_dir + "capacityfactors_offshore.py",
        eez = rules.eez.output[0],
        shared_coast = rules.potentials.output.shared_coast,
        timeseries = ancient("data/automatic/capacityfactors/wind-offshore-timeseries.nc")
    params:
        threshold = config["capacity-factors"]["min"],
        year = config["year"],
        trim_ts = config["capacity-factors"]["trim-ninja-timeseries"]
    output: "build/model/{resolution}/capacityfactors-wind-offshore.csv"
    conda: "envs/geo.yaml"
    script: "scripts/capacityfactors_offshore.py"


rule capacity_factors_hydro:
    message: "Generate capacityfactor time series for hydro electricity on {wildcards.resolution} resolution."
    input:
        script = script_dir + "capacityfactors_hydro.py",
        capacities = rules.hydro_capacities.output[0],
        stations = rules.inflow_mwh.output[0],
        locations = rules.units.output[0]
    params:
        threshold = config["capacity-factors"]["min"]
    output:
        ror = "build/model/{resolution}/capacityfactors-hydro-ror.csv",
        reservoir = "build/model/{resolution}/capacityfactors-hydro-reservoir-inflow.csv"
    conda: "envs/geo.yaml"
    script: "scripts/capacityfactors_hydro.py"


rule download_raw_load:
    message: "Download raw load."
    params: url = config["data-sources"]["load"]
    output: protected("data/automatic/raw-load-data.csv")
    conda: "envs/shell.yaml"
    shell: "curl -sLo {output} '{params.url}'"


rule electricity_load_national:
    message: "Preprocess raw electricity load data and retrieve load time series per country."
    input:
        script = script_dir + "national_load.py",
        load = rules.download_raw_load.output[0]
    output: "build/data/electricity-demand-national.csv"
    params:
        year = config["year"],
        data_quality_config = config["quality-control"]["load"],
        countries = config["scope"]["countries"]
    conda: "envs/default.yaml"
    script: "scripts/national_load.py"


rule electricity_load:
    message: "Generate electricity load time series for every location on {wildcards.resolution} resolution."
    input:
        script = script_dir + "load.py",
        units = rules.units.output[0],
        demand_per_unit = rules.potentials.output.demand,
        national_load = rules.electricity_load_national.output[0]
    params:
        scaling_factor = config["scaling-factors"]["power"]
    output: "build/model/{resolution}/electricity-demand.csv"
    conda: "envs/geo.yaml"
    script: "scripts/load.py"


rule download_entsoe_tyndp_zip:
    message: "Download ENTSO-E ten-year network development plan (TYNDP) 2020 scenario dataset"
    params: url = config["data-sources"]["entsoe-tyndp"]
    output: protected("data/automatic/raw-entsoe-tyndp.xlsx.zip")
    conda: "envs/shell.yaml"
    shell: "curl -sLo {output} '{params.url}'"


rule entsoe_tyndp_xlsx:
    message: "Unzip ENTSO-E TYNDP 2020 scenario dataset."
    input: rules.download_entsoe_tyndp_zip.output[0]
    shadow: "minimal"
    output: "build/data/national/TYNDP-2020-Scenario-Datafile.xlsx",
    conda: "envs/shell.yaml"
    shell: "unzip -o {input} 'TYNDP-2020-Scenario-Datafile.xlsx' -d build/data/national"


rule entsoe_tyndp_links:
    message: "Create YAML file of national-scale links with ENTSO-E TYNDP net-transfer capacities"
    input:
        script = script_dir + "link_entsoe_tyndp.py",
        units = rules.units_without_shape.output[0],
        entsoe_tyndp = rules.entsoe_tyndp_xlsx.output[0]
    params:
        scenario = config["parameters"]["entsoe-tyndp"]["scenario"],
        grid = config["parameters"]["entsoe-tyndp"]["grid"],
        ntc_limit = config["parameters"]["entsoe-tyndp"]["ntc_limit"],
        energy_cap_limit = config["parameters"]["entsoe-tyndp"]["energy_cap_limit"],
        year = config["parameters"]["entsoe-tyndp"]["projection-year"],
        scaling_factor = config["scaling-factors"]["power"]
    output: "build/model/{resolution}/entsoe-tyndp-links.yaml"
    wildcard_constraints: resolution = "national"
    conda: "envs/default.yaml"
    script: "scripts/link_entsoe_tyndp.py"


rule link_neighbours:
    message: "Create links between all direct neighbours on {wildcards.resolution} resolution."
    input:
        script = script_dir + "link_neighbours.py",
        units = rules.units.output[0]
    params:
        sea_connections = lambda wildcards: config["sea-connections"][wildcards.resolution]
    output: "build/model/{resolution}/link-all-neighbours.yaml"
    conda: "envs/geo.yaml"
    script: "scripts/link_neighbours.py"


rule build_metadata:
    message: "Generate build metadata."
    input:
        script = script_dir + "metadata.py"
    params:
        config = config,
        version = __version__
    output: "build/model/build-metadata.yaml"
    conda: "envs/default.yaml"
    script: "scripts/metadata.py"


rule model:
    message: "Generate euro-calliope with {wildcards.resolution} resolution."
    input:
        "build/model/interest-rate.yaml",
        "build/model/link-techs.yaml",
        "build/model/tech-costs.yaml",
        "build/model/renewable-techs.yaml",
        "build/model/storage-techs.yaml",
        "build/model/demand-techs.yaml",
        "build/model/environment.yaml",
        "build/model/README.md",
        rules.locations.output,
        rules.electricity_load.output,
        rules.link_neighbours.output,
        rules.capacity_factors_hydro.output,
        rules.hydro_capacities.output,
        rules.directional_rooftop_pv.output,
        rules.load_shedding.output,
        expand(
            "build/model/{{resolution}}/capacityfactors-{technology}.csv",
            technology=ALL_WIND_AND_SOLAR_TECHNOLOGIES
        ),
        rules.build_metadata.output,
        lambda wildcards: rules.entsoe_tyndp_links.output[0] if wildcards.resolution == "national" else [],
        example_model = template_dir + "example-model.yaml"
    output:
        log = "build/logs/{resolution}/model.done",
        example_model = "build/model/{resolution}/example-model.yaml"
    shell:
        """
        cp {input.example_model} {output.example_model}
        touch {output.log}
        """


rule clean: # removes all generated results
    shell:
        """
        rm -r build/
        echo "Data downloaded to data/automatic/ and data/euro-calliope-datasets has not been cleaned."
        """


rule docs:
    message: "Build documentation"
    input: *glob.glob("docs/*")
    conda: "envs/docs.yaml"
    output: directory("build/docs")
    shell: "mkdocs build --no-directory-urls"


rule test:
    message: "Run tests"
    input:
        "build/logs/{resolution}/model.done",
        test_dir = model_test_dir,
        tests = map(str, Path(model_test_dir).glob("**/test_*.py")),
        model = test_dir + "resources/{resolution}/model.yaml",
        example_model = "build/model/{resolution}/example-model.yaml",
        capacity_factor_timeseries = expand(
            "build/model/{{resolution}}/capacityfactors-{technology}.csv",
            technology=ALL_WIND_AND_SOLAR_TECHNOLOGIES + ["hydro-ror", "hydro-reservoir-inflow"]
        )
    params:
        config = config
    output: "build/logs/{resolution}/test-report.html"
    conda: "./envs/test.yaml"
    script: "./tests/model/test_runner.py"


rule download_eurocalliope_dataset:
    message: "Downloading `{wildcards.dataset}` from Euro-Calliope dataset submodule"
    params: url = lambda wildcards: config["data-sources"]["data-repository"].format(dataset=wildcards.dataset)
    output: "data/euro-calliope-datasets/{dataset}"
    shell: "curl -sLfo {output} {params.url}"
