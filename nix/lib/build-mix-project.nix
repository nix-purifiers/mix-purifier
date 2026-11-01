# SPDX-License-Identifier: MIT
#
# buildMixProject: builds a Mix project in the Nix sandbox from its
# mix.lock, with no generated Nix files in the project.
#
#   buildMixProject { src = ./.; }
#
# The dependencies come from the locks (nix/lib/deps.nix), and nixpkgs'
# mixRelease compiles the project and builds its release, offline. Every
# argument mixRelease takes passes through, such as `mixEnv`,
# `mixReleaseName` and `escriptBinName`. Beyond those:
#
# - `pname` and `version` default to the application name and version in
#   mix.exs (nix/lib/mix-project.nix).
# - `lockFile` is mix.lock, and `purifierLockFile` is
#   mix-purifier.lock.json when the project has one.
# - `hexMirror` is the Hex repository the tarballs come from.
#
# The Erlang and Elixir versions are those of `beamPackages`, so
# `buildMixProject.override { beamPackages = beam27Packages; }` builds with
# another set. The result's `deps` is the dependency directory.
{
  lib,
  beamPackages,
  callPackage,
}:
{
  src,
  lockFile ? src + "/mix.lock",
  purifierLockFile ?
    if builtins.pathExists (src + "/mix-purifier.lock.json") then
      src + "/mix-purifier.lock.json"
    else
      null,
  hexMirror ? "https://repo.hex.pm",
  pname ? null,
  version ? null,
  passthru ? { },
  ...
}@args:
let
  project = import ./mix-project.nix { inherit lib; } (src + "/mix.exs");
  deps = callPackage ./deps.nix { inherit beamPackages; } {
    inherit lockFile purifierLockFile hexMirror;
  };
  orFromMixExs =
    field: given: found:
    if given != null then
      given
    else if found != null then
      found
    else
      throw "mix-purifier: cannot read the ${field} from ${toString src}/mix.exs. Give `${field}` to buildMixProject.";
in
beamPackages.mixRelease (
  removeAttrs args [
    "lockFile"
    "purifierLockFile"
    "hexMirror"
  ]
  // {
    pname = orFromMixExs "pname" pname project.app;
    version = orFromMixExs "version" version project.version;
    mixFodDeps = deps;
    passthru = passthru // {
      inherit deps;
    };
  }
)
