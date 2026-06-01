{
  pkgs,
  nixosModules,
  lib ? pkgs.lib,
  testers,
}:
testers.nixosTest {
  name = "declarative-multi-instance-test";

  nodes.machine = {
    config,
    pkgs,
    ...
  }: {
    imports = [nixosModules.default];

    networking.firewall.enable = false;

    nixarr = {
      enable = true;

      radarr = let
        apiKeyFile = "${pkgs.writeText "api.key" "API_KEY"}";
      in {
        enable = true;
        declarative = true;
        inherit apiKeyFile;
        instances = {
          uhd = {
            inherit apiKeyFile;
            guiSettings = {
              rootFolders = ["/data/movies-uhd"];
            };
          };
          anime = {inherit apiKeyFile;};
          kids = {inherit apiKeyFile;};
        };
      };
    };

    # Create a test user to verify mediaUsers functionality
    users.users.testuser = {
      isNormalUser = true;
      home = "/home/testuser";
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # Check that all services are operational
    machine.succeed("systemctl is-active radarr")
    machine.succeed("systemctl is-active radarr-uhd")
    machine.succeed("systemctl is-active radarr-anime")
    machine.succeed("systemctl is-active radarr-kids")

    print("\n=== Nixarr Declarative Multi-Instance Test Completed ===")
  '';
}
