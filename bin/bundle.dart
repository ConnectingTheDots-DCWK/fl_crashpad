// Puts the handler into a `dart build cli` bundle, beside the library the
// build hook put there — the step a Flutter build does with CMake or a pod,
// which a Dart build has no place for.
//
//   dart build cli
//   dart run fl_crashpad:bundle build/cli/bundle
//
// Takes the handler from the same per-user cache the build hook filled,
// downloading and verifying it first if the cache is empty, so the handler and
// the library always come from one native release. For this machine's own
// target only: `dart build cli` builds for the machine it runs on.
import 'dart:io';
import 'dart:isolate';

import 'package:fl_crashpad/src/build/bundle.dart';
import 'package:fl_crashpad/src/build/native_artifacts.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 || arguments.single.startsWith('-')) {
    stderr.writeln(
      'usage: dart run fl_crashpad:bundle <dart build cli bundle>',
    );
    exitCode = 64;
    return;
  }
  final target = hostTarget();
  if (target == null) {
    stderr.writeln('fl_crashpad has no build for this machine');
    exitCode = 1;
    return;
  }
  final packageRoot = await Isolate.resolvePackageUri(
    Uri.parse('package:fl_crashpad/'),
  );
  final resolver = ArtifactResolver(
    lock: ArtifactLock.read(
      File.fromUri(packageRoot!.resolve('../native/artifacts.lock.json')),
    ),
    cacheRoot: artifactCacheRoot(
      os: Platform.operatingSystem,
      environment: Platform.environment,
    ),
  );
  try {
    final artifacts = await resolver.resolve(target);
    for (final file in bundleHandler(artifacts, Directory(arguments.single))) {
      stdout.writeln(file.path);
    }
  } on ArgumentError catch (e) {
    stderr.writeln('fl_crashpad: ${e.message}: ${e.invalidValue}');
    exitCode = 1;
  } on ArtifactUnavailable catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  }
}
