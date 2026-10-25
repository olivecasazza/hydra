import importlib.util
import sys
from pathlib import Path

from buildbot.plugins import schedulers
from buildbot.test.fake.fakemaster import FakeMaster
from twisted.python.failure import Failure
from twisted.internet.task import Clock

class PeriodicWithStartup(schedulers.Periodic):
    def __init__(self, *args, run_on_startup=False, **kwargs):
        super().__init__(*args, **kwargs)
        self.run_on_startup = run_on_startup


def result_of(deferred):
    values = []
    deferred.addBoth(lambda value: values.append(value) or value)
    if not values:
        raise AssertionError("expected Deferred to complete synchronously")
    value = values[0]
    if isinstance(value, Failure):
        value.raiseException()
    return value


def load_configurator(source):
    spec = importlib.util.spec_from_file_location("github_projects_refresh", source)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.GithubProjectsRefreshConfigurator


def scheduler_config(name, builder_names, timer=43_200):
    return PeriodicWithStartup(
        name=name,
        builderNames=builder_names,
        periodicBuildTimer=timer,
        properties={"refresh": "preserve"},
        codebases={"": {}},
        priority=7,
        run_on_startup=True,
    )


def test_refresh_reconfiguration_preserves_scheduler_state(source):
    configurator = load_configurator(source)(900)
    target = scheduler_config("reload-github-projects-bidaily", ["reload-github-projects"])
    unrelated = scheduler_config("unrelated", ["other-builder"])
    config = {"schedulers": [target, unrelated]}
    configurator.configure(config)

    replacement = config["schedulers"][0]
    assert replacement.getConfigDict()["kwargs"]["periodicBuildTimer"] == 900
    assert replacement.run_on_startup is True
    assert replacement.name == target.name
    assert replacement.builderNames == target.builderNames
    assert replacement.getConfigDict()["kwargs"]["properties"] == {
        "refresh": "preserve"
    }
    assert replacement.getConfigDict()["kwargs"]["priority"] == 7
    assert config["schedulers"][1] is unrelated

    # Exercise the public reconfiguration path with an existing last_build and
    # a Twisted clock.  The running service retains its in-flight marker while
    # the next normal refresh is calculated from the new interval.
    clock = Clock()
    master = FakeMaster(clock)
    running = scheduler_config("reload-github-projects-bidaily", ["reload-github-projects"])
    running.setServiceParent(master)
    running.lastActuated = 1_000
    running.actuateAt = 1_234
    result_of(running.reconfigServiceWithSibling(replacement))
    assert running.periodicBuildTimer == 900
    assert running.actuateAt == 1_234
    assert result_of(running.getNextBuildTime(running.lastActuated)) == 1_900


def test_refresh_requires_exactly_one_match(source):
    configurator = load_configurator(source)(900)
    with_missing = {"schedulers": [scheduler_config("other", ["other-builder"])]}
    try:
        configurator.configure(with_missing)
    except RuntimeError as error:
        assert "found 0" in str(error)
    else:
        raise AssertionError("missing discovery scheduler was accepted")

    duplicate = {
        "schedulers": [
            scheduler_config("one", ["reload-github-projects"]),
            scheduler_config("two", ["reload-github-projects"]),
        ]
    }
    try:
        configurator.configure(duplicate)
    except RuntimeError as error:
        assert "found 2" in str(error)
    else:
        raise AssertionError("duplicate discovery schedulers were accepted")


if __name__ == "__main__":
    source = Path(sys.argv[1])
    test_refresh_reconfiguration_preserves_scheduler_state(source)
    test_refresh_requires_exactly_one_match(source)
