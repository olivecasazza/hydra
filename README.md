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
| `lib/default.nix` | `buildMachinesLine` / `machinesFile` helpers — format the nix remote-builder machines file without importing nixlab's `lib/hosts.nix` (no circular dep). |
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
