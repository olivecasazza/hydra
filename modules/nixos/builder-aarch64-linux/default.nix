# Remote-builder host config for aarch64-linux targets.
#
# *** NO HARDWARE YET ***
# nixlab has no aarch64-linux nodes in lib/hosts.nix (only x86_64-linux on
# seir/hp0x and aarch64-darwin on mm0x). This module exists for future
# Pi/Ampere nodes. Do not apply to any host until hardware is added; the
# `enable` flag defaults to false so importing it is inert.
{
  lib,
  config,
  ...
}:
let
  cfg = config.services.casazza-hydra.builder.aarch64-linux;
in
{
  options.services.casazza-hydra.builder.aarch64-linux = {
    enable = lib.mkEnableOption "aarch64-linux remote-builder host (NO HARDWARE YET)";

    maxJobs = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 4;
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
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings.max-jobs = cfg.maxJobs;
    nix.settings.system-features = cfg.features;
    nix.settings.trusted-users = [ "hydra-builder" ];

    users.users.hydra-builder = {
      isNormalUser = true;
      home = "/var/lib/hydra-builder";
      createHome = true;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };

    services.openssh.enable = true;
  };
}
