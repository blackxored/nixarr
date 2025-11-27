{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.nixarr.sonarr;
  globals = config.util-nixarr.globals;
  nixarr = config.nixarr;
  arrLib = config.util-nixarr.arrLib;
  defaultPort = 8989;
  additionalInstancesRaw =
    mapAttrsToList (
      name: instanceCfg: instanceCfg // {__name = name;}
    )
    cfg.instances;

  normalizeInstance = index: inst: let
    name = inst.__name;
    computedPort =
      if inst.port != null
      then inst.port
      else cfg.port + index;
    computedPackage =
      if inst.package != null
      then inst.package
      else cfg.package;
    computedVpnEnable =
      if inst.vpn.enable != null
      then inst.vpn.enable
      else cfg.vpn.enable;
    computedOpenFirewall =
      if inst.openFirewall != null
      then inst.openFirewall
      else !computedVpnEnable;
    computedStateDir =
      if inst.stateDir != null
      then inst.stateDir
      else "${cfg.stateDir}-${name}";
    computedLibrarySubDir =
      if inst.librarySubDir != null
      then inst.librarySubDir
      else "${cfg.librarySubDir}-${name}";
    computedGuiSettings =
      recursiveUpdate cfg.guiSettings (inst.guiSettings or {});
    computedEnableDeclarative =
      if inst.declarative != null
      then inst.declarative
      else cfg.declarative;
    computedApiKeyFile =
      if inst.apiKeyFile != null
      then inst.apiKeyFile
      else cfg.apiKeyFile;
  in {
    key = name;
    serviceName = "sonarr-${name}";
    enable = inst.enable;
    package = computedPackage;
    port = computedPort;
    stateDir = computedStateDir;
    librarySubDir = computedLibrarySubDir;
    vpnEnable = computedVpnEnable;
    openFirewall = computedOpenFirewall;
    declarative = computedEnableDeclarative;
    apiKeyFile = computedApiKeyFile;
    guiSettings = computedGuiSettings;
  };

  additionalInstances = imap1 normalizeInstance additionalInstancesRaw;

  baseInstance = {
    key = "default";
    serviceName = "sonarr";
    enable = cfg.enable;
    package = cfg.package;
    port = cfg.port;
    stateDir = cfg.stateDir;
    librarySubDir = cfg.librarySubDir;
    vpnEnable = cfg.vpn.enable;
    openFirewall = cfg.openFirewall;
    declarative = cfg.declarative;
    apiKeyFile = cfg.apiKeyFile;
    guiSettings = cfg.guiSettings;
  };

  allInstances = [baseInstance] ++ additionalInstances;

  enabledInstances = filter (instance: instance.enable) allInstances;

  vpnInstances =
    filter (
      instance: instance.enable && instance.vpnEnable
    )
    allInstances;

  openFirewallInstances =
    filter (
      instance: instance.enable && instance.openFirewall
    )
    allInstances;

  anyEnabled = enabledInstances != [];

  mediaLibraryDir = "${nixarr.mediaDir}/library";

  mediaSubDirs = unique (
    map (instance: "${mediaLibraryDir}/${instance.librarySubDir}") enabledInstances
  );

  stateDirs = unique (map (instance: instance.stateDir) enabledInstances);

  ports = map (instance: instance.port) enabledInstances;

  mkInstanceInitScript = instance:
    arrLib.mkArrInitScript {
      serviceName = "sonarr";
      instanceName = instance.serviceName;
      apiPath = "api/v3";
      package = instance.package;
      dataDir = instance.stateDir;
      apiKeyFile = instance.apiKeyFile;
      port = instance.port;
      guiSettings = instance.guiSettings;

      enableNaming = true;
      namingDefault = {
        renameEpisodes = true;
        replaceIllegalCharacters = true;
        colonReplacementFormat = 4;
        customColonReplacementFormat = "";
        # TODO: confirm is Prefixed Range
        multiEpisodeStyle = 5;
        standardEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}";
        dailyEpisodeFormat = "{Series TitleYear} - {Air-Date} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}";
        animeEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle:90} {[Custom Formats]}{[Quality Full]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoDynamicRangeType]}[{Mediainfo VideoCodec }{MediaInfo VideoBitDepth}bit]{-Release Group}";
        seriesFolderFormat = "{Series TitleYear}";
        seasonFolderFormat = "Season {season:00}";
        specialsFolderFormat = "Specials";
      };
      enableRootFolders = true;
      enableMediaManagement = true;
    };
