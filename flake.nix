{
  description = ''
    A garnix module for projects using NodeJS.

    Add dependencies, run tests, and optionally deploy a web server. Can be used either for frontend servers and backend servers.

    [Documentation](https://garnix.io/docs/modules/nodejs) - [Source](https://github.com/garnix-io/nodejs-module).
  '';

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  inputs.dream2nix = {
    url = "github:jkarni/dream2nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { dream2nix, ... }:
    {
      garnixModules.default =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        let

          webServerSubmodule.options = {
            command =
              lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "The command to run to start the server in production.";
                example = "server --port \"$PORT\"";
              }
              // {
                name = "server command";
              };

            port = lib.mkOption {
              type = lib.types.port;
              description = "Port to forward incoming HTTP requests to. The server command has to listen on this port. This also sets the PORT environment variable for the server command.";
              default = 3000;
            };

            path =
              lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Path your NodeJS server will be hosted on.";
                default = "/";
              }
              // {
                name = "API path";
              };
          };

          nodejsSubmodule.options = {
            src =
              lib.mkOption {
                type = lib.types.path;
                description = "A path to the directory containing `package.json`, `package.lock`, and `src`.";
                example = "./.";
              }
              // {
                name = "source directory";
              };

            prettier = lib.mkOption {
              type = lib.types.bool;
              description = "Whether to create a CI check with prettier, and add it to the devshells.";
              default = false;
            };

            devTools =
              lib.mkOption {
                type = lib.types.listOf lib.types.package;
                description = "A list of packages make available in the devshell for this project. This is useful for things like LSPs, formatters, etc.";
                default = [ ];
              }
              // {
                name = "development tools";
              };

            buildDependencies = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              description = ''
              A list of additional dependencies required to build this package. They are made available in the devshell, and at build time.

              (It's not necessary to include library dependencies manually, these will be included automatically.)
              '';
              default = [ ];
            };

            runtimeDependencies = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              description = "A list of dependencies required at runtime. They are made available in the devshell, at build time, and are available on the server at runtime.";
              default = [ ];
            };

            testCommand = lib.mkOption {
              type = lib.types.str;
              description = "The command to run the test.";
              default = "npm run test";
            };

            webServer = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule webServerSubmodule);
              description = "Whether to build a server configuration based on this project and deploy it to the garnix cloud.";
              default = null;
            };

          };

          hasAnyWebServer = builtins.any (projectConfig: projectConfig.webServer != null) (
            builtins.attrValues config.nodejs
          );
        in
        {
          options = {
            nodejs = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule nodejsSubmodule);
              description = "An attrset of NodeJS projects to generate.";
            };
          };

          config =
            let
              theModule =
                projectConfig:
                {
                  lib,
                  config,
                  dream2nix,
                  ...
                }:
                {
                  imports = [
                    dream2nix.modules.dream2nix.nodejs-package-lock-v3
                    dream2nix.modules.dream2nix.nodejs-granular-v3
                  ];

                  mkDerivation = {
                    src = projectConfig.src;
                    buildInputs = projectConfig.buildDependencies;
                  };

                  deps =
                    { nixpkgs, ... }:
                    {
                      inherit (nixpkgs)
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
            rec {
              packages = builtins.mapAttrs (
                name: projectConfig:
                dream2nix.lib.evalModules {
                  packageSets.nixpkgs = pkgs;
                  modules = [
                    (theModule projectConfig)
                  ];
                }
              ) config.nodejs;
              checks = lib.foldlAttrs (
                acc: name: projectConfig:
                acc
                // {
                  "${name}-test" =
                    pkgs.runCommand "${name}-test"
                      {
                        buildInputs = [
                          pkgs.nodejs
                        ] ++ projectConfig.buildDependencies;
                      }
                      ''
                        GLOBIGNORE=".:.."
                        cp -r ${packages."${name}"}/lib/node_modules/nodejs-app/* .
                        chmod -R 755 .

                        export PATH=${packages."${name}"}/lib/node_modules/.bin:$PATH

                        # The .gitignore might be outside the dir. So we add some
                        # basic things since it influences e.g. ESLint
                        touch /build/.gitignore
                        echo build/ >> /build/.gitignore

                        ${projectConfig.testCommand}
                        mkdir $out
                      '';
                }
                // (
                  if projectConfig.prettier then
                    {
                      "${name}-prettier" =
                        pkgs.runCommand "${name}-prettier"
                          {
                            buildInputs = [
                              pkgs.nodePackages.prettier
                              pkgs.coreutils
                            ];
                          }
                          ''
                            find ${projectConfig.src} -regex '.*\.\(js\|jsx\|ts\|tsx\)' |
                              xargs prettier --check
                            mkdir $out
                          '';
                    }
                  else
                    { }
                )
              ) { } config.nodejs;

              devShells = builtins.mapAttrs (
                name: projectConfig:
                pkgs.mkShell {
                  inputsFrom = [ packages."${name}" ];
                  packages =
                    [ pkgs.nodejs ]
                    ++ projectConfig.devTools
                    ++ projectConfig.buildDependencies
                    ++ projectConfig.runtimeDependencies
                    ++ (if projectConfig.prettier then [ pkgs.nodePackages.prettier ] else [ ]);
                }
              ) config.nodejs;

              nixosConfigurations = lib.mkIf hasAnyWebServer {
                default =
                  # Global NixOS configuration
                  [
                    {
                      services.nginx = {
                        enable = true;
                        recommendedProxySettings = true;
                        recommendedOptimisation = true;
                        virtualHosts.default = {
                          default = true;
                        };
                      };

                      networking.firewall.allowedTCPPorts = [ 80 ];
                    }
                  ]
                  ++
                  # Per project NixOS configuration
                  builtins.attrValues (
                    builtins.mapAttrs (
                      name: projectConfig:
                      lib.mkIf (projectConfig.webServer != null) {
                        environment.systemPackages = [ pkgs.nodejs ] ++ projectConfig.runtimeDependencies;

                        systemd.services.${name} =
                          let
                            stateDirectoryBase = "${name}-nodejs-app/";
                          in
                          {
                            description = "${name} NodeJS garnix module";
                            wantedBy = [ "multi-user.target" ];
                            after = [ "network-online.target" ];
                            wants = [ "network-online.target" ];
                            environment.PORT = toString projectConfig.webServer.port;
                            serviceConfig = {
                              Type = "simple";
                              User = "nobody";
                              Group = "nobody";
                              StateDirectory = stateDirectoryBase;
                              WorkingDirectory = "${packages."${name}"}/lib/node_modules/nodejs-app/";
                              ExecStart = lib.getExe (
                                pkgs.writeShellApplication {
                                  name = "start-${name}";
                                  runtimeInputs = [
                                    pkgs.nodejs
                                    pkgs.bash
                                    config.packages.${name}
                                  ] ++ projectConfig.runtimeDependencies;
                                  text = projectConfig.webServer.command;
                                }
                              );
                            };
                          };

                        services.nginx.virtualHosts.default.locations.${projectConfig.webServer.path}.proxyPass =
                          "http://localhost:${toString projectConfig.webServer.port}";
                      }
                    ) config.nodejs
                  );
              };
            };
        };
    };
}
