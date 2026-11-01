# mix-purifier

A Nix library and command that build a Mix project in the Nix sandbox from
its `mix.lock`, with no generated Nix files in the project.

- **Builds from mix.lock.** `mix.lock` records the SHA-256 of every Hex
  tarball, so Nix fetches each package straight from the lock.
- **A lockfile for what mix.lock leaves out.** `mix-purifier lock` writes
  `mix-purifier.lock.json`. It records every output the project produces,
  as Mix reports it: the releases, the project's own applications, the
  escript and the Hex package. It also records the hash of each git
  dependency's checkout, and the URL of each Hex repository other than
  hexpm. `mix.exs` is Elixir code, and Nix reads only JSON and TOML, so
  this file is how Nix knows each output by name.
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

In the directory of `mix.exs`, run the lock run. It runs `mix deps.get`,
which brings `mix.lock` up to date with `mix.exs`, and writes
`mix-purifier.lock.json`. Commit both files:

```zsh
nix run github:nix-purifiers/mix-purifier -- lock
```

Run Mix through the same command. It builds `deps/` from the locks with
Nix, copies each changed dependency into the project, and runs Mix with
Hex offline:

```zsh
nix run github:nix-purifiers/mix-purifier -- mix compile
nix run github:nix-purifiers/mix-purifier -- mix test
```

To add or upgrade a dependency, edit `mix.exs`, or run a Mix task that
changes `mix.lock` such as `deps.update`, then run the lock run again.
`deps.get`, `deps.update` and `deps.unlock` run online:

```zsh
nix run github:nix-purifiers/mix-purifier -- mix deps.update jason
nix run github:nix-purifiers/mix-purifier -- lock
```

`mix-purifier lock --offline` rewrites the lockfile without the network,
after an edit to `mix.exs` that does not change `mix.lock`. It reuses the
recorded git hashes and repository URLs, and fails with a message to run
the online lock run when `mix.lock` has an entry it has not recorded.

Once `mix-purifier mix` has copied the dependencies into `deps/`, plain
`mix compile` and `mix test` work offline too, because Mix only asks Hex
for anything in `mix deps.get`. An editor's language server compiles the
project through Mix the same way. The language server needs its own files
at its first start, though: nixpkgs' ElixirLS 0.31.1 fetches its
dependency elixir_sense from GitHub when it starts, whatever the project.

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

`nix build` builds the project's first release, or its compiled
applications if it has no release. A release reads its cookie from
`RELEASE_COOKIE`, because nixpkgs' `mixRelease` keeps the cookie out of
the store.

### Outputs

Every output the lock records is an attribute of the result, which Nix
knows without building anything:

- `releases.<name>` is the release that `mix release` builds.
- `apps.<name>` is the compiled application, with its `ebin` and `priv`
  directories, for each of the project's own applications. An umbrella
  project has one per child application.
- `escripts.<name>` is the escript that `mix escript.build` builds, in
  `bin/`.
- `hexPackage` is the package tarball that `mix hex.build` builds, as
  `package.tar`. It is null for a project without package metadata.
- `docs` is the HTML documentation that `mix docs` builds.
- `deps` is the dependency directory, and `outputs` is the record of the
  outputs as the lock holds it.

### Arguments

`buildMixProject` passes every argument that `mixRelease` takes, such as
`mixEnv`, `mixReleaseName` and `escriptBinName`. Beyond those:

- `root` is the directory of `mix.exs` inside `src`. A project with a path
  dependency outside its own directory gives a `src` that holds both, and
  names its own directory as `root`.
- `pname` and `version` replace the name and version that the lock
  records. An umbrella root without a version gives `version`.
- `lockFile` is `mix.lock`, and `purifierLockFile` is
  `mix-purifier.lock.json`.
- `hexMirror` is the URL that serves hexpm's tarballs.
- `docsMixEnv` is the Mix environment that has ex_doc. It defaults to
  `dev`.

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

## Common mistakes

Each of these stops a build or the lock run with a message that names the
command to run:

