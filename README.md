# mix-purifier

A Nix library and command that build a Mix project in the Nix sandbox from
its `mix.lock`, with no generated Nix files in the project.

- **Builds from mix.lock.** `mix.lock` records the SHA-256 of every Hex
  tarball, so Nix fetches each package straight from the lock. A project
  that uses only hexpm packages needs nothing beyond its `mix.lock`.
- **A lockfile for what mix.lock leaves out.** `mix-purifier lock` writes
  `mix-purifier.lock.json` when a project needs it: the hash of each git
  dependency's checkout, and the URL of each Hex repository other than
  hexpm.
- **Sandboxed builds.** `buildMixProject`, which the flake's overlay adds to
  a package set, builds the project's `deps/` directory from the locks and
  hands it to nixpkgs' `mixRelease`, which compiles the project and builds
  its release offline.
- **Interactive Mix on the locked downloads.** `mix-purifier mix <args>`
  builds the same `deps/` directory with Nix, copies it into the project,
  and runs Mix with Hex offline.
- **Publishing what Nix built.** `mix-purifier publish` publishes the
  package tarball and documentation that Nix builds, with your usual Hex
  credentials.

## Use

Run Mix through the flake's command in the directory of `mix.exs`:

```zsh
nix run github:nix-purifiers/mix-purifier -- mix compile
```

The command builds `deps/` from the locks and runs `mix compile` with Hex
offline. The Mix tasks that change `mix.lock` (`deps.get`, `deps.update`
and `deps.unlock`) run online, as usual:

```zsh
nix run github:nix-purifiers/mix-purifier -- mix deps.get
```

After `mix.lock` changes, run the lock run, and commit
`mix-purifier.lock.json` beside `mix.lock` if it writes one:

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

### Arguments

`buildMixProject` passes every argument that `mixRelease` takes, such as
`mixEnv`, `mixReleaseName` and `escriptBinName`. Beyond those:

- `root` is the directory of `mix.exs` inside `src`. A project with a path
  dependency outside its own directory gives a `src` that holds both, and
  names its own directory as `root`.
- `pname` and `version` default to the application name and version in
  `mix.exs`. An umbrella root has no application, so an umbrella project
  gives `pname`, and gives `version` unless its root `mix.exs` sets one.
- `lockFile` is `mix.lock`. `purifierLockFile` is `mix-purifier.lock.json`
  when the project has one.
- `hexMirror` is the URL that serves hexpm's tarballs.
- `docsMixEnv` is the Mix environment that has ex_doc. It defaults to
  `dev`.

The result is the release. Beside it, `hexPackage` holds the package
tarball that `mix hex.build` makes, as `package.tar`. `docs` holds the HTML
documentation that `mix docs` makes, and `deps` is the dependency
directory.

The Erlang and Elixir versions are those of the package set's
`beamPackages`, so `buildMixProject.override { beamPackages =
pkgs.beam27Packages; }` builds with another set. The same override on
`pkgs.mix-purifier.cli` runs the command with it.

### Dependency sources

Every kind of dependency that `mix.lock` can hold builds:

- **hexpm packages**, including Erlang packages that rebar3 builds.
- **Packages from self-hosted Hex repositories** that `mix hex.repo add`
  configures. Private Hex organizations (`organization: "acme"`) take the
  same path, but they are untested (see Limits). The lock run asks Hex for
  each repository's URL
  and records it. It also downloads each tarball with Hex, using your Hex
  credentials, checks it against `mix.lock`, and adds it to the Nix store
  under the same path a build's fetch produces. The build then finds the
  tarball in the store and needs no credentials. Another machine, such as
  CI, needs the tarball too: from a binary cache, or from its own lock run
  with Hex credentials. A repository that needs no credentials downloads
  in the build as usual.
- **Git dependencies**, with `submodules: true`, `sparse:` and `subdir:`.
  Mix checks out the whole repository either way, so the build does too.
- **Path dependencies and umbrella projects.** `mix.lock` holds their own
  dependencies, and their sources are part of `src`. See `root` above.

### Interactive Mix

`mix-purifier mix <args>` builds `deps/` and copies into `./deps` each
dependency whose marker changed: the `.hex` file of a Hex package, or
`.git/HEAD` of a git dependency. It keeps the result as a garbage-collector
root under `_build/mix-purifier`. With `MIX_PURIFIER_DEPS` naming a
dependency directory that Nix already built, such as a package's `deps`, it
copies that one instead of building.

### Publishing

`mix-purifier publish` builds the package tarball and the documentation
with Nix, then publishes them to hexpm, or to an organization with
`--organization`. It asks before publishing unless `--yes` is given.
`--replace` replaces an existing release, and `--no-docs` publishes the
package alone.

`mix hex.publish` builds the package tarball from the project's source with
the same code `mix hex.build` uses, and Hex builds tarballs reproducibly,
so the tarball Nix builds is the one `mix hex.publish` would send. The
command sends it through Hex's own API calls, with the credentials Hex
uses for `mix hex.publish`. `MIX_PURIFIER_HEX_PACKAGE` and
`MIX_PURIFIER_DOCS` name a package and docs that Nix already built, such as
a package's `hexPackage` and `docs`.

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

- A package that downloads files while it compiles fails in the sandbox,
  because the sandbox has no network and the download is in no lock.
  Packages that fetch precompiled NIFs are the common case, such as those
  built on rustler_precompiled. Such a package usually also builds its NIF
  from source when told to, which the sandbox allows.
- Private Hex organizations are untested. They go through the same code as
  self-hosted repositories, with the repository URL that Hex resolves for
  the organization, and the checks test that code with a self-hosted
  repository. No test has run against a real organization, because that
  needs organization credentials.
- Mix writes `mix.lock` one entry per line, and mix-purifier reads it that
  way. A lock entry it cannot read is an error, so a dependency is never
  left out of a build.

## Credits

mix-purifier follows the design of
[sbt-nix-backend](https://github.com/clhodapp/sbt-nix-backend): the tool
keeps planning the build, a lockfile pins what it downloads, and Nix builds
from the lockfile in its sandbox. Purifiers were inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).
