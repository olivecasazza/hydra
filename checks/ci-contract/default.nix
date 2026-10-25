{ pkgs, lib, ... }:
let
  ci = import ../../lib/ci.nix { inherit lib; };
  systemA = "system-a";
  systemB = "system-b";
  drvA = pkgs.runCommand "ci-contract-system-a" { } "touch $out";
  drvB = pkgs.runCommand "ci-contract-system-b" { } "touch $out";

  valid = ci.mkOutputs {
    systems = [ systemA systemB ];
    packageSystems = [ systemA systemB ];
    checkSystems = [ systemA ];
    hydraSystems = [ systemB ];
    buildFor = system:
      if system == systemA then
        {
          packages = { app = drvA; };
          checks = { app = drvA; };
        }
      else
        {
          packages = { app = drvB; };
          # Keep a nested Hydra tree: Hydra accepts jobsets deeper than one attr.
          hydraJobs = { nested = { app = drvB; }; };
        };
  };

  # An unselected system is not evaluated. If mkOutputs forced all buildFor
  # results while projecting systemA, this value would fail the whole check.
  lazySelected = ci.mkOutputs {
    systems = [ systemA systemB ];
    packageSystems = [ systemA ];
    checkSystems = [ systemA ];
    hydraSystems = [ ];
    buildFor = system:
      if system == systemA then
        {
          packages = { app = drvA; };
          checks = { app = drvA; };
        }
      else
        throw "unselected buildFor system was evaluated";
  };

  packageHydraFallback = ci.mkOutputs {
    systems = [ systemA ];
    packageSystems = [ systemA ];
    checkSystems = [ ];
    hydraSystems = [ systemA ];
    buildFor = _system: {
      packages = { app = drvA; };
    };
  };

  checksOnly = ci.mkOutputs {
    systems = [ systemA ];
    packageSystems = [ ];
    checkSystems = [ systemA ];
    hydraSystems = [ ];
    buildFor = _system: {
      checks = { check-only = drvA; };
    };
  };

  hydraOnly = ci.mkOutputs {
    systems = [ systemB ];
    packageSystems = [ ];
    checkSystems = [ ];
    hydraSystems = [ systemB ];
    buildFor = _system: {
      hydraJobs = { job-only = drvB; };
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
    (builtins.toString valid.packages.${systemA}.app == builtins.toString drvA)
    (builtins.toString valid.packages.${systemB}.app == builtins.toString drvB)
    (builtins.toString valid.packages.${systemA}.app != builtins.toString valid.packages.${systemB}.app)
    (builtins.toString valid.checks.${systemA}.app == builtins.toString drvA)
    (builtins.toString valid.hydraJobs.${systemB}.nested.app == builtins.toString drvB)
    (builtins.hasAttr systemB valid.checks == false)
    (builtins.hasAttr systemA valid.hydraJobs == false)
    (builtins.toString lazySelected.packages.${systemA}.app == builtins.toString drvA)
    (builtins.toString packageHydraFallback.hydraJobs.${systemA}.app == builtins.toString drvA)
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
