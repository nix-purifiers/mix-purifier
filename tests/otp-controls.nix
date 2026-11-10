{ pkgs, purifier }:
let
  built = pkgs.mix-purifier.buildMixProject { src = ./fixtures/umbrella; };
  erlang = built.packages.release-umbrella.erlang;
  elixir = builtins.head (
    builtins.filter (
      p: pkgs.lib.hasPrefix "elixir-" (p.name or "")
    ) built.packages.release-umbrella.nativeBuildInputs
  );
  roots = [ "shouter" ];
  selection =
    producer: runtime:
    pkgs.mix-purifier.callPackage ../nix/lib/otp-projections.nix { inherit purifier; } {
      inherit producer roots elixir;
      release = "umbrella";
      ownApplications = [
        "greeter"
        "shouter"
      ];
      erlang = runtime;
    };
  # These are explicit adversarial copies of a real relx producer, using real
  # compiled SDK/project bytes. They are not claimed as fresh native captures.
  mutated =
    name: command:
    pkgs.runCommand "otp-controlled-${name}" { } ''
      mkdir -p "$out"
      cp -rL ${built.packages.release-umbrella}/lib "$out/"
      cp -rL ${built.packages.release-umbrella}/releases "$out/"
      chmod -R u+w "$out"
      ${command}
    '';
in
{
  wrongSdk = (selection built.packages.release-umbrella pkgs.beam.packages.erlang_27.erlang).producer;
  sdkCollision =
    (selection (mutated "sdk-module" ''
      cp ${erlang}/lib/erlang/lib/stdlib-*/ebin/sets.beam "$out/lib/greeter-0.3.0/ebin/"
    '') erlang).producer;
  elixirCollision =
    (selection (mutated "sdk-elixir-module" ''
      cp ${elixir}/lib/elixir/lib/elixir/ebin/Elixir.Enum.beam "$out/lib/greeter-0.3.0/ebin/"
    '') erlang).producer;
  duplicateModule =
    (selection (mutated "duplicate-module" ''
      cp "$out/lib/greeter-0.3.0/ebin/Elixir.Greeter.beam" "$out/lib/shouter-0.3.0/ebin/"
    '') erlang).producer;
  nativePayload =
    (selection (mutated "actual-native-payload" ''
      mkdir -p "$out/lib/greeter-0.3.0/priv"
      cp ${erlang}/lib/erlang/erts-*/bin/erl_child_setup "$out/lib/greeter-0.3.0/priv/helper"
    '') erlang).producer;
}
