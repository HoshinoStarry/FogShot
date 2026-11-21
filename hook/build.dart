import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_cmake/native_toolchain_cmake.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final target = code.targetOS;
    final platform =
        target == OS.iOS && code.iOS.targetSdk == IOSSdk.iPhoneSimulator
        ? 'ios-simulator'
        : target.name;
    final fileName = switch (target) {
      OS.windows => 'rincast_backend.dll',
      OS.linux || OS.android => 'librincast_backend.so',
      OS.iOS || OS.macOS => 'librincast_backend.dylib',
      _ => throw UnsupportedError('Unsupported build target $target'),
    };
    final source = input.packageRoot;
    final install = input.outputDirectory.resolve('install/');
    final logger = Logger.root..level = Level.ALL;
    final logs = logger.onRecord.listen(
      (record) => stderr.writeln(record.message),
    );
    final dependencies = <String, String>{};
    for (final name in [
      'RINCAST',
      'RINCAST_OPENH264',
      'RINCAST_LIBYUV',
      'RINCAST_MINIAUDIO',
      'RINCAST_DAV1D',
      'RINCAST_MESON',
    ]) {
      final path = input.userDefines.path('${name.toLowerCase()}_source');
      if (path == null) continue;
      dependencies['FETCHCONTENT_SOURCE_DIR_$name'] = path.toFilePath();
      output.dependencies.add(path);
    }
    final builder = CMakeBuilder.create(
      name: 'rincast_backend',
      sourceDir: source,
      outDir: source.resolve(
        'build/native/$platform/${code.targetArchitecture.name}/',
      ),
      targets: const ['install'],
      defines: {'CMAKE_INSTALL_PREFIX': install.toFilePath(), ...dependencies},
      parallelJobs: Platform.numberOfProcessors.clamp(
        1,
        target == OS.android ? 2 : 8,
      ),
      logger: logger,
    );
    try {
      await builder.run(input: input, output: output, logger: logger);
    } finally {
      await logs.cancel();
    }
    final file = install.resolve(fileName);
    if (!File.fromUri(file).existsSync()) {
      throw StateError('CMake did not install $fileName');
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'native_bindings.dart',
        linkMode: DynamicLoadingBundled(),
        file: file,
      ),
    );
    output.dependencies.add(source.resolve('CMakeLists.txt'));
    for (final folder in ['src/', 'cmake/']) {
      await for (final entry in Directory.fromUri(
        source.resolve(folder),
      ).list(recursive: true)) {
        if (entry is File) output.dependencies.add(entry.uri);
      }
    }
  });
}
