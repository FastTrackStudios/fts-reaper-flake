{
  description = "fts-reaper-flake — FTS audio production environment (REAPER + plugins + audio libs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    reaper-flake.url = "github:FastTrackStudios/reaper-flake";
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
    } @ inputs:
    let
      # ── mkFtsPackages ─────────────────────────────────────────────────────
      # Wraps reaper-flake.lib.mkReaperPackages and adds fts-* aliases so
      # consumers don't need to know the underlying reaper-flake names.
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

      # Re-export reaper-flake presets so consumers can reference them directly.
      presets = reaper-flake.presets;

      ftsReaperConfig = "$HOME/.config/FastTrackStudio/Reaper";
    in
    {
      inherit presets;
      lib.mkFtsPackages = mkFtsPackages;

      # home-manager module — declarative FTS REAPER rig management.
      # See modules/home.nix for options and usage.
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

        # ── Audio production library set ──────────────────────────────────
        # Full set of native libs needed for CLAP/VST plugins and DAW tools.
        audioProductionLibs = with pkgs; [
          # X11 / windowing (baseview, raw-window-handle, x11 crate)
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

          # GPU / Vulkan (wgpu backend)
          vulkan-loader
          vulkan-headers
          vulkan-tools
          libGL
          mesa

          # GTK / GLib (file dialogs, clipboard, tray)
          gtk3
          glib
          gdk-pixbuf
          pango
          cairo
          atk

          # Wayland (optional secondary backend)
          wayland
          wayland-protocols

          # Font rendering
          fontconfig
          freetype

          # Audio
          alsa-lib
          pipewire.jack
          rubberband

          # C/C++ bindgen (signalsmith-stretch and other C wrappers)
          llvmPackages.libclang

          # Misc
          dbus
          zlib
          stdenv.cc.cc.lib
        ];
      in
      {
        packages = {
          default = devPkgs.fts-test;
          fts-test = devPkgs.fts-test;
          fts-gui = devPkgs.fts-gui;
          reaper-fhs = devPkgs.reaper-fhs;
        };

        devShells.default = pkgs.mkShell {
          packages =
            [
              devPkgs.fts-test
              devPkgs.fts-gui
              devPkgs.reaper-fhs
              pkgs.pkg-config
              pkgs.openssl
            ]
            ++ audioProductionLibs;

          # Static store-path env vars set directly
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
            export FTS_REAPER_CONFIG="$HOME/.config/FastTrackStudio/Reaper"
            echo ""
            echo "  fts-reaper-flake dev shell"
            echo "  ─────────────────────────────────────────"
            echo "  fts-test [cmd]  — headless REAPER FHS env"
            echo "  fts-gui         — launch REAPER with GUI"
            echo ""
            echo "  REAPER: ${devPkgs.reaper}/bin/reaper"
            echo ""
          '';
        };
      }
    );
}
