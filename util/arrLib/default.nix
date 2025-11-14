{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;

  curl_base = api_key_path: base_url: type: url: t: data:
  # bash
  ''
    cat "${pkgs.writeText "data.json" (builtins.toJSON data)}" \
    ${t}| curl \
        --silent \
        --show-error \
        --retry 3 \
        --retry-connrefused \
        --url "${base_url}${url}" \
        -X ${type} \
        -H "X-Api-Key: $(cat "${api_key_path}")" \
        -H "Content-Type: application/json" \
        --data-binary @-'';

  json-file-resolve =
    pkgs.writers.writePython3Bin "json-file-resolve" {
      libraries = with pkgs.python3Packages; [
        jsonpath-ng
      ];
    } ''
      import json
      import jsonpath_ng.ext as jsonpath
      import sys
      import os


      def func(_, data, field):
          credentials_dir = os.getenv("CREDENTIALS_DIRECTORY")
          if credentials_dir:
              file_path = data[field].replace("%d/", credentials_dir + "/")
          else:
              file_path = data[field]

          with open(file_path) as f:
              return f.read().strip()


      json_data_raw = sys.stdin.read()
      data = json.loads(json_data_raw)

      for arg in sys.argv[1:]:
          jsonpath.parse(arg).update(data, func)

      print(json.dumps(data, indent=2))
    '';

  mkArrContract = d:
    d
    // {
      enable = true;
      configContract = "${d.implementation}Settings";
      fields =
        lib.mapAttrsToList (n: v: {
          name = n;
          value = v;
        })
        d.fields;
    };

  # Core reusable function that generates init script for any instance
  mkArrInitScript = {
    serviceName, # e.g., "sonarr"
    instanceName, # e.g., "sonarr-4k"
    apiPath, # e.g., "api/v3"
    package, # The package to run
    dataDir, # Where data is stored
    apiKeyFile, # Path to API key file
    port, # Port number
    urlBase ? "", # Optional URL base
    guiSettings, # The settings configuration
    # Feature flags
    enableRootFolders ? false,
    enableNaming ? false,
    namingDefault ? {},
    enableMediaManagement ? false,
    enableIndexers ? false,
    enableIndexerProxies ? false,
    enableApplications ? false,
  }: let
    s = guiSettings;

    appUrl = lib.concatStringsSep "/" (lib.filter (x: x != "") [
      "http://localhost:${toString port}"
      urlBase
      apiPath
    ]);

    curl' = curl_base apiKeyFile appUrl;
    curl = type: url: curl' type url "";

    tryGetAttrs = g: attrs: (
      lib.getAttrs (lib.intersectLists (lib.attrNames attrs) g) attrs
    );

    tags = lib.pipe s [
      (tryGetAttrs ["indexers" "indexerProxies"])
      lib.attrValues
      (lib.map (a: lib.mapAttrsToList (_: v: v.tags or []) a))
      lib.concatLists
      lib.concatLists
      lib.unique
    ];

    mapTags = let
      tm = lib.pipe tags [
        (lib.imap1 (i: v: {
          name = v;
          value = i;
        }))
        lib.listToAttrs
      ];
    in
      d: {
        tags = lib.map (t: tm.${t}) (d.tags or []);
      };

    mapArrReqs' = name: apiPath: cond: data:
      lib.optionalString cond
      # bash
      ''
        echo "Deleting old ${name}"
        delete-all "${apiPath}"

        echo "Creating ${name}"
        ${lib.concatStringsSep "\n\n" data}
      '';

    mapArrReqs = name: apiPath: cond: attrs: f:
      mapArrReqs' name apiPath cond (
        lib.imap1 f
        (lib.mapAttrsToList
          (n: v: {name = n;} // v)
          attrs)
      );

    apiKeyEnvVar = "${lib.toUpper serviceName}__AUTH__APIKEY";
  in
    pkgs.writeShellApplication {
      name = "${instanceName}-init";
      extraShellCheckFlags = ["-S" "error"];
      runtimeInputs = with pkgs; [
        sqlite
        openssl
        unixtools.xxd
        pkgs.curl
        jq
        util-linux
        json-file-resolve
      ];
      text =
        # bash
        ''
          db_file="${dataDir}/${serviceName}.db"

          echo "Starting ${instanceName} to generate db..."

          ${apiKeyEnvVar}=$(cat ${apiKeyFile}) \
            ${lib.getExe package} \
            -nobrowser \
            -data="${dataDir}"&

          echo "Waiting for db to be created..."
          until [ -f "$db_file" ]
          do
            sleep 1
          done

          echo "Waiting for the users table to be created..."
          while true; do
            sqlite3 "$db_file" "
              SELECT 1 FROM sqlite_master
              WHERE type='table'
              AND name='users';
            " > /dev/null 2>&1

            if [ $? -eq 0 ]; then
              break
            fi

            sleep 1
          done

          echo "Waiting for other tables to be created"
          sleep 5

          echo "Sending api requests to configure application"

          ${curl' "PUT" "/config/host/1" ''
              | json-file-resolve \
                '$.password' \
                '$.passwordConfirmation' \
                '$.apikey' \
            '' ({
                id = 1;
                apiKey = apiKeyFile;
                analyticsEnabled = false;
                authenticationMethod = "basic"; # For Authentik. Default: "forms".
                authenticationRequired = "enabled";
                username = s.host.username or "";
                passwordConfirmation = s.host.password or "";
                backupInterval = 7;
                backupRetention = 28;
                port = port;
                urlBase = urlBase;
                bindAddress = "*";
                proxyEnabled = false;
                sslCertPath = "";
                sslCertPassword = "";
                instanceName = instanceName;
                branch = "master";
                logLevel = "debug";
                consoleLogLevel = "";
                logSizeLimit = 1;
                updateScriptPath = "";
              }
              // (s.host or {}))}

          echo "Configuring naming"
          ${lib.optionalString enableNaming (
            curl "PUT" "/config/naming/1" (
              {id = 1;}
              // namingDefault
              // s.naming
            )
          )}

          echo "Configuring media management"
          ${lib.optionalString enableMediaManagement (
            curl "PUT" "/config/mediamanagement/1" ({
                id = 1;
                autoUnmonitorPreviouslyDownloadedEpisodes = false;
                # TODO: does this need to be true?
                setPermissionsLinux = false;
                chmodFolder = "775";
                # TODO: nixarr's guide only talks about the 775, but if there are issues, use this
                chownGroup = "";
                createEmptySeriesFolders = true;
                deleteEmptyFolders = false;
                enableMediaInfo = true;
                episodeTitleRequired = "always";
                extraFileExtensions = "srt";
                fileDate = "none";
                recycleBin = "";
                recycleBinCleanupDays = 7;
                rescanAfterRefresh = "always";
                downloadPropersAndRepacks = "preferAndUpgrade";
                copyUsingHardlinks = true;
                minimumFreeSpaceWhenImporting = 100;
                skipFreeSpaceCheckWhenImporting = false;
                importExtraFiles = false;
                useScriptImport = false;
                scriptImportPath = "";
              }
              // (s.mediaManagement or {}))
          )}

          delete-one () {
            ${curl "DELETE" "/$1/$2" {}}
          }

          delete-all () {
            ids=$(${curl "GET" "/$1" {}} | jq ".[].id")

            for id in $ids; do
              delete-one "$1" "$id"
            done
          }

          ${mapArrReqs' "root folders" "rootfolder"
            enableRootFolders
            (lib.map
              (d: curl "POST" "/rootfolder" {path = d;})
              (s.rootFolders or []))}

          ${mapArrReqs "download clients" "downloadclient" true
            (s.downloadClients or {})
            (_: d: (
              curl' "POST" "/downloadclient" ''
                | json-file-resolve \
                  '$.fields[?(@.name=="password")].value' \
                  '$.fields[?(@.name=="apiKey")].value' \
              '' ({
                  categories = [];
                  priority = 25;
                }
                // (mkArrContract d))
            ))}

          ${mapArrReqs' "tags" "tag" true
            (lib.map
              (d: curl "POST" "/tag" {label = d;})
              tags)}

          ${mapArrReqs "indexer proxies" "indexerProxy"
            enableIndexerProxies
            (s.indexerProxies or {})
            (_: d: (
              curl "POST" "/indexerProxy"
              ((
                  mkArrContract
                  (d // {implementation = d.name;})
                )
                // (mapTags d))
            ))}

          ${mapArrReqs "indexers" "indexer"
            enableIndexers
            (s.indexers or {})
            (_: d: (
              curl' "POST" "/indexer" ''
                | json-file-resolve \
                  '$.fields[?(@.name=="password")].value' \
                  '$.fields[?(@.name=="apiKey")].value' \
              '' ({
                  appProfileId = 1;
                  priority = 25;
                }
                // (mkArrContract d)
                // (mapTags d))
            ))}

          ${mapArrReqs "applications" "applications"
            enableApplications
            (s.applications or {})
            (_: d: (
              curl' "POST" "/applications" ''
                | json-file-resolve \
                  '$.fields[?(@.name=="apiKey")].value' \
              '' ({
                  appProfileId = 1;
                }
                // (mkArrContract d))
            ))}

          echo "${instanceName} init finished"
          wait
        '';
    };

  # Helper to create option types for GUI settings
  mkGuiSettingsType = {
    serviceName,
    enableNaming ? false,
    enableRootFolders ? false,
    enableMediaManagement ? false,
    enableIndexers ? false,
    enableIndexerProxies ? false,
    enableApplications ? false,
  }:
    types.submodule {
      options =
        lib.getAttrs (
          ["host" "downloadClients"]
          ++ lib.optional enableRootFolders "rootFolders"
          ++ lib.optional enableNaming "naming"
          ++ lib.optional enableMediaManagement "mediaManagement"
          ++ lib.optional enableIndexers "indexers"
          ++ lib.optional enableIndexerProxies "indexerProxies"
          ++ lib.optional enableApplications "applications"
        ) {
          host = mkOption {
            type = types.attrs;
            default = {};
            description = "Host configuration including password (file path).";
          };
          applications = mkOption {
            type = types.attrs;
            default = {};
            description = "Application sync configuration (for Prowlarr).";
          };
          indexerProxies = mkOption {
            type = types.attrs;
            default = {};
            description = "Indexer proxy configuration.";
          };
          indexers = mkOption {
            type = types.attrs;
            default = {};
            description = "Indexer configuration.";
          };
          mediaManagement = mkOption {
            type = types.attrs;
            default = {};
            description = "Media management settings.";
          };
          naming = mkOption {
            type = types.attrs;
            default = {};
            description = "File naming configuration.";
          };
          rootFolders = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Root folders for media management.";
            example = ["/media/shows"];
          };
          downloadClients = mkOption {
            type = types.attrs;
            default = {};
            description = "Download client configurations.";
            example = {
              "qBittorrent" = {
                implementation = "QBittorrent";
                fields = {
                  port = 8080;
                  username = "admin";
                  password = "/path/to/password/file";
                };
              };
            };
          };
        };
    };
in {
  # Export the reusable functions as a hidden option
  options.util-nixarr.arrLib = mkOption {
    type = types.unspecified;
    visible = false;
    internal = true;
    default = {
      inherit mkArrInitScript mkGuiSettingsType;
    };
  };
}
