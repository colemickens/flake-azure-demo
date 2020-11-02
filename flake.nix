{
  description = "nixos-azure-demos";

  inputs = {
    nixpkgs = { url = "github:nixos/nixpkgs/nixos-unstable"; };
    nixos-azure = {
      url = "github:colemickens/flake-azure/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils = { url = "github:numtide/flake-utils"; }; # TODO: adopt this
  };

  outputs = inputs:
    let
      nameValuePair = name: value: { inherit name value; };
      genAttrs = names: f: builtins.listToAttrs (map (n: nameValuePair n (f n)) names);
      forAllSystems = genAttrs [ "x86_64-linux" "i686-linux" "aarch64-linux" ];

      pkgsFor = pkgs: system: includeOverlay:
        import pkgs {
          inherit system;
          #config.allowUnfree = true;
          #overlays = if includeOverlay then [ overlay ] else [];
        };

      mkSystem = system: pkgs_: thing:
        #(pkgsFor pkgs_ system).lib.nixosSystem {
        pkgs_.lib.nixosSystem {
          inherit system;
          modules = [ thing ];
          specialArgs.inputs = inputs;
        };
    in
    rec {
      devShell = forAllSystems (system:
        let
          nixpkgs_ = (pkgsFor inputs.nixpkgs system true);
        in
          nixpkgs_.mkShell {
            nativeBuildInputs = with nixpkgs_; [
              nixFlakes
              bash cacert cachix
              curl git jq mercurial
              nix-build-uncached
              nix-prefetch openssh ripgrep

              #azure-cli
              azure-storage-azcopy
              mkp224o

              inputs.nixos-azure.packages.${system}.blobxfer
            ];
          }
      );

      # TODO:
      examples = (
        let
          system = "x86_64-linux";
          nixpkgs_ = (pkgsFor inputs.nixpkgs system true);
          x = name: (mkSystem system inputs.nixpkgs name).config.system.build;
        in {
          demo = x ./examples/demo;
        }
      );
    };
}
