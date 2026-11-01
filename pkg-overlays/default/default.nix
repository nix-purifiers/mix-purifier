# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.mix-purifier` (`.cli`, the `mix-purifier` command). A consumer that
# lists this flake in `projects` holds it as `mix-purifier/default`, which
# its package sets apply by default. The builder is in the library, as
# `lib.mix-purifier.buildMixProject`.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "mix-purifier";
}