- **A `mix.exs` changed since the lock.** A Nix build fails with
  "mix.exs changed since mix-purifier.lock.json was written. Run
  `mix-purifier lock`.", and `mix-purifier mix` warns the same way.
- **No `mix-purifier.lock.json`, or one without outputs.** A Nix build
  fails with "… has no mix-purifier.lock.json with the project's outputs.
  Run `mix-purifier lock`."
- **A git dependency or Hex repository missing from the lock**, or locked
  at another commit than `mix.lock` has. A Nix build fails, naming the
  dependency, with "Run `mix-purifier lock`".
- **An edited inner checksum in `mix.lock`.** The build fails with "jason
  1.4.5: the inner checksum is …, but mix.lock locks …".
- **An edited outer checksum in `mix.lock`, or an edited hash in
  `mix-purifier.lock.json`.** Nix fails the fetch with a hash mismatch that
  names the tarball or the checkout. Restore the file from version control,
  or run `mix-purifier mix deps.get` and `mix-purifier lock`.
- **A `mix.lock` entry mix-purifier cannot read.** The build fails with
  the line it cannot read.
- **A lockfile from another version of mix-purifier.** The build fails
  with the version it found and "Run `mix-purifier lock` with this
  mix-purifier."

## Tested on

The checks build these real projects, pinned to a commit, beside the
fixtures:

- **[credo](https://github.com/rrrene/credo) v1.7.19** (commit
  `d4a88d49`), the Elixir static analysis tool: 257 source files, an
  escript, a Hex package, and dependencies for prod, dev and test. The
  checks rerun its lock run, build its release, escript, application and
  Hex package, run the escript on credo's own source, and run its test
  suite (1740 tests and 21 doctests) offline through `mix-purifier mix
  test`. credo's own `mix docs` fails at this commit, with or without
  mix-purifier, because its `mix.exs` gives ex_doc an `assets` string that
  the ex_doc in its `mix.lock` rejects.

Working through credo changed mix-purifier in these ways:

- The lock run now runs `mix deps.get` first, so adding or upgrading a
  dependency takes one command after the edit.
- `mix-purifier lock --offline` relocks without the network.
- The lock run reads `mix.lock` through Mix itself.
- `mix-purifier mix` warns when `mix.exs` changed since the lock.

On credo, the quickstart above works as written, with the published
flake:

- The first lock run, with an empty Hex home, took 3.8 seconds and wrote
  the same lockfile the checks hold for credo.
- `mix-purifier mix compile` built credo and its dependencies offline in
  17 seconds, and `mix-purifier mix test` passed every test.
- `mix-purifier mix deps.update jason` moved jason from 1.4.4 to 1.4.5, and
  the relock after it took 1.4 seconds. The test suite then passed on the
  new jason.
- An edit to `mix.exs` without a relock made `mix-purifier mix` warn,
  naming the file and `mix-purifier lock`.

## Tests

`nix flake check` builds the test suite. Unit tests in `tests/unit.nix`
check how the lock is read, and the path and URL of each download. Each
dependency source has a fixture that the checks build and run. The
offline lock run reruns on every fixture and on credo, and must write the
committed lockfile byte for byte (`tests/relock.nix`). Negative tests
check that each mistake above fails as described: a stale lock, a missing
entry, a tampered checksum, an unreadable entry and a lockfile of another
version. Further checks run the interactive mode, plain Mix after it, and
publishing to a stand-in Hex API, and build credo as an integration test.

CI runs the suite on x86_64-linux and on aarch64-linux. A second CI job
runs the online lock run on every fixture (`tests/relock-online.sh`) and
fails if a lockfile changes.

## How it works

`mix deps.get` resolves dependencies through Hex's registry even when
`mix.lock` is complete, and the registry changes with every new release of
a package, so it cannot be locked. mix-purifier never runs `mix deps.get`
offline. It builds the `deps/` directory that `mix deps.get` would leave
behind:

- Each download is an entry of the shared
  [purifier](https://github.com/nix-purifiers/purifier) library, which
  fetches it: a file entry for a Hex tarball, and a git entry for a git
  dependency.
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
