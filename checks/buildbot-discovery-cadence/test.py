import importlib.util
import sys
from pathlib import Path

from buildbot.plugins import util
from buildbot.www.authz import Authz, Forbidden
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

    def capture(value):
        values.append(value)
        return None

    deferred.addBoth(capture)
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

def load_private_configurator(source, private_source=None):
    private_source = Path(private_source or Path(source).with_name("private_ci_data_authz.py"))
    spec = importlib.util.spec_from_file_location("private_ci_data_authz", private_source)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.PrivateCiDataAuthzConfigurator


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
    force = schedulers.ForceScheduler(
        name="reload-github-projects-force",
        builderNames=["reload-github-projects"],
    )
    unrelated = scheduler_config("unrelated", ["other-builder"])
    config = {"schedulers": [target, force, unrelated]}
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
    assert config["schedulers"][1] is force
    assert config["schedulers"][2] is unrelated

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
    except RuntimeError:
        pass
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
    except RuntimeError:
        pass
    else:
        raise AssertionError("duplicate discovery schedulers were accepted")


def test_private_ci_data_authz(source, private_source):
    configurator = load_private_configurator(source, private_source)(True)
    authz = Authz(
        allowRules=[
            util.AnyEndpointMatcher(role="admin", defaultDeny=False),
            util.AnyControlEndpointMatcher(role="maintainer"),
        ],
        roleMatchers=[
            util.RolesFromUsername(roles=["admin"], usernames=["olivecasazza"]),
            util.RolesFromGroups(groupPrefix=""),
        ],
    )
    configurator.configure({"www": {"authz": authz}})
    authz.setMaster(object())

    assert type(authz.allowRules[0]).__name__ == "AnyReadEndpointMatcher"
    assert result_of(authz.assertUserAllowed("logs/1", "get", {}, {"username": "olivecasazza"})) is None
    for user in ({}, {"username": "other"}):
        try:
            result_of(authz.assertUserAllowed("logs/1", "get", {}, user))
        except Forbidden:
            pass
        else:
            raise AssertionError("non-admin read was allowed")

    assert result_of(authz.assertUserAllowed("builds/1", "stop", {}, {"username": "olivecasazza"})) is None
    maintainer = {"username": "worker", "groups": ["maintainer"]}
    assert result_of(authz.assertUserAllowed("builds/1", "stop", {}, maintainer)) is None
    try:
        result_of(authz.assertUserAllowed("logs/1", "get", {}, maintainer))
    except Forbidden:
        pass
    else:
        raise AssertionError("non-admin read was allowed for an existing control role")

    try:
        result_of(authz.assertUserAllowed("builds/1", "stop", {}, {}))
    except Forbidden:
        pass
    else:
        raise AssertionError("anonymous control action was allowed")

    disabled_authz = Authz(
        allowRules=[util.AnyEndpointMatcher(role="admin", defaultDeny=False)],
        roleMatchers=[util.RolesFromUsername(roles=["admin"], usernames=["olivecasazza"])],
    )
    disabled_authz.setMaster(object())
    load_private_configurator(source, private_source)(False).configure({"www": {"authz": disabled_authz}})
    assert len(disabled_authz.allowRules) == 1


def test_nix_generated_configurator_modes(source, private_source, true_expr, false_expr):
    configurator_class = load_private_configurator(source, private_source)
    for expression, expected in ((true_expr, True), (false_expr, False)):
        namespace = {"PrivateCiDataAuthzConfigurator": configurator_class}
        configurator = eval(expression, namespace)
        assert isinstance(configurator, configurator_class)
        assert configurator.enabled is expected


if __name__ == "__main__":
    source = Path(sys.argv[1])
    private_source = Path(sys.argv[2])
    true_expr = sys.argv[3]
    false_expr = sys.argv[4]
    test_refresh_reconfiguration_preserves_scheduler_state(source)
    test_refresh_requires_exactly_one_match(source)
    test_private_ci_data_authz(source, private_source)
    test_nix_generated_configurator_modes(source, private_source, true_expr, false_expr)
