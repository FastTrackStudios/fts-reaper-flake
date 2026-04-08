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

        # ── Per-rig self-contained wrappers ────────────────────────────────
        # Each rig is a standalone script that generates its own launch.json
        # at runtime (expanding $HOME), then execs reaper-launcher.
        # No home-manager or setup step required — nix run .#fts-keys just works.
        mkRigWrapper = rig: pkgs.writeShellScriptBin rig.id ''
          set -euo pipefail
          LAUNCHER="${reaper-launcher}/bin/reaper-launcher"
          FTS_REAPER="$HOME/.fasttrackstudio/Reaper"
          RIG_DIR="$FTS_REAPER/${rig.id}"
          CONFIG="$RIG_DIR/launch.json"
          ICONS="${self}/assets/icons"
          SELF="$(readlink -f "$0")"

          setup() {
            # launch.json
            mkdir -p "$RIG_DIR"
            cat > "$CONFIG" << 'EOF'
          {
            "role": "signal",
            "rig_type": "${rig.rig_type}",
            "reaper_executable": "${prodPkgs.reaper}/bin/reaper",
            "resources_dir": "PLACEHOLDER_HOME/.fasttrackstudio/Reaper",
            "ini_path": "PLACEHOLDER_HOME/.fasttrackstudio/Reaper/reaper.ini",
            "ini_overrides": { "undo_max_mem": 0 },
            "restore_ini_after_launch": false,
            "reaper_args": ["-newinst", "-nosplash", "-ignoreerrors"]
          }
          EOF
            ${pkgs.gnused}/bin/sed -i "s|PLACEHOLDER_HOME|$HOME|g" "$CONFIG"

            # Icons into XDG hicolor
            for size in 48 128 256; do
              dir="$HOME/.local/share/icons/hicolor/''${size}x''${size}/apps"
              mkdir -p "$dir"
              cp "$ICONS/$size/${rig.id}.png" "$dir/${rig.id}.png" 2>/dev/null || true
            done

            # Ensure index.theme for KDE
            HICOLOR="$HOME/.local/share/icons/hicolor"
            if [ ! -f "$HICOLOR/index.theme" ]; then
              cat > "$HICOLOR/index.theme" << 'THEME'
          [Icon Theme]
          Name=Hicolor
          Comment=Fallback icon theme
          Hidden=true
          Directories=48x48/apps,128x128/apps,256x256/apps
          [48x48/apps]
          Size=48
          Context=Apps
          Type=Threshold
          [128x128/apps]
          Size=128
          Context=Apps
          Type=Threshold
          [256x256/apps]
          Size=256
          Context=Apps
          Type=Threshold
          THEME
            fi

            # App launcher desktop entry (uses XDG icon name)
            mkdir -p "$HOME/.local/share/applications"
            cat > "$HOME/.local/share/applications/${rig.id}.desktop" << DESKTOP
          [Desktop Entry]
          Type=Application
          Name=${rig.name}
          Comment=${rig.comment}
          Exec=$SELF %F
          Icon=${rig.id}
          Terminal=false
          Categories=AudioVideo;Audio;
          StartupWMClass=REAPER
          Keywords=reaper;daw;${rig.rig_type};fasttrackstudio;
          DESKTOP

            # Desktop shortcut in Reaper folder (works in Dolphin + Nautilus)
            cat > "$FTS_REAPER/${rig.name}.desktop" << DESKTOP
          [Desktop Entry]
          Type=Application
          Name=${rig.name}
          Comment=${rig.comment}
          Exec=$SELF %F
          Icon=$HOME/.local/share/icons/hicolor/128x128/apps/${rig.id}.png
          Terminal=false
          DESKTOP
            chmod +x "$FTS_REAPER/${rig.name}.desktop"
            # Set custom icon metadata for Nautilus/GNOME
            gio set "$FTS_REAPER/${rig.name}.desktop" metadata::custom-icon "file://$HOME/.local/share/icons/hicolor/128x128/apps/${rig.id}.png" 2>/dev/null || true

            touch "$RIG_DIR/.setup-done"
          }

          # --setup: install icons/desktop entries without launching REAPER
          if [ "''${1:-}" = "--setup" ]; then
            setup
            echo "${rig.id}: setup complete"
            exit 0
          fi

          # Auto-setup on first run
          [ -f "$RIG_DIR/.setup-done" ] || setup

          exec "$LAUNCHER" --config "$CONFIG" "$@"
        '';

        # Single package containing all rig wrappers + reaper-launcher
        fts-rigs = pkgs.symlinkJoin {
          name = "fts-rigs";
          paths = (nixpkgs.lib.mapAttrsToList (_: mkRigWrapper) predefinedRigs) ++ [ reaper-launcher ];
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
        #   - creates ~/.fasttrackstudio/Reaper/ with a seed reaper.ini
        #   - writes launch.json for each rig (GUI REAPER, $HOME expanded)
        #   - generates per-rig badge icons via awk + rsvg-convert
        #   - symlinks rig wrappers and reaper-launcher to ~/.local/bin/
        #   - installs named .desktop entries to ~/.local/share/applications/
        setup-script = pkgs.writeShellScriptBin "fts-setup" ''
          set -euo pipefail

          REAPER_EXE="${prodPkgs.reaper}/bin/reaper"
          REAPER_CONFIG="$HOME/.fasttrackstudio/Reaper"
          LAUNCHER="${reaper-launcher}/bin/reaper-launcher"
          RIGS_PKG="${fts-rigs}"
          RSVG="${pkgs.librsvg}/bin/rsvg-convert"

          echo ""
          echo "  FTS Audio Production Setup"
          echo "  ──────────────────────────"

          # Directories
          mkdir -p "$REAPER_CONFIG"
          mkdir -p "$HOME/.config/fts/rigs"
          mkdir -p "$HOME/.local/bin"
          mkdir -p "$HOME/.local/share/applications"

          # Ensure hicolor index.theme exists (required for KDE Plasma icon lookup)
          HICOLOR="$HOME/.local/share/icons/hicolor"
          mkdir -p "$HICOLOR"
          if [ ! -f "$HICOLOR/index.theme" ]; then
            cat > "$HICOLOR/index.theme" << 'THEME'
          [Icon Theme]
          Name=Hicolor
          Comment=Fallback icon theme
          Hidden=true
          Directories=48x48/apps,128x128/apps,256x256/apps

          [48x48/apps]
          Size=48
          Context=Apps
          Type=Threshold

          [128x128/apps]
          Size=128
          Context=Apps
          Type=Threshold

          [256x256/apps]
          Size=256
          Context=Apps
          Type=Threshold
          THEME
            echo "  index.theme → $HICOLOR/index.theme"
          fi

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

          # Generate a badged icon at one size using awk (mirrors icon_gen::build_svg).
          # Usage: gen_icon_svg <size> <r> <g> <b> <badge_text>
          gen_icon_svg() {
            local size=$1 r=$2 g=$3 b=$4 badge=$5
            awk -v size="$size" -v r="$r" -v g="$g" -v b="$b" -v badge="$badge" '
            BEGIN {
              s = size + 0
              margin       = s * 0.06
              icon_size    = s - margin * 2
              corner_r     = icon_size * 0.18
              badge_w      = icon_size * 0.55
              badge_h      = icon_size * 0.16
              badge_x      = (s - badge_w) / 2
              badge_y      = s - margin - badge_h - icon_size * 0.08
              badge_rx     = badge_h / 2
              font_size    = badge_h * 0.55
              text_x       = s / 2
              text_y       = badge_y + badge_h / 2
              wf_x1        = s * 0.25
              wf_x2        = s * 0.75
              wf_cy        = s * 0.42
              wf_stroke    = s * 0.02
              border_r     = int(r * 0.5)
              border_g     = int(g * 0.5)
              border_b     = int(b * 0.5)

              printf "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n", size, size, size, size
              print "  <defs><filter id=\"s\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feDropShadow dx=\"0\" dy=\"1\" stdDeviation=\"2\" flood-color=\"rgba(0,0,0,0.6)\"/></filter></defs>"
              printf "  <rect x=\"%g\" y=\"%g\" width=\"%g\" height=\"%g\" rx=\"%g\" ry=\"%g\" fill=\"#2a2a2a\"/>\n", margin, margin, icon_size, icon_size, corner_r, corner_r
              printf "  <rect x=\"%g\" y=\"%g\" width=\"%g\" height=\"%g\" rx=\"%g\" ry=\"%g\" fill=\"rgba(%d,%d,%d,0.3)\"/>\n", margin, margin, icon_size, icon_size, corner_r, corner_r, r, g, b
              printf "  <line x1=\"%g\" y1=\"%g\" x2=\"%g\" y2=\"%g\" stroke=\"rgba(255,255,255,0.15)\" stroke-width=\"%g\"/>\n", wf_x1, wf_cy, wf_x2, wf_cy, wf_stroke
              printf "  <rect x=\"%g\" y=\"%g\" width=\"%g\" height=\"%g\" rx=\"%g\" ry=\"%g\" fill=\"rgba(%d,%d,%d,0.95)\" stroke=\"rgb(%d,%d,%d)\" stroke-width=\"1.5\" filter=\"url(#s)\"/>\n", badge_x, badge_y, badge_w, badge_h, badge_rx, badge_rx, r, g, b, border_r, border_g, border_b
              printf "  <text x=\"%g\" y=\"%g\" font-family=\"system-ui,-apple-system,sans-serif\" font-weight=\"bold\" font-size=\"%g\" fill=\"white\" text-anchor=\"middle\" dominant-baseline=\"central\">%s</text>\n", text_x, text_y, font_size, badge
              print "</svg>"
            }' /dev/null
          }

          # Install icons for one rig at 48, 128, 256px
          install_icons() {
            local id=$1 r=$2 g=$3 b=$4 badge=$5
            for size in 48 128 256; do
              local dir="$HOME/.local/share/icons/hicolor/''${size}x''${size}/apps"
              mkdir -p "$dir"
              gen_icon_svg "$size" "$r" "$g" "$b" "$badge" \
                | "$RSVG" -w "$size" -h "$size" - -o "$dir/$id.png"
            done
          }

          # Per-rig setup
          setup_rig() {
            local id="$1" name="$2" rig_type="$3" comment="$4" r="$5" g="$6" b="$7" badge="$8"

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

            # Icons (48, 128, 256px)
            install_icons "$id" "$r" "$g" "$b" "$badge"

            # .desktop entry — Icon= references the per-rig XDG icon name
            cat > "$HOME/.local/share/applications/$id.desktop" << DESKTOP
          [Desktop Entry]
          Type=Application
          Name=$name
          Comment=$comment
          Exec=$HOME/.local/bin/$id %F
          Icon=$id
          Terminal=false
          Categories=AudioVideo;Audio;
          StartupWMClass=REAPER
          Keywords=reaper;daw;signal;$rig_type;fasttrackstudio;
          DESKTOP

            echo "  $id → installed"
          }

          ${nixpkgs.lib.concatStringsSep "\n" (
            nixpkgs.lib.mapAttrsToList (_: rig: ''
              setup_rig "${rig.id}" "${rig.name}" "${rig.rig_type}" "${rig.comment}" \
                        "${toString rig.color.r}" "${toString rig.color.g}" "${toString rig.color.b}" \
                        "${rig.badge}"
            '') predefinedRigs
          )}

          # Refresh caches
          if command -v gtk-update-icon-cache &>/dev/null; then
            gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
          fi
          if command -v update-desktop-database &>/dev/null; then
            update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
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
          default = fts-rigs;
          inherit
            reaper-launcher
            fts-rigs
            ;
          fts-test = devPkgs.fts-test;
          fts-gui = devPkgs.fts-gui;
          reaper-fhs = devPkgs.reaper-fhs;
          setup = setup-script;
        }
        // nixpkgs.lib.mapAttrs' (_: rig: nixpkgs.lib.nameValuePair rig.id (mkRigWrapper rig)) predefinedRigs;

        apps = {
          default = {
            type = "app";
            program = "${setup-script}/bin/fts-setup";
          };
          setup = {
            type = "app";
            program = "${setup-script}/bin/fts-setup";
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
