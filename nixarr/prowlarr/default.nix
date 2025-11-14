{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.nixarr.prowlarr;
  globals = config.util-nixarr.globals;
  nixarr = config.nixarr;
  arrLib = config.util-nixarr.arrLib;
  port = 9696;
  configPath = cfg.stateDir + "/config.json";

  mkInstanceInitScript = instance:
    arrLib.mkArrInitScript {
      serviceName = "prowlarr";
      instanceName = instance.serviceName;
      apiPath = "api/v1";
      package = instance.package;
      dataDir = instance.dataDir;
      apiKeyFile = instance.apiKeyFile;
      port = instance.port;
      guiSettings = instance.guiSettings;

      enableIndexers = true;
      enableIndexerProxies = true;
      enableApplications = true;
    };
in {
  imports = [./settings-sync];

  options.nixarr.prowlarr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Whether or not to enable the Prowlarr service. This has
        a seperate service since running two instances is the standard
        way of being able to query both ebooks and audiobooks.
      '';
    };

    package = mkPackageOption pkgs "prowlarr" {};

    port = mkOption {
      type = types.port;
      default = port;
      description = "Port for Prowlarr to use.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "${nixarr.stateDir}/prowlarr";
      defaultText = literalExpression ''"''${nixarr.stateDir}/prowlarr"'';
      example = "/nixarr/.state/prowlarr";
      description = ''
        The location of the state directory for the Prowlarr service.

        > **Warning:** Setting this to any path, where the subpath is not
        > owned by root, will fail! For example:
        >
        > ```nix
        >   stateDir = /home/user/nixarr/.state/prowlarr
        > ```
        >
        > Is not supported, because `/home/user` is owned by `user`.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = "Open firewall for Prowlarr";
    };

    vpn.enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        **Required options:** [`nixarr.vpn.enable`](#nixarr.vpn.enable)

        Route Prowlarr traffic through the VPN.
      '';
    };

    vpn.configureNginx = mkOption {
      type = types.bool;
      default = cfg.vpn.enable;
      example = false;
      description = ''
        **Required options:** [`nixarr.prowlarr.vpn.enable`)(#nixarr.prowlarr.vpn.enable)

        Configure nginx as a reverse proxy for the Prowlarrweb ui.
      '';
      defaultText = literalExpression "nixarr.prowlarr.vpn.enable";
    };

    declarative = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Enable declarative initialization and configuration via API.
        When enabled, Prowlarr will be configured on first start using the
        settings defined in `guiSettings`.

        **Requires:** `apiKeyFile` to be set.
      '';
    };

    apiKeyFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/secrets/prowlarr_api_key";
      description = ''
        Path to file containing the API key for Prowlarr.
        Required when `declarative` is true.
      '';
    };

    guiSettings = mkOption {
      type = arrLib.mkGuiSettingsType {
        serviceName = "prowlarr";

        enableIndexers = true;
        enableIndexerProxies = true;
        enableApplications = true;
      };
      default = {};
      # TODO: indexer example
      example = literalExpression ''
        host.password = config.sops.secrets."prowlarr_password".path;
      '';
      description = ''
        Declarative configuration for Prowlarr via API.
        Only used when `declarative` is true.

        Note: Quality Profiles and Naming should be managed via recyclarr instead.
      '';
    };
  };

  config = mkIf (nixarr.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.vpn.enable -> nixarr.vpn.enable;
        message = ''
          The nixarr.prowlarr.vpn.enable option requires the
          nixarr.vpn.enable option to be set, but it was not.
        '';
      }
      {
        assertion = cfg.vpn.configureNginx -> cfg.vpn.enable;
        message = ''
          The nixarr.prowlarr.vpn.configureNginx option requires the
          nixarr.prowlarr.vpn.enable option to be set, but it was not.
        '';
      }
    ];

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0700 ${globals.prowlarr.user} root - -"
    ];

    services.prowlarr = {
      enable = cfg.enable;
      package = cfg.package;
      settings.server.port = cfg.port;
      openFirewall = cfg.openFirewall;
    };

    systemd.services.prowlarr = {
      serviceConfig = let
        initScript = mkInstanceInitScript {
          inherit (cfg) package port apiKeyFile guiSettings;
          serviceName = "prowlarr";
          dataDir = cfg.stateDir;
        };
      in {
        # `User` and `Group` override `DynamicUser = true` from the NixOS Prowlarr
        # module (because a user and group with those names exists).
        User = globals.prowlarr.user;
        Group = globals.prowlarr.group;
        # ExecStart = mkForce "${lib.getExe cfg.package} -nobrowser -data=${cfg.stateDir}";
        ReadWritePaths = [cfg.stateDir];
        ExecStart = lib.mkForce (
          if cfg.declarative
          then "${lib.getExe initScript}"
          else "${lib.getExe cfg.package} -nobrowser -data=${lib.escapeShellArg cfg.stateDir}"
        );
        Restart = "on-failure";
      };

      # Enable and specify VPN namespace to confine service in.
      vpnConfinement = mkIf cfg.vpn.enable {
        enable = true;
        vpnNamespace = "wg";
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [cfg.port];
    };

    users = {
      groups.${globals.prowlarr.group}.gid = globals.gids.${globals.prowlarr.group};
      users.${globals.prowlarr.user} = {
        isSystemUser = true;
        group = globals.prowlarr.group;
        uid = globals.uids.${globals.prowlarr.user};
      };
    };

    vpnNamespaces.wg = mkIf cfg.vpn.enable {
      portMappings = [
        {
          from = cfg.port;
          to = cfg.port;
        }
      ];
    };
    services.nginx = mkIf cfg.vpn.configureNginx {
      enable = true;

      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;

      virtualHosts."127.0.0.1:${builtins.toString cfg.port}" = {
        listen = [
          {
            addr = nixarr.vpn.proxyListenAddr;
            port = cfg.port;
          }
        ];
        locations."/" = {
          recommendedProxySettings = true;
          proxyWebsockets = true;
          proxyPass = "http://192.168.15.1:${builtins.toString cfg.port}";
        };
      };
    };
  };
}
