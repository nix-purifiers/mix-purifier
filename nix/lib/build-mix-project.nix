# SPDX-License-Identifier: MIT
#
# buildMixProject: builds a Mix project in the Nix sandbox from mix.lock and
# mix-purifier.lock.json, with no generated Nix files in the project.
#
#   buildMixProject { src = ./.; }
#
# mix-purifier.lock.json records every output the project produces, as Mix
# reported it to `mix-purifier lock`, so Nix knows each one by name when it
# evaluates:
#
# - `releases.<name>`: the release `mix release <name>` builds.
# - `apps.<name>`: the compiled application, with its ebin and priv
#   directories, for each of the project's own applications.
# - `escripts.<name>`: the escript `mix escript.build` builds, in bin/.
# - `hexPackage`: the package tarball `mix hex.build` builds, as
#   `package.tar`, or null for a project with no package metadata.
# - `docs`: the HTML documentation `mix docs` builds.
# - `deps`: the dependency directory (nix/lib/deps.nix).
# - `outputs`: the record of the outputs, as the lock holds it.
#
# The result itself is the first release, or the compiled applications for
# a project without a release. A mix.exs that changed since the lock was
# written fails the evaluation, rather than building outputs the lock no
# longer describes.
#
# nixpkgs' mixRelease compiles each output, offline. Every argument
# mixRelease takes passes through, such as `mixEnv`. Beyond those:
#
# - `root` is the directory of mix.exs inside `src`. A project with a path
#   dependency outside its own directory takes a `src` that holds both, and
#   names its own directory as `root`.
# - `lockFile` is mix.lock, and `purifierLockFile` is
#   mix-purifier.lock.json.
# - `hexMirror` is the mirror the hexpm tarballs come from.
# - `docsMixEnv` is the Mix environment that has ex_doc, for `docs`.
# - `pname` and `version` replace the name and version the lock records.
#
# The Erlang and Elixir versions are those of `beamPackages`, so
# `buildMixProject.override { beamPackages = beam27Packages; }` builds with
# another set.
{
  lib,
  pkgs,
  beamPackages,
  callPackage,
  # The shared purifier library (github:nix-purifiers/purifier).
  purifier,
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
  passthru ? { },
  ...
}@args:
let
  projectDir = src + "/${root}";
  purifierLock = import ./purifier-lock.nix { inherit lib; } purifierLockFile;

  recorded =
    if purifierLock.outputs == null then
      throw "mix-purifier: ${toString projectDir} has no mix-purifier.lock.json with the project's outputs. Run `mix-purifier lock`."
    else
      purifierLock.outputs;
  changed = lib.attrNames (
    lib.filterAttrs (
      file: hash: builtins.hashFile "sha256" (projectDir + "/${file}") != hash
    ) recorded.definitionFiles
  );
  outputs =
    if changed != [ ] then
      throw "mix-purifier: ${lib.concatStringsSep ", " changed} changed since mix-purifier.lock.json was written. Run `mix-purifier lock`."
    else
      recorded;

  name =
    args.pname or (
      if outputs.app != null then
        outputs.app
      else if outputs.releases != [ ] then
        builtins.head outputs.releases
      else
        baseNameOf (toString projectDir)
    );
  version =
    args.version or (
      if outputs.version != null then
        outputs.version
      else
        throw "mix-purifier: ${toString projectDir}/mix.exs sets no version. Give `version` to buildMixProject."
    );

  deps =
    callPackage ./deps.nix
      {
        inherit beamPackages;
        fetchEntry = purifier.fetchEntry { inherit pkgs; };
      }
      {
        inherit lockFile purifierLockFile hexMirror;
      };

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
      inherit version;
      mixFodDeps = deps;
    }
    // lib.optionalAttrs (root != ".") {
      # The project builds in its own directory inside the unpacked source.
      postUnpack = (args.postUnpack or "") + ''
        sourceRoot="$sourceRoot"/${lib.escapeShellArg root}
      '';
    };

  # A derivation of the project that installs something other than a
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

  # `mix release` builds a project's only release, configured or the
  # implicit one named after the application, and `mix release <name>`
  # accepts only a configured name, so the name is given only to choose
  # among several.
  releases = lib.genAttrs outputs.releases (
    release:
    beamPackages.mixRelease (
      common
      // {
        pname = release;
        mixReleaseName = if lib.length outputs.releases > 1 then release else "";
      }
    )
  );

  compiled = artifact "apps" {
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      for app in ${lib.escapeShellArgs (lib.attrNames outputs.apps)}; do
        cp -rL "_build/$MIX_BUILD_PREFIX/lib/$app" "$out/$app"
      done
      runHook postInstall
    '';
  };
  apps = lib.mapAttrs (app: _: "${compiled}/${app}") outputs.apps;

  escripts = lib.genAttrs outputs.escripts (
    escript:
    artifact "escript-${escript}" {
      escriptBinName = escript;
    }
  );

  hexPackage =
    if outputs.package == null then
      null
    else
      artifact "hex-package" {
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

  default = if outputs.releases != [ ] then releases.${builtins.head outputs.releases} else compiled;
in
default.overrideAttrs (previous: {
  passthru =
    (previous.passthru or { })
    // passthru
    // {
      inherit
        releases
        apps
        escripts
        hexPackage
        docs
        deps
        outputs
        ;
    };
})
