{
  description = "A garnix module for nodejs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  inputs.dream2nix = {
    url = "github:nix-community/dream2nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };


  outputs =
    { self
    , dream2nix
    , nixpkgs
    ,
    }:
    let
      lib = nixpkgs.lib;

      nodejsSubmodule.options = {
        src = lib.mkOption {
          type = lib.types.path;
          description = "A path to the directory containing package.json, package.lock, and src";
          example = ./.;
        };

        testCommand = lib.mkOption {
          type = lib.types.str;
          description = "The command to run the test. Default: npm run test";
          default = "npm run test";
        };

        serverCommand = lib.mkOption {
          type = lib.types.str;
          description = "The command to run to start the server in production";
          example = "server --port 7000";
        };

      };
    in
    {
      garnixModules.default = { pkgs, config, ... }: {
        options = {
          nodejs = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule nodejsSubmodule);
            description = "An attrset of rust projects to generate";
          };
        };

        config =
          let
            theModule = projectConfig:
              { lib
              , config
              , dream2nix
              , ...
              }:
              {
                imports = [
                  dream2nix.modules.dream2nix.nodejs-package-lock-v3
                  dream2nix.modules.dream2nix.nodejs-granular-v3
                ];

                mkDerivation = { src = projectConfig.src; };

                deps = { nixpkgs, ... }: {
                  inherit
                    (nixpkgs)
                    fetchFromGitHub
                    stdenv
                    ;
                };

                nodejs-package-lock-v3 = {
                  packageLockFile = "${config.mkDerivation.src}/package-lock.json";
                };

                name = "nodejs-app";
                version = "0.1.0";

                paths.projectRoot = ./.;
                paths.projectRootFile = "flake.nix";
                paths.package = ./.;
              };
          in
          {
            packages = builtins.mapAttrs
              (name: projectConfig: {
                "${name}" = dream2nix.lib.evalModules {
                  packageSets.nixpkgs = pkgs;
                  modules = [
                    (theModule projectConfig)
                  ];
                };
              })
              config.nodejs;
            nixosConfigurations = builtins.mapAttrs
              (name: projectConfig: {
                systemd.services.${name} = {
                  description = "${name} nodejs garnix module";
                  wantedBy = [ "multi-user.target" ];
                  after = [ "network-online.target" ];
                  wants = [ "network-online.target" ];
                  serviceConfig = {
                    Type = "simple";
                    DynamicUser = true;
                    ExecStart = lib.getExe (pkgs.writeShellApplication {
                      name = "start-${name}";
                      runtimeInputs = [ config.packages.${name} ];
                      text = projectConfig.serverCommand;
                    });
                  };
                };
              })
              config.nodejs;
          };
      };
    };
}

