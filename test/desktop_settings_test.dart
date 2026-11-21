import 'dart:io';

import 'package:fogshot/desktop_settings.dart';
import 'package:fogshot/desktop_settings_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('uses safe defaults and ignores persisted microphone settings', () {
    expect(
      DesktopSettings.defaults(mobile: true).frameRate,
      DesktopFrameRate.fps30,
    );
    expect(
      DesktopSettings.defaults(mobile: false).frameRate,
      DesktopFrameRate.fps60,
    );

    final settings = DesktopSettings.parse('''
      {
        "desktopFps": 90,
        "desktopBitrateMbps": 999,
        "volume": 4,
        "skyBrightness": -2,
        "codec": "av1",
        "tenBit": true,
        "autoConnect": true,
        "lastAddress": "100.64.0.8:38711",
        "lastPcId": "desk-1",
        "micPassthrough": true
      }
    ''', mobile: false);

    expect(settings.frameRate, DesktopFrameRate.fps90);
    expect(settings.desktopBitrateMbps, DesktopSettings.maxDesktopBitrateMbps);
    expect(settings.playbackVolume, DesktopSettings.maxPlaybackVolume);
    expect(settings.brightness, DesktopSettings.minBrightness);
    expect(settings.preferredCodec, VideoCodecPreference.av1);
    expect(settings.tenBit, isTrue);
    expect(settings.autoConnect, isTrue);
    expect(settings.lastAddress, '100.64.0.8:38711');
    expect(settings.lastPcId, 'desk-1');
    expect(settings.toJson().containsKey('micPassthrough'), isFalse);
  });

  test('round-trips JSON through the supplied file path', () async {
    final directory = await Directory.systemTemp.createTemp(
      'fogshot-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}settings.json';
    const settings = DesktopSettings(
      frameRate: DesktopFrameRate.auto,
      desktopBitrateMbps: 65,
      adaptiveBitrate: false,
      audioPassthrough: false,
      playbackVolume: 0.35,
      brightness: 1.25,
      maxDecodeWidth: 2560,
      maxDecodeHeight: 1440,
      preferredCodec: VideoCodecPreference.hevc,
      tenBit: true,
      autoReconnect: false,
      autoConnect: true,
      lastAddress: '192.168.1.20:38711',
      lastPcId: 'office-pc',
      lastPcAccountId: 'work-account',
    );

    await settings.save(path: path);
    final restored = await DesktopSettings.load(path: path, mobile: false);

    expect(restored.frameRate, settings.frameRate);
    expect(restored.desktopBitrateMbps, settings.desktopBitrateMbps);
    expect(restored.adaptiveBitrate, isFalse);
    expect(restored.audioPassthrough, isFalse);
    expect(restored.playbackVolume, closeTo(0.35, 0.0001));
    expect(restored.brightness, closeTo(1.25, 0.0001));
    expect(restored.decodePreset, DesktopDecodePreset.p1440);
    expect(restored.preferredCodec, VideoCodecPreference.hevc);
    expect(restored.tenBit, isTrue);
    expect(restored.autoReconnect, isFalse);
    expect(restored.autoConnect, isTrue);
    expect(restored.lastAddress, settings.lastAddress);
    expect(restored.lastPcId, settings.lastPcId);
    expect(restored.lastPcAccountId, settings.lastPcAccountId);
  });

  testWidgets('settings dialog works in a narrow viewport', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    DesktopSettings? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showDesktopSettings(
                    context,
                    DesktopSettings.defaults(mobile: false).copyWith(
                      preferredCodec: VideoCodecPreference.hevc,
                      lastAddress: '10.0.0.5:38711',
                      lastPcId: 'home',
                      lastPcAccountId: 'personal-account',
                    ),
                    supportedCodecs: const {VideoCodecPreference.hevc},
                  );
                },
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    expect(find.text('桌面串流设置'), findsOneWidget);
    expect(find.textContaining('麦克风'), findsNothing);
    expect(find.textContaining('下次连接'), findsOneWidget);
    expect(find.text('HEVC'), findsOneWidget);
    expect(find.text('H.264'), findsNothing);
    expect(find.text('AV1'), findsNothing);
    expect(find.text('10-bit 色深'), findsNothing);
    await tester.tap(find.text('90 fps'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result?.frameRate, DesktopFrameRate.fps90);
    expect(result?.preferredCodec, VideoCodecPreference.hevc);
    expect(result?.lastAddress, '10.0.0.5:38711');
    expect(result?.lastPcId, 'home');
    expect(result?.lastPcAccountId, 'personal-account');
    expect(tester.takeException(), isNull);
  });

  testWidgets('10-bit toggle follows AV1 and codec support', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    DesktopSettings? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showDesktopSettings(
                    context,
                    DesktopSettings.defaults(mobile: false).copyWith(
                      preferredCodec: VideoCodecPreference.auto,
                      tenBit: true,
                    ),
                    supportedCodecs: const {
                      VideoCodecPreference.h264,
                      VideoCodecPreference.av1,
                    },
                  );
                },
                child: const Text('打开设置'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, '10 位色深'),
          )
          .value,
      isTrue,
    );
    await tester.ensureVisible(find.text('H.264'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('H.264'));
    await tester.pumpAndSettle();
    expect(find.text('10 位色深'), findsNothing);

    final autoCodec = find.widgetWithText(ChoiceChip, '自动').last;
    await tester.ensureVisible(autoCodec);
    await tester.pumpAndSettle();
    await tester.tap(autoCodec);
    await tester.pumpAndSettle();
    expect(find.text('10 位色深'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(result?.preferredCodec, VideoCodecPreference.auto);
    expect(result?.tenBit, isTrue);
    expect(tester.takeException(), isNull);
  });
}
