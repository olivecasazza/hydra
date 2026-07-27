# buildbot-nix — NixOS service for PR CI + tag→GAR push.
#
# Coexistence with Hydra: buildbot-nix is a parallel CI, NOT a Hydra poller.
# It uses its own nix-eval-jobs to build `.#checks` per PR and report commit
# status to GitHub (replaces GHA conventional-commits/approval-check role).
# On `v*` tag pushes, it builds `.#dockerImage` itself and pushes the OCI
# archive to Google Artifact Registry via a postBuildStep. Hydra stays the
# canonical build record-keeper + cachix populator; both share the same
# remote-builder pool.
#
# Auth: defaults to OIDC via Keycloak (which federates GitHub + Google).
# Can fall back to native GitHub OAuth via authBackend = "github". GitHub
# App webhook/PR detection is always enabled regardless of auth backend —
# it drives CI pipeline triggers, not user login.
#
# Remote builders: the `builders` option configures distributed Nix builds
# to the same builder pool used by Hydra. Builder hosts must run the
# `services.casazza-hydra.builder.*` modules with matching authorizedKeys.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.services.casazza-hydra.buildbot;
in
{
  options.services.casazza-hydra.buildbot = {
    enable = lib.mkEnableOption "buildbot-nix PR CI + tag→GAR push";

    authBackend = lib.mkOption {
      type = lib.types.enum [
        "github"
        "oidc"
      ];
      default = "oidc";
      description = ''
        Authentication backend for the buildbot web UI.
        - "oidc": delegate to Keycloak OIDC (supports GitHub/Google federation)
        - "github": native GitHub OAuth2
        GitHub App webhook/PR detection is always enabled regardless.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "buildbot.casazza.io";
      description = "Public URL for buildbot web UI";
    };

    admins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "olivecasazza" ];
      description = "GitHub usernames granted buildbot admin (login + restart privileges)";
    };

    oidc = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "Keycloak";
        description = "Display name for the OIDC provider in buildbot UI";
      };

      discoveryUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://auth.casazza.io/realms/master/.well-known/openid-configuration";
        description = "OIDC discovery endpoint URL";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "buildbot";
        description = "OIDC client ID registered in Keycloak";
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to OIDC client secret file (via SOPS).
          Required when authBackend = "oidc".
        '';
      };

      scope = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "openid"
          "email"
          "profile"
        ];
        description = "OIDC scopes to request";
      };
    };

    github = {
      appId = lib.mkOption {
        type = lib.types.ints.unsigned;
        description = "GitHub App ID (non-secret; from app settings page)";
      };

      oauthId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          OAuth App client ID (non-secret). Required when authBackend = "github".
          Unused for OIDC (login goes through Keycloak).
        '';
      };

      topic = lib.mkOption {
        type = lib.types.str;
        default = "nixlab-ci";
        description = "Repos tagged with this GitHub topic are auto-enrolled";
      };

      appSecretKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to GitHub App private key (.pem) — provisioned via sops";
      };

      webhookSecretFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to webhook secret (random string) — provisioned via sops";
      };

      oauthSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to OAuth App client secret. Required when authBackend = "github".
        '';
      };
    };

    workerPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a random worker password — master and worker share this";
    };

    workerName = lib.mkOption {
      type = lib.types.str;
      default = "buildbot-worker-1";
      description = "Worker name; must match an entry in the synthesized workersFile";
    };

    workerCores = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 4;
      description = "Cores advertised by the local worker (build parallelism hint)";
    };

    builders = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            hostName = lib.mkOption {
              type = lib.types.str;
              description = "Builder hostname or IP (as reachable from this host)";
            };
            systems = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "x86_64-linux" ];
              description = "Nix systems this builder can build";
            };
            maxJobs = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 4;
              description = "Max concurrent build jobs on this builder";
            };
            speedFactor = lib.mkOption {
              type = lib.types.ints.unsigned;
              default = 1;
              description = "Scheduling priority weight (higher = preferred)";
            };
            supportedFeatures = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [
                "big-parallel"
                "nixos-test"
              ];
              description = "Nix system-features supported by this builder";
            };
            sshUser = lib.mkOption {
              type = lib.types.str;
              default = "hydra-builder";
              description = "SSH user on the builder host (matches builder module user)";
            };
            sshKeyFile = lib.mkOption {
              type = lib.types.path;
              description = "SSH private key for authenticating to this builder";
            };
            publicHostKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                SSH public host key for known_hosts verification (e.g.
                "ssh-ed25519 AAAA..."). When null, consumer must configure
                known_hosts separately.
              '';
            };
          };
        }
      );
      default = [ ];
      description = ''
        Remote builder hosts for distributed Nix builds. Shares the same
        builder pool as Hydra. Builder hosts must run the
        `services.casazza-hydra.builder.*` modules with matching
        `authorizedKeys` for the sshUser specified here.
      '';
    };

    garPush = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable GAR push postBuildStep (runs on v* tag builds)";
      };

      repository = lib.mkOption {
        type = lib.types.str;
        default = "us-central1-docker.pkg.dev/casazza-identity/nixlab/definitely-not-crosswords";
        description = "Full GAR image path (without tag) — :$TAG appended at push time";
      };

      tagGlob = lib.mkOption {
        type = lib.types.str;
        default = "v*";
        description = "Branch glob that triggers the GAR push postBuildStep";
      };

      credentialsFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to GCP SA JSON key with artifactregistry.writer on the repo";
      };

      outputAttribute = lib.mkOption {
        type = lib.types.str;
        default = "dockerImage";
        description = "Flake attribute whose build output is the OCI archive to push";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.buildbot-nix.master = {
      enable = true;
      domain = cfg.domain;
      admins = cfg.admins;
      authBackend = cfg.authBackend;
      useHTTPS = true;

      # GitHub App is always enabled — webhook/PR detection is needed
      # regardless of how users authenticate to the web UI.
      github = {
        enable = true;
        appId = cfg.github.appId;
        topic = cfg.github.topic;
        appSecretKeyFile = cfg.github.appSecretKeyFile;
        webhookSecretFile = cfg.github.webhookSecretFile;
        oauthId = cfg.github.oauthId;
        oauthSecretFile = cfg.github.oauthSecretFile;
      };

      # OIDC auth (Keycloak) — only wired when authBackend = "oidc".
      oidc = lib.mkIf (cfg.authBackend == "oidc") {
        inherit (cfg.oidc)
          name
          discoveryUrl
          clientId
          scope
          ;
        clientSecretFile = cfg.oidc.clientSecretFile;
      };

      # Synthesize the workersFile from the password + local worker config.
      workersFile = pkgs.writeText "buildbot-workers.json" (
        builtins.toJSON [
          {
            name = cfg.workerName;
            pass = "${cfg.workerPasswordFile}";
            cores = cfg.workerCores;
          }
        ]
      );

      postBuildSteps = lib.optional cfg.garPush.enable {
        name = "push-to-gar";
        environment = {
          GOOGLE_APPLICATION_CREDENTIALS = "%(secret:gar-sa-key)s";
        };
        command = [
          "${pkgs.skopeo}/bin/skopeo"
          "copy"
          "oci-archive:%(prop:outpath)s"
          "docker://${cfg.garPush.repository}:%(prop:branch)s"
        ];
        warnOnly = false;
      };

      effects.perRepoSecretFiles = lib.mkIf cfg.garPush.enable {
        "github:olivecasazza/definitely-not-crosswords" = cfg.garPush.credentialsFile;
      };
    };

    # Local worker — co-located with master. Heavy lifting goes to remote
    # builders via nix distributed builds (see builders option above).
    services.buildbot-nix.worker = {
      enable = true;
      workerPasswordFile = cfg.workerPasswordFile;
    };

    # Distributed builds — dispatch to the shared remote-builder pool.
    # The nix daemon reads /etc/nix/machines (written by nix.buildMachines)
    # and connects to remote builders via ssh-ng as hydra-builder.
    nix.distributedBuilds = lib.mkIf (cfg.builders != [ ]) true;
    nix.buildMachines = map (b: {
      inherit (b)
        hostName
        systems
        maxJobs
        speedFactor
        supportedFeatures
        sshUser
        ;
      sshKey = b.sshKeyFile;
      mandatoryFeatures = [ ];
      protocol = "ssh-ng";
    }) cfg.builders;

    # Host key verification for builder SSH connections.
    programs.ssh.knownHosts = lib.listToAttrs (
      lib.imap0 (i: b: {
        name = "buildbot-builder-${toString i}";
        value = {
          hostNames = [ b.hostName ];
          publicKey = b.publicHostKey;
        };
      }) (lib.filter (b: b.publicHostKey != null) cfg.builders)
    );

    # Render the GAR SA key into /run/buildbot-gar/key.json with strict perms.
    systemd.services.buildbot-gar-key = lib.mkIf cfg.garPush.enable {
      description = "Materialize GAR SA key for buildbot-nix postBuildStep";
      wantedBy = [ "multi-user.target" ];
      after = [ "sops-install-secrets.service" ];
      requires = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /run/buildbot-gar
        cp ${cfg.garPush.credentialsFile} /run/buildbot-gar/key.json
        chmod 0400 /run/buildbot-gar/key.json
        chown buildbot:buildbot /run/buildbot-gar/key.json 2>/dev/null || true
      '';
    };

    # nginx is configured by buildbot-nix itself (enableNginx, default true).
    # TLS is terminated upstream by Cloudflare (useHTTPS above).
    networking.firewall.allowedTCPPorts = lib.optionals (cfg.domain != "localhost") [
      80
      443
    ];

    environment.systemPackages = lib.mkIf cfg.garPush.enable [ pkgs.skopeo ];
  };
}
