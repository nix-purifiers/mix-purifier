# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../version.txt);
  toolchain = callPackage ./toolchain { };
in
{
  # The toolchain that `mix-purifier prefetch` keeps alive in a project.
  inherit toolchain;
  # The `mix-purifier` command, with `lock`, `prefetch` and `publish`.
  cli = callPackage ./cli { inherit version toolchain; };
}
