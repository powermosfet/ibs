{ pkgs, package }:
pkgs.testers.runNixOSTest {
  name = "iterative-barcode-searcher";
  nodes.machine = { ... }: {
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    services.rabbitmq = {
      enable = true;
      plugins = [ "rabbitmq_management" ];
    };
    environment.systemPackages = [
      pkgs.curl
      package
    ];
    systemd.services.product-stub = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${../test/http_stub.py}";
    };
    systemd.services.ibs = {
      wantedBy = [ "multi-user.target" ];
      after = [
        "rabbitmq.service"
        "product-stub.service"
      ];
      environment = {
        PRODUCT_LOOKUP_URL_TEMPLATE = "http://localhost:8080/products/{barcode}";
        PMS_HOST = "localhost";
        PMS_PORT = "8080";
        BPD_URL = "http://localhost:8082/";
        HTTP_TIMEOUT_MS = "200";
        RETRY_INITIAL_DELAY_MS = "100";
        RETRY_MAX_DELAY_MS = "400";
        RABBITMQ_HEARTBEAT_SECONDS = "2";
      };
      serviceConfig = {
        ExecStart = "${package}/bin/iterative-barcode-searcher";
        Restart = "no";
      };
    };
  };
  testScript = builtins.readFile ../test/integration.py;
}
