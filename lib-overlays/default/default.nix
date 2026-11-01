# SPDX-License-Identifier: MIT
#
# The `mix-purifier` library namespace, with the two functions of the
# purifier contract: `buildMixProject` (nix/lib/build-mix-project.nix), the
# builder, and `readLock` (nix/lib/read-lock.nix), which reads a project's
# locks into the lock in memory. Both use the purifier library, which this
# flake lists in its `projects`, so `lib.purifier` is beside them.
{ ... }:
{

  overlay = final: prev: {
    mix-purifier = (prev.mix-purifier or { }) // {
      buildMixProject = import ../../nix/lib/build-mix-project.nix { lib = final; };
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
