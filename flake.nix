{
  description = "fts-reaper-flake — FTS audio production environment (REAPER + plugins + audio libs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    reaper-flake.url = "github:FastTrackStudios/reaper-flake";
    crane.url = "github:ipetkov/crane";
    wrappers.url = "github:Lassulus/wrappers";

    # daw source only — not evaluated as a flake to avoid circular dependency
    # (daw uses fts-reaper-flake; we only need it to build reaper-launcher).
    daw = {
      url = "github:FastTrackStudios/daw";
      flake = false;
    };
  };

  nixConfig = {
    extra-trusted-public-keys = [
      "fasttrackstudio.cachix.org-1:r7v7WXBeSZ7m5meL6w0wttnvsOltRvTpXeVNItcy9f4="
    ];
    extra-substituters = [
      "https://fasttrackstudio.cachix.org"
    ];
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      reaper-flake,
      crane,
      wrappers,
      daw,
    } @ inputs:
    let
      # ── mkFtsPackages ─────────────────────────────────────────────────────
      mkFtsPackages =
        { pkgs, cfg }:
        let
          base = reaper-flake.lib.mkReaperPackages { inherit pkgs cfg; };
        in
        base
        // {
          fts-test = base.reaper-test;
          fts-gui = base.reaper-gui;
        };

      presets = reaper-flake.presets;

      ftsReaperConfig = "$HOME/.fasttrackstudio/Reaper";

      # ── Predefined rig definitions ─────────────────────────────────────
      # Colors and badges match icon_gen::rig_appearance in reaper-launcher.
      predefinedRigs = {
        keys = {
          id = "fts-keys";
          name = "FTS Keys";
          comment = "REAPER signal rig for keyboard instruments";
          rig_type = "keys";
        };
        drums = {
          id = "fts-drums";
          name = "FTS Drums";
          comment = "REAPER signal rig for drums and percussion";
          rig_type = "drums";
        };
        bass = {
          id = "fts-bass";
          name = "FTS Bass";
          comment = "REAPER signal rig for bass";
          rig_type = "bass";
        };
        guitar = {
          id = "fts-guitar";
          name = "FTS Guitar";
          comment = "REAPER signal rig for guitar";
          rig_type = "guitar";
        };
        vocals = {
          id = "fts-vocals";
          name = "FTS Vocals";
          comment = "REAPER signal rig for vocals";
          rig_type = "vocals";
        };
      };
    in
    {
      inherit presets;
      lib.mkFtsPackages = mkFtsPackages;

      homeManagerModules.default = ./modules/home.nix;
      homeManagerModules.fts-reaper = ./modules/home.nix;
    }
    // flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate =
            pkg:
            builtins.elem (nixpkgs.lib.getName pkg) [
              "reaper"
            ];
        };

        devPkgs = mkFtsPackages {
          inherit pkgs;
          cfg = presets.dev // {
            reaper.configDir = ftsReaperConfig;
          };
        };

        wlib = wrappers.lib;

        # ── reaper-launcher ───────────────────────────────────────────────
        craneLib = crane.mkLib pkgs;

        reaper-launcher =
          let
            src = craneLib.cleanCargoSource daw;
            commonArgs = {
              inherit src;
              pname = "reaper-launcher";
              version = "0.1.0";
              cargoExtraArgs = "-p reaper-launcher";
              strictDeps = true;
              doCheck = false;
            };
            cargoArtifacts = craneLib.buildDepsOnly commonArgs;
          in
          craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; });

        # ── Per-rig wrapper scripts ────────────────────────────────────────
        # Each rig gets its own binary (fts-keys, fts-drums, etc.) that calls
        # reaper-launcher with the rig's launch.json path.
        # $HOME in args is preserved unescaped by escapeShellArgWithEnv —
        # the shell expands it at runtime.
        mkRigWrapper =
          rig:
          wlib.wrapPackage {
            inherit pkgs;
            package = reaper-launcher;
            exePath = "${reaper-launcher}/bin/reaper-launcher";
            binName = rig.id;
            args = [
              "--config"
              "$HOME/.config/fts/rigs/${rig.id}/launch.json"
              "$@"
            ];
          };

        # Single package containing all rig wrappers
        fts-rigs = pkgs.symlinkJoin {
          name = "fts-rigs";
          paths = nixpkgs.lib.mapAttrsToList (_: mkRigWrapper) predefinedRigs;
        };

        # ── Audio production library set ──────────────────────────────────
        audioProductionLibs = with pkgs; [
          libx11
          libxi
          libxext
          libxrandr
          libxcursor
          libxinerama
          libxcomposite
          libxdamage
          libxfixes
          libxrender
          libxtst
          libxcb
          libxscrnsaver
          libxkbcommon
          vulkan-loader
          vulkan-headers
          vulkan-tools
          libGL
          mesa
          gtk3
          glib
          gdk-pixbuf
          pango
          cairo
          atk
          wayland
          wayland-protocols
          fontconfig
          freetype
          alsa-lib
          pipewire.jack
          rubberband
          llvmPackages.libclang
          dbus
          zlib
          stdenv.cc.cc.lib
        ];

        # ── Setup script ──────────────────────────────────────────────────
        # nix run .#setup — installs the full FTS audio production environment:
        #   - creates ~/.fasttrackstudio/Reaper/
        #   - writes launch.json for each predefined rig
        #   - symlinks rig wrappers and reaper-launcher to ~/.local/bin/
        #   - installs .desktop entries to ~/.local/share/applications/
        setup-script = pkgs.writeShellScriptBin "fts-setup" ''
          set -euo pipefail

          REAPER_EXE="${devPkgs.reaper}/bin/reaper"
          REAPER_CONFIG="$HOME/.fasttrackstudio/Reaper"
          LAUNCHER="${reaper-launcher}/bin/reaper-launcher"
          RIGS_PKG="${fts-rigs}"

          echo ""
          echo "  FTS Audio Production Setup"
          echo "  ──────────────────────────"

          # Directories
          mkdir -p "$REAPER_CONFIG"
          mkdir -p "$HOME/.config/fts/rigs"
          mkdir -p "$HOME/.local/bin"
          mkdir -p "$HOME/.local/share/applications"

          # Seed a minimal reaper.ini if none exists
          if [ ! -f "$REAPER_CONFIG/reaper.ini" ]; then
            cat > "$REAPER_CONFIG/reaper.ini" << 'INI'
          [reaper]
          audiodriver=2
          undomaxmem=0
          INI
            echo "  reaper.ini  → $REAPER_CONFIG/reaper.ini"
          fi

          # Install reaper-launcher
          ln -sf "$LAUNCHER" "$HOME/.local/bin/reaper-launcher"
          echo "  reaper-launcher → $HOME/.local/bin/reaper-launcher"

          # Per-rig setup
          setup_rig() {
            local id="$1"
            local name="$2"
            local rig_type="$3"
            local comment="$4"

            # launch.json — written at runtime so $HOME is expanded
            mkdir -p "$HOME/.config/fts/rigs/$id"
            cat > "$HOME/.config/fts/rigs/$id/launch.json" << JSON
          {
            "role": "signal",
            "rig_type": "$rig_type",
            "reaper_executable": "$REAPER_EXE",
            "resources_dir": "$REAPER_CONFIG",
            "ini_path": "$REAPER_CONFIG/reaper.ini",
            "ini_overrides": { "undo_max_mem": 0 },
            "restore_ini_after_launch": false,
            "reaper_args": ["-newinst", "-nosplash", "-ignoreerrors"]
          }
          JSON

            # Rig wrapper binary
            ln -sf "$RIGS_PKG/bin/$id" "$HOME/.local/bin/$id"

            # .desktop entry
            cat > "$HOME/.local/share/applications/$id.desktop" << DESKTOP
          [Desktop Entry]
          Type=Application
          Name=$name
          Comment=$comment
          Exec=$HOME/.local/bin/$id %F
          Icon=reaper
          Terminal=false
          Categories=AudioVideo;Audio;
          StartupWMClass=REAPER
          Keywords=reaper;daw;signal;$rig_type;fasttrackstudio;
          DESKTOP

            echo "  $id → installed"
          }

          ${nixpkgs.lib.concatStringsSep "\n" (
            nixpkgs.lib.mapAttrsToList (_: rig: ''
              setup_rig "${rig.id}" "${rig.name}" "${rig.rig_type}" "${rig.comment}"
            '') predefinedRigs
          )}

          # Refresh desktop database if available
          if command -v update-desktop-database &>/dev/null; then
            update-desktop-database "$HOME/.local/share/applications"
          fi

          echo ""
          echo "  Done. REAPER: $REAPER_EXE"
          echo ""
          echo "  Rigs installed:"
          ${nixpkgs.lib.concatStringsSep "\n" (
            nixpkgs.lib.mapAttrsToList (_: rig: ''
              echo "    ${rig.id}"
            '') predefinedRigs
          )}
          echo ""
          echo "  Run any rig with: ${nixpkgs.lib.concatStringsSep ", " (
            nixpkgs.lib.mapAttrsToList (_: rig: rig.id) predefinedRigs
          )}"
          echo ""
        '';
      in
      {
        packages = {
          default = setup-script;
          inherit
            reaper-launcher
            fts-rigs
            ;
          fts-test = devPkgs.fts-test;
          fts-gui = devPkgs.fts-gui;
          reaper-fhs = devPkgs.reaper-fhs;
          setup = setup-script;
        };

        apps = {
          default = {
            type = "app";
            program = "${setup-script}/bin/fts-setup";
          };
          setup = {
            type = "app";
            program = "${setup-script}/bin/fts-setup";
          };
        };

        devShells.default = pkgs.mkShell {
          packages =
            [
              devPkgs.fts-test
              devPkgs.fts-gui
              devPkgs.reaper-fhs
              reaper-launcher
              fts-rigs
              pkgs.pkg-config
              pkgs.openssl
            ]
            ++ audioProductionLibs;

          FTS_REAPER_EXECUTABLE = "${devPkgs.reaper}/bin/reaper";
          FTS_REAPER_RESOURCES = "${devPkgs.reaper}/opt/REAPER";
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.rubberband ];
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
            pkgs.vulkan-loader
            pkgs.libGL
            pkgs.wayland
            pkgs.libxkbcommon
          ];

          shellHook = ''
            export FTS_REAPER_CONFIG="$HOME/.fasttrackstudio/Reaper"
            echo ""
            echo "  fts-reaper-flake dev shell"
            echo "  ─────────────────────────────────────────"
            echo "  fts-test [cmd]  — headless REAPER FHS env"
            echo "  fts-gui         — launch REAPER with GUI"
            echo "  reaper-launcher — rig launcher binary"
            echo "  fts-keys / fts-drums / fts-bass / fts-guitar / fts-vocals"
            echo ""
            echo "  REAPER: ${devPkgs.reaper}/bin/reaper"
            echo ""
          '';
        };
      }
    );
}
