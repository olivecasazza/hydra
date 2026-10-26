{ pkgs, ... }:
let
  python = pkgs.buildbot.passthru.python.withPackages (
    _: pkgs.buildbot.passthru.dependencies
      ++ [ pkgs.buildbot.passthru.python.pkgs.setuptools ]
  );
  pythonSitePackages = "lib/python${pkgs.buildbot.passthru.python.pythonVersion}/site-packages";
  pythonPath = "${pkgs.buildbot}/${pythonSitePackages}";
in
pkgs.runCommand "buildbot-discovery-cadence" {
  nativeBuildInputs = [ python ];
  PYTHONPATH = pythonPath;
} ''
  ${python}/bin/python ${./test.py} ${../../modules/nixos/buildbot/github_projects_refresh.py} ${../../modules/nixos/buildbot/private_ci_data_authz.py} 'PrivateCiDataAuthzConfigurator(True)' 'PrivateCiDataAuthzConfigurator(False)'
  touch "$out"
''
