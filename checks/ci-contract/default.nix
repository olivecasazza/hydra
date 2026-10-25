{ pkgs, lib, ... }:
let
  ci = import ../../lib/ci.nix { inherit lib; };
  systemA = "system-a";
  systemB = "system-b";
  drv = pkgs.runCommand "ci-contract-identity" { } "touch $out";

  valid = ci.mkOutputs {
    systems = [ systemA systemB ];
    packageSystems = [ systemA systemB ];
    checkSystems = [ systemA ];
    hydraSystems = [ systemB ];
    buildFor = _system: {
      packages = { app = drv; };
      checks = { app = drv; };
      hydraJobs = { app = drv; };
    };
  };

  checksOnly = ci.mkOutputs {
    systems = [ systemA ];
    packageSystems = [ ];
    checkSystems = [ systemA ];
    hydraSystems = [ ];
    buildFor = _system: {
      checks = { check-only = drv; };
    };
  };

  hydraOnly = ci.mkOutputs {
    systems = [ systemB ];
    packageSystems = [ ];
    checkSystems = [ ];
    hydraSystems = [ systemB ];
    buildFor = _system: {
      hydraJobs = { job-only = drv; };
    };
  };

  fails = expression: !(builtins.tryEval (builtins.deepSeq expression true)).success;

  invalidSystem = ci.mkOutputs {
    systems = [ systemA ];
    packageSystems = [ systemB ];
    checkSystems = [ ];
    hydraSystems = [ ];
    buildFor = _system: { };
  };

  duplicateSystem = ci.mkOutputs {
    systems = [ systemA systemA ];
    packageSystems = [ ];
    checkSystems = [ ];
    hydraSystems = [ ];
    buildFor = _system: { };
  };

  emptyCheck = ci.mkOutputs {
    systems = [ systemA ];
    packageSystems = [ ];
    checkSystems = [ systemA ];
    hydraSystems = [ ];
    buildFor = _system: { checks = { }; };
  };

  missingChecks = ci.mkOutputs {
    systems = [ systemA ];
    packageSystems = [ ];
    checkSystems = [ systemA ];
    hydraSystems = [ ];
    buildFor = _system: { };
  };

  missingHydra = ci.mkOutputs {
    systems = [ systemA ];
    packageSystems = [ ];
    checkSystems = [ ];
    hydraSystems = [ systemA ];
    buildFor = _system: { };
  };

  invalidSystemType = ci.mkOutputs {
    systems = [ 1 ];
    packageSystems = [ ];
    checkSystems = [ ];
    hydraSystems = [ ];
    buildFor = _system: { };
  };

  emptyPackage = ci.mkOutputs {
    systems = [ systemA ];
    packageSystems = [ systemA ];
    checkSystems = [ ];
    hydraSystems = [ ];
    buildFor = _system: { packages = { }; };
  };

  emptyHydra = ci.mkOutputs {
    systems = [ systemA ];
    packageSystems = [ ];
    checkSystems = [ ];
    hydraSystems = [ systemA ];
    buildFor = _system: { hydraJobs = { }; };
  };

  assertions = [
    (builtins.toString valid.packages.${systemA}.app == builtins.toString valid.checks.${systemA}.app)
    (builtins.toString valid.checks.${systemA}.app == builtins.toString valid.hydraJobs.${systemB}.app)
(builtins.hasAttr systemB valid.checks == false)
(builtins.hasAttr systemA valid.hydraJobs == false)
    (builtins.attrNames checksOnly.checks.${systemA} == [ "check-only" ])
    (builtins.attrNames hydraOnly.hydraJobs.${systemB} == [ "job-only" ])
    (fails invalidSystem)
    (fails duplicateSystem)
    (fails emptyCheck)
    (fails missingChecks)
    (fails missingHydra)
    (fails invalidSystemType)
    (fails emptyPackage)
    (fails emptyHydra)
  ];

  allPassed = lib.all (value: value) assertions;
in
assert lib.assertMsg allPassed "ci-contract: one or more behavioral assertions failed";
pkgs.runCommand "ci-contract" { } "touch $out"
