# home-manager module for FTS REAPER rigs.
#
# Declaratively installs launch.json configs, wrapper scripts, and .desktop
# entries for predefined FTS instrument rigs. Each rig is a named REAPER
# instance with a fixed role and rig_type, configured for signal capture.
#
# Usage in home-manager:
#
#   imports = [ fts-reaper-flake.homeManagerModules.default ];
#
#   fts.reaper = {
#     enable = true;
#     package = fts-reaper-flake.packages.${system}.reaper;  # or pkgs.reaper
#     rigs.all = true;           # enable all predefined rigs, or pick individually:
#     rigs.keys = true;
#     rigs.drums = true;
#   };
{ config, lib, pkgs, ... }:
let
  cfg = config.fts.reaper;

  # ── Predefined rig definitions ─────────────────────────────────────────
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

  # ── File generators ────────────────────────────────────────────────────

  mkLaunchJson = rig: builtins.toJSON {
    role = "signal";
    rig_type = rig.rig_type;
    reaper_executable = "${cfg.package}/bin/reaper";
    resources_dir = cfg.configDir;
    ini_path = "${cfg.configDir}/reaper.ini";
    ini_overrides = { undo_max_mem = 0; };
    restore_ini_after_launch = false;
    reaper_args = [ "-newinst" "-nosplash" "-ignoreerrors" ];
  };

  mkWrapperScript = rig: ''
    #!/usr/bin/env bash
    exec "${config.home.homeDirectory}/.local/bin/reaper-launcher" \
      --config "${config.home.homeDirectory}/.config/fts/rigs/${rig.id}/launch.json" \
      "$@"
  '';

  mkDesktopEntry = rig: ''
    [Desktop Entry]
    Type=Application
    Name=${rig.name}
    Comment=${rig.comment}
    Exec=${config.home.homeDirectory}/.local/bin/${rig.id} %F
    Icon=${rig.id}
    Terminal=false
    Categories=AudioVideo;Audio;
    StartupWMClass=REAPER
    Keywords=reaper;daw;signal;${rig.rig_type};fasttrackstudio;
  '';

  # Which rigs to actually install
  rigEnabled = name: cfg.rigs.all || cfg.rigs.${name};
  enabledRigs = lib.filterAttrs (name: _: rigEnabled name) predefinedRigs;

  # Build home.file entries for one rig
  rigFiles = _name: rig: {
    ".config/fts/rigs/${rig.id}/launch.json".text = mkLaunchJson rig;
    ".local/bin/${rig.id}" = {
      text = mkWrapperScript rig;
      executable = true;
    };
    ".local/share/applications/${rig.id}.desktop".text = mkDesktopEntry rig;
  };
in
{
  options.fts.reaper = {
    enable = lib.mkEnableOption "FTS REAPER rig management";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The REAPER package to use. The executable at ''${package}/bin/reaper
        is embedded in each rig''s launch.json.

        Use reaper-flake''s packages.reaper for a properly patched build, or
        pkgs.reaper from nixpkgs (requires allowUnfree).
      '';
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.fasttrackstudio/Reaper";
      description = ''
        REAPER config and resources directory. Written into each rig''s
        launch.json as resources_dir and the ini_path base.
      '';
    };

    rigs = {
      all = lib.mkEnableOption "all predefined FTS signal rigs";
      keys   = lib.mkEnableOption "FTS Keys rig (keyboard instruments)";
      drums  = lib.mkEnableOption "FTS Drums rig (drums and percussion)";
      bass   = lib.mkEnableOption "FTS Bass rig";
      guitar = lib.mkEnableOption "FTS Guitar rig";
      vocals = lib.mkEnableOption "FTS Vocals rig";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = lib.mkMerge (
      lib.mapAttrsToList rigFiles enabledRigs
    );
  };
}
