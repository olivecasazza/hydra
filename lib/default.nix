# Helpers for formatting the nix remote-builder machines file.
# Parameterized so this repo doesn't import nixlab's lib/hosts.nix (no circular dep):
# consumers pass builder host records in as module options.
{ lib, ... }:
let
  inherit (lib) concatStringsSep;
in
{
  # Format a single machines file line for one builder.
  # Shape mirrors Hydra's queue-runner / nix remote-builder format:
  #   ssh-ng://USER@HOST SYSTEMS SSHKEY MAXJOBS SPEEDFACTOR FEATURES
  # (the in-cluster Deployment mounts this at /etc/nix/machines; the NixOS
  # orchestrator module writes the same shape to /etc/hydra/machines).
  buildMachinesLine =
    {
      user,
      host,
      systems,
      sshKey ? "/var/lib/hydra/.ssh/id_ed25519",
      maxJobs,
      speedFactor,
      features,
    }:
    "ssh-ng://${user}@${host} ${concatStringsSep "," systems} ${sshKey} ${toString maxJobs} ${toString speedFactor} ${concatStringsSep "," features}";

  # Fold a list of builder records into a multi-line machines file.
  # Each record: { user, host, systems, maxJobs, speedFactor, features, sshKey? }
  machinesFile =
    builders:
    concatStringsSep "\n" (
      builtins.map (
        b:
        let
          line = {
            inherit (b)
              user
              host
              systems
              maxJobs
              speedFactor
              features
              ;
            sshKey = b.sshKey or "/var/lib/hydra/.ssh/id_ed25519";
          };
        in
        # re-use buildMachinesLine via lib to avoid import cycle weirdness
        "${line.user}@${line.host} ${concatStringsSep "," line.systems} ${line.sshKey} ${toString line.maxJobs} ${toString line.speedFactor} ${concatStringsSep "," line.features}"
      ) builders
    );
}
