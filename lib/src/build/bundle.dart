// What a Flutter build does with the handler, done for a `dart build cli`
// bundle: the Dart build hook delivers the library, and nothing at all places
// an executable, so `dart run fl_crashpad:bundle` copies one in.
import 'dart:io';

import 'native_artifacts.dart';

/// Copies the handler of [artifacts] — and beside it the revision stamp
/// `start` checks it against, and on Windows `crashpad_wer.dll` — into
/// `lib/` of the `dart build cli` bundle [bundle], where the build hook has
/// already put the library and where `CrashpadHandler.defaultPath` looks.
///
/// Returns the files written. Throws [ArgumentError] for a directory that is
/// not such a bundle, and [ArtifactUnavailable] for a target with no handler.
List<File> bundleHandler(ArtifactDirectory artifacts, Directory bundle) {
  final lib = Directory('${bundle.path}/lib');
  if (!Directory('${bundle.path}/bin').existsSync() || !lib.existsSync()) {
    throw ArgumentError.value(
      bundle.path,
      'bundle',
      'not a `dart build cli` bundle: it has no bin/ and lib/ — pass the '
          '`bundle` directory inside the build output',
    );
  }
  final handler = artifacts.handler;
  if (handler == null) {
    throw ArtifactUnavailable(
      '${artifacts.target.id} has no handler executable to bundle',
    );
  }
  final written = <File>[];
  for (final name in [
    handler.uri.pathSegments.last,
    'crashpad_handler.rev',
    'crashpad_wer.dll',
  ]) {
    final source = File('${artifacts.directory.path}/bin/$name');
    if (!source.existsSync()) continue;
    final copy = source.copySync('${lib.path}/$name');
    if (name == handler.uri.pathSegments.last) makeExecutable(copy);
    written.add(copy);
  }
  return written;
}
