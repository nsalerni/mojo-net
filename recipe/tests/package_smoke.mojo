from net import IPv4Address


def main() raises:
    var address = IPv4Address("127.0.0.1", 443)
    if address.port != 443:
        raise Error("installed mojo-net package returned the wrong port")
    print("mojo-net package smoke test passed")
