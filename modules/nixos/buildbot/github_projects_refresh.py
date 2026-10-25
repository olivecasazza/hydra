from buildbot.configurators import ConfiguratorBase
from buildbot.plugins import schedulers


class GithubProjectsRefreshConfigurator(ConfiguratorBase):
    def __init__(self, interval):
        super().__init__()
        self.interval = interval

    def configure(self, config):
        super().configure(config)
        matches = [
            scheduler
            for scheduler in self.schedulers
            if isinstance(scheduler, schedulers.Periodic)
            and scheduler.builderNames == ["reload-github-projects"]
        ]
        if len(matches) != 1:
            raise RuntimeError(
                "expected exactly one GitHub project Periodic scheduler "
                "for builder ['reload-github-projects'], found "
                f"{len(matches)}"
            )

        scheduler = matches[0]
        scheduler_config = scheduler.getConfigDict()
        scheduler_kwargs = dict(scheduler_config["kwargs"])
        scheduler_kwargs["periodicBuildTimer"] = self.interval
        if hasattr(scheduler, "run_on_startup"):
            scheduler_kwargs["run_on_startup"] = scheduler.run_on_startup

        replacement = type(scheduler)(
            *scheduler_config["args"],
            name=scheduler_config["name"],
            **scheduler_kwargs,
        )
        replacement_config = replacement.getConfigDict()
        for key, value in scheduler_config["kwargs"].items():
            if key != "periodicBuildTimer" and replacement_config["kwargs"].get(key) != value:
                raise RuntimeError(f"refresh configurator changed scheduler {key}")
        if scheduler_config["args"] != replacement_config["args"]:
            raise RuntimeError("refresh configurator changed scheduler constructor args")
        if scheduler.name != replacement.name:
            raise RuntimeError("refresh configurator changed scheduler name")
        if scheduler.builderNames != replacement.builderNames:
            raise RuntimeError("refresh configurator changed scheduler builderNames")
        if hasattr(scheduler, "run_on_startup") and (
            scheduler.run_on_startup != replacement.run_on_startup
        ):
            raise RuntimeError("refresh configurator changed scheduler run_on_startup")
        self.schedulers[self.schedulers.index(scheduler)] = replacement
