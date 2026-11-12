# SPDX-License-Identifier: MIT
#
# The `mix-purifier` library namespace, with `readLock`
# (lib-overlays/default/read-lock.nix), which reads a project's locks into the lock in
# memory of the purifier contract. The builder, `buildMixProject`
# (pkgs/build-mix-project/default.nix), is a package, which the default package
# overlay adds to the package set.
{ ... }:
{

  overlay = final: prev: {
    mix-purifier = (prev.mix-purifier or { }) // {
      readLock = import ./read-lock.nix { lib = final; };
    };
  };

}
