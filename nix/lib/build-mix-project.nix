# SPDX-License-Identifier: MIT
#
# buildMixProject: builds a Mix project in the Nix sandbox from mix.lock and
# mix-purifier.lock.json, with no generated Nix files in the project. It
# meets the purifier contract (CONTRACT.md in
# github:nix-purifiers/purifier).
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set, and the result is the builder. The flake's
# overlay (`overlays.default`) adds it to the package set as
# `buildMixProject`, so a package written for callPackage takes it like any
# other builder:
#
#   { buildMixProject }: (buildMixProject { src = ./.; }).packages.release-my_app
#
# and `buildMixProject.override` replaces what it takes from the set, such
# as `beamPackages`, the Erlang and Elixir package set.
#
# The builder's result has, each known when Nix evaluates, with no
# import-from-derivation:
#
# - `packages.<name>`: what the project builds. `release-<name>` is the
#   release `mix release` builds, `escript-<name>` the escript
#   `mix escript.build` builds (in bin/), and `app-<name>` the compiled
#   application, with its ebin and priv directories, for each of the
#   project's own applications. `docs` is the HTML documentation
#   `mix docs` builds.
# - `tests`: the project's `mix test` run, in the sandbox.
# - `release`: the package tarball `mix hex.build` builds, as
#   `package.tar`, which `mix-purifier publish` uploads. It is null for a
#   project with no package metadata.
# - `fetches`: the purifier library entries the build fetches, which are
#   the entries of the lock.
# - `lock`: the lock in memory (readLock), `deps`: the dependency
#   directory (deps.nix), and `outputs`: the record of the outputs, as
#   mix-purifier.lock.json holds it.
#
# The builder reads the locks with readLock and passes the result to the
# purifier library's checkLock, so a lock with problems, such as a mix.exs
# that changed since the lock was written, fails the evaluation with them.
#
# nixpkgs' mixRelease compiles each output, offline. Every argument
# mixRelease takes passes through, such as `mixEnv`. The builder's own
# arguments are these:
#
# - `fetchers` goes to the purifier library's fetchEntry, so a
#   `fetchers.fetchurl` that sends credentials or uses a mirror reaches
#   every download.
# - `root` is the directory of mix.exs inside `src`. A project with a path
#   dependency outside its own directory takes a `src` that holds both, and
#   names its own directory as `root`.
# - `lockFile` is mix-purifier.lock.json, and `mixLock` is mix.lock. Each
#   defaults to the file in the project's directory, and a file given
#   outside `src` replaces any copy in it, so a packaging flake can build a
#   project whose author keeps no mix-purifier.lock.json.
# - `hexMirror` is the mirror the hexpm tarballs come from.
# - `docsMixEnv` is the Mix environment that has ex_doc, for
#   `packages.docs`.
# - `pname` and `version` replace the name and version the lock records.
{
  lib,
  stdenv,
  callPackage,
  beamPackages,
  fetchurl,
  fetchgit,
  # The shared purifier library (github:nix-purifiers/purifier), which the
  # overlay passes in.
  purifier,
}:
{
  src,
  lockFile ?
    if builtins.pathExists (src + "/${root}/mix-purifier.lock.json") then
      src + "/${root}/mix-purifier.lock.json"
    else
      null,
  fetchers ? { },
  root ? ".",
  mixLock ? src + "/${root}/mix.lock",
  hexMirror ? "https://repo.hex.pm",
  docsMixEnv ? "dev",
  ...
}@args:
let
  projectDir = src + "/${root}";
  # The lock in memory of the purifier contract. checkLock fails evaluation
  # with its problems, each naming `mix-purifier lock`.
  lock = import ./read-lock.nix { inherit lib; } {
    inherit
      src
      root
      lockFile
      mixLock
      hexMirror
      ;
  };
  checked = purifier.checkLock lock;
  outputs = checked.record;

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

  # Hex tarballs are file entries and git dependencies are git entries, so
  # the fetchers the builder takes by name are the ones it needs.
  deps = callPackage ./deps.nix {
    inherit beamPackages;
    fetchEntry = purifier.fetchEntry ({ inherit fetchurl fetchgit; } // fetchers);
  } (purifier.entriesFor stdenv.hostPlatform.system checked);

  common =
    removeAttrs args [
      "src"
      "fetchers"
      "root"
      "lockFile"
      "mixLock"
      "hexMirror"
      "docsMixEnv"
    ]
    // {
      inherit src version;
      pname = name;
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

  escripts = lib.genAttrs outputs.escripts (
    escript:
    artifact "escript-${escript}" {
      escriptBinName = escript;
    }
  );

  docs = artifact "docs" {
    mixEnv = docsMixEnv;
    installPhase = ''
      runHook preInstall
      mix docs --formats html --output "$out"
      runHook postInstall
    '';
  };

  prefixed = prefix: lib.mapAttrs' (key: value: lib.nameValuePair "${prefix}-${key}" value);
in
{
  packages =
    prefixed "release" releases
    // prefixed "escript" escripts
    // prefixed "app" (lib.mapAttrs (app: _: "${compiled}/${app}") outputs.apps)
    // {
      inherit docs;
    };

  tests = artifact "tests" {
    mixEnv = "test";
    installPhase = ''
      runHook preInstall
      mix test --no-deps-check
      touch "$out"
      runHook postInstall
    '';
  };

  release =
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

  fetches = checked.entries;

  inherit deps outputs lock;
}
