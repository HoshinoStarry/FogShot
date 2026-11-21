import 'dart:async';
import 'dart:convert';
import 'dart:io';

class IpLocation {
  const IpLocation({required this.ip, this.label, this.isp, this.asn});

  final InternetAddress ip;
  final String? label, isp;
  final int? asn;
}

class IpLocationService {
  IpLocationService({
    Duration timeout = const Duration(seconds: 6),
    Future<String> Function(Uri uri)? fetcher,
  }) : timeout = timeout,
       _fetcher = fetcher ?? ((uri) => _fetch(uri, timeout)) {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
  }

  final Duration timeout;
  final Future<String> Function(Uri uri) _fetcher;
  final _cache = <String, ({IpLocation value, DateTime expiresAt})>{};

  Future<IpLocation?> lookup(String publicIp) async {
    final address = _publicIp(publicIp);
    if (address == null) return null;
    final now = DateTime.now();
    _cache.removeWhere((_, entry) => !entry.expiresAt.isAfter(now));
    final key = _addressKey(address);
    final cached = _cache[key];
    if (cached != null) return cached.value;

    final result = await _lookup(
      Uri(
        scheme: 'https',
        host: 'api.ip.sb',
        path: '/geoip/${address.address}',
      ),
      expectedType: address.type,
      expectedIp: address,
    );
    if (result != null) {
      if (_cache.length >= 32) _cache.clear();
      _cache[key] = (
        value: result,
        expiresAt: now.add(const Duration(minutes: 2)),
      );
    }
    return result;
  }

  Future<IpLocation?> lookupSelf(InternetAddressType family) {
    final host = switch (family) {
      InternetAddressType.IPv4 => 'api-ipv4.ip.sb',
      InternetAddressType.IPv6 => 'api-ipv6.ip.sb',
      _ => null,
    };
    if (host == null) return Future.value();
    return _lookup(
      Uri(scheme: 'https', host: host, path: '/geoip'),
      expectedType: family,
    );
  }

  Future<IpLocation?> _lookup(
    Uri uri, {
    required InternetAddressType expectedType,
    InternetAddress? expectedIp,
  }) async {
    try {
      final body = await _fetcher(uri).timeout(timeout);
      return _parse(body, expectedType: expectedType, expectedIp: expectedIp);
    } catch (_) {
      return null;
    }
  }
}

InternetAddress? publicIp(String value) => _publicIp(value);

/// Extracts a public IP from a bare address or an address:port observation.
String? endpointIp(String endpoint) {
  final value = endpoint.trim();
  final direct = _publicIp(value);
  if (direct != null) return direct.address;

  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close <= 1) return null;
    final suffix = value.substring(close + 1);
    if (suffix.isNotEmpty &&
        (!suffix.startsWith(':') || !_validPort(suffix.substring(1)))) {
      return null;
    }
    final address = _publicIp(value.substring(1, close));
    return address?.address;
  }

  final colon = value.lastIndexOf(':');
  if (colon <= 0 ||
      colon != value.indexOf(':') ||
      !_validPort(value.substring(colon + 1))) {
    return null;
  }
  final address = _publicIp(value.substring(0, colon));
  return address?.type == InternetAddressType.IPv4 ? address?.address : null;
}

IpLocation? _parse(
  String body, {
  required InternetAddressType expectedType,
  InternetAddress? expectedIp,
}) {
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (json is! Map<String, dynamic>) return null;

  final ipValue = json['ip'];
  if (ipValue is! String) return null;
  final ip = _publicIp(ipValue);
  if (ip == null ||
      ip.type != expectedType ||
      (expectedIp != null && !_sameIp(ip, expectedIp))) {
    return null;
  }

  final country = _text(json['country']);
  final region = _text(json['region']);
  final city = _text(json['city']);
  final isp =
      _text(json['isp']) ??
      _text(json['organization']) ??
      _text(json['asn_organization']);
  final label = {
    city,
    region,
    country,
  }.whereType<String>().where((part) => part.isNotEmpty).join(', ');
  return IpLocation(
    ip: expectedIp ?? ip,
    label: label.isEmpty ? null : label,
    isp: isp,
    asn: switch (json['asn']) {
      final int value when value > 0 => value,
      _ => null,
    },
  );
}

InternetAddress? _publicIp(String value) {
  final address = InternetAddress.tryParse(value.trim());
  if (address == null) return null;
  final raw = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return raw.length == 4 && _publicIpv4(raw)
        ? InternetAddress(_formatIpv4(raw), type: InternetAddressType.IPv4)
        : null;
  }
  if (raw.length != 16) return null;
  if (_mappedIpv4(raw)) {
    final ipv4 = raw.sublist(12);
    return _publicIpv4(ipv4)
        ? InternetAddress(_formatIpv4(ipv4), type: InternetAddressType.IPv4)
        : null;
  }
  return _publicIpv6(raw) ? address : null;
}

bool _sameIp(InternetAddress left, InternetAddress right) {
  if (left.type != right.type) return false;
  final a = left.rawAddress;
  final b = right.rawAddress;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

String _addressKey(InternetAddress address) =>
    '${address.type.name}:${address.rawAddress.join('.')}';

bool _validPort(String value) {
  final port = int.tryParse(value);
  return port != null && port > 0 && port <= 65535;
}

bool _mappedIpv4(List<int> raw) {
  for (var index = 0; index < 10; index++) {
    if (raw[index] != 0) return false;
  }
  return raw[10] == 0xff && raw[11] == 0xff;
}

bool _publicIpv4(List<int> raw) {
  final a = raw[0];
  final b = raw[1];
  final c = raw[2];
  final d = raw[3];
  if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
  if (a == 100 && b >= 64 && b <= 127) return false;
  if (a == 169 && b == 254) return false;
  if (a == 172 && b >= 16 && b <= 31) return false;
  if (a == 192 && b == 0 && c == 0) return d == 9 || d == 10;
  if (a == 192 && b == 0 && c == 2) return false;
  if (a == 192 && b == 88 && c == 99) return false;
  if (a == 192 && b == 168) return false;
  if (a == 198 && (b == 18 || b == 19)) return false;
  if (a == 198 && b == 51 && c == 100) return false;
  if (a == 203 && b == 0 && c == 113) return false;
  return true;
}

bool _publicIpv6(List<int> raw) {
  if ((raw[0] & 0xe0) != 0x20) return false;
  if (raw[0] == 0x20 && raw[1] == 0x01 && raw[2] <= 0x01) return false;
  if (raw[0] == 0x20 && raw[1] == 0x01 && raw[2] == 0x0d && raw[3] == 0xb8) {
    return false;
  }
  return !(raw[0] == 0x3f && raw[1] == 0xff && (raw[2] & 0xf0) == 0);
}

String _formatIpv4(List<int> raw) => '${raw[0]}.${raw[1]}.${raw[2]}.${raw[3]}';

String? _text(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

Future<String> _fetch(Uri uri, Duration timeout) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..autoUncompress = false;
  try {
    return await () async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return '';
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 64 * 1024) return '';
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes);
    }().timeout(timeout);
  } catch (_) {
    return '';
  } finally {
    client.close(force: true);
  }
}
