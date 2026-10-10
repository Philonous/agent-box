{
  description = "agent-box — run a command confined to the current project directory";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      # Allow only claude-code as unfree.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg:
          nixpkgs.lib.getName pkg == "claude-code";
      };
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));

      # Sandbox toolchain. agent-box drops $HOME entries from PATH, so this is
      # what makes `nix run .` work on a bare machine. Appended, so host tools
      # win.
      toolchain = pkgs: with pkgs; [
        claude-code

        # shell and POSIX basics
        bashInteractive coreutils findutils gnugrep gnused gawk
        diffutils patch less which procps

        # no sudo: it must be the host's setuid one

        # version control and search
        git gh ripgrep fd jq tree

        # Nix daemon client (see --no-nix)
        nix

        # runtimes; python3 also seeds agent-box's config
        python3 nodejs

        # network and archives (cacert has no bin/; see SSL_CERT_FILE below)
        curl gnutar gzip xz unzip
      ];
    in
    {
      packages = forAllSystems (pkgs: rec {
        agent-box = pkgs.stdenvNoCC.mkDerivation {
          pname = "agent-box";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            install -Dm755 agent-box $out/bin/agent-box
            install -Dm755 agent-box-mount $out/bin/agent-box-mount
            patchShebangs $out/bin/agent-box $out/bin/agent-box-mount
            # Runs as root: PATH pinned to store paths. Not wrapped, so
            # sudoers can name the script itself.
            substituteInPlace $out/bin/agent-box-mount \
              --replace-fail 'PATH=/run/current-system/sw/bin:/usr/bin:/bin' \
                             'PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.getent ]}'
            # bwrap pinned ahead of the host's; the toolchain is a fallback.
            # AGENT_BOX_SELF: the privilege drop re-execs this wrapper, since
            # sudo resets PATH.
            wrapProgram $out/bin/agent-box \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bubblewrap ]} \
              --suffix PATH : ${pkgs.lib.makeBinPath (toolchain pkgs)} \
              --set AGENT_BOX_SELF $out/bin/agent-box \
              --set AGENT_BOX_MOUNT $out/bin/agent-box-mount \
              --set-default SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "Run a command confined to the current project directory";
            platforms = platforms.linux;
            mainProgram = "agent-box";
          };
        };
        default = agent-box;
      });

      apps = forAllSystems (pkgs: rec {
        agent-box = {
          type = "app";
          program = "${self.packages.${pkgs.system}.agent-box}/bin/agent-box";
        };
        default = agent-box;
      });
    };
}
