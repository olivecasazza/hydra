# Remote-builder host config for aarch64-darwin targets (macOS).
#
# NOTE: This is a nix-darwin module, NOT NixOS. The consumer's flake must
# declare a `darwinConfiguration` (not nixosConfiguration) that imports
# this module. Targets the mm01-mm05 Mac Minis in the nixlab fleet —
# used for Tauri desktop builds (crossword-desktop).
{
  lib,
  config,
  ...
}:
let
  cfg = config.services.casazza-hydra.builder.aarch64-darwin;
in
{
  options.services.casazza-hydra.builder.aarch64-darwin = {
    enable = lib.mkEnableOption "aarch64-darwin remote-builder host (macOS / nix-darwin)";

    maxJobs = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 4;
      description = "Concurrent build slots (match to Mac Mini CPU/RAM)";
    };

    speedFactor = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
    };

    features = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "big-parallel" ];
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys authorized to dispatch builds as the builder user";
    };
  };

  config = lib.mkIf cfg.enable {
    # nix-darwin options. Same shape as NixOS nix.settings but under
    # services.nix or nix.* depending on nix-darwin version. Using the
    # modern unified nix.* namespace (nix-darwin ≥ 2024).
    nix.settings.max-jobs = cfg.maxJobs;
    nix.settings.system-features = cfg.features;
    nix.settings.trusted-users = [ "hydra-builder" ];

    users.users.hydra-builder = {
      home = "/var/lib/hydra-builder";
      createHome = true;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
  };
}
