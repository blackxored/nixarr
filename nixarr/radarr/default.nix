{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.nixarr.radarr;
  globals = config.util-nixarr.globals;
  nixarr = config.nixarr;
  defaultPort = 7878;

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
  in {
    key = name;
    serviceName = "radarr-${name}";
    enable = inst.enable;
    package = computedPackage;
    port = computedPort;
    stateDir = computedStateDir;
    librarySubDir = computedLibrarySubDir;
    vpnEnable = computedVpnEnable;
    openFirewall = computedOpenFirewall;
  };

  additionalInstances = imap1 normalizeInstance additionalInstancesRaw;

  baseInstance = {
    key = "default";
    serviceName = "radarr";
    enable = cfg.enable;
    package = cfg.package;
    port = cfg.port;
    stateDir = cfg.stateDir;
    librarySubDir = cfg.librarySubDir;
    vpnEnable = cfg.vpn.enable;
    openFirewall = cfg.openFirewall;
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
in {
  imports = [./settings-sync];

  options.nixarr.radarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Whether or not to enable the Radarr service.
      '';
    };

    package = mkPackageOption pkgs "radarr" {};

    port = mkOption {
      type = types.port;
      default = defaultPort;
      description = "Port for Radarr to use.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "${nixarr.stateDir}/radarr";
      defaultText = literalExpression ''"''${nixarr.stateDir}/radarr"'';
      example = "/nixarr/.state/radarr";
      description = ''
        The location of the state directory for the Radarr service.

        > **Warning:** Setting this to any path, where the subpath is not
        > owned by root, will fail! For example:
        >
        > ```nix
        >   stateDir = /home/user/nixarr/.state/radarr
        > ```
        >
        > Is not supported, because `/home/user` is owned by `user`.
      '';
    };

    librarySubDir = mkOption {
      type = types.str;
      default = "movies";
      example = "movies-uhd";
      description = ''
        Subdirectory under `${nixarr.mediaDir}/library` that Radarr manages.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = "Open firewall for Radarr";
    };

    vpn.enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        **Required options:** [`nixarr.vpn.enable`](#nixarr.vpn.enable)

        Route Radarr traffic through the VPN.
      '';
    };

    vpn.configureNginx = mkOption {
      type = types.bool;
      default = cfg.vpn.enable;
      example = false;
      description = ''
        **Required options:** [`nixarr.radarr.vpn.enable`)(#nixarr.radarr.vpn.enable)

        Configure nginx as a reverse proxy for the Radarr web ui.
      '';
      defaultText = literalExpression "nixarr.radarr.vpn.enable";
    };

    instances = mkOption {
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to enable this Radarr instance.";
          };

          package = mkOption {
            type = types.nullOr types.package;
            default = null;
            description = "Package to use for this Radarr instance.";
          };

          port = mkOption {
            type = types.nullOr types.port;
            default = null;
            description = ''
              Port for this Radarr instance. If unset, one will be assigned
              automatically based on `nixarr.radarr.port`.
            '';
          };

          stateDir = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''
              Override the state directory for this instance. Defaults to
              `"''${nixarr.stateDir}/radarr-${name}"`.
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
              `nixarr.radarr.vpn.enable`.
            '';
          };
        };
      }));
      default = {};
      example = literalExpression ''
        {
          "4k" = {
            port = 7879;
            librarySubDir = "movies-4k";
          };
          kids.port = 7880;
        }
      '';
      description = ''
        Additional Radarr instances keyed by a name that is appended to the
        service name (e.g. `radarr-4k`).
      '';
    };
  };

  config = mkIf (nixarr.enable && anyEnabled) {
    assertions = [
      {
        assertion = cfg.vpn.enable -> nixarr.vpn.enable;
        message = ''
          The nixarr.radarr.vpn.enable option requires the
          nixarr.vpn.enable option to be set, but it was not.
        '';
      }
      {
        assertion = cfg.vpn.configureNginx -> cfg.vpn.enable;
        message = ''
          The nixarr.radarr.vpn.configureNginx option requires the
          nixarr.radarr.vpn.enable option to be set, but it was not.
        '';
      }
      {
        assertion = (vpnInstances == []) || nixarr.vpn.enable;
        message = "All Radarr instances that enable VPN require nixarr.vpn.enable.";
      }
      {
        assertion = length ports == length (unique ports);
        message = "Each Radarr instance must use a unique port.";
      }
    ];

    systemd.tmpfiles.rules =
      [
        "d '${mediaLibraryDir}' 2775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      ]
      ++ map (
        dir: "d '${dir}' 2775 ${globals.libraryOwner.user} ${globals.libraryOwner.group} - -"
      )
      mediaSubDirs
      ++ map (
        dir: "d '${dir}' 0700 ${globals.radarr.user} root - -"
      )
      stateDirs;

    users = {
      groups.${globals.radarr.group}.gid = globals.gids.${globals.radarr.group};
      users.${globals.radarr.user} = {
        isSystemUser = true;
        group = globals.radarr.group;
        uid = globals.uids.${globals.radarr.user};
      };
    };

    services.radarr = {
      enable = cfg.enable;
      package = cfg.package;
      user = globals.radarr.user;
      group = globals.radarr.group;
      settings.server.port = cfg.port;
      openFirewall = cfg.openFirewall;
      dataDir = cfg.stateDir;
    };

    # Port mappings
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

    networking.firewall = mkIf (openFirewallInstances != []) {
      allowedTCPPorts = map (instance: instance.port) openFirewallInstances;
    };

    systemd.services =
      {
        # Enable and specify VPN namespace to confine service in.
        radarr.vpnConfinement = mkIf cfg.vpn.enable {
          enable = true;
          vpnNamespace = "wg";
        };
      }
      // mkMerge (
        (map (
            instance: {
              ${instance.serviceName} = {
                description =
                  "Radarr"
                  + (
                    if instance.serviceName != "radarr"
                    then " (${instance.key})"
                    else ""
                  );
                after = ["network.target"];
                wantedBy = ["multi-user.target"];
                environment.RADARR__SERVER__PORT = builtins.toString instance.port;
                serviceConfig = {
                  Type = "simple";
                  User = globals.radarr.user;
                  Group = globals.radarr.group;
                  ExecStart = "${lib.getExe instance.package} -nobrowser -data=${lib.escapeShellArg instance.stateDir}";
                  Restart = "on-failure";
                  # Set UMask to 0002 so directories are created with group write permission (775)
                  # This allows other services in the media group (like Jellyfin) to modify files
                  UMask = lib.mkForce "002";
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
