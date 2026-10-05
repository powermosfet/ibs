import json
import shlex
import time

start_all()
machine.wait_for_unit("rabbitmq.service")
machine.wait_for_open_port(15672)
machine.wait_for_open_port(8080)
machine.wait_for_unit("ibs.service")


def api(method, path, data=None, product=False):
    url = ("http://127.0.0.1:8080" if product else "http://127.0.0.1:15672/api") + path
    args = ["curl", "--fail", "--silent", "--show-error", "-u", "guest:guest", "-X", method, url]
    if data is not None:
        args += ["-H", "Content-Type: application/json", "--data-binary", json.dumps(data)]
    output = machine.succeed(shlex.join(args))
    return json.loads(output) if output.strip() else None


def wait(predicate, message, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError(message)


def scanned(text):
    assert api("POST", "/exchanges/%2F/amq.default/publish", {
        "properties": {"delivery_mode": 2}, "routing_key": "scanned_barcodes",
        "payload": text, "payload_encoding": "string",
    })["routed"]


def get(queue):
    return api("POST", "/queues/%2F/" + queue + "/get", {
        "count": 1, "ackmode": "ack_requeue_false", "encoding": "auto",
    })


def expect(queue, body, content_type):
    messages = []
    wait(lambda: messages.extend(get(queue)) or bool(messages), "No output in " + queue)
    assert messages[0]["payload"] == body, messages
    assert messages[0]["properties"]["content_type"] == content_type
    assert messages[0]["properties"]["delivery_mode"] == 2


def control(barcode, **values):
    api("POST", "/control", {barcode: values}, product=True)


def seen(barcode, count=1):
    return api("GET", "/requests", product=True).count(barcode) >= count


def outstanding():
    return api("GET", "/queues/%2F/scanned_barcodes").get("messages", 0)


def product_body(barcode):
    return json.dumps({"barcode": barcode, "name": "Milk"})


machine.wait_until_succeeds("curl -sf -u guest:guest http://localhost:15672/api/queues/%2F/scanned_barcodes")

with subtest("durable queues, whitespace, leading zeros, and unchanged JSON"):
    for queue in ["scanned_barcodes", "shopping_list_items", "missing_barcodes"]:
        info = api("GET", "/queues/%2F/" + queue)
        assert info["durable"] and not info["exclusive"] and not info["auto_delete"]
    body = ' {"name":"Milk","unknown":[1,null,{"x":true}]} \n'
    control("001234", body=body)
    scanned(" 001234\r\n")
    expect("shopping_list_items", body, "application/json")

with subtest("404 and repeated scans"):
    control("00999", status=404, body="not JSON")
    scanned("00999\n")
    expect("missing_barcodes", "00999", "text/plain")
    for _ in range(2):
        scanned("001234")
        expect("shopping_list_items", body, "application/json")
    assert not get("missing_barcodes")

with subtest("URL encoding"):
    barcode = "00/A B?&+#é"
    scanned(barcode)
    expect("shopping_list_items", product_body(barcode), "application/json")

with subtest("transient HTTP failure retains scan and blocks following scan"):
    control("retry", status=503)
    scanned("retry")
    scanned("behind")
    wait(lambda: seen("retry", 3), "HTTP retries did not happen")
    assert not seen("behind")
    assert not get("shopping_list_items") and not get("missing_barcodes")
    control("retry")
    expect("shopping_list_items", product_body("retry"), "application/json")
    expect("shopping_list_items", product_body("behind"), "application/json")

with subtest("invalid JSON objects and HTTP timeout are retried"):
    for barcode, values in [("bad-json", {"body": "[]"}), ("timeout", {"delay": 1})]:
        control(barcode, **values)
        scanned(barcode)
        wait(lambda: seen(barcode, 2), "Response failure was not retried")
        assert not get("shopping_list_items") and not get("missing_barcodes")
        control(barcode)
        expect("shopping_list_items", product_body(barcode), "application/json")

with subtest("unroutable publication never acknowledges input"):
    control("unroutable", status=503)
    scanned("unroutable")
    wait(lambda: seen("unroutable"), "Scan was not received")
    api("DELETE", "/queues/%2F/shopping_list_items")
    control("unroutable")
    # A returned publication must trigger reconnection, queue recreation, and
    # redelivery. If the input was acknowledged here there would be no output.
    machine.wait_until_succeeds("curl -sf -u guest:guest http://localhost:15672/api/queues/%2F/shopping_list_items")
    expect("shopping_list_items", product_body("unroutable"), "application/json")
    assert seen("unroutable", 2)

with subtest("broker restart recovers unacknowledged input"):
    control("broker-restart", status=503)
    scanned("broker-restart")
    wait(lambda: seen("broker-restart"), "Scan was not received")
    pid = machine.succeed("systemctl show ibs -p MainPID --value").strip()
    machine.succeed("systemctl stop rabbitmq")
    control("broker-restart")
    machine.succeed("systemctl start rabbitmq")
    machine.wait_for_open_port(15672)
    expect("shopping_list_items", product_body("broker-restart"), "application/json")
    assert machine.succeed("systemctl show ibs -p MainPID --value").strip() == pid

with subtest("service shutdown returns unfinished scan"):
    control("shutdown", status=503)
    scanned("shutdown")
    wait(lambda: seen("shutdown"), "Scan was not received")
    machine.succeed("systemctl stop ibs")
    control("shutdown")
    machine.succeed("systemctl start ibs")
    expect("shopping_list_items", product_body("shutdown"), "application/json")

wait(lambda: outstanding() == 0, "Processed scans remain outstanding")
assert not get("shopping_list_items") and not get("missing_barcodes")

with subtest("invalid UTF-8 and empty scans remain unacknowledged"):
    api("POST", "/exchanges/%2F/amq.default/publish", {
        "properties": {"delivery_mode": 2}, "routing_key": "scanned_barcodes",
        "payload": "/w==", "payload_encoding": "base64",
    })
    time.sleep(1)
    assert not get("shopping_list_items") and not get("missing_barcodes")
    machine.succeed("systemctl stop ibs")
    invalid = get("scanned_barcodes")
    assert invalid and invalid[0]["payload"] == "/w=="
    machine.succeed("systemctl start ibs")
    # Empty scans deliberately retry forever; shutdown leaves the input intact.
    scanned(" \r\n")
    scanned("behind-empty")
    time.sleep(2)
    assert not seen("behind-empty")
    machine.succeed("systemctl stop ibs")
    messages = get("scanned_barcodes")
    assert messages and messages[0]["payload"] == " \r\n"
    assert get("scanned_barcodes")[0]["payload"] == "behind-empty"

with subtest("incompatible queue declarations fail startup"):
    api("DELETE", "/queues/%2F/scanned_barcodes")
    api("PUT", "/queues/%2F/scanned_barcodes", {"durable": True, "auto_delete": True, "arguments": {}})
    machine.execute("systemctl start ibs")
    machine.wait_until_succeeds("systemctl is-failed ibs")
    machine.succeed("journalctl -u ibs --no-pager | grep 'Queue declaration mismatch'")
