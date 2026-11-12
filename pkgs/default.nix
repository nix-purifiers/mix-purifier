# SPDX-License-Identifier: MIT
{ callPackage, lib, ... }:
let
  version = import ./version.nix;
  toolchain = callPackage ./toolchain { };
in
{
  # The builder of the purifier contract (pkgs/build-mix-project/default.nix).
  buildMixProject = callPackage ./build-mix-project {
    inherit (lib) purifier;
  };
  # The toolchain that `mix-purifier prefetch` keeps alive in a project.
  inherit toolchain;
  # The `mix-purifier` command, with `lock`, `prefetch` and `publish`.
  cli = callPackage ./cli { inherit version toolchain; };
}
