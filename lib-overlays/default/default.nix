# SPDX-License-Identifier: MIT
#
# The `mix-purifier` library namespace: `buildMixProject`
# (nix/lib/build-mix-project.nix), the builder of the purifier contract. It
# takes the package set as `pkgs` and fetches through the purifier library,
# which this flake lists in its `projects`, so `lib.purifier` is beside it.
{ ... }:
{

  overlay = final: prev: {
    mix-purifier = (prev.mix-purifier or { }) // {
      buildMixProject = import ../../nix/lib/build-mix-project.nix { lib = final; };
    };
  };

}
