{
  pkgs,
  src1 ? ./fixtures/umbrella,
  src2 ? ./fixtures/umbrella-hola,
}:
let
  build =
    src:
    pkgs.mix-purifier.buildMixProject {
      inherit src;
      otpApplications.umbrella = [ "shouter" ];
    };
  first = build src1;
  second = build src2;
  erlang = first.projections.umbrella.otp.runtime;
  elixir = first.projections.umbrella.otp.elixir;
  version = built: marker: {
    inherit marker;
    catalog = built.projections.umbrella.otp.catalog;
    library = built.projections.umbrella.otp.applicationRoot;
    web = built.projections.umbrella.web.documentRoot;
    jar = built.projections.umbrella.java-resources.classPath;
  };
  spec = pkgs.writeText "mix-otp-consumer-spec.json" (
    builtins.toJSON {
      erlang = toString erlang;
      elixir = toString elixir;
      versions = [
        (version first "HELLO")
        (version second "HOLA")
      ];
    }
  );
in
assert import ./otp-eval.nix { inherit pkgs; };
pkgs.runCommand "mix-compiled-otp-cross-language-consumers"
  {
    nativeBuildInputs = [
      pkgs.python3
      erlang
      elixir
      pkgs.jdk25
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    cp ${./otp/consumer.erl} otp_consumer.erl
    cp ${./otp/Resources.java} Resources.java
    python3 ${./otp/consumers.py} ${spec} "$out"
  ''
