{ config, pkgs, lib, modulesPath, inputs, ... }:

let
  hs = lib.fileContents ./hostname;
  payload = pkgs.substituteAll {
    name = "index.html";
    src = ./site/index.html;
    dir = "/";
    systemLabel = config.system.nixos.label;
  };
in
{
  imports = [
    "${modulesPath}/profiles/headless.nix"
    "${inputs.azure}/modules"
    "${inputs.sops-nix}/modules/sops"
  ];

  config = {
    virtualisation.azure = {
      integration.enable = true;
      image = { diskSize = 2500; };
      scripts.enable = true;
    };

    nix.nrBuildUsers = 64;

    # not sure thrilled about this bits VVVV
    boot.initrd.network.enable = true;
    boot.initrd.network.flushBeforeStage2 = false;

    services.nginx.enable = true;
    services.nginx.virtualHosts."default" = {
      root = pkgs.substituteAll {
        name = "index.html";
        src = ./site/index.html;
        dir = "/";
        systemLabel = config.system.nixos.label;
      };
      default = true;
    };


    services.tor.enable = true;
    services.tor.hiddenServices = {
      "${hs}" = {
        keyPath = config.sops.secrets."${hs}-key".path;
        map = [{ port = "80"; toPort = "80"; }];
      };
    };
    systemd.services.tor = {
      serviceConfig.SupplementaryGroups = [ config.users.groups.keys.name ]; # we shouldn't need this AND owner/mode below tho?
    };


    sops = {
      secrets = {
        "${hs}-key" = {
          format = "binary";
          sopsFile = ./hs_ed25519_secret_key.sops;
          #owner = config.users.users.tor.name;
          mode = "0600";
        };
      };
    };

    system.stateVersion = "20.03";
    boot.kernelPackages = pkgs.linuxPackages_latest;

    documentation.enable = false;
    documentation.doc.enable = false;
    documentation.info.enable = false;
    documentation.man.enable = false;
    documentation.nixos.enable = false;
  };
}
