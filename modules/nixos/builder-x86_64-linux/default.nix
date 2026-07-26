# Remote-builder host config for x86_64-linux targets.
#
# Configures this host to RECEIVE builds dispatched by Hydra's queue-runner
# (and buildbot-nix worker) over ssh-ng. The orchestrator's machinesFile
# (modules/k8s/hydra.nix) must reference this host's user@host; supplying it
# there is the consumer's job.
#
# Enable aarch64-linux emulation via binfmt if you want this box to also
# service ARM Linux builds (slow — QEMU user-mode). Disabled by default.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.services.casazza-hydra.builder.x86_64-linux;
in
{
  options.services.casazza-hydra.builder.x86_64-linux = {
    enable = lib.mkEnableOption "x86_64-linux remote-builder host";

    maxJobs = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 8;
      description = "Concurrent build slots (match to host CPU/RAM budget)";
    };

    speedFactor = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = "Hydra scheduling weight (faster hosts → higher)";
    };

    features = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "big-parallel"
        "nixos-test"
      ];
      description = "nix supportedFeatures advertised to the dispatcher";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys authorized to dispatch builds as the builder user (typically the orchestrator's id_ed25519)";
    };

    enableAarch64Emulation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Register QEMU binfmt handlers for aarch64-linux (slow but works)";
    };
  };

  config = lib.mkIf cfg.enable {
    # nix daemon: advertise build capacity and features.
    nix.settings.max-jobs = cfg.maxJobs;
    nix.settings.system-features = cfg.features;
    nix.settings.trusted-users = [ "hydra-builder" ];

    # Builder user. Orchestrator ssh's in as this user; authorized_keys
    # is populated from cfg.authorizedKeys.
    users.users.hydra-builder = {
      isNormalUser = true;
      home = "/var/lib/hydra-builder";
      createHome = true;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    # Optional: ARM Linux cross-build via QEMU user-mode. Slow but lets the
    # same hardware service aarch64-linux jobs (e.g. Pi images).
    boot.binfmt.emulatedSystems = lib.mkIf cfg.enableAarch64Emulation [ "aarch64-linux" ];

    # sshd must be enabled for the orchestrator to reach us. Consumer's
    # base config typically already does this — assert rather than enable.
    services.openssh.enable = true;
  };
}
