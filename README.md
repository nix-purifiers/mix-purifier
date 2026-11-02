# mix-purifier

mix-purifier keeps Mix's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

`mix.lock` records the SHA-256 of every Hex tarball, so Nix fetches each
package straight from it. `mix-purifier lock` writes
`mix-purifier.lock.json` beside it for what `mix.lock` cannot record:

- every output the project produces, as Mix reports it: the releases, the
  project's own applications, the escript and the Hex package. `mix.exs`
  is Elixir code, and Nix reads only JSON and TOML, so this file is how
  Nix knows each output by name;
- the hash of each git dependency's checkout, because `mix.lock` pins only
  the commit;
- the URL of each Hex repository other than hexpm, which lives in the
  user's Hex configuration rather than in the project.

## Quickstart

From the project root:

```zsh
nix shell \
  'github:nix-purifiers/mix-purifier' \
  'github:nix-purifiers/mix-purifier#toolchain'
mix-purifier lock
mix-purifier prefetch
export PATH="$PWD/_build/mix-purifier/toolchain/bin:$PATH"
mix compile
mix test
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

For persistent use, add these packages through your usual Nix configuration.


## Development loop

`mix-purifier prefetch` builds the dependency directory from the locks
with Nix, copies each changed dependency into `deps/`, and keeps it and a
toolchain alive under `_build/mix-purifier`. The toolchain's `mix` runs
with Hex offline, so the everyday loop goes through Mix itself:

```zsh
nix shell \
  'github:nix-purifiers/mix-purifier' \
  'github:nix-purifiers/mix-purifier#toolchain'
mix-purifier prefetch
_build/mix-purifier/toolchain/bin/mix compile
_build/mix-purifier/toolchain/bin/mix test
```

With `_build/mix-purifier/toolchain/bin` first on `PATH`, such as with
direnv's `PATH_add`, plain `mix` is that toolchain.

To upgrade dependencies, run `mix-purifier update`, which updates them
through Mix's own `mix deps.update` (every one, or the ones named) and
then runs the lock run on the result. `mix-purifier lock` keeps `mix.lock`
as Mix resolved it, adding only what `mix.exs` asks for and `mix.lock`
lacks, so after an edit to `mix.exs` the lock run is enough. Run the
prefetch again after either:

```zsh
nix shell \
  'github:nix-purifiers/mix-purifier' \
  'github:nix-purifiers/mix-purifier#toolchain'
