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

      ftsReaperConfig = "$HOME/.fasttrackstudio/Reaper";
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

        # ── reaper-launcher ───────────────────────────────────────────────
        # Builds just the reaper-launcher binary from the daw workspace source.
        # reaper-launcher only depends on libc, serde, serde_json — pure Rust,
        # no native deps — so this builds cleanly without the rest of the workspace.
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
          inherit reaper-launcher;
        };

        devShells.default = pkgs.mkShell {
          packages =
            [
              devPkgs.fts-test
              devPkgs.fts-gui
              devPkgs.reaper-fhs
              reaper-launcher
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
            export FTS_REAPER_CONFIG="$HOME/.fasttrackstudio/Reaper"
            echo ""
            echo "  fts-reaper-flake dev shell"
            echo "  ─────────────────────────────────────────"
            echo "  fts-test [cmd]  — headless REAPER FHS env"
            echo "  fts-gui         — launch REAPER with GUI"
            echo "  reaper-launcher — rig launcher binary"
            echo ""
            echo "  REAPER: ${devPkgs.reaper}/bin/reaper"
            echo ""
          '';
        };
      }
    );
}
