# agent-box

Run an AI coding agent (Claude Code by default) — or any other command —
confined to a single project directory, using
[bubblewrap](https://github.com/containers/bubblewrap) instead of Docker.

Coding agents normally run with your full ambient authority: they can read
every file under `$HOME` (other projects, SSH keys, browser profiles, shell
history), see and signal every process on the machine, and write anywhere you
can. `agent-box` puts the agent in a namespace jail where the project directory is the only
writable path outside its own tmpfs, running as a **separate unprivileged user**
so that the Nix daemon treats it as an untrusted client and your own files are
out of reach by file permissions, not just by what is bound.

It is a single bash script. There is no image to build and no daemon.

## Usage

```sh
nix run github:you/agent-box                 # no install needed, see below
```

```sh
./agent-box                                  # confine to $PWD, resume claude
./agent-box --new                            # start a fresh conversation
./agent-box -d ~/src/foo                     # confine to another directory
./agent-box -- claude -p 'run the tests'     # pass args through to claude
./agent-box --dry-run                        # print the bwrap command, don't run
```

The command defaults to `claude --continue`, resuming the project's last
conversation; `--new` starts a fresh one instead. On a project with no
conversation yet, plain `claude` is run, since `--continue` would fail there.
The default command also gets `--append-system-prompt` telling Claude it is in
a restricted sandbox, so it doesn't read missing tools or paths as facts about
the project. An explicitly given command (`agent-box -- claude ...`) is always run verbatim.

Any other command works too, which is the easiest
way to see what the sandbox actually looks like from inside:

```sh
./agent-box bash                             # interactive shell in the jail
./agent-box -- env                            # inspect the scrubbed environment
./agent-box -- ls -a ~                        # $HOME really is an empty tmpfs
./agent-box --offline -- npm test             # run a build with no network
./agent-box -- nix build .#foo                # daemon builds work inside
```

Use `--` to separate the command from `agent-box`'s own options. A command
whose first word starts with `-` is rejected rather than guessed at, so the
older `agent-box -- -p '...'` form now tells you to write
`agent-box -- claude -p '...'`.

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
| `--new` | Start a fresh conversation instead of passing `--continue` to the default `claude` |
| `--dry-run` | Print the command that would run and exit (at the user switch, which is runnable as printed) |

Everything after `--` is the command line to run, verbatim.

## What is confined

| | |
|---|---|
| **Filesystem** | `$HOME` is a tmpfs. Only the project directory is bound read-write. `/nix/store` and `/etc` are read-only. `/tmp` and `/var/tmp` are tmpfs. |
| **Processes** | Private PID namespace — the agent sees ~5 processes instead of your full table, and cannot signal anything on the host. |
| **IPC / UTS / cgroup** | Separate namespaces; hostname reads as `agent-box`. |
| **User** | A separate unprivileged user (`agents`, set in `agent-box-mount`), so your own files are unreachable by permissions and the Nix daemon sees an untrusted client. Files it creates are still owned by you (see below). |
| **Capabilities** | All dropped, plus `no_new_privs` — the setuid binaries under `/run/wrappers` cannot elevate inside. |
| **Environment** | `--clearenv`, then only locale/terminal and `ANTHROPIC_*` variables are re-set, so stray `AWS_*` / `GITHUB_TOKEN` values in your shell do not leak in. |
| **Lifetime** | `--die-with-parent`: the sandbox dies with the launcher. |

Sibling directories do not leak. Binding `~/projects/foo/bar` materialises only
the empty path chain `~/projects/foo/`, not `foo`'s other children.

## Running as a separate user

The sandbox does not run as you. On startup `agent-box` re-execs itself
through `sudo agent-box-mount`, a small fixed helper that drops to an
unprivileged user, and only then builds the sandbox. The user is `agents`; to
change it, edit the `box_user=` line in `agent-box-mount` — that line is the
only place it is set.

The reason is the Nix daemon. It decides whether a client is trusted from the
peer's uid (`SO_PEERCRED`), and a user namespace cannot change what the kernel
reports there: `bwrap --uid` only relabels the uid inside the namespace. So if
you are in `trusted-users`, a sandbox running as you can tell the daemon to use
a different `build-hook`, `post-build-hook` or `substituters`, or to add
`extra-sandbox-paths` that read host files into a build. That is
root-equivalent in practice. As a uid that is not trusted, those settings are
ignored with a warning instead. `agent-box` verifies it rather than assuming
it, and refuses to launch if the daemon still reports `"trusted":true`:

```sh
nix store info --json          # inside the box: {"trusted":false,...}
```

The privilege drop is always printed before it runs, in full:

```
agent-box: switching to the box user — the Nix daemon decides client trust by uid
agent-box: + sudo -- /nix/store/...-agent-box/bin/agent-box-mount \
    rw /home/you/src/foo rw /home/you/.local/state/agent-box/home%you%src%foo-123 \
    rw /home/you/.claude/.credentials.json \
    -- /nix/store/...-agent-box/bin/agent-box \
    --internal-switched --internal-user you --internal-home /home/you \
    --internal-handoff /tmp/agent-box-handoff.Ab3kR9
```

The handoff file is how the second phase learns what the first worked out — the
project path, the state directory, your `$PATH`, the resolved Nix profile links,
the scrubbed `NIX_CONFIG`. It is kept out of the command line so that the line
above stays short enough to read, and out of the environment because `sudo`
resets that unless the sudoers rule says `SETENV`. It is world-readable and
contains no secrets, by design: `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`
are *not* carried across, and agent-box says so when they are set.

### File ownership: idmapped mounts

The box user cannot normally read your project (`~/projects` is typically
`0700`), and anything it wrote would be owned by it. `agent-box-mount` solves
both with [idmapped mounts](https://docs.kernel.org/filesystems/idmappings.html).
In a private mount namespace, it bind-mounts each path it is given under
`/run/agent-box/N`, mapped so that your uid and primary gid read as the box
user's. Then it drops to the box user. bwrap binds those copies back to their
real paths inside the sandbox.

The effect:

- Inside, the project reads as the box user's own, so permissions just work.
- Whatever the box creates lands on disk as **you** (`you:users`), so there is
  nothing to chown back and no ACLs to manage.
- Your `0700` ancestors stay `0700`. The staged copies are reached through
  `/run/agent-box`, not through your `$HOME`.
- The mounts exist only in that namespace. Outside the box, the user `agents`
  still cannot reach any of your files.

`agent-box-mount` is the only part that runs as root, so it is deliberately
small and strict:

- The box user is a constant in the script, not an argument.
- Only your own uid and primary gid are mapped. Anything else under a shared
  path (a root-owned file, a file with another group) reads as `nobody` there.
  The box gets the same "other" access to it as it would have anyway.
- Each path must be owned by you. This is checked on what actually got
  mounted, so a symlink swapped in at the last moment cannot redirect it to
  someone else's files.
- `ro` paths are remounted read-only on top of bwrap's own `--ro-bind`.
- It drops to the box user with `no_new_privs` set, so even before bwrap
  starts nothing can regain privileges through a setuid binary.

A `--bind`/`--ro-bind` path you don't own (a system file, say) is not idmapped.
It is bound as it is, and the box user has to be able to reach it on its own
permissions; `agent-box` says so if it can't.

The binds are not recursive: a filesystem mounted *inside* the project
directory does not appear in the box.

This needs a filesystem that supports idmapped mounts: ext4, btrfs, xfs, tmpfs
and overlayfs do, on any reasonably recent kernel.

#### Migrating from the ACL setup

Earlier versions granted access with ACLs, and files created back then are owned
by `agents`. To clean up a project:

```sh
sudo chown -R --from=agents you:users ~/src/foo
setfacl -R -x u:agents -x d:u:agents -x d:u:you ~/src/foo
```

Do the same for `~/.local/state/agent-box` and, if you shared it,
`~/.claude/.credentials.json`. Then remove the `x` entries on ancestors such as
`setfacl -x u:agents ~/src`.

## Per-project Claude state

Each project gets its own state directory under
`~/.local/state/agent-box/<slug>`, holding a private `.claude/` and
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

That credentials file is shared through `agent-box-mount` like the project, so
it is reachable only from inside the box's mount namespace, for as long as the
box runs.

Use `--share-claude` to opt out and use your real `~/.claude` and
`~/.claude.json` directly, idmapped the same way. That is a much broader grant.

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

This matters more than it looks: `agent-box` builds the sandbox's `PATH` from
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
- `/nix/var/nix/daemon-socket` is re-bound read-write on top. Every actual write
  to the store stays the daemon's to make. Note that the read-write bind is not
  what grants access: `connect()` on a unix socket works through a read-only
  bind mount too, because the kernel's `EROFS` check covers regular files,
  directories and symlinks but not sockets — the same reason mounting
  `docker.sock:ro` protects nothing. What makes the connection untrusted is the
  uid it comes from.
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
inside `agent-box`, and the script deliberately does **not** pass
`--unshare-user`, which would break it.

## Limitations

These are real, and worth reading before relying on this.

- **Network egress is unrestricted.** The agent needs its API endpoint
  (`api.anthropic.com` for Claude), and without a filtering proxy there is no way to allow that while blocking
  everything else. An agent determined to exfiltrate the project's contents
  still can. This is the largest residual hole; `--offline` is the only
  mitigation offered, and it disables the agent entirely.
- **The Nix daemon is reachable.** `nix build` inside the sandbox is a request
  to a root process outside it. The daemon has its own build sandbox and its own
  network access, so this is a channel the confinement does not cover. It is
  bounded by what the daemon exposes to an *untrusted* client — client-specified
  `substituters`, `build-hook`, `extra-sandbox-paths` and friends are ignored —
  but realising derivations and fetching from the configured substituters are
  still possible, so CPU and disk abuse are not prevented. Evaluation-time
  fetching (`builtins.fetchurl`, import-from-derivation) happens client-side,
  inside the sandbox, with the sandbox's network. `--no-nix` closes all of it.
- **No git identity.** `~/.gitconfig` is not bound, so `git commit` fails on a
  missing `user.name`/`user.email` unless the repo sets them locally. Opt in
  with `--ro-bind ~/.gitconfig`.
- **No SSH agent**, so `git push` over SSH will not work.
- **Not a privilege boundary.** It contains a misbehaving agent, not a kernel
  exploit. There is no seccomp filter. The separate uid adds real depth — your
  files are protected by permissions, not only by which paths are bound — but
  a `0755` `$HOME` still lets it read world-readable files that happen to be
  bound in.

## Requirements

A kernel allowing unprivileged user namespaces (check
`/proc/sys/user/max_user_namespaces` is non-zero), plus three things for the
user switch:

- **The box user.** An unprivileged account that is *not* in `trusted-users`
  (`nix.conf`). It is `agents` unless you change `box_user=` in
  `agent-box-mount`. It needs no home directory, shell or group of its own.
- **A sudo rule** letting you run `agent-box-mount` as root, e.g.
  `you ALL=(root) NOPASSWD: /nix/store/...-agent-box/bin/agent-box-mount` —
  or no rule beyond plain sudo access, and type your password at each start.
  On NixOS:

  ```nix
  security.sudo.extraRules = [{
    users = [ "you" ];
    commands = [{
      command = "${agent-box}/bin/agent-box-mount";
      options = [ "NOPASSWD" ];
    }];
  }];
  ```

  `sudo` has to be the host's setuid one, so it is deliberately not in the
  flake's toolchain.
- **A filesystem with idmapped-mount support** for the project and state paths
  (ext4, btrfs, xfs, tmpfs, overlayfs).

Everything else — `bubblewrap`, `python3` or `jq` for first-run config seeding,
and the toolchain the sandbox sees — comes from the flake, which also pins
`agent-box-mount`'s `PATH` to store paths. Running the scripts directly rather
than through Nix needs `bubblewrap` and util-linux (`mount`, `unshare`,
`setpriv`) installed, with `agent-box-mount` next to `agent-box`.
