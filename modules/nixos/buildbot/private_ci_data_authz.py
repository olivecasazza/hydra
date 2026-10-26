from buildbot.configurators import ConfiguratorBase
from buildbot.util import bytes2unicode
from buildbot.www.authz.endpointmatchers import EndpointMatcherBase, Match


class AnyReadEndpointMatcher(EndpointMatcherBase):
    """Require the existing admin role for every read-only data endpoint."""

    def match(self, _ep, action="get", _options=None):
        if bytes2unicode(action).lower() == "get":
            return Match(self.master)
        return None


class PrivateCiDataAuthzConfigurator(ConfiguratorBase):
    def __init__(self, enabled):
        super().__init__()
        self.enabled = enabled

    def configure(self, config):
        super().configure(config)
        if not self.enabled:
            return

        authz = self.www.get("authz")
        if authz is None or not hasattr(authz, "allowRules"):
            raise RuntimeError("private CI data requires the native Buildbot authz configuration")

        rules = authz.allowRules
        matches = [
            rule
            for rule in rules
            if type(rule).__name__ == "AnyEndpointMatcher"
            and getattr(rule, "role", None) == "admin"
            and getattr(rule, "defaultDeny", None) is False
        ]
        if len(matches) != 1:
            raise RuntimeError(
                "private CI data requires exactly one permissive admin endpoint rule; "
                f"found {len(matches)}"
            )

        matcher = AnyReadEndpointMatcher(role="admin", defaultDeny=True)
        matcher.setAuthz(authz)
        rules.insert(0, matcher)
