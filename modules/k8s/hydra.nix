# Hydra CI — k8s Deployment manifest (kubenix).
# Extracted from nixlab's modules/k8s/apps/hydra.nix and parameterized so this
# repo doesn't import nixlab's lib/hosts.nix (no circular dep): builder hosts
# come in as a module option supplied by the consumer (nixlab).
#
# Components: PostgreSQL StatefulSet + Hydra server/evaluator/queue-runner.
# Schedule on a control-plane node for reliable network access to builders.
{ lib, config, ... }:
let
  cfg = config.services.casazza-hydra.k8s;
  namespace = cfg.namespace;
  name = cfg.name;

  postgresImage = cfg.postgresImage;
  # nixos/nix image with Hydra available via `nix profile install` at runtime.
  # Pinned to :latest deliberately — the entrypoint installs hydra from nixpkgs
  # anyway, so a floating base keeps security patches current without a module bump.
  nixImage = cfg.nixImage;

  webPort = cfg.webPort;
  pgPort = cfg.postgresPort;

  # Generate nix remote-builder machines file content from the supplied
  # builderHosts option (consumer passes them in; we don't import nixlab's hosts).
  machinesFileContent = lib.concatStringsSep "\n" (
    builtins.map (
      b:
      "ssh-ng://${b.user}@${b.host} ${lib.concatStringsSep "," b.systems} /var/lib/hydra/.ssh/id_ed25519 ${toString b.maxJobs} ${toString b.speedFactor} ${lib.concatStringsSep "," b.features}"
    ) cfg.builderHosts
  );

  # Hydra server entrypoint script. Identical behavior to nixlab's original:
  # install hydra from nixpkgs, set up SSH for builders, write machines file,
  # wait for postgres. The container's real command is appended by the caller
  # (server/evaluator/queue-runner each have their own command).
  hydraEntrypoint = ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Install Hydra from nixpkgs
    export NIX_CONFIG="experimental-features = nix-command flakes"
    nix profile install nixpkgs#hydra --accept-flake-config || true

    # Setup SSH for builders
    mkdir -p /var/lib/hydra/.ssh
    if [ -f /secrets/ssh-key/id_ed25519 ]; then
      cp /secrets/ssh-key/id_ed25519 /var/lib/hydra/.ssh/id_ed25519
      chmod 600 /var/lib/hydra/.ssh/id_ed25519
    fi
    cat > /var/lib/hydra/.ssh/config <<SSHEOF
    Host *
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
    SSHEOF
    chmod 600 /var/lib/hydra/.ssh/config

    # Write machines file
    mkdir -p /etc/nix
    cat > /etc/nix/machines <<MACHINES
    ${machinesFileContent}
    MACHINES

    # Wait for PostgreSQL
    echo "Waiting for PostgreSQL..."
    while ! pg_isready -h hydra-postgres -p ${toString pgPort} -U hydra; do
      sleep 2
    done
    echo "PostgreSQL is ready"

    # Initialize Hydra database if needed
    export HYDRA_DBI="dbi:Pg:dbname=hydra;host=hydra-postgres;port=${toString pgPort};user=hydra;"
    export HYDRA_DATA="/var/lib/hydra"
    export HYDRA_CONFIG="/etc/hydra/hydra.conf"
    mkdir -p "$HYDRA_DATA"

    # Run the requested component
    exec "$@"
  '';

  # Hydra configuration file. Mirrors nixlab's modules/nixos/hydra/default.nix
  # extraConfig (evaluator_workers tuned for cluster capacity).
  hydraConf = ''
    using_frontend_proxy = 1
    base_uri = ${cfg.baseUrl}
    notification_sender = ${cfg.notificationSender}
    max_output_size = ${toString cfg.maxOutputSize}
    evaluator_workers = ${toString cfg.evaluatorWorkers}
    max_concurrent_evals = ${toString cfg.maxConcurrentEvals}
    use-hierarchical-build-cache = 1

    <hipchat>
      enabled = 0
    </hipchat>
  '';
