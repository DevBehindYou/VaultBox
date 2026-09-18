import "dart:io";

/// RFC 1918 ranges: 10/8, 172.16/12, 192.168/16.
bool isPrivateIPv4(String address) {
  final List<int?> parts = address.split(".").map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((int? p) => p == null)) return false;
  final int a = parts[0]!;
  final int b = parts[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

/// True for a client that is this phone itself or on a private network. The
/// plain-HTTP listener refuses everyone else: HTTP has no encryption, so it is
/// only ever meant for a network you own.
bool isPrivateOrLoopbackClient(InternetAddress address) {
  if (address.isLoopback) return true;
  if (address.type == InternetAddressType.IPv4) return isPrivateIPv4(address.address);
  return false;
}

/// The phone's private-network IPv4 address (what other devices would type).
Future<String?> lanAddress() async {
  final List<NetworkInterface> interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  for (final NetworkInterface interface in interfaces) {
    for (final InternetAddress address in interface.addresses) {
      if (isPrivateIPv4(address.address)) return address.address;
    }
  }
  return null;
}
