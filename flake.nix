{
  description = "casazza-hydra — Hydra CI + remote-builder NixOS modules extracted from nixlab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    snowfall-lib.url = "github:snowfallorg/lib";
    snowfall-lib.inputs.nixpkgs.follows = "nixpkgs";

    # buildbot-nix and kubenix are NOT declared here:
    #   - consumers (nixlab) add buildbot-nix as a direct flake input and import
    #     `inputs.buildbot-nix.nixosModules.buildbot-master`/`buildbot-worker`
    #     alongside this repo's `nixosModules.buildbot`. One source of truth
    #     for the buildbot-nix version (matches how niri/home-manager are used).
    #   - nixlab brings its own kubenix and imports this repo's k8s modules by
    #     source path (snowfall doesn't auto-export non-NixOS modules).
  };

  outputs =
    inputs:
    let
      # Mirror nixlab's working snowfall-lib invocation: mkLib first, then
      # lib.mkFlake. The single-step `snowfall-lib.mkFlake` shortcut exists
      # but the two-step form is what the consumer (nixlab) uses, so we match.
      lib = inputs.snowfall-lib.mkLib {
        inherit inputs;
        src = ./.;
        snowfall = {
          # Treat the flake root as the Snowfall root so modules/ and lib/
          # are discovered automatically. Snowfall's directory convention:
          #   modules/nixos/<name>/default.nix → nixosModules.<name>
          # (flat files do NOT auto-discover; use the directory pattern.)
          root = ./.;
          namespace = "casazza-hydra";
          meta = {
            name = "casazza-hydra";
            title = "casazza-hydra";
          };
        };
      };
    in
    lib.mkFlake {
      # NixOS system modules (global) — empty: consumers import this repo's
      # modules explicitly per host (buildbot on seir, builders on builder hosts).
      systems.modules.nixos = [ ];
    };
}
