{
  description = "claude-box — run a command confined to the current project directory";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      # claude-code carries an unfree licence, so legacyPackages refuses to
      # evaluate it. Allow that one package by name — a blanket allowUnfree
      # would silently cover anything else added to the toolchain later.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg:
          nixpkgs.lib.getName pkg == "claude-code";
      };
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));

      # The toolchain the sandbox gets. claude-box builds the sandbox's PATH by
      # stripping the $HOME entries off the host's, so anything installed under
      # $HOME (npm globals, ~/.local/bin) is *not* there — these store paths are
      # what makes `nix run .` work on a machine with nothing installed.
      #
      # Appended as a suffix, so a tool the user already has still wins.
      toolchain = pkgs: with pkgs; [
        claude-code

        # shell and the POSIX basics the script and any agent lean on
        bashInteractive coreutils findutils gnugrep gnused gawk
        diffutils patch less which procps

        # setfacl/getfacl: how the box user is granted the paths it needs
        # (claude-box only ever prints those commands, or runs them under
        # --setfacl). sudo is deliberately absent: the privilege drop needs the
        # host's setuid one, which a store copy could never be.
        acl

        # version control and search
        git gh ripgrep fd jq tree

        # the client half of the Nix daemon passthrough (see --no-nix)
        nix

        # runtimes: python3 also does claude-box's first-run config seeding
        python3 nodejs

        # network and archives (cacert is not listed: it ships no bin/, it is
        # referenced directly for SSL_CERT_FILE below)
        curl gnutar gzip xz unzip
      ];
    in
    {
      packages = forAllSystems (pkgs: rec {
        claude-box = pkgs.stdenvNoCC.mkDerivation {
          pname = "claude-box";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            install -Dm755 claude-box $out/bin/claude-box
            patchShebangs $out/bin/claude-box
            # bwrap is pinned ahead of the host's: the sandbox depends on its
            # exact flag behaviour. Everything else is a fallback.
            # CLAUDE_BOX_SELF is the wrapper's own path. The privilege drop
            # re-execs claude-box under sudo, and it has to be this wrapper
            # rather than the wrapped script: sudo resets the environment, so
            # the PATH set up here is what puts bubblewrap and the toolchain
            # back for the second phase.
            wrapProgram $out/bin/claude-box \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bubblewrap ]} \
              --suffix PATH : ${pkgs.lib.makeBinPath (toolchain pkgs)} \
              --set CLAUDE_BOX_SELF $out/bin/claude-box \
              --set-default SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "Run a command confined to the current project directory";
            platforms = platforms.linux;
            mainProgram = "claude-box";
          };
        };
        default = claude-box;
      });

      apps = forAllSystems (pkgs: rec {
        claude-box = {
          type = "app";
          program = "${self.packages.${pkgs.system}.claude-box}/bin/claude-box";
        };
        default = claude-box;
      });
    };
}
