# casazza-hydra

Hydra CI + Nix remote-builder NixOS modules, extracted from
[`nixlab`](https://github.com/casazza-info/nixlab) for separation of concerns.
Consumed as a flake input.

## Layout

| Path | What |
|------|------|
| `modules/k8s/hydra.nix` | Kubenix manifest — Hydra Deployment (server + evaluator + queue-runner + Postgres), parameterized over builder hosts. Runs in-cluster. Exposed as `kubenixModules.hydra`. |
| `modules/k8s/dashboard.nix` | Kubenix manifest — Hydra CI Grafana dashboard (web-layer health + systemd unit state + host infra). Parameterized over Prometheus `instance` label. Exposed as `kubenixModules.dashboard`. |
| `modules/nixos/hydra-server.nix` | NixOS service module for a host running Hydra CI. Declarative project/jobset reconciliation, Cachix push hook, SSH/git setup, evaluator limits, Postgres backup/restore to GCS, GC/optimise timers. Parameterized over builder hosts (no `lib/hosts.nix` import). |
| `modules/nixos/buildbot.nix` | NixOS service — buildbot-nix PR CI + tag→GAR push postBuildStep. |
| `modules/nixos/builder-*.nix` | NixOS service — remote-builder host configs per platform (`x86_64-linux`, `aarch64-linux`, `aarch64-darwin`). |
| `lib/default.nix`, `lib/ci.nix` | `buildMachinesLine` / `machinesFile` and the framework-neutral `ci.mkOutputs` helper. The CI helper projects one caller-owned `buildFor` function into ordinary `packages`, `checks`, and `hydraJobs` outputs without constructing or rebuilding derivations. |
| `secrets/buildbot.yaml.example` | SOPS template documenting the keys the buildbot module expects. The consumer (nixlab) owns the actual encrypted secret. |
| `systems/` | (reserved) full NixOS configs if this repo ever owns builder hosts directly. Currently empty — nixlab owns the hosts. |

## Flake outputs

```nix
inputs.casazza-hydra.url = "github:olivecasazza/hydra";
```

| Output | What |
|--------|------|
| `nixosModules.hydra-server` | Hydra CI NixOS server module (options under `services.casazza-hydra.hydra-server.*`). |
| `nixosModules.buildbot` | buildbot-nix wrapper module (options under `services.casazza-hydra.buildbot.*`). |
| `nixosModules.builder-x86_64-linux`, `builder-aarch64-linux`, `builder-aarch64-darwin` | Remote-builder host modules. |
| `nixosModules.buildbot-nix-master`, `nixosModules.buildbot-nix-worker` | Re-exports of upstream buildbot-nix NixOS modules (so consumers don't add buildbot-nix as a separate flake input). |
| `kubenixModules.hydra` | Kubenix module — in-cluster Hydra Deployment. |
| `kubenixModules.dashboard` | Kubenix module — Hydra Grafana dashboard CR. |

## Shared CI output helper

`lib/ci.nix` is pure Nix source. It has no Buildbot, Hydra API, GitHub, SSH,
credential, framework, or network dependency. The caller keeps one derivation
function and chooses every output system explicitly:

```nix
ci = import "${inputs.casazza-hydra-src}/lib/ci.nix" {
  inherit (nixpkgs) lib;
};

ci.mkOutputs {
  systems = [ "x86_64-linux" "aarch64-linux" ];
  packageSystems = [ "x86_64-linux" "aarch64-linux" ];
  checkSystems = [ "x86_64-linux" ];
  hydraSystems = [ "x86_64-linux" ];
  buildFor = system: {
    packages = { inherit app image; };
    checks = { inherit app image; };
    hydraJobs = { inherit app image; };
  };
}
```

The result has the normal flake shape: `packages.<system>`,
`checks.<system>`, and `hydraJobs.<system>`. `systems` is the evaluation
universe; the three `*Systems` lists select which ordinary outputs are
projected. `buildFor` values for unselected systems remain lazy, so a
non-buildable or intentionally omitted architecture does not become an
accidental check. The helper evaluates selected `buildFor` values once and
projects the same derivation values; it does not rebuild packages for checks or
Hydra. When `hydraJobs` is omitted for a selected Hydra system, that system's
`packages` attrset is the fallback. Required selected output sets must be
non-empty, while `packageSystems = []`, `checkSystems = []`, or
`hydraSystems = []` are valid for a checks-only or Hydra-only flake.
Invalid/duplicate systems and missing selected outputs fail during evaluation.

Existing consumers that already depend on the Hydra flake may use the
convenience export from its `lib` namespace. Consumers that do not need the
Hydra modules should use a pinned `flake = false` source input and import
`lib/ci.nix` directly, avoiding unrelated Snowfall/Kubenix inputs. The helper
does not enroll repositories or configure branch protection; those remain
operational checks.

The helper's release remains controlled by the repository's normal review and
pinning process; this PR intentionally creates no release tag.

## Consumption (nixlab)

### In-cluster Hydra Deployment

```nix
# nixlab/modules/k8s/apps/hydra-via-casazza.nix
{ lib, flake, ... }:
{
  imports = [ flake.inputs.casazza-hydra.kubenixModules.hydra ];
  services.casazza-hydra.k8s = {
    enable = true;
    builderHosts = [ /* ...from lib/hosts.nix */ ];
  };
}
```

### Hydra Grafana dashboard

```nix
# nixlab/modules/k8s/monitoring/hydra-dashboard.nix
{ flake, ... }:
{
  imports = [ flake.inputs.casazza-hydra.kubenixModules.dashboard ];
  services.casazza-hydra.dashboard = {
    enable = true;
    instance = "hydra";  # matches prometheus scrape job target label
  };
}
```

### Hydra NixOS server (host running Hydra, e.g. gcp-hydra)

```nix
# nixlab/systems/x86_64-linux/gcp-hydra/default.nix
{ inputs, lib, hosts, peers, ... }:
{
  imports = [ inputs.casazza-hydra.nixosModules.hydra-server ];

  services.casazza-hydra.hydra-server = {
    enable = true;
    hostname = "gcp-hydra";
    sshKeyFile = "/run/hydra-builder-key";
    cachixTokensFile = "/run/hydra-cachix-tokens";
    builders = lib.mapAttrsToList (hostname: bcfg: {
      inherit (bcfg) systems maxJobs speedFactor features;
      name = hostname;
      user = hosts.users.${hostname};
      host = peers.${hostname}.tunnelIp;
    }) (lib.filterAttrs (n: _: n != "gcp-hydra") hosts.builders);
    projects = { /* ... */ };
  };
}
```

### Builder host (receives dispatched builds)

```nix
# nixlab/systems/x86_64-linux/seir/default.nix
{ inputs, ... }:
{
  imports = [
    inputs.casazza-hydra.nixosModules.builder-x86_64-linux
    inputs.casazza-hydra.nixosModules.buildbot
  ];
  services.casazza-hydra.builder.x86_64-linux = { enable = true; maxJobs = 8; };
  services.casazza-hydra.buildbot = { enable = true; /* ... */ };
}
```

### Buildbot GitHub project discovery cadence

The shared module keeps buildbot-nix's upstream 12-hour discovery interval by
default. A consumer that needs faster enrollment can opt into a 15-minute
interval explicitly:

```nix
services.casazza-hydra.buildbot = {
  enable = true;
  githubProjectsRefreshInterval = 15 * 60; # 900 seconds
};
```

The shorter cadence is an opt-in rate-budget decision for installations that
need new topic-matched repositories to appear within minutes. It uses the
public Buildbot periodic scheduler and preserves its persistent `last_build`
state, builders, and in-flight work; it does not force a scheduler, bypass
authentication, or delete caches. With the current upstream NixOS service
defaults, changing the generated master configuration requires one normal
`buildbot-master` restart at a quiet point; this is not a manual refresh or
cache workaround.


## Architecture

- **Hydra** runs in-cluster (k8s Deployment from `modules/k8s/hydra.nix`). Canonical
  build records + Cachix population. Dispatches builds over ssh-ng to remote builders.
  A NixOS host form (`modules/nixos/hydra-server.nix`) also exists for the
  decommissioned gcp-hydra VM path and any future bare-metal Hydra deployment.
- **buildbot-nix** runs as a NixOS service on a host (default: `seir`). Reports PR
  status to GitHub. On `v*` tag pushes, builds `.#dockerImage` itself and pushes to
  Google Artifact Registry via `skopeo` (postBuildStep). Does NOT poll Hydra —
  buildbot and Hydra are parallel CI systems sharing the same builder pool.
- **Builders** (seir, hp0x, mm0x) receive dispatched builds over ssh-ng.
- **Dashboard** (`modules/k8s/dashboard.nix`) ships as a GrafanaDashboard CR scraped
  by grafana-operator. Web-layer + systemd-unit + host-infra panels.

## Activation

See inline `ACTIVATION TODO` comments in `modules/nixos/buildbot.nix` for required
GitHub App + OAuth app + GAR service-account key provisioning steps. The SOPS key
shape is documented in `secrets/buildbot.yaml.example`.
