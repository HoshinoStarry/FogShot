// These declarations use the exported C ABI names directly.
// ignore_for_file: non_constant_identifier_names

@DefaultAsset('package:fogshot/native_bindings.dart')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

final class NativeClient extends Opaque {}

final class NativeFrame extends Opaque {}

final class NativeFrameView extends Struct {
  @Uint64()
  external int sequence;

  @Uint32()
  external int width;

  @Uint32()
  external int height;

  external Pointer<Uint8> pixels;
}

@Native<Pointer<NativeClient> Function(Pointer<Utf8>, Pointer<Utf8>, Int32)>()
external Pointer<NativeClient> rcd_create(
  Pointer<Utf8> profile,
  Pointer<Utf8> platform,
  int mobile,
);

@Native<
  Pointer<NativeClient> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Int32,
  )
>()
external Pointer<NativeClient> rcd_create_named(
  Pointer<Utf8> profile,
  Pointer<Utf8> platform,
  Pointer<Utf8> deviceName,
  int mobile,
);

@Native<Void Function(Pointer<NativeClient>)>()
external void rcd_destroy(Pointer<NativeClient> client);

@Native<Void Function(Pointer<NativeClient>, Int32, Pointer<Utf8>, Int32)>()
external void rcd_command(
  Pointer<NativeClient> client,
  int kind,
  Pointer<Utf8> text,
  int value,
);

@Native<
  Void Function(Pointer<NativeClient>, Int32, Int32, Int32, Float, Float)
>()
external void rcd_input(
  Pointer<NativeClient> client,
  int kind,
  int code,
  int down,
  double x,
  double y,
);

@Native<Size Function(Pointer<NativeClient>, Pointer<Uint8>, Size)>()
external int rcd_state(
  Pointer<NativeClient> client,
  Pointer<Uint8> output,
  int capacity,
);

@Native<
  Pointer<NativeFrame> Function(
    Pointer<NativeClient>,
    Uint64,
    Uint64,
    Pointer<NativeFrameView>,
  )
>()
external Pointer<NativeFrame> rcd_acquire_frame(
  Pointer<NativeClient> client,
  int after,
  int generation,
  Pointer<NativeFrameView> output,
);

@Native<
  Pointer<NativeFrame> Function(
    Pointer<NativeClient>,
    Int32,
    Uint64,
    Uint64,
    Pointer<NativeFrameView>,
  )
>()
external Pointer<NativeFrame> rcd_acquire_stream_frame(
  Pointer<NativeClient> client,
  int streamId,
  int after,
  int generation,
  Pointer<NativeFrameView> output,
);

@Native<Void Function(Pointer<NativeFrame>)>()
external void rcd_release_frame(Pointer<NativeFrame> frame);
