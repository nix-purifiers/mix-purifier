# mix-purifier

A Nix library and command that build a Mix project in the Nix sandbox from
its `mix.lock`, with no generated Nix files in the project.

- **Builds from mix.lock.** `mix.lock` records the SHA-256 of every Hex
  tarball, so Nix fetches each package straight from the lock. A project
  that uses only Hex packages needs nothing beyond its `mix.lock`.
- **Sandboxed builds.** `buildMixProject`, which the flake's overlay adds to
  a package set, builds the project's `deps/` directory from the lock and
  hands it to nixpkgs' `mixRelease`, which compiles the project and builds
  its release offline.
- **Interactive Mix on the locked downloads.** `mix-purifier mix <args>`
  builds the same `deps/` directory with Nix, copies it into the project,
  and runs Mix with Hex offline.
- **Git dependencies.** `mix.lock` pins a git dependency to a commit but
  records no hash of its checkout. `mix-purifier lock` writes
  `mix-purifier.lock.json` with that hash.

## Use

Run Mix through the flake's command in the directory of `mix.exs`:

```zsh
nix run github:nix-purifiers/mix-purifier -- mix compile
```

The command builds `deps/` from `mix.lock` and runs `mix compile` with
Hex offline. The Mix tasks that change `mix.lock` (`deps.get`,
`deps.update` and `deps.unlock`) run online, as usual:

```zsh
nix run github:nix-purifiers/mix-purifier -- mix deps.get
```

If `mix.lock` has git dependencies, lock them as well, and commit
`mix-purifier.lock.json` beside `mix.lock`:

```zsh
nix run github:nix-purifiers/mix-purifier -- lock
```

The flake's `overlays.default` adds `buildMixProject` to a package set. A
package written for `callPackage` takes it by name, like any other
builder:

```nix
# package.nix
{ buildMixProject }:
buildMixProject { src = ./.; }
```

```nix
{
  inputs.mix-purifier.url = "github:nix-purifiers/mix-purifier";
  inputs.nixpkgs.follows = "mix-purifier/nixpkgs";

  outputs = { nixpkgs, mix-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          mix-purifier.overlays.default
          (final: prev: { my-app = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.default = pkgs.my-app;
    };
}
```

`nix build` builds the project's release. The release reads its cookie
from `RELEASE_COOKIE`, because nixpkgs' `mixRelease` keeps the cookie out
of the store.

`buildMixProject` passes every argument that `mixRelease` takes, such as
`mixEnv`, `mixReleaseName` and `escriptBinName`. Beyond those:

- `pname` and `version` default to the application name and version in
  `mix.exs`. A `mix.exs` that sets them some other way, such as an umbrella
  root, gives them to `buildMixProject`.
- `lockFile` is `mix.lock`. `purifierLockFile` is `mix-purifier.lock.json`
  when the project has one.
- `hexMirror` is the Hex repository the tarballs come from.

The Erlang and Elixir versions are those of the package set's
`beamPackages`, so `buildMixProject.override { beamPackages =
pkgs.beam27Packages; }` builds with another set. The same override on
`pkgs.mix-purifier.cli` runs the command with it.

## How it works

`mix deps.get` resolves dependencies through Hex's registry even when
`mix.lock` is complete, and the registry changes with every new release of
a package, so it cannot be locked. mix-purifier never runs `mix deps.get`
offline. It builds the `deps/` directory that `mix deps.get` would leave
behind:

- Each Hex package is fetched by the URL and SHA-256 in `mix.lock`, then
  unpacked by Hex's own tarball code (`nix/hex-unpack.exs`). The script
  checks both of the package's checksums against `mix.lock` and writes the
  `.hex` file that Hex writes, so Mix sees a package that `mix deps.get`
  fetched.
- Each git dependency is fetched with nixpkgs' `fetchgit` at the locked
  commit, with the hash from `mix-purifier.lock.json`. It gets a minimal
  `.git` directory whose `HEAD` names the locked commit and whose config
  names the origin, which is what Mix asks git when it checks the
  dependency against `mix.lock`.

`mix deps` then reports every dependency as locked and fetched, and
`mix compile` builds offline.

## Limits

- Packages come only from the public Hex repository, hexpm. A dependency
  from a private Hex organization fails with a message that names it.
- A package that downloads files while it compiles fails in the sandbox.
  Examples are packages that fetch precompiled NIFs, such as those built on
  rustler_precompiled.
- Mix writes `mix.lock` one entry per line, and mix-purifier reads it that
  way. A lock entry it cannot read is an error, so a dependency is never
  left out of a build.

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).
