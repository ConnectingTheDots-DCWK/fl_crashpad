// Fills the per-user artifact cache ahead of a build: for CI, for a machine
// about to go offline, or to see a download fail on its own rather than in the
// middle of `flutter build`.
//
//   dart run fl_crashpad:prefetch                 # this machine's target
//   dart run fl_crashpad:prefetch --all-targets   # every target in the lock
//
// Only the targets this machine can build apps for: its own desktop, Android
// from anywhere, and iOS from a Mac.
import 'dart:io';
import 'dart:isolate';

import 'package:fl_crashpad/src/build/native_artifacts.dart';

Future<void> main(List<String> arguments) async {
  final all = arguments.contains('--all-targets');
  final os = Platform.operatingSystem;
  final packageRoot = await Isolate.resolvePackageUri(
    Uri.parse('package:fl_crashpad/'),
  );
  final lock = ArtifactLock.read(
    File.fromUri(packageRoot!.resolve('../native/artifacts.lock.json')),
  );
  final resolver = ArtifactResolver(
    lock: lock,
    cacheRoot: artifactCacheRoot(os: os, environment: Platform.environment),
  );

  final targets = all
      ? NativeTarget.values.where(
          (t) =>
              t.os == os ||
              t.os == 'android' ||
              (t.os == 'ios' && os == 'macos'),
        )
      : [
          hostTarget() ??
              (throw UnsupportedError(
                'fl_crashpad has no build for this machine',
              )),
        ];
  var failed = false;
  for (final target in targets) {
    try {
      final found = await resolver.resolve(target);
      stdout.writeln('${target.id}  ${found.directory.path}');
    } on ArtifactUnavailable catch (e) {
      stderr.writeln('${target.id}  $e');
      failed = true;
    }
  }
  if (failed) exitCode = 1;
}
