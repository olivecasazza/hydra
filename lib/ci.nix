# Framework-neutral projection of one repository's per-system derivations.
#
# This helper does not construct packages, run Buildbot/Hydra, inspect GitHub,
# read credentials, or fetch anything. The caller owns buildFor and chooses the
# systems on which each ordinary flake output is exposed.
{ lib }:
let
  isStringList = value: builtins.isList value && lib.all builtins.isString value;
  isUnique = value: lib.unique value == value;

  assertSystemList =
    name: systems: allSystems:
    assert lib.assertMsg (isStringList systems) "ci.mkOutputs: ${name} must be a list of strings";
    assert lib.assertMsg (isUnique systems) "ci.mkOutputs: ${name} must not contain duplicates";
    assert lib.assertMsg (lib.all (system: lib.elem system allSystems) systems)
      "ci.mkOutputs: every ${name} entry must appear in systems";
    true;

  requireAttrset =
    label: value:
    assert lib.assertMsg (builtins.isAttrs value) "ci.mkOutputs: ${label} must be an attrset";
    value;

  requireNonEmpty =
    label: value:
    let
      checked = requireAttrset label value;
    in
    assert lib.assertMsg (builtins.attrNames checked != [ ])
      "ci.mkOutputs: ${label} must not be empty";
    checked;

  selectedAttrset =
    values: attr: kind: system:
    let
      entry = requireAttrset "buildFor ${system}" values.${system};
    in
    if builtins.hasAttr attr entry then
      requireNonEmpty "${kind}.${system}" (builtins.getAttr attr entry)
    else
      throw "ci.mkOutputs: buildFor ${system} does not provide ${attr} for ${kind}.${system}";
in
{
  mkOutputs =
    {
      systems,
      packageSystems,
      checkSystems,
      hydraSystems,
      buildFor,
    }:
    assert lib.assertMsg (isStringList systems) "ci.mkOutputs: systems must be a list of strings";
    assert lib.assertMsg (isUnique systems) "ci.mkOutputs: systems must not contain duplicates";
    assert assertSystemList "packageSystems" packageSystems systems;
    assert assertSystemList "checkSystems" checkSystems systems;
    assert assertSystemList "hydraSystems" hydraSystems systems;
    assert lib.assertMsg (builtins.isFunction buildFor) "ci.mkOutputs: buildFor must be a function";
    let
      values = lib.genAttrs systems (system: requireAttrset "buildFor ${system}" (buildFor system));
      packages = lib.genAttrs packageSystems (system: selectedAttrset values "packages" "packages" system);
      checks = lib.genAttrs checkSystems (system: selectedAttrset values "checks" "checks" system);
      hydraJobs = lib.genAttrs hydraSystems (
        system:
        let
          entry = values.${system};
        in
        if entry ? hydraJobs then
          requireNonEmpty "hydraJobs.${system}" entry.hydraJobs
        else if entry ? packages then
          requireNonEmpty "hydraJobs.${system} (packages fallback)" entry.packages
        else
          throw "ci.mkOutputs: buildFor ${system} provides neither hydraJobs nor packages for hydraJobs.${system}"
      );
    in
    {
      inherit packages checks hydraJobs;
    };
}