in {
  imports = [./settings-sync];

  options.nixarr.sonarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Whether or not to enable the Sonarr service.
      '';
    };

    package = mkPackageOption pkgs "sonarr" {};

    port = mkOption {
      type = types.port;
      default = defaultPort;
      description = "Port for Sonarr to use.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "${nixarr.stateDir}/sonarr";
      defaultText = literalExpression ''"''${nixarr.stateDir}/sonarr"'';
      example = "/nixarr/.state/sonarr";
      description = ''
        The location of the state directory for the Sonarr service.

        > **Warning:** Setting this to any path, where the subpath is not
        > owned by root, will fail! For example:
        >
        > ```nix
        >   stateDir = /home/user/nixarr/.state/sonarr
        > ```
        >
        > Is not supported, because `/home/user` is owned by `user`.
      '';
    };

    librarySubDir = mkOption {
      type = types.str;
      default = "shows";
      example = "shows-uhd";
      description = ''
        Subdirectory under `${nixarr.mediaDir}/library` that Sonarr manages.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = "Open firewall for Sonarr";
    };

    vpn.enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        **Required options:** [`nixarr.vpn.enable`](#nixarr.vpn.enable)

        Route Sonarr traffic through the VPN.
      '';
    };

    vpn.configureNginx = mkOption {
      type = types.bool;
      default = cfg.vpn.enable;
      example = false;
      description = ''
        **Required options:** [`nixarr.sonarr.vpn.enable`)(#nixarr.sonarr.vpn.enable)

        Configure nginx as a reverse proxy for the Sonarr web ui.
      '';
      defaultText = literalExpression "nixarr.sonarr.vpn.enable";
    };

    declarative = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Enable declarative initialization and configuration via API.
        When enabled, Sonarr will be configured on first start using the
        settings defined in `guiSettings`.

        **Requires:** `apiKeyFile` to be set.
      '';
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/sonarr-apikey";
      description = ''
        Path to file containing the API key for Sonarr.
        Required when `enableInit` is true.
      '';
    };

    guiSettings = mkOption {
      type = arrLib.mkGuiSettingsType {
        serviceName = "sonarr";
        enableRootFolders = true;
        enableNaming = true;
        enableMediaManagement = true;
      };
      default = {};
      example = literalExpression ''
          host.password = config.sops.secrets."sonarr-password".path;
          rootFolders = ["/media/tv"];
          downloadClients = {
            qBittorrent = {
              implementation = "QBittorrent";
              fields = {
                host = "localhost";
                port = 8080;
                username = "admin";
                password = "/run/secrets/qbit-password";
              };
            };
          };
        }
      '';
      description = ''
        Declarative configuration for Sonarr via API.
        Only used when `declarative` is true.

        Note: Quality Profiles and Naming should be managed via recyclarr instead.
      '';
    };

    instances = mkOption {
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to enable this Sonarr instance.";
          };

          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Package to use for this Sonarr instance.";
          };

          port = mkOption {
            type = types.nullOr types.port;
            default = null;
            description = ''
              Port for this Sonarr instance. If unset, one will be assigned
              automatically based on `nixarr.sonarr.port`.
            '';
          };

          stateDir = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''
              Override the state directory for this instance. Defaults to
              `"''${nixarr.stateDir}/sonarr-${name}"`.
            '';
          };

          librarySubDir = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Override the media library subdirectory for this instance.
              Defaults to `"''${cfg.librarySubDir}-${name}"`.
            '';
          };

          openFirewall = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = ''
              Whether to open the firewall for this instance. Defaults to the
              inverse of the resolved VPN setting.
            '';
          };

          vpn.enable = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = ''
              Route traffic for this instance through the VPN. Defaults to
              `nixarr.sonarr.vpn.enable`.
            '';
          };

          declarative = mkOption {
            type = types.nullOr types.bool;
            default = null;
            # TODO: explain default behavior
            description = ''
              Override `declarative` for this instance.
            '';
          };

          apiKeyFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Override the API key file for this instance.
              Defaults to `nixarr.sonarr.apiKeyFile`;
            '';
          };

          guiSettings = mkOption {
            type = arrLib.mkGuiSettingsType {
              serviceName = "sonarr";
              enableRootFolders = true;
              enableMediaManagement = true;
            };
            default = {};
            description = ''
              Override or extend GUI settings for this instance.
              These are recursively merged with the base `guiSettings`.
            '';
          };
        };
      }));
      default = {};
      example = literalExpression ''
        {
          "4k" = {
            port = 8990;
            librarySubDir = "shows-4k";
          };
          anime.port = 8991;
        }
      '';
      description = ''
        Additional Sonarr instances keyed by a name that is appended to the
        service name (e.g. `sonarr-anime`).
      '';
    };

    jellyseerrServerId = mkOption {
      type = types.int;
    };

    enabledInstances = mkOption {
      type = types.unspecified;
      visible = false;
      internal = true;
      readOnly = true;
      default = enabledInstances;
    };
  };

  config = mkIf (nixarr.enable && anyEnabled) {
    assertions = [
      {
        assertion = cfg.vpn.configureNginx -> cfg.vpn.enable;
        message = ''
          The nixarr.sonarr.vpn.configureNginx option requires the
          nixarr.sonarr.vpn.enable option to be set, but it was not.
        '';
      }
      {
        assertion = (vpnInstances == []) || nixarr.vpn.enable;
        message = "All Sonarr instances that enable VPN require nixarr.vpn.enable.";
      }
      {
        assertion = length ports == length (unique ports);
        message = "Each Sonarr instance must use a unique port.";
      }
      {
        assertion = all (inst: !inst.declarative || inst.apiKeyFile != null) enabledInstances;
        message = "All Sonarr instances with declarative=true must have apiKeyFile set.";
      }
    ];

    users = {
      groups.${globals.sonarr.group}.gid = globals.gids.${globals.sonarr.group};
      users.${globals.sonarr.user} = {
        isSystemUser = true;
        group = globals.sonarr.group;
        uid = globals.uids.${globals.sonarr.user};
      };
    };

    systemd.tmpfiles.rules =
      [
        "d '${mediaLibraryDir}' 2775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      ]
      ++ map (
        dir: "d '${dir}' 2775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      )
      mediaSubDirs
      ++ map (
        dir: "d '${dir}' 0700 ${globals.sonarr.user} root - -"
      )
      stateDirs;

    networking.firewall = mkIf (openFirewallInstances != []) {
      allowedTCPPorts = map (instance: instance.port) openFirewallInstances;
    };

    systemd.services =
      {
        # Enable and specify VPN namespace to confine service in.
        sonarr.vpnConfinement = mkIf cfg.vpn.enable {
          enable = true;
          vpnNamespace = "wg";
        };
      }
      // mkMerge (
        (map (
            instance: let
              initScript = mkInstanceInitScript instance;
            in {
              ${instance.serviceName} = {
                description =
                  "Sonarr"
                  + (
                    if instance.serviceName != "sonarr"
                    then " (${instance.key})"
                    else ""
                  );
                after = ["network.target"];
                wantedBy = ["multi-user.target"];
                environment.SONARR__SERVER__PORT = builtins.toString instance.port;
                serviceConfig = {
                  Type = "simple";
                  User = globals.sonarr.user;
                  Group = globals.sonarr.group;
                  ExecStart =
                    if instance.declarative
                    then "${lib.getExe initScript}"
                    else "${lib.getExe instance.package} -nobrowser -data=${lib.escapeShellArg instance.stateDir}";
                  Restart = "on-failure";
                };
              };
            }
          )
          enabledInstances)
        ++ (map (
            instance:
              mkIf instance.vpnEnable {
                ${instance.serviceName}.vpnConfinement = {
                  enable = true;
                  vpnNamespace = "wg";
                };
              }
          )
          enabledInstances)
      );

    vpnNamespaces.wg = mkIf (vpnInstances != []) {
      portMappings =
        map (
          instance: {
            from = instance.port;
            to = instance.port;
          }
        )
        vpnInstances;
    };

    services.nginx = mkIf (vpnInstances != []) {
      enable = true;

      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;

      virtualHosts = listToAttrs (
        map (
          instance: let
            portString = builtins.toString instance.port;
          in {
            name = "127.0.0.1:${portString}";
            value = {
              listen = [
                {
                  addr = instance.vpn.proxyListenAddr;
                  port = instance.port;
                }
              ];
              locations."/" = {
                recommendedProxySettings = true;
                proxyWebsockets = true;
                proxyPass = "http://192.168.15.1:${portString}";
              };
            };
          }
        )
        vpnInstances
      );
    };
  };
}
