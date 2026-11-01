# SPDX-License-Identifier: MIT
#
# The `mix-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildMixProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    mix-purifier = prev.mix-purifier or { };
  };

}
