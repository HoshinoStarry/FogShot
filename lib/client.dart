import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

import 'native_bindings.dart';
import 'stream_network.dart';
import 'desktop_settings.dart';

enum Phase { idle, connecting, approval, connected, failed }

typedef Host = ({String name, String address, bool busy, String os});
typedef Display = ({String id, String name, int width, int height});
typedef DisplayStream = ({
  int streamId,
  String id,
  String name,
  int width,
  int height,
});

class ClientState {
  const ClientState({
    this.phase = Phase.idle,
    this.status = '',
    this.discover = true,
    this.hosts = const [],
    this.displays = const [],
    this.display = '',
    this.notice = '',
    this.generation = 0,
    this.decoded = 0,
    this.audioPackets = 0,
    this.deviceId = '',
    this.network = const StreamNetwork(),
    this.streams = const [],
    this.allDisplays = false,
    this.microphone = false,
    this.supportedCodecs = const {VideoCodecPreference.h264},
  });

  factory ClientState.fromJson(Map<String, dynamic> data) {
    return ClientState(
      phase: Phase.values[data['state'] as int],
      status: data['status'] as String,
      discover: data['discover'] as bool? ?? !Platform.isIOS,
      hosts: (data['hosts'] as List? ?? [])
          .map(
            (host) => (
              name: host['name'] as String,
              address: host['address'] as String,
              busy: host['busy'] as bool,
              os: host['os'] as String,
            ),
          )
          .toList(),
      displays: (data['displays'] as List? ?? [])
          .map(
            (display) => (
              id: display['id'] as String,
              name: display['name'] as String,
              width: display['width'] as int,
              height: display['height'] as int,
            ),
          )
          .toList(),
      display: data['display'] as String? ?? '',
      notice: data['notice'] as String? ?? '',
      generation: data['generation'] as int? ?? 0,
      decoded: data['decoded'] as int? ?? 0,
      audioPackets: data['audioPackets'] as int? ?? 0,
      deviceId: data['deviceId'] as String? ?? '',
      network: StreamNetwork.fromJson(
        data['network'] as Map<String, dynamic>? ?? const {},
      ),
      streams: (data['streams'] as List? ?? [])
          .map(
            (item) => (
              streamId: item['streamId'] as int,
              id: item['id'] as String,
              name: item['name'] as String,
              width: item['width'] as int,
              height: item['height'] as int,
            ),
          )
          .toList(),
      allDisplays: data['allDisplays'] as bool? ?? false,
      microphone: data['microphone'] as bool? ?? false,
      supportedCodecs: (data['codecs'] as List? ?? ['h264'])
          .map((value) => VideoCodecPreference.fromValue(value as String))
          .toSet(),
    );
  }

  final Phase phase;
  final String status;
  final bool discover;
  final List<Host> hosts;
  final List<Display> displays;
  final String display;
  final String notice;
  final int generation;
  final int decoded;
  final int audioPackets;
  final String deviceId;
  final StreamNetwork network;
  final List<DisplayStream> streams;
  final bool allDisplays;
  final bool microphone;
  final Set<VideoCodecPreference> supportedCodecs;

  bool get connected => phase == Phase.connected;
  bool get pending => phase == Phase.connecting || phase == Phase.approval;
}

class Client implements Finalizable {
  Client._(this._handle) {
    _finalizer.attach(this, _handle.cast(), detach: this);
  }

  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<NativeClient>)>>(
      rcd_destroy,
    ).cast(),
  );

  static bool get mobile => Platform.isIOS || Platform.isAndroid;

  static Future<Client> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return using((arena) {
      final handle = rcd_create(
        dir.path.toNativeUtf8(allocator: arena),
        Platform.operatingSystem.toNativeUtf8(allocator: arena),
        mobile ? 1 : 0,
      );
      if (handle == nullptr) throw StateError('无法初始化 RinCast 客户端');
      return Client._(handle);
    });
  }

  Pointer<NativeClient> _handle;
  Pointer<Uint8> _buffer = malloc<Uint8>(8192);
  int _capacity = 8192;
  final Pointer<NativeFrameView> _view = calloc<NativeFrameView>();
  String? _lastState;
  final Map<int, int> _sequences = {};

  void dispose() {
    if (_handle == nullptr) return;
    _finalizer.detach(this);
    rcd_destroy(_handle);
    _handle = nullptr;
    malloc.free(_buffer);
    calloc.free(_view);
  }

  ClientState? poll() {
    if (_handle == nullptr) return null;
    final size = rcd_state(_handle, _buffer, _capacity);
    if (size > _capacity) {
      malloc.free(_buffer);
      _capacity = size;
      _buffer = malloc<Uint8>(_capacity);
      return null;
    }
    final text = utf8.decode(_buffer.asTypedList(size));
    if (text == _lastState) return null;
    _lastState = text;
    return ClientState.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  Future<ui.Image>? nextFrame(int generation, {int streamId = 0}) {
    if (_handle == nullptr) return null;
    final frame = rcd_acquire_stream_frame(
      _handle,
      streamId,
      _sequences[streamId] ?? 0,
      generation,
      _view,
    );
    if (frame == nullptr) return null;
    final data = _view.ref;
    final width = data.width;
    final height = data.height;
    _sequences[streamId] = data.sequence;
    return _loadFrame(frame, data.pixels, width, height);
  }

  Future<ui.Image> _loadFrame(
    Pointer<NativeFrame> frame,
    Pointer<Uint8> data,
    int width,
    int height,
  ) async {
    late final ui.ImmutableBuffer buffer;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(
        data.asTypedList(width * height * 4),
      );
    } finally {
      rcd_release_frame(frame);
    }
    try {
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.bgra8888,
      );
      try {
        final codec = await descriptor.instantiateCodec();
        try {
          return (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  void _command(int kind, [String? value, bool flag = false]) {
    using(
      (arena) => rcd_command(
        _handle,
        kind,
        value?.toNativeUtf8(allocator: arena) ?? nullptr,
        flag ? 1 : 0,
      ),
    );
  }

  void connect(String address) {
    final firstColon = address.indexOf(':');
    if (address.startsWith('[') && address.endsWith(']')) {
      _command(0, '$address:38711');
    } else if (!address.startsWith('[') &&
        firstColon >= 0 &&
        firstColon != address.lastIndexOf(':')) {
      _command(0, '[$address]:38711');
    } else {
      _command(0, address);
    }
  }

  void connectRemote(Map<String, dynamic> offer) =>
      _command(5, jsonEncode(offer));
  void disconnect() => _command(1);
  void display(String id) => _command(2, id);
  void showAllDisplays() => _command(2, null, true);
  void mute(bool enabled) => _command(3, null, enabled);
  void text(String text) => _command(4, text);
  void settings(DesktopSettings settings) =>
      _command(6, jsonEncode(settings.toJson()));
  void microphone(bool enabled) => _command(7, null, enabled);
  void point(double u, double v, {int streamId = 0}) =>
      rcd_input(_handle, 0, streamId, 0, u, v);
  void button(int button, bool down) =>
      rcd_input(_handle, 1, button, down ? 1 : 0, 0, 0);
  void scroll(double x, double y) => rcd_input(_handle, 2, 0, 0, x, y);
  void key(int key, bool down) =>
      rcd_input(_handle, 3, key, down ? 1 : 0, 0, 0);
  void release() => rcd_input(_handle, 4, 0, 0, 0, 0);
}
