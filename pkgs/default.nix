# SPDX-License-Identifier: MIT
{ callPackage, lib, ... }:
let
  version = import ./version.nix;
  toolchain = callPackage ./toolchain { };
in
{
  # The builder of the purifier contract (nix/lib/build-mix-project.nix).
  buildMixProject = callPackage ../nix/lib/build-mix-project.nix {
    inherit (lib) purifier;
  };
  # The toolchain that `mix-purifier prefetch` keeps alive in a project.
  inherit toolchain;
  # The `mix-purifier` command, with `lock`, `prefetch` and `publish`.
  cli = callPackage ./cli { inherit version toolchain; };
}
