{
  description = "fts-reaper-flake — FTS audio production environment (REAPER + plugins + audio libs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    reaper-flake.url = "github:FastTrackStudios/reaper-flake";
    crane.url = "github:ipetkov/crane";
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
      # Colors and badges must match icon_gen::rig_appearance in reaper-launcher.
      predefinedRigs = {
        reaper = {
          id = "fts-reaper";
          name = "FTS REAPER";
          comment = "FTS REAPER — Main DAW Instance";
          rig_type = "reaper";
          badge = "FTS";
          color = { r = 221; g = 221; b = 221; };   # 0xdddddd white/light gray
          noTint = true;
        };
        keys = {
          id = "fts-keys";
          name = "FTS Keys";
          comment = "REAPER Signal Rig for Keyboard Instruments";
          rig_type = "keys";
          badge = "KEYS";
          color = { r = 34; g = 197; b = 94; };    # 0x22c55e green
        };
        drums = {
          id = "fts-drums";
          name = "FTS Drums";
          comment = "REAPER Signal Rig for Drums and Percussion";
          rig_type = "drums";
          badge = "DRUMS";
          color = { r = 239; g = 68; b = 68; };    # 0xef4444 red
        };
        bass = {
          id = "fts-bass";
          name = "FTS Bass";
          comment = "REAPER Signal Rig for Bass";
          rig_type = "bass";
          badge = "BASS";
          color = { r = 234; g = 179; b = 8; };    # 0xeab308 yellow
        };
        guitar = {
          id = "fts-guitar";
          name = "FTS Guitar";
          comment = "REAPER Signal Rig for Guitar";
          rig_type = "guitar";
          badge = "GUITAR";
          color = { r = 59; g = 130; b = 246; };   # 0x3b82f6 blue
        };
        vocals = {
          id = "fts-vocals";
          name = "FTS Vocals";
          comment = "REAPER Signal Rig for Vocals";
          rig_type = "vocals";
          badge = "VOCALS";
          color = { r = 236; g = 72; b = 153; };   # 0xec4899 pink
        };
      };
    in
    {
      inherit presets;
      lib.mkFtsPackages = mkFtsPackages;

      homeManagerModules.default = import ./modules/home.nix { perSystemPackages = self.packages; };
      homeManagerModules.fts-reaper = import ./modules/home.nix { perSystemPackages = self.packages; };
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

        # headless build — for CI/testing devShell
        devPkgs = mkFtsPackages {
          inherit pkgs;
          cfg = presets.dev // {
            reaper.configDir = ftsReaperConfig;
          };
        };

        # GUI build — for production signal rigs (headless.enable = false)
        prodPkgs = mkFtsPackages {
          inherit pkgs;
          cfg = presets.full // {
            reaper.configDir = ftsReaperConfig;
          };
        };

        # ── reaper-launcher ───────────────────────────────────────────────
        craneLib = crane.mkLib pkgs;

        reaper-launcher =
          let
            src = nixpkgs.lib.cleanSourceWith {
              src = daw;
              filter = path: type:
                (craneLib.filterCargoSources path type)
                || (builtins.match ".*\\.icns$" path != null)
                || (builtins.match ".*\\.ttf$" path != null);
            };
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

        # ── Shared setup script ────────────────────────────────────────────
        # Writes a single launch.json with all rigs, installs icons and
        # desktop entries. Run once via `fts-setup` or any rig's --setup flag.
        launchJsonContent = builtins.toJSON (
          nixpkgs.lib.mapAttrs' (_: rig: nixpkgs.lib.nameValuePair rig.id {
            role = "signal";
            rig_type = rig.rig_type;
            reaper_executable = "${prodPkgs.reaper}/bin/reaper";
            resources_dir = "%FTS_REAPER%";
            ini_path = "%FTS_REAPER%/reaper.ini";
            ini_overrides = { undo_max_mem = 0; };
            restore_ini_after_launch = false;
            reaper_args = [ "-newinst" "-nosplash" "-ignoreerrors" ];
          }) predefinedRigs
        );

        fts-setup-standalone = pkgs.writeShellScriptBin "fts-setup" ''
          set -euo pipefail
          FTS_REAPER="$HOME/.fasttrackstudio/Reaper"
          FTS_DIR="$FTS_REAPER/FastTrackStudio"
          mkdir -p "$FTS_DIR" "$FTS_REAPER/UserPlugins" "$FTS_REAPER/Scripts"

          # Write single launch.json with all rig configs
          echo '${launchJsonContent}' | ${pkgs.gnused}/bin/sed "s|%FTS_REAPER%|$FTS_REAPER|g" \
            | ${pkgs.jq}/bin/jq . > "$FTS_DIR/launch.json"

          # Symlink SWS and ReaPack extensions into UserPlugins
          ln -sf "${prodPkgs.sws}/UserPlugins/reaper_sws-x86_64.so" "$FTS_REAPER/UserPlugins/"
          ln -sf "${prodPkgs.sws}/Scripts/sws_python.py" "$FTS_REAPER/Scripts/"
          ln -sf "${prodPkgs.sws}/Scripts/sws_python64.py" "$FTS_REAPER/Scripts/"
          ln -sf "${prodPkgs.reapack}/UserPlugins/reaper_reapack-x86_64.so" "$FTS_REAPER/UserPlugins/"

          echo "FTS REAPER setup complete"
          echo "  launch.json → $FTS_DIR/launch.json"
          echo "  SWS → $FTS_REAPER/UserPlugins/reaper_sws-x86_64.so"
          echo "  ReaPack → $FTS_REAPER/UserPlugins/reaper_reapack-x86_64.so"
          echo "  Rigs: ${nixpkgs.lib.concatStringsSep ", " (nixpkgs.lib.mapAttrsToList (_: rig: rig.id) predefinedRigs)}"
        '';

        # ── Per-rig wrappers ──────────────────────────────────────────────
        # Each rig is a thin script that ensures setup is done, then
        # execs reaper-launcher with --config launch.json --rig <id>.
        mkRigWrapper = rig: pkgs.writeShellScriptBin rig.id ''
          set -euo pipefail
          CONFIG="$HOME/.fasttrackstudio/Reaper/FastTrackStudio/launch.json"

          # --setup: just run setup without launching REAPER
          if [ "''${1:-}" = "--setup" ]; then
            exec "${fts-setup-standalone}/bin/fts-setup"
          fi

          # Auto-setup if launch.json is missing
          if [ ! -f "$CONFIG" ]; then
            "${fts-setup-standalone}/bin/fts-setup"
          fi

          # Launch REAPER in background, then tag its XWayland window with
          # _KDE_NET_WM_DESKTOP_FILE so KDE shows the correct per-rig icon.
          "${reaper-launcher}/bin/reaper-launcher" --config "$CONFIG" --rig "${rig.id}" "$@" &
          REAPER_PID=$!

          # Wait for REAPER's window to appear (up to 10s)
          for i in $(seq 1 20); do
            WID=$(${pkgs.xdotool}/bin/xdotool search --pid "$REAPER_PID" 2>/dev/null | head -1) && break
            sleep 0.5
          done

          # Tag the window so KDE matches it to our .desktop file
          if [ -n "''${WID:-}" ]; then
            ${pkgs.xorg.xprop}/bin/xprop -id "$WID" -f _KDE_NET_WM_DESKTOP_FILE 8u \
              -set _KDE_NET_WM_DESKTOP_FILE "${rig.id}" 2>/dev/null || true
          fi

          # Wait for REAPER to exit
          wait "$REAPER_PID" 2>/dev/null || true
        '';

        # Icons + desktop entries as a proper Nix package
        # KDE finds these via /run/current-system/sw/share/ or the home profile
        fts-icons = pkgs.runCommand "fts-icons" {} ''
          for size in 48 128 256; do
            dir=$out/share/icons/hicolor/''${size}x''${size}/apps
            mkdir -p $dir
            cp ${self}/assets/icons/$size/*.png $dir/
          done

          mkdir -p $out/share/applications
          ${nixpkgs.lib.concatStringsSep "\n" (nixpkgs.lib.mapAttrsToList (_: rig:
            let wrapper = mkRigWrapper rig; in ''
              cat > $out/share/applications/${rig.id}.desktop << 'EOF'
          [Desktop Entry]
          Type=Application
          Name=${rig.name}
          Comment=${rig.comment}
          Exec=${wrapper}/bin/${rig.id} %F
          Icon=${rig.id}
          Terminal=false
          Categories=AudioVideo;Audio;
          StartupWMClass=${rig.id}
          Keywords=reaper;daw;${rig.rig_type};fasttrackstudio;
          EOF
            ''
          ) predefinedRigs)}
        '';

        # Single package containing all rig wrappers + reaper-launcher + icons
        fts-rigs = pkgs.symlinkJoin {
          name = "fts-rigs";
          paths = (nixpkgs.lib.mapAttrsToList (_: mkRigWrapper) predefinedRigs) ++ [ reaper-launcher fts-setup-standalone fts-icons ];
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

      in
      {
        packages = {
          default = fts-rigs;
          inherit
            reaper-launcher
            fts-rigs
            fts-icons
            ;
          fts-test = devPkgs.fts-test;
          fts-gui = devPkgs.fts-gui;
          reaper-fhs = devPkgs.reaper-fhs;
          setup = fts-setup-standalone;
        }
        // nixpkgs.lib.mapAttrs' (_: rig: nixpkgs.lib.nameValuePair rig.id (mkRigWrapper rig)) predefinedRigs;

        apps = {
          default = {
            type = "app";
            program = "${fts-setup-standalone}/bin/fts-setup";
          };
          setup = {
            type = "app";
            program = "${fts-setup-standalone}/bin/fts-setup";
          };
        }
        // nixpkgs.lib.mapAttrs' (_: rig: nixpkgs.lib.nameValuePair rig.id {
          type = "app";
          program = "${mkRigWrapper rig}/bin/${rig.id}";
        }) predefinedRigs;

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