mix-purifier update jason
mix-purifier prefetch
```

When the toolchain's `mix` fails because it needs a dependency the locks
do not have, it says to run `mix-purifier lock`.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

A project whose authors want a flake that packages it can add one, which
calls the builder directly. The flake can live in the project's repository
or in another one:

```nix
{
  inputs.mix-purifier.url =
    "github:nix-purifiers/mix-purifier";
  inputs.nixpkgs.follows = "mix-purifier/nixpkgs";

  outputs =
    { nixpkgs, mix-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ mix-purifier.overlays.default ];
      };
    in
    {
      packages.${system}.default =
        (pkgs.mix-purifier.buildMixProject { src =
          ./.; })
        .packages.release-my_app;
    };
}
```

`buildMixProject` takes the packages it needs by name, so
`mix-purifier.buildMixProject.override { beamPackages = pkgs.beam27Packages; }`
builds one project with another Erlang and Elixir package set, and
`mix-purifier.overrideScope (_: _: { beamPackages = pkgs.beam27Packages; })`
replaces it for everything in the scope. It takes `{ src, lockFile ?
src + "/mix-purifier.lock.json", fetchers ? { }, ... }` and returns, with
every name known at evaluation time:

- `packages.release-<name>`: the release that `mix release` builds. A
  release reads its cookie from `RELEASE_COOKIE`, because nixpkgs'
  `mixRelease` keeps the cookie out of the store.
- `packages.escript-<name>`: the escript that `mix escript.build` builds,
  in `bin/`.
- `packages.app-<name>`: the compiled application, with its `ebin` and
  `priv` directories, for each of the project's own applications. An
  umbrella project has one per child application.
- `packages.docs`: the HTML documentation that `mix docs` builds.
- `tests`: the project's `mix test` run, in the sandbox.
- `release`: the package tarball that `mix hex.build` builds, as
  `package.tar`, which `mix-purifier publish` uploads. It is null for a
  project without package metadata.
- `fetches`: the [purifier](https://github.com/nix-purifiers/purifier)
  library entries that the build fetches.

`fetchers` goes to the purifier library's `fetchEntry`, so a
`fetchers.fetchurl` that sends credentials or uses a company mirror reaches
every download. The other arguments are these:

- `lockFile` and `mixLock` name `mix-purifier.lock.json` and `mix.lock`.
  Each defaults to the file in the project's directory. A file given
  outside `src` replaces any copy in it, so a packaging flake can build a
  project whose author keeps no `mix-purifier.lock.json`.
- `root` is the directory of `mix.exs` inside `src`, for a project with a
  path dependency outside its own directory.
- `hexMirror` is the URL that serves hexpm's tarballs.
- `docsMixEnv` is the Mix environment that has ex_doc, `dev` by default.
- Every argument of nixpkgs' `mixRelease`, such as `mixEnv`, passes
  through.

`mix-purifier publish` builds `release` and `packages.docs` with Nix and
publishes them to hexpm, or to an organization with `--organization`. It
asks before publishing unless `--yes` is given, `--replace` replaces an
existing release, and `--no-docs` publishes the package alone. Hex builds
package tarballs reproducibly, so the tarball Nix builds is the one
`mix hex.publish` would send. The command sends it with the credentials
Hex uses for `mix hex.publish`.

`mix-purifier.lib.mix-purifier.readLock { src, lockFile ?, mixLock ?, ...
}` reads the two locks into the shape every purifier shares:
`{ purifier, entries, outputs, problems }`. `entries` are the purifier
library's download entries, `outputs` names each output as `packages`
does, and `problems` holds a message, naming the fix, for each lockfile
that is stale, tampered, malformed or incomplete. The builder passes it
to the library's `checkLock`, and `fetches` is its `entries`.

Committing both lockfiles to the project's repository is the recommended
setup, and the commands and the builder look for them there. A project can
instead keep its build external, with the lockfiles in the flake that calls
the builder. Every command then takes `--lockfile <path>` (or the
environment variable `MIX_PURIFIER_LOCKFILE`) for a `mix-purifier.lock.json`
kept outside the project, and `--tool-lockfile <path>` (or
`MIX_PURIFIER_TOOL_LOCKFILE`) for a `mix.lock` kept outside it. With
`--tool-lockfile`, `lock` and `update` write `mix.lock` there and leave the
project's copy as it is, and `lock` starts from the project's copy when the
outside file does not exist yet. The builder takes the same two files as
`lockFile` and `mixLock`.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/mix-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.mix-purifier.buildMixProject { src = ./.; })
.packages.release-my_app'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

After `mix-purifier prefetch`, the toolchain's `mix` compiles and tests the
project with no network: the dependencies are in `deps/`, the toolchain is
in the Nix store under a garbage-collector root, and Mix asks Hex only
during `mix deps.get`.

`mix-purifier lock --offline` rewrites the lockfile without the network,
after an edit to `mix.exs` that does not change `mix.lock`. It reuses the
recorded git hashes and repository URLs, and stops with a message naming
the online lock run when `mix.lock` has an entry it has not recorded.

## Editor

Point the editor's Elixir language server at
`_build/mix-purifier/toolchain/bin/elixir-ls`, which is nixpkgs' ElixirLS
with Hex on its code path. ElixirLS fetches its own files when it first
starts, so `mix-purifier prefetch` starts it once, with the network, to
fetch them. Afterwards it starts with no network.
`mix-purifier prefetch --no-editor` skips that step.

## Troubleshooting

Each of these stops a build, a command or the lock run with a message that
names the command to run:

- **A `mix.exs` changed since the lock.** "mix.exs changed since
  mix-purifier.lock.json was written. Run `mix-purifier lock`."
- **No `mix-purifier.lock.json`, or one without outputs.** "… has no
  mix-purifier.lock.json with the project's outputs. Run `mix-purifier
  lock`."
- **A lockfile edited by hand.** "… does not match the hash of its content,
  so it was edited after `mix-purifier lock` wrote it. Run `mix-purifier
  lock` to rewrite it."
- **A lockfile that is not valid JSON, or not of this format.** "… which
  is not valid JSON. Run `mix-purifier lock` to rewrite it."
- **A git dependency or Hex repository missing from the lock**, or locked
  at another commit than `mix.lock` has. The message names the dependency
  and says "Run `mix-purifier lock`".
- **A dependency the toolchain's `mix` cannot find.** Mix's own error,
  followed by "if Mix needs a dependency that mix.lock or
  mix-purifier.lock.json does not have, run `mix-purifier lock`".
- **An edited inner checksum in `mix.lock`.** "jason 1.4.5: the inner
  checksum is …, but mix.lock locks …".
- **An edited outer checksum in `mix.lock`.** Nix fails the fetch with a
  hash mismatch that names the tarball, because a fixed-output fetch
  reports only that. Restore the file from version control, or run
  `mix-purifier lock`.
- **A `mix.lock` entry mix-purifier cannot read.** The build fails with the
  line it cannot read. Mix writes `mix.lock` one entry per line, and
  mix-purifier reads it that way.

## Supported language repositories

Every kind of dependency that `mix.lock` can hold builds:

- **hexpm packages**, including Erlang packages that rebar3 builds. Each is
  fetched by the URL and SHA-256 in `mix.lock`, then unpacked by Hex's own
  tarball code (`nix/hex-unpack.exs`), which checks both of its checksums
  against `mix.lock` and writes the `.hex` file that Mix checks.
- **Packages from self-hosted Hex repositories** that `mix hex.repo add`
  configures. The lock run asks Hex for each repository's URL and records
  it. It also downloads each tarball with Hex, using your Hex credentials,
  checks it against `mix.lock`, and adds it to the Nix store under the
  same path a build's fetch produces, so the build needs no credentials.
  Another machine, such as CI, needs the tarball too: from a binary cache,
  or from its own lock run.
- **Private Hex organizations** take the same path, with the URL and the
  credentials that Hex has for the organization.
- **Git dependencies**, with `submodules: true`, `sparse:` and `subdir:`.
  Each is fetched with nixpkgs' `fetchgit` at the locked commit, and gets a
  minimal `.git` whose `HEAD` names the commit and whose config names the
  origin, which is what Mix asks git.
- **Path dependencies and umbrella projects.** `mix.lock` holds their own
  dependencies, and their sources are part of `src`.

The sandbox has no network, so a package that downloads files while it
compiles needs those files in the lock. Packages that fetch precompiled
NIFs are the common case, such as those built on rustler_precompiled. Such
a package usually builds its NIF from source when told to, which the
sandbox allows.

`mix deps.get` always resolves through Hex's registry, which changes with
every release and cannot be locked. mix-purifier builds `deps/` itself from
the locks, and Mix accepts it as fetched and locked.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### credo

[credo](https://github.com/rrrene/credo) is the static analysis tool for
Elixir. Clone the release you want, run the lock run in the checkout, and
build the escript from the same directory:

```zsh
nix shell \
  'github:nix-purifiers/mix-purifier' \
  'github:nix-purifiers/mix-purifier#toolchain'
git clone --branch v1.7.19 https://github.com/rrrene/credo
cd credo
mix-purifier lock
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/mix-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.mix-purifier.buildMixProject { src = ./.; })
.packages.escript-credo'
```

`nix build` puts credo at `result/bin/credo`. To package credo without
touching its source, run the lock run with the lockfile written outside the
checkout, with `--lockfile ../credo.mix-purifier.lock.json`, and pass that
file to the builder as `lockFile` in a flake of your own that takes credo
as a non-flake input.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).
