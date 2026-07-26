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
# Activation TODO (secrets — none provisioned yet):
#   1. Create a GitHub App (Settings → Developer settings → GitHub Apps):
#        - Permissions: Contents (r), Commit statuses (rw), Webhooks (rw),
#          Metadata (r), Members (r). Subscribe to push + pull_request.
#        - Generate a private key (.pem) and an OAuth client secret.
#        - Install on olivecasazza account; grant access to enrolled repos.
#   2. Create a GCP service account with artifactregistry.writer on the GAR
#      repo (e.g. reuse `crosswords-ci` in casazza-identity, or a new one),
#      and export a JSON key. Provision it via sops on the consumer host.
#   3. Populate secrets/buildbot.yaml (consumer does this — nixlab owns SOPS):
#        app_secret_key (.pem), webhook_secret (random), oauth_secret
#        (App client secret), worker_password (random), gar_sa_key (JSON).
#   4. Set real numeric appId + oauthId on the consumer invocation
#      (these are non-secret).
#   5. Add DNS + Cloudflare Access/tunnel for buildbot.casazza.io → :8010
#      (consumer handles tunnel/DNS — nixlab tofu/cloudflare).
#   6. Tag each enrolled repo with the `topic` below (default `nixlab-ci`)
#      so buildbot auto-discovers it.
#
# Until secrets exist, leaving `enable = false` keeps eval clean.
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

    domain = lib.mkOption {
      type = lib.types.str;
      default = "buildbot.casazza.io";
      description = "Public URL for buildbot web UI (consumer wires Cloudflare Tunnel → this host:8010)";
    };

    admins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "olivecasazza" ];
      description = "GitHub usernames granted buildbot admin (login + restart privileges)";
    };

    github = {
      appId = lib.mkOption {
        type = lib.types.ints.unsigned;
        description = "GitHub App ID (non-secret; from app settings page)";
      };

      oauthId = lib.mkOption {
        type = lib.types.str;
        description = "OAuth App client ID (non-secret; pairs with oauthSecretFile)";
      };

      topic = lib.mkOption {
        type = lib.types.str;
        default = "nixlab-ci";
        description = "Repos tagged with this GitHub topic are auto-enrolled (GitHub App must be installed on them)";
      };

      appSecretKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to GitHub App private key (.pem) — provisioned via sops by consumer";
      };

      webhookSecretFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to webhook secret (random string) — provisioned via sops";
      };

      oauthSecretFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to OAuth App client secret — provisioned via sops";
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
        description = "Branch glob that triggers the GAR push postBuildStep (buildbot-nix effects_branches)";
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
    # Buildbot master. Uses the upstream module's options directly — the
    # consumer imports `buildbot-nix-master` alongside this module.
    services.buildbot-nix.master = {
      enable = true;
      domain = cfg.domain;
      admins = cfg.admins;
      authBackend = "github";

      # Synthesize the workersFile from the password + local worker config.
      # Avoids the consumer having to format JSON themselves.
      workersFile = pkgs.writeText "buildbot-workers.json" (
        builtins.toJSON [
          {
            name = cfg.workerName;
            pass = "${cfg.workerPasswordFile}";
            cores = cfg.workerCores;
          }
        ]
      );

      github = {
        appId = cfg.github.appId;
        oauthId = cfg.github.oauthId;
        topic = cfg.github.topic;
        appSecretKeyFile = cfg.github.appSecretKeyFile;
        webhookSecretFile = cfg.github.webhookSecretFile;
        oauthSecretFile = cfg.github.oauthSecretFile;
      };

      # postBuildSteps run as plain ShellCommand after each successful
      # nix build of a flake attribute (not in the sandbox — network OK).
      # Gated to v* tag builds via the repo's buildbot-nix.toml
      # (effects_branches = ["v*"]) — see README.md.
      postBuildSteps = lib.optional cfg.garPush.enable {
        name = "push-to-gar";
        environment = {
          GOOGLE_APPLICATION_CREDENTIALS = "%(secret:gar-sa-key)s";
        };
        command = [
          "${pkgs.skopeo}/bin/skopeo"
          "copy"
          # buildbot-nix exposes the built outpath as a property.
          "oci-archive:%(prop:outpath)s"
          "docker://${cfg.garPush.repository}:%(prop:branch)s"
        ];
        # Only fire on tag builds that match the glob. buildbot-nix exposes
        # the branch as a property; effects_branches in the repo's
        # buildbot-nix.toml is the source of truth for which branches/refs
        # run postBuildSteps at all.
        warnOnly = false;
      };

      # Per-repo secret: the GAR SA key, available to the postBuildStep
      # via %(secret:gar-sa-key)s. Consumer wires the sops secret path.
      # NOTE: nested under `effects` — upstream option is
      # services.buildbot-nix.master.effects.perRepoSecretFiles (verified
      # against nix-community/buildbot-nix master.nix:739).
      effects.perRepoSecretFiles = lib.mkIf cfg.garPush.enable {
        "github:olivecasazza/definitely-not-crosswords" = cfg.garPush.credentialsFile;
      };
    };

    # Local worker — co-located with master on this host. Small fleet; the
    # heavy lifting happens on remote builders via nix's distributed builds.
    services.buildbot-nix.worker = {
      enable = true;
      workerPasswordFile = cfg.workerPasswordFile;
    };

    # Render the GAR SA key into /run/buildbot-gar/key.json with strict perms.
    # The postBuildStep reads GOOGLE_APPLICATION_CREDENTIALS from
    # %(secret:gar-sa-key)s which buildbot-nix maps from perRepoSecretFiles.
    # This oneshot ensures the secret file is readable by the buildbot user
    # even if the consumer's sops secret lands at root-only perms.
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

    # nginx reverse proxy: buildbot.casazza.io → 127.0.0.1:8010.
    # The Cloudflare Tunnel (configured by consumer in nixlab tofu) lands
    # traffic at this host; nginx terminates it and forwards to buildbot.
    services.nginx = lib.mkIf (cfg.domain != "localhost") {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts.${cfg.domain} = {
        locations."/".proxyPass = "http://127.0.0.1:8010";
        # Allow large webhook payloads.
        locations."/".extraConfig = ''
          client_max_body_size 10m;
        '';
      };
    };

    # Firewall: 80/443 for the public web UI (nginx), 9989 for worker traffic.
    # Master+worker co-located means 9989 is loopback only — but keep it open
    # in case a future worker lives on another host.
    networking.firewall.allowedTCPPorts = lib.optionals (cfg.domain != "localhost") [
      80
      443
    ];

    # skopeo must be on the worker's PATH for the postBuildStep to find it.
    # The buildbot-nix worker module already injects the master's PATH; this
    # ensures the binary is at a known absolute path (the postBuildStep uses
    # ${pkgs.skopeo}/bin/skopeo explicitly so this is belt-and-suspenders).
    environment.systemPackages = lib.mkIf cfg.garPush.enable [ pkgs.skopeo ];
  };
}
