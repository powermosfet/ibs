{ pkgs, package, module }:
pkgs.testers.runNixOSTest {
  name = "iterative-barcode-searcher";
  nodes.machine = { lib, ... }: {
    imports = [ module ];
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
    services.ibs = {
      enable = true;
      environmentFile = "/etc/ibs-test.env";
      settings = {
        PRODUCT_LOOKUP_URL_TEMPLATE = "http://localhost:8080/products/{barcode}";
        PMS_HOST = "localhost";
        PMS_PORT = 8080;
        RABBITMQ_PASSWORD = "overridden-by-environment-file";
        BPD_URL = "http://localhost:8082/";
        HTTP_TIMEOUT_MS = "200";
        RETRY_INITIAL_DELAY_MS = "100";
        RETRY_MAX_DELAY_MS = "400";
        RABBITMQ_HEARTBEAT_SECONDS = "2";
      };
    };
    environment.etc."ibs-test.env".text = "RABBITMQ_PASSWORD=guest\n";
    systemd.services.ibs = {
      after = [ "product-stub.service" ];
      serviceConfig.Restart = lib.mkForce "no";
    };
  };
  testScript = builtins.readFile ../test/integration.py;
}
