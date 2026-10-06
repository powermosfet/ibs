{ config, lib, ... }:
let
  cfg = config.services.ibs;
in
{
  options.services.ibs = {
    enable = lib.mkEnableOption "Iterative Barcode Searcher";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Iterative Barcode Searcher package to run.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.str lib.types.int);
      default = { };
      example = {
        PRODUCT_LOOKUP_URL_TEMPLATE = "http://localhost:8080/products/{barcode}";
        PMS_HOST = "localhost";
        PMS_PORT = 8081;
        BPD_URL = "http://localhost:8082/";
      };
      description = ''
        Service configuration as environment variables. Unspecified settings
        use the application's defaults. PRODUCT_LOOKUP_URL_TEMPLATE and BPD_URL
        must be supplied here or in environmentFile. Use environmentFile for
        secrets, since these settings are stored in the Nix store.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/ibs.env";
      description = ''
        Absolute path to a runtime environment file, for example containing
        RABBITMQ_PASSWORD. Its values override settings. The file must exist
        before the service starts and use systemd EnvironmentFile syntax.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.environmentFile != null || (
          cfg.settings ? PRODUCT_LOOKUP_URL_TEMPLATE && cfg.settings ? BPD_URL
        );
        message = "services.ibs requires PRODUCT_LOOKUP_URL_TEMPLATE and BPD_URL in settings or environmentFile.";
      }
      {
        assertion = cfg.environmentFile == null || lib.hasPrefix "/" cfg.environmentFile;
        message = "services.ibs.environmentFile must be an absolute path.";
      }
    ];

    systemd.services.ibs = {
      description = "Iterative Barcode Searcher";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "rabbitmq.service" ];
      environment = lib.mapAttrs (_: value: toString value) cfg.settings;
      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = "5s";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };
  };
}
