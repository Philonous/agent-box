# claude-box

Run Claude Code confined to a single project directory, using
[bubblewrap](https://github.com/containers/bubblewrap) instead of Docker.

Claude Code normally runs with your full ambient authority: it can read every
file under `$HOME` (other projects, SSH keys, browser profiles, shell history),
see and signal every process on the machine, and write anywhere you can.
`claude-box` puts it in a namespace jail where the project directory is the only
writable path outside its own tmpfs.

It is a single ~200-line bash script. There is no image to build and no daemon.

## Usage

```sh
./claude-box                                  # confine to $PWD, interactive
./claude-box -d ~/src/foo                     # confine to another directory
./claude-box -- -p 'run the tests'            # pass args through to claude
./claude-box --dry-run                        # print the bwrap command, don't run
```

| Flag | Effect |
|---|---|
| `-d, --dir PATH` | Project root to confine to (default: `$PWD`) |
| `--ro` | Bind the project read-only |
| `--offline` | Cut off network access (breaks the API; for auditing untrusted code) |
| `--share-claude` | Bind the real `~/.claude` and `~/.claude.json` read-write |
| `--bind PATH` | Additionally bind `PATH` read-write (repeatable) |
| `--ro-bind PATH` | Additionally bind `PATH` read-only (repeatable) |
| `--env VAR` | Pass one more environment variable through the scrub (repeatable) |
| `--dry-run` | Print the fully-expanded `bwrap` command and exit |

Everything after `--` goes to `claude` verbatim.

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
- **No Nix builds inside.** The daemon socket is not bound, so `nix build`,
  `nix develop`, `nix-shell` and `direnv` will not work. Existing tools on
  `$PATH` are fine.
- **No git identity.** `~/.gitconfig` is not bound, so `git commit` fails on a
  missing `user.name`/`user.email` unless the repo sets them locally. Opt in
  with `--ro-bind ~/.gitconfig`.
- **No SSH agent**, so `git push` over SSH will not work.
- **Same UID.** This is a namespace jail, not a privilege boundary. It contains
  a misbehaving agent, not a kernel exploit. There is no seccomp filter.

## Requirements

`bubblewrap`, and a kernel allowing unprivileged user namespaces (check
`/proc/sys/user/max_user_namespaces` is non-zero). `python3` or `jq` is used
once, for first-run config seeding, and is optional.
