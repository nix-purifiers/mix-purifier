{ pkgs }:
let
  build = pkgs.mix-purifier.buildMixProject;
  src = ./fixtures/umbrella;
  bad = [
    { nonexistent = [ "shouter" ]; }
    { umbrella = [ ]; }
    {
      umbrella = [
        "shouter"
        "shouter"
      ];
    }
    { umbrella = [ "jason" ]; }
    { umbrella = [ "../greeter" ]; }
  ];
  refused =
    otpApplications:
    !(builtins.tryEval (build { inherit src otpApplications; }).packages.release-umbrella.drvPath)
    .success;
  cross =
    if pkgs.stdenv.buildPlatform.isAarch64 then
      pkgs.pkgsCross.gnu64
    else
      pkgs.pkgsCross.aarch64-multiplatform;
  crossBuild = build.override { stdenv = cross.stdenv; };
in
assert builtins.all refused bad;
assert (build { inherit src; }).projections == { };
assert cross.stdenv.buildPlatform != cross.stdenv.hostPlatform;
assert
  !(builtins.tryEval
    (crossBuild {
      inherit src;
      otpApplications.umbrella = [ "shouter" ];
    }).packages.release-umbrella.drvPath
  ).success;
true
