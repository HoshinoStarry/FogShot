import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/ip_location.dart';

void main() {
  test('normalizes public IPv4 and IPv6, including mapped IPv4', () {
    expect(publicIp('8.8.8.8')?.address, '8.8.8.8');
    expect(
      publicIp('2606:4700:4700:0:0:0:0:1111')?.type,
      InternetAddressType.IPv6,
    );
    expect(publicIp('::ffff:8.8.8.8')?.address, '8.8.8.8');
    expect(publicIp('::ffff:8.8.8.8')?.type, InternetAddressType.IPv4);
  });

  test('rejects non-public and unresolved addresses', () {
    for (final value in [
      '10.0.0.1',
      '100.64.0.1',
      '127.0.0.1',
      '192.0.2.1',
      '::1',
      'fe80::1',
      'fd00::1',
      '2001:db8::1',
      'example.com',
    ]) {
      expect(publicIp(value), isNull, reason: value);
      expect(endpointIp(value), isNull, reason: value);
    }
  });

  test('extracts public IPs from local UDP endpoint strings', () {
    expect(endpointIp('8.8.8.8:38711'), '8.8.8.8');
    expect(endpointIp('[2606:4700:4700::1111]:38711'), '2606:4700:4700::1111');
    expect(endpointIp('2606:4700:4700::1111'), '2606:4700:4700::1111');
    expect(endpointIp('8.8.8.8:0'), isNull);
    expect(endpointIp('[2606:4700:4700::1111]'), '2606:4700:4700::1111');
  });

  test('lookup sends only the official specific-IP endpoint', () async {
    final uris = <Uri>[];
    final service = IpLocationService(
      fetcher: (uri) async {
        uris.add(uri);
        return jsonEncode({
          'ip': '8.8.8.8',
          'country': 'United States',
          'region': 'New York',
          'city': 'New York',
          'isp': 'Example ISP',
          'asn': 64500,
        });
      },
    );

    final result = await service.lookup('8.8.8.8');

    expect(uris.single.toString(), 'https://api.ip.sb/geoip/8.8.8.8');
    expect(result?.ip.address, '8.8.8.8');
    expect(result?.label, 'New York, United States');
    expect(result?.isp, 'Example ISP');
    expect(result?.asn, 64500);
  });

  test('specific lookup requires the requested address', () async {
    final mismatched = IpLocationService(
      fetcher: (_) async => jsonEncode({'ip': '1.1.1.1'}),
    );
    final equivalentIpv6 = IpLocationService(
      fetcher: (_) async =>
          jsonEncode({'ip': '2606:4700:4700::1111', 'country': 'Australia'}),
    );

    expect(await mismatched.lookup('8.8.8.8'), isNull);
    final requested = '2606:4700:4700:0:0:0:0:1111';
    final equivalent = await equivalentIpv6.lookup(requested);
    expect(equivalent, isNotNull);
    expect(equivalent?.ip.address, publicIp(requested)?.address);
  });

  test('successful specific lookups use a short per-service cache', () async {
    var calls = 0;
    final service = IpLocationService(
      fetcher: (_) async {
        calls++;
        return jsonEncode({'ip': '8.8.8.8', 'country': 'United States'});
      },
    );

    final first = await service.lookup('8.8.8.8');
    final second = await service.lookup('8.8.8.8');

    expect(calls, 1);
    expect(identical(first, second), isTrue);
  });

  test('lookupSelf selects the same-family self endpoint explicitly', () async {
    final uris = <Uri>[];
    final service = IpLocationService(
      fetcher: (uri) async {
        uris.add(uri);
        return jsonEncode({
          'ip': '2606:4700:4700::1111',
          'country': 'Australia',
          'city': 'Sydney',
        });
      },
    );

    final result = await service.lookupSelf(InternetAddressType.IPv6);

    expect(uris.single.toString(), 'https://api-ipv6.ip.sb/geoip');
    expect(result?.ip.address, '2606:4700:4700::1111');
    expect(result?.label, 'Sydney, Australia');
  });

  test('invalid input does not call HTTP and failures return null', () async {
    var calls = 0;
    final service = IpLocationService(
      fetcher: (_) async {
        calls++;
        throw const SocketException('offline');
      },
    );

    expect(await service.lookup('192.168.1.2'), isNull);
    expect(calls, 0);
    expect(await service.lookup('8.8.8.8'), isNull);
    expect(await service.lookup('8.8.8.8'), isNull);
    expect(calls, 2);
    expect(await service.lookupSelf(InternetAddressType.any), isNull);
    expect(calls, 2);
  });

  test('malformed and wrong-family JSON return null', () async {
    final malformed = IpLocationService(fetcher: (_) async => 'not-json');
    final wrongFamily = IpLocationService(
      fetcher: (_) async => jsonEncode({'ip': '1.1.1.1'}),
    );

    expect(await malformed.lookup('8.8.8.8'), isNull);
    expect(await wrongFamily.lookup('2606:4700:4700::1111'), isNull);
  });
}
