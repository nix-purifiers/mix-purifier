# SPDX-License-Identifier: MIT
#
# The `mix-purifier` library namespace, with `readLock`
# (nix/lib/read-lock.nix), which reads a project's locks into the lock in
# memory of the purifier contract. The builder, `buildMixProject`
# (nix/lib/build-mix-project.nix), is a package, which the default package
# overlay adds to the package set.
{ ... }:
{

  overlay = final: prev: {
    mix-purifier = (prev.mix-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
