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
# - `root` is the directory of mix.exs inside `src`. A project with a path
#   dependency outside its own directory takes a `src` that holds both, and
#   names its own directory as `root`.
# - `pname` and `version` default to the application name and version in
#   mix.exs (nix/lib/mix-project.nix). An umbrella root has no application,
#   so an umbrella project gives both.
# - `lockFile` is mix.lock, and `purifierLockFile` is
#   mix-purifier.lock.json when the project has one.
# - `hexMirror` is the mirror the hexpm tarballs come from.
# - `docsMixEnv` is the Mix environment that has ex_doc, for `docs`.
#
# The result is the release. Beside it, `hexPackage` is the package tarball
# `mix hex.build` makes, `docs` is the HTML documentation `mix docs` makes,
# and `deps` is the dependency directory. `mix-purifier publish` publishes
# `hexPackage` and `docs`.
#
# The Erlang and Elixir versions are those of `beamPackages`, so
# `buildMixProject.override { beamPackages = beam27Packages; }` builds with
# another set.
{
  lib,
  beamPackages,
  callPackage,
}:
{
  src,
  root ? ".",
  lockFile ? src + "/${root}/mix.lock",
  purifierLockFile ?
    if builtins.pathExists (src + "/${root}/mix-purifier.lock.json") then
      src + "/${root}/mix-purifier.lock.json"
    else
      null,
  hexMirror ? "https://repo.hex.pm",
  docsMixEnv ? "dev",
  pname ? null,
  version ? null,
  passthru ? { },
  ...
}@args:
let
  project = import ./mix-project.nix { inherit lib; } (src + "/${root}/mix.exs");
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
      throw "mix-purifier: cannot read the ${field} from ${toString src}/${root}/mix.exs. Give `${field}` to buildMixProject.";
  name = orFromMixExs "pname" pname project.app;

  common =
    removeAttrs args [
      "root"
      "lockFile"
      "purifierLockFile"
      "hexMirror"
      "docsMixEnv"
      "passthru"
    ]
    // {
      pname = name;
      version = orFromMixExs "version" version project.version;
      mixFodDeps = deps;
    }
    // lib.optionalAttrs (root != ".") {
      # The project builds in its own directory inside the unpacked source.
      postUnpack = (args.postUnpack or "") + ''
        sourceRoot="$sourceRoot"/${lib.escapeShellArg root}
      '';
    };

  # A derivation of the project that installs something other than the
  # release, so the release fixups do not apply.
  artifact =
    suffix: extra:
    beamPackages.mixRelease (
      common
      // {
        pname = "${name}-${suffix}";
        dontMixReleaseFixup = true;
        removeCookie = false;
      }
      // extra
    );

  hexPackage = artifact "hex-package" {
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      mix hex.build --output "$out/package.tar"
      runHook postInstall
    '';
  };

  docs = artifact "docs" {
    mixEnv = docsMixEnv;
    installPhase = ''
      runHook preInstall
      mix docs --formats html --output "$out"
      runHook postInstall
    '';
  };
in
beamPackages.mixRelease (
  common
  // {
    passthru = passthru // {
      inherit deps hexPackage docs;
    };
  }
)
