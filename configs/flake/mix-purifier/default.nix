# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  # The flake's `packages` output is the derivations of this scope.
  purifier.scope = "mix-purifier";

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The `mix-purifier` scope is the `default` entry of the package overlay
    # registry (pkg-overlays/): the package set applies it by default, and
    # the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`.
  };

  # `nix run github:nix-purifiers/mix-purifier -- lock` locks the project in
  # the current directory, `… -- prefetch` readies it for work with no
  # network, and `… -- publish` publishes what Nix built.
  perSystem =
    { pkgs, ... }:
    {
      packages.default = pkgs.mix-purifier.cli;
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              inherit (self.packages.${system}) cli toolchain;
              overlay = self.overlays.default;
              mixPurifier = self.lib.mix-purifier;
              inherit (self.lib) purifier;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