in
{
  options.services.casazza-hydra.k8s = {
    enable = lib.mkEnableOption "Hydra CI in-cluster Deployment";

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "apps";
      description = "Kubernetes namespace for all Hydra resources";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "hydra";
      description = "Base name for Hydra Deployment/Service/resources";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://hydra.casazza.io";
      description = "Public URL (Cloudflare Tunnel target's public face)";
    };

    notificationSender = lib.mkOption {
      type = lib.types.str;
      default = "hydra@casazza.io";
    };

    webPort = lib.mkOption {
      type = lib.types.int;
      default = 3300;
      description = "Hydra web UI port (Cloudflare Tunnel points at this)";
    };

    postgresPort = lib.mkOption {
      type = lib.types.int;
      default = 5432;
    };

    postgresImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/postgres:16-alpine";
    };

    nixImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/nixos/nix:latest";
      description = "Base image; hydra installed at runtime via `nix profile install`";
    };

    maxOutputSize = lib.mkOption {
      type = lib.types.int;
      default = 10737418240; # 10 GiB
    };

    evaluatorWorkers = lib.mkOption {
      type = lib.types.int;
      default = 4;
    };

    maxConcurrentEvals = lib.mkOption {
      type = lib.types.int;
      default = 2;
    };

    # Builder hosts supplied by the consumer (nixlab maps lib/hosts.nix → this).
    # Each record: { user, host, systems, maxJobs, speedFactor, features }.
    builderHosts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            user = lib.mkOption { type = lib.types.str; };
            host = lib.mkOption { type = lib.types.str; };
            systems = lib.mkOption { type = lib.types.listOf lib.types.str; };
            maxJobs = lib.mkOption { type = lib.types.int; };
            speedFactor = lib.mkOption {
              type = lib.types.int;
              default = 1;
            };
            features = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "big-parallel" ];
            };
          };
        }
      );
      default = [ ];
      description = ''
        Remote builder hosts. Consumer maps its fleet (e.g. nixlab's
        lib/hosts.nix builders attrset) into this list. The orchestrator
        writes one ssh-ng:// line per host to /etc/nix/machines.
      '';
    };

    nodeSelector = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        "node-role.kubernetes.io/control-plane" = "true";
      };
      description = "Node selector for the Hydra Deployment (control-plane for stable builder network)";
    };

    pvcSizes = {
      postgres = lib.mkOption {
        type = lib.types.str;
        default = "20Gi";
      };
      hydraData = lib.mkOption {
        type = lib.types.str;
        default = "50Gi";
      };
      nixStore = lib.mkOption {
        type = lib.types.str;
        default = "100Gi";
      };
    };

    storageClassName = lib.mkOption {
      type = lib.types.str;
      default = "longhorn";
    };

    resources = {
      server = lib.mkOption {
        type = lib.types.attrs;
        default = {
          requests = {
            cpu = "250m";
            memory = "512Mi";
          };
          limits = {
            cpu = "2";
            memory = "2Gi";
          };
        };
      };
      evaluator = lib.mkOption {
        type = lib.types.attrs;
        default = {
          requests = {
            cpu = "500m";
            memory = "1Gi";
          };
          limits = {
            cpu = "4";
            memory = "4Gi";
          };
        };
      };
      queueRunner = lib.mkOption {
        type = lib.types.attrs;
        default = {
          requests = {
            cpu = "250m";
            memory = "512Mi";
          };
          limits = {
            cpu = "2";
            memory = "2Gi";
          };
        };
      };
      postgres = lib.mkOption {
        type = lib.types.attrs;
        default = {
          requests = {
            cpu = "250m";
            memory = "512Mi";
          };
          limits = {
            cpu = "2";
            memory = "2Gi";
          };
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # -- ConfigMaps --------------------------------------------------------

    kubernetes.resources.configMaps.hydra-config = {
      metadata = {
        inherit namespace;
        name = "hydra-config";
      };
      data = {
        "hydra.conf" = hydraConf;
        "entrypoint.sh" = hydraEntrypoint;
      };
    };

    kubernetes.resources.configMaps.hydra-machines = {
      metadata = {
        inherit namespace;
        name = "hydra-machines";
      };
      data = {
        "machines" = machinesFileContent;
      };
    };

    # -- PVCs --------------------------------------------------------------

    kubernetes.resources.persistentVolumeClaims.hydra-postgres-data = {
      metadata = {
        inherit namespace;
        name = "hydra-postgres-data";
      };
      spec = {
        accessModes = [ "ReadWriteOnce" ];
        storageClassName = cfg.storageClassName;
        resources.requests.storage = cfg.pvcSizes.postgres;
      };
    };

    kubernetes.resources.persistentVolumeClaims.hydra-data = {
      metadata = {
        inherit namespace;
        name = "hydra-data";
      };
      spec = {
        accessModes = [ "ReadWriteOnce" ];
        storageClassName = cfg.storageClassName;
        resources.requests.storage = cfg.pvcSizes.hydraData;
      };
    };

    kubernetes.resources.persistentVolumeClaims.hydra-nix-store = {
      metadata = {
        inherit namespace;
        name = "hydra-nix-store";
      };
      spec = {
        accessModes = [ "ReadWriteOnce" ];
        storageClassName = cfg.storageClassName;
        resources.requests.storage = cfg.pvcSizes.nixStore;
      };
    };

    # -- PostgreSQL StatefulSet --------------------------------------------

    kubernetes.resources.statefulSets.hydra-postgres = {
      metadata = {
        inherit namespace;
        name = "hydra-postgres";
        labels.app = "hydra-postgres";
      };
      spec = {
        serviceName = "hydra-postgres";
        replicas = 1;
        selector.matchLabels.app = "hydra-postgres";
        template = {
          metadata.labels.app = "hydra-postgres";
          spec = {
            containers.postgres = {
              image = postgresImage;
              ports = [
                {
                  containerPort = pgPort;
                  name = "postgres";
                }
              ];

              env = [
                {
                  name = "POSTGRES_USER";
                  value = "hydra";
                }
                {
                  name = "POSTGRES_DB";
                  value = "hydra";
                }
                {
                  name = "POSTGRES_PASSWORD";
                  valueFrom.secretKeyRef = {
                    name = "hydra-secrets";
                    key = "postgres-password";
                  };
                }
                {
                  name = "PGDATA";
                  value = "/var/lib/postgresql/data/pgdata";
                }
              ];

              resources = cfg.resources.postgres;

              volumeMounts = [
                {
                  name = "postgres-data";
                  mountPath = "/var/lib/postgresql/data";
                }
              ];

              livenessProbe = {
                exec.command = [
                  "pg_isready"
                  "-U"
                  "hydra"
                ];
                initialDelaySeconds = 30;
                periodSeconds = 10;
              };

              readinessProbe = {
                exec.command = [
                  "pg_isready"
                  "-U"
                  "hydra"
                ];
                initialDelaySeconds = 5;
                periodSeconds = 5;
              };
            };

            volumes = [
              {
                name = "postgres-data";
                persistentVolumeClaim.claimName = "hydra-postgres-data";
              }
            ];
          };
        };
      };
    };

    # PostgreSQL headless service (for StatefulSet DNS)
    kubernetes.resources.services.hydra-postgres = {
      metadata = {
        inherit namespace;
        name = "hydra-postgres";
        labels.app = "hydra-postgres";
      };
      spec = {
        clusterIP = "None";
        ports = [
          {
            name = "postgres";
            port = pgPort;
            targetPort = pgPort;
          }
        ];
        selector.app = "hydra-postgres";
      };
    };

    # -- Hydra Deployment --------------------------------------------------

    kubernetes.resources.deployments.hydra = {
      metadata = {
        inherit namespace name;
        labels.app = name;
      };
      spec = {
        replicas = 1;
        strategy.type = "Recreate";
        selector.matchLabels.app = name;
        template = {
          metadata.labels.app = name;
          spec = {
            nodeSelector = cfg.nodeSelector;

            initContainers = [
              {
                # The nix-store PVC mounts over /nix in every container below,
                # shadowing the image's own /nix/store. That dangles the
                # /bin/sh -> /nix/store/...bash symlink, so those containers
                # fail to even exec (StartError, exit 128 — what crashlooped
                # hydra-init). Seed the PVC from the image store via a non-/nix
                # mount (/pvc-nix) so the image's sh stays usable here. cp -an
                # is archive + no-clobber and runs every start: seeds when
                # empty, no-ops when populated, re-heals if bash is ever GC'd
                # (nothing roots it in the PVC).
                name = "seed-nix-store";
                image = nixImage;
                command = [
                  "/bin/sh"
                  "-c"
                  "cp -an /nix/. /pvc-nix/ || true"
                ];
                volumeMounts = [
                  {
                    name = "nix-store";
                    mountPath = "/pvc-nix";
                  }
                ];
              }
              {
                name = "wait-for-postgres";
                image = postgresImage;
                command = [
                  "sh"
                  "-c"
                  "until pg_isready -h hydra-postgres -p ${toString pgPort} -U hydra; do echo 'Waiting for postgres...'; sleep 2; done"
                ];
              }
              {
                name = "hydra-init";
                image = nixImage;
                command = [
                  "sh"
                  "-c"
                  ''
                    set -e
                    export NIX_CONFIG="experimental-features = nix-command flakes"
                    nix profile install nixpkgs#hydra --accept-flake-config || true
                    export HYDRA_DBI="dbi:Pg:dbname=hydra;host=hydra-postgres;port=${toString pgPort};user=hydra;password=$(cat /secrets/db-password/postgres-password);"
                    export HYDRA_DATA="/var/lib/hydra"
                    mkdir -p "$HYDRA_DATA"
                    hydra-init || true
                  ''
                ];
                volumeMounts = [
                  {
                    name = "hydra-data";
                    mountPath = "/var/lib/hydra";
                  }
                  {
                    name = "nix-store";
                    mountPath = "/nix";
                  }
                  {
                    name = "db-password";
                    mountPath = "/secrets/db-password";
                    readOnly = true;
                  }
                ];
              }
            ];

            containers = {
              # Hydra web server
              hydra-server = {
                image = nixImage;
                command = [
                  "sh"
                  "-c"
                  ''
                    set -e
                    export NIX_CONFIG="experimental-features = nix-command flakes"
                    nix profile install nixpkgs#hydra --accept-flake-config || true
                    export HYDRA_DBI="dbi:Pg:dbname=hydra;host=hydra-postgres;port=${toString pgPort};user=hydra;password=$(cat /secrets/db-password/postgres-password);"
                    export HYDRA_DATA="/var/lib/hydra"
                    export HYDRA_CONFIG="/etc/hydra/hydra.conf"
                    mkdir -p "$HYDRA_DATA"
                    exec hydra-server -f -h 0.0.0.0 -p ${toString webPort} --max_spare_servers 5 --max_servers 25
                  ''
                ];

                ports = [
                  {
                    containerPort = webPort;
                    name = "http";
                  }
                ];

                resources = cfg.resources.server;

                volumeMounts = [
                  {
                    name = "hydra-data";
                    mountPath = "/var/lib/hydra";
                  }
                  {
                    name = "nix-store";
                    mountPath = "/nix";
                  }
                  {
                    name = "hydra-config";
                    mountPath = "/etc/hydra/hydra.conf";
                    subPath = "hydra.conf";
                  }
                  {
                    name = "db-password";
                    mountPath = "/secrets/db-password";
                    readOnly = true;
                  }
                ];

                livenessProbe = {
                  httpGet = {
                    path = "/";
                    port = webPort;
                  };
                  initialDelaySeconds = 120;
                  periodSeconds = 30;
                };
              };

              # Hydra evaluator
              hydra-evaluator = {
                image = nixImage;
                command = [
                  "sh"
                  "-c"
                  ''
                    set -e
                    # nix requires LOGNAME/HOME/USER (see hydra-queue-runner).
                    export HOME=/var/lib/hydra
                    export LOGNAME=root
                    export USER=root
                    export NIX_CONFIG="experimental-features = nix-command flakes"
                    nix profile install nixpkgs#hydra --accept-flake-config || true
                    export HYDRA_DBI="dbi:Pg:dbname=hydra;host=hydra-postgres;port=${toString pgPort};user=hydra;password=$(cat /secrets/db-password/postgres-password);"
                    export HYDRA_DATA="/var/lib/hydra"
                    export HYDRA_CONFIG="/etc/hydra/hydra.conf"
                    mkdir -p "$HYDRA_DATA"
                    exec hydra-evaluator
                  ''
                ];

                resources = cfg.resources.evaluator;

                volumeMounts = [
                  {
                    name = "hydra-data";
                    mountPath = "/var/lib/hydra";
                  }
                  {
                    name = "nix-store";
                    mountPath = "/nix";
                  }
                  {
                    name = "hydra-config";
                    mountPath = "/etc/hydra/hydra.conf";
                    subPath = "hydra.conf";
                  }
                  {
                    name = "db-password";
                    mountPath = "/secrets/db-password";
                    readOnly = true;
                  }
                ];
              };

              # Hydra queue runner (dispatches builds to remote builders)
              hydra-queue-runner = {
                image = nixImage;
                command = [
                  "sh"
                  "-c"
                  ''
                    set -e
                    # nix requires LOGNAME/HOME/USER; without them hydra-queue-runner
                    # exits with "environment variable 'LOGNAME' is not set" and crashloops.
                    export HOME=/var/lib/hydra
                    export LOGNAME=root
                    export USER=root
                    export NIX_CONFIG="experimental-features = nix-command flakes"
                    nix profile install nixpkgs#hydra --accept-flake-config || true

                    # Setup SSH for builders
                    mkdir -p /var/lib/hydra/.ssh
                    if [ -f /secrets/ssh-key/id_ed25519 ]; then
                      cp /secrets/ssh-key/id_ed25519 /var/lib/hydra/.ssh/id_ed25519
                      chmod 600 /var/lib/hydra/.ssh/id_ed25519
                    fi
                    cat > /var/lib/hydra/.ssh/config <<SSHEOF
                    Host *
                      StrictHostKeyChecking no
                      UserKnownHostsFile /dev/null
                    SSHEOF
                    chmod 600 /var/lib/hydra/.ssh/config

                    export HYDRA_DBI="dbi:Pg:dbname=hydra;host=hydra-postgres;port=${toString pgPort};user=hydra;password=$(cat /secrets/db-password/postgres-password);"
                    export HYDRA_DATA="/var/lib/hydra"
                    export HYDRA_CONFIG="/etc/hydra/hydra.conf"
                    export NIX_REMOTE_SYSTEMS="/etc/nix/machines"
                    mkdir -p "$HYDRA_DATA" /etc/nix
                    cp /config/machines /etc/nix/machines
                    exec hydra-queue-runner --builders /etc/nix/machines
                  ''
                ];

                resources = cfg.resources.queueRunner;

                volumeMounts = [
                  {
                    name = "hydra-data";
                    mountPath = "/var/lib/hydra";
                  }
                  {
                    name = "nix-store";
                    mountPath = "/nix";
                  }
                  {
                    name = "hydra-config";
                    mountPath = "/etc/hydra/hydra.conf";
                    subPath = "hydra.conf";
                  }
                  {
                    name = "machines";
                    mountPath = "/config/machines";
                    subPath = "machines";
                  }
                  {
                    name = "ssh-key";
                    mountPath = "/secrets/ssh-key";
                    readOnly = true;
                  }
                  {
                    name = "db-password";
                    mountPath = "/secrets/db-password";
                    readOnly = true;
                  }
                ];
              };
            };

            volumes = [
              {
                name = "hydra-data";
                persistentVolumeClaim.claimName = "hydra-data";
              }
              {
                name = "nix-store";
                persistentVolumeClaim.claimName = "hydra-nix-store";
              }
              {
                name = "hydra-config";
                configMap.name = "hydra-config";
              }
              {
                name = "machines";
                configMap.name = "hydra-machines";
              }
              {
                name = "ssh-key";
                secret = {
                  secretName = "hydra-secrets";
                  items = [
                    {
                      key = "id_ed25519";
                      path = "id_ed25519";
                      mode = 384; # 0600
                    }
                  ];
                };
              }
              {
                name = "db-password";
                secret = {
                  secretName = "hydra-secrets";
                  items = [
                    {
                      key = "postgres-password";
                      path = "postgres-password";
                    }
                  ];
                };
              }
            ];
          };
        };
      };
    };

    # -- Services ----------------------------------------------------------

    # Hydra web UI (LoadBalancer for LAN access; Cloudflare Tunnel brings in
    # the public face via modules/k8s/... cloudflared, see nixlab consumer).
    kubernetes.resources.services.hydra = {
      metadata = {
        inherit namespace name;
        labels.app = name;
      };
      spec = {
        type = "LoadBalancer";
        ports = [
          {
            name = "http";
            port = webPort;
            targetPort = webPort;
          }
        ];
        selector.app = name;
      };
    };
  };
}
