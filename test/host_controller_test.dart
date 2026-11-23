import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fogshot/host_controller.dart';

class _HostProcess implements Process {
  _HostProcess() {
    _input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => commands.add(jsonDecode(line) as Map<String, dynamic>),
          onDone: () {
            unawaited(_output.close());
            _exit.complete(0);
          },
        );
  }

  final _input = StreamController<List<int>>();
  final _output = StreamController<List<int>>();
  final _exit = Completer<int>();
  final commands = <Map<String, dynamic>>[];

  @override
  late final stdin = IOSink(_input.sink);
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 0;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;

  void send(Map<String, Object> event) =>
      _output.add(utf8.encode('${jsonEncode(event)}\n'));
}

void main() {
  test(
    'delivers explicit pairing approval and stops its own host process',
    () async {
      final process = _HostProcess();
      final host = HostController.withProcess(() async => process);
      addTearDown(host.dispose);
      host.start();
      process.send({
        'type': 'state',
        'system': {
          'addresses': ['192.168.7.2'],
          'port': 38711,
        },
      });
      process.send({
        'type': 'approval',
        'deviceId': 'client-a',
        'deviceName': 'Laptop',
      });
      await Future<void>.delayed(Duration.zero);

      expect(host.phase, SharingPhase.sharing);
      expect(host.addresses.single, '192.168.7.2:38711');
      expect(process.commands, isEmpty);
      host.answer(host.approval!, allow: true);
      await Future<void>.delayed(Duration.zero);
      expect(process.commands.single, {
        'type': 'approve',
        'deviceId': 'client-a',
        'remember': false,
      });

      await host.stop();
      await Future<void>.delayed(Duration.zero);
      expect(process.commands.last, {'type': 'stop'});
      expect(host.phase, SharingPhase.idle);
    },
  );
}
