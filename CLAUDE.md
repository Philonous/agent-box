* Sandboxing for AI agents or similar
* Nix project, please take the flake into account
* If you stumble over something unexpected, take note of it in this file in the CLAUDE NOTES section. Keep additions as brief as possible


[CLAUDE NOTES]
* The agent's own Bash sandbox has a minimal PATH: no coreutils, bash, or nix,
  and no `/usr/bin/env` (so `./agent-box` fails with "bad interpreter").
  Fix: `export PATH=/run/current-system/sw/bin:$PATH`, and run `bash ./agent-box`.
* That sandbox binds /nix/store but not /nix/var, so `nix eval` works while
  `nix build`/`nix run` fall back to a chroot store at ~/.local/share/nix/root
  (grows to ~500MB of fetched sources) — don't build from here.
* `pkgs.claude-code` is unfree; the flake scopes an `allowUnfreePredicate` to it
  so `nix run .` needs no `--impure`.
* Nix passthrough: /nix/var ro + daemon-socket rw. The profile `--symlink` loop
  must skip /nix/var paths or bwrap aborts with EEXIST (relative default-N-link).
* Can't test the daemon from the agent sandbox; simulate with
  `bwrap --dev-bind / / --bind <fake> /nix/var`. That leaves an empty /nix/var
  mountpoint behind, so `test -d /nix/var` afterwards lies — `rmdir` it.
* The nixpkgs non-interactive `bash` (what `patchShebangs` resolves
  `env bash` to) is built without programmable completion, so `compgen` is
  "command not found" in the installed script though it works on the host.
* Nix daemon trust is per-uid via SO_PEERCRED; `bwrap --uid` cannot change what
  the daemon sees. `nix store info --json` reports `"trusted"` — use it to check.
* A read-only bind mount does not stop `connect()` on a unix socket: the EROFS
  check in `sb_permission` covers reg/dir/lnk only. Hiding a socket means
  removing the path, not binding it ro.
* The sudo switch can't be tested from the agent sandbox: bwrap sets
  NO_NEW_PRIVS, so setuid sudo refuses ("no new privileges flag is set").
* agent-box-mount (idmapped mounts) needs real root: untestable from the agent
  sandbox. Phase 2 can be simulated by hand-binding paths to $AGENT_BOX_STAGE/N.
* The agent sandbox runs as `agents`, so `nix eval .` fails ("repository path
  ... is not owned by current user"); `nix eval "path:$PWD#..."` works but
  rewrote flake.lock with a newer nixpkgs — `git checkout flake.lock` after.
* This repo is shared with the agent sandbox via ACLs; `chmod` on a file resets
  its ACL mask and locks the agent out (happened to agent-box-mount). Fix:
  `setfacl -m m::rwx FILE`.
* `X-mount.idmap=u:A:B:1` maps on-disk A to B as seen on the mount — reverse of
  the mount(8) wording. A map without a `g:` part fails with EINVAL.
