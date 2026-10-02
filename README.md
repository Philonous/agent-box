# claude-box

Run Claude Code — or any other command — confined to a single project
directory, using
[bubblewrap](https://github.com/containers/bubblewrap) instead of Docker.

Claude Code normally runs with your full ambient authority: it can read every
file under `$HOME` (other projects, SSH keys, browser profiles, shell history),
see and signal every process on the machine, and write anywhere you can.
`claude-box` puts it in a namespace jail where the project directory is the only
writable path outside its own tmpfs.

It is a single ~200-line bash script. There is no image to build and no daemon.

## Usage

```sh
nix run github:you/claude-box                 # no install needed, see below
```

```sh
./claude-box                                  # confine to $PWD, run claude
./claude-box -d ~/src/foo                     # confine to another directory
./claude-box -- claude -p 'run the tests'     # pass args through to claude
./claude-box --dry-run                        # print the bwrap command, don't run
```

The command defaults to `claude`, but any command works, which is the easiest
way to see what the sandbox actually looks like from inside:

```sh
./claude-box bash                             # interactive shell in the jail
./claude-box -- env                            # inspect the scrubbed environment
./claude-box -- ls -a ~                        # $HOME really is an empty tmpfs
./claude-box --offline -- npm test             # run a build with no network
./claude-box -- nix build .#foo                # daemon builds work inside
```

Use `--` to separate the command from `claude-box`'s own options. A command
whose first word starts with `-` is rejected rather than guessed at, so the
older `claude-box -- -p '...'` form now tells you to write
`claude-box -- claude -p '...'`.

| Flag | Effect |
|---|---|
| `-d, --dir PATH` | Project root to confine to (default: `$PWD`) |
| `--ro` | Bind the project read-only |
| `--offline` | Cut off network access (breaks the API; for auditing untrusted code). Also disables Nix access |
| `--no-nix` | Do not pass the Nix daemon socket through |
| `--share-claude` | Bind the real `~/.claude` and `~/.claude.json` read-write |
| `--bind PATH` | Additionally bind `PATH` read-write (repeatable) |
| `--ro-bind PATH` | Additionally bind `PATH` read-only (repeatable) |
| `--env VAR` | Pass one more environment variable through the scrub (repeatable) |
| `--dry-run` | Print the fully-expanded `bwrap` command and exit |

Everything after `--` is the command line to run, verbatim.

## What is confined

| | |
|---|---|
| **Filesystem** | `$HOME` is a tmpfs. Only the project directory is bound read-write. `/nix/store` and `/etc` are read-only. `/tmp` and `/var/tmp` are tmpfs. |
| **Processes** | Private PID namespace — Claude sees ~5 processes instead of your full table, and cannot signal anything on the host. |
| **IPC / UTS / cgroup** | Separate namespaces; hostname reads as `claude-box`. |
| **Capabilities** | All dropped, plus `no_new_privs`. |
| **Environment** | `--clearenv`, then only locale/terminal and `ANTHROPIC_*` variables are re-set, so stray `AWS_*` / `GITHUB_TOKEN` values in your shell do not leak in. |
| **Lifetime** | `--die-with-parent`: the sandbox dies with the launcher. |

Sibling directories do not leak. Binding `~/projects/foo/bar` materialises only
the empty path chain `~/projects/foo/`, not `foo`'s other children.

## Per-project Claude state

Each project gets its own state directory under
`~/.local/state/claude-box/<slug>`, holding a private `.claude/` and
`.claude.json`. Transcripts, session history and todos from one project are
invisible to another.

Two details make this painless:

- **No re-onboarding.** On first run the project's `.claude.json` is seeded from
  your real one with the `projects` and `githubRepoPaths` keys stripped. Those
  two fields are the ones carrying other projects' history; the remaining ~75
  (onboarding state, theme, user ID, cached config) are benign and carrying them
  over means no theme/trust prompt in every new directory.
- **No re-auth, no token divergence.** `~/.claude/.credentials.json` is
  bind-mounted read-write as a single file rather than copied. A copy would let
  the sandbox rotate the OAuth refresh token and silently invalidate your host
  login; sharing the one file keeps them in sync while exposing nothing else.

Use `--share-claude` to opt out and use your real config directly.

## Running it with Nix

The flake bundles Claude Code and a working development toolchain, so

```sh
nix run .
```

is enough on a machine with nothing installed globally. The wrapper appends
these to `PATH` as a *suffix*, so anything you already have keeps winning:

`claude-code`, `bashInteractive`, `coreutils`, `findutils`, `gnugrep`, `gnused`,
`gawk`, `diffutils`, `patch`, `less`, `which`, `procps`, `git`, `gh`, `ripgrep`,
`fd`, `jq`, `tree`, `nix`, `python3`, `nodejs`, `curl`, `gnutar`, `gzip`, `xz`,
`unzip`.

This matters more than it looks: `claude-box` builds the sandbox's `PATH` from
the host's minus the `$HOME` entries, so a Claude Code installed under
`~/.local/bin` or an npm global prefix is *not* visible inside. The store paths
above are.

`bubblewrap` is the one exception, pinned as a `PATH` prefix, because the
sandbox depends on its exact flag behaviour. `SSL_CERT_FILE` is defaulted to the
`cacert` bundle and passed through the environment scrub, so `curl`, `git` and
`gh` have working TLS inside even on a non-NixOS host.

Claude Code is unfree, so the flake instantiates nixpkgs with an
`allowUnfreePredicate` scoped to that single package — `nix run .` needs no
`--impure` and no `NIXPKGS_ALLOW_UNFREE`.

## Nix builds

`nix build`, `nix develop`, `nix-shell` and `direnv` work inside the sandbox.
Nothing in the store becomes writable to do it: builds are performed by the Nix
daemon, which runs as root *outside* the sandbox, so passing them through is
just a matter of reaching its socket.

- `/nix/var` is bound **read-only** — `NIX_PATH` channels live under
  `/nix/var/nix/profiles`, and the client only ever reads them.
- `/nix/var/nix/daemon-socket` is re-bound read-write on top, so `connect()`
  works. Every actual write to the store stays the daemon's to make.
- `NIX_PATH` and `NIX_REMOTE` are passed through, so `<nixpkgs>` resolves.
- `~/.config/nix/nix.conf` is **not** bound, because it routinely carries
  `access-tokens`. Its settings still matter — `experimental-features` decides
  whether `nix build` runs at all — so the file is passed through as
  `NIX_CONFIG` with `access-tokens`, `extra-access-tokens`, `netrc-file` and
  `secret-key-files` filtered out.

Two ways this turns itself off:

- `--no-nix`, explicitly.
- `--offline`, implicitly. The daemon fetches on the sandbox's behalf, so
  leaving the socket connected would make that flag a lie.

If there is no daemon socket (a single-user Nix install, where the client writes
to the store itself) the passthrough silently does nothing, and builds will fail
against the read-only store. See the note in Limitations for what this costs.

## Nix awareness

- `/nix/store` is bound read-only, so the sandbox cannot corrupt the store.
- NixOS indirection is handled: `/etc/static` and `/run/current-system` are
  symlinks into the store, so `/etc` and `/run/current-system` are bound too.
- The toolchain lives behind symlink chains in `$HOME`
  (`~/.nix-profile → ~/.local/state/nix/profiles/profile → /nix/store/...-user-environment`)
  which the tmpfs `$HOME` would erase. The script resolves each to its store
  path and recreates it with `--symlink` *after* the tmpfs is mounted, so `$PATH`
  keeps working without binding anything real from `$HOME`. `$PATH` entries under
  `$HOME` that are not the Nix profile are dropped, since they will not exist.
- Works on plain-Nix (non-NixOS) hosts too: every NixOS-specific path is probed
  before being bound.
- The profile-symlink recreation skips anything under `/nix/var` when the daemon
  is passed through: those paths already exist via the read-only bind, and
  `--symlink` over an existing link with a different target aborts bwrap.

Claude Code's own Bash sandbox also uses bubblewrap. Nested bubblewrap works
inside `claude-box`, and the script deliberately does **not** pass
`--unshare-user`, which would break it.

## Limitations

These are real, and worth reading before relying on this.

- **Network egress is unrestricted.** Claude needs `api.anthropic.com`, and
  without a filtering proxy there is no way to allow that while blocking
  everything else. An agent determined to exfiltrate the project's contents
  still can. This is the largest residual hole; `--offline` is the only
  mitigation offered, and it disables Claude entirely.
- **The Nix daemon is reachable.** `nix build` inside the sandbox is a request
  to a root process outside it. The daemon has its own build sandbox and its own
  network access, so this is a channel the confinement does not cover. It is
  bounded by what the daemon already exposes to any unprivileged user on the
  host, and `--no-nix` closes it.
- **No git identity.** `~/.gitconfig` is not bound, so `git commit` fails on a
  missing `user.name`/`user.email` unless the repo sets them locally. Opt in
  with `--ro-bind ~/.gitconfig`.
- **No SSH agent**, so `git push` over SSH will not work.
- **Same UID.** This is a namespace jail, not a privilege boundary. It contains
  a misbehaving agent, not a kernel exploit. There is no seccomp filter.

## Requirements

A kernel allowing unprivileged user namespaces (check
`/proc/sys/user/max_user_namespaces` is non-zero). Everything else —
`bubblewrap`, `python3` or `jq` for first-run config seeding, and the toolchain
the sandbox sees — comes from the flake. Running the script directly rather than
through Nix needs `bubblewrap` on `PATH`.
