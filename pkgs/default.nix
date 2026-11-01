# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../version.txt);
in
{
  # The `mix-purifier` command, with `mix` and `lock`.
  cli = callPackage ./cli { inherit version; };
}
