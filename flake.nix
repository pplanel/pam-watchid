{
  description = "PAM module for authenticating with Apple Watch";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["aarch64-darwin" "x86_64-darwin"];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      apple-sdk = pkgs.apple-sdk_26 or pkgs.apple-sdk_15 or pkgs.apple-sdk;
      pam-watchid = pkgs.callPackage ./default.nix {inherit apple-sdk;};
    in {
      default = pam-watchid;
      inherit pam-watchid;
      harness = pkgs.callPackage ./harness.nix {inherit apple-sdk pam-watchid;};

      # nixcache-oci proxy: bridges the Nix binary-cache protocol to this
      # repo's GHCR-backed cache. Used by the darwinModule below and runnable
      # directly with `nix run .#cache-proxy`.
      cache-proxy = pkgs.stdenv.mkDerivation {
        pname = "nixcache-proxy";
        version = "0.1.0";
        src = ./proxy;
        nativeBuildInputs = [pkgs.python3];
        installPhase = ''
          mkdir -p $out/bin
          cp main.py $out/bin/nixcache-proxy
          chmod +x $out/bin/nixcache-proxy
          patchShebangs $out/bin/nixcache-proxy
        '';
      };
    });

    apps = forAllSystems (system: {
      cache-proxy = {
        type = "app";
        program = "${self.packages.${system}.cache-proxy}/bin/nixcache-proxy";
      };
    });

    overlays.default = final: prev: {
      pam-watchid = prev.callPackage ./default.nix {
        apple-sdk = prev.apple-sdk_26 or prev.apple-sdk_15 or prev.apple-sdk;
      };
    };

    # nix-darwin module: runs the cache proxy as a launchd daemon and points a
    # substituter at it. Import into your darwinConfiguration and set
    # `services.nixcache-proxy.enable = true;`.
    darwinModules.default = {
      config,
      pkgs,
      lib,
      ...
    }: let
      cfg = config.services.nixcache-proxy;
      proxyPkg = self.packages.${pkgs.stdenv.hostPlatform.system}.cache-proxy;
    in {
      options.services.nixcache-proxy = {
        enable = lib.mkEnableOption "nixcache-oci proxy substituter (GHCR)";
        repo = lib.mkOption {
          type = lib.types.str;
          default = "pplanel/pam_watchid";
          description = "GitHub owner/repo hosting the OCI cache.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 37515;
          description = "Port the proxy listens on (localhost only).";
        };
        publicKey = lib.mkOption {
          type = lib.types.str;
          default = "pam-watchid-cache-1:cipv8xpwzNYvPYw/Zx71IkouiDY3vOWxryEfQtIHfzo=";
          description = "Trusted public key for verifying cache signatures.";
        };
      };

      config = lib.mkIf cfg.enable {
        launchd.daemons.nixcache-proxy = {
          serviceConfig = {
            ProgramArguments = ["${proxyPkg}/bin/nixcache-proxy"];
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "/var/log/nixcache-proxy.log";
            StandardErrorPath = "/var/log/nixcache-proxy.log";
            EnvironmentVariables = {
              NIXCACHE_REPO = cfg.repo;
              NIXCACHE_PORT = toString cfg.port;
              NIXCACHE_LISTEN = "127.0.0.1";
            };
          };
        };

        nix.settings = {
          extra-substituters = ["http://127.0.0.1:${toString cfg.port}"];
          extra-trusted-substituters = ["http://127.0.0.1:${toString cfg.port}"];
          extra-trusted-public-keys = [cfg.publicKey];
        };
      };
    };
  };
}
