import 'dart:io';
import 'dart:isolate';

import 'build/native_artifacts.dart';
import 'options.dart';

/// Where this package's build puts `crashpad_handler` inside an app bundle.
///
/// **Advanced: for custom packaging only.** An app built the ordinary way
/// never needs this — [CrashpadOptions.handler] defaults to [defaultPath].
/// It is public for a bundle laid out by hand, an installer that moves the
/// handler, or a test run outside a bundle.
///
/// A Flutter build places it with each platform's own mechanism, never with
/// the Dart build hook, because a hook can ship libraries but not
/// executables:
///
/// | | |
/// | --- | --- |
/// | Linux | `<bundle>/lib/crashpad_handler`, installed with its executable bit by the plugin's CMake. |
/// | Windows | `crashpad_handler.exe` beside the app's `.exe`, with `crashpad_wer.dll`. |
/// | macOS | `Contents/Frameworks/fl_crashpad.framework/Versions/A/Helpers/crashpad_handler`, embedded by the plugin's pod — where Apple expects a helper tool, so it can be signed inside-out with the rest of the app. |
///
/// A Dart app has no such step. After `dart build cli`,
/// `dart run fl_crashpad:bundle <bundle>` copies the handler into the
/// bundle's `lib/`, beside the library the hook put there; and under
/// `dart run` or `dart test` it is found in the per-user cache the hook
/// filled, so development needs no step at all.
abstract final class CrashpadHandler {
  /// The handler for the running app: the first of [candidates] that exists,
  /// or, when none does, where a Flutter build would have put it.
  static File defaultPath() {
    final found = candidates(
      os: Platform.operatingSystem,
      executable: Platform.resolvedExecutable,
    );
    return found.firstWhere((f) => f.existsSync(), orElse: () => found.first);
  }

  /// Windows: `crashpad_wer.dll`, which travels beside the handler, at the
  /// first of the handler's [candidates] that has one; null elsewhere.
  static File? defaultWerModule() {
    if (!Platform.isWindows) return null;
    final found = [
      for (final handler in candidates(
        os: 'windows',
        executable: Platform.resolvedExecutable,
      ))
        File('${_parent(handler.path, r'\')}\\crashpad_wer.dll'),
    ];
    return found.firstWhere((f) => f.existsSync(), orElse: () => found.first);
  }

  /// Every place the handler of an app whose executable is [executable] may
  /// be, in the order [defaultPath] tries them:
  ///
  /// 1. where a Flutter build puts it ([pathFor]);
  /// 2. in a `dart build cli` bundle, the executable being in `<bundle>/bin/`:
  ///    `<bundle>/lib/`, where `dart run fl_crashpad:bundle` puts it;
  /// 3. only when [executable] is the Dart VM itself — `dart run`,
  ///    `dart test` — the per-user cache the build hook filled. A shipped
  ///    app is never the `dart` executable, so a bundle missing its handler
  ///    can never be covered up by this machine's cache.
  static List<File> candidates({
    required String os,
    required String executable,
    File? Function()? cached,
  }) {
    final separator = os == 'windows' ? r'\' : '/';
    final name = os == 'windows' ? 'crashpad_handler.exe' : 'crashpad_handler';
    final directory = _parent(executable, separator);
    final program = executable.split(RegExp(r'[\\/]')).last.toLowerCase();
    final fromCache = program == 'dart' || program == 'dart.exe'
        ? (cached ?? () => _cachedHandler(os))()
        : null;
    return [
      pathFor(os: os, executable: executable),
      File('${_parent(directory, separator)}${separator}lib$separator$name'),
      ?fromCache,
    ];
  }

  /// The handler for an app whose executable is [executable] on [os]
  /// (as [Platform.operatingSystem] spells it).
  static File pathFor({required String os, required String executable}) {
    final separator = os == 'windows' ? r'\' : '/';
    final directory = _parent(executable, separator);
    return switch (os) {
      'linux' => File('$directory/lib/crashpad_handler'),
      'windows' => File('$directory\\crashpad_handler.exe'),
      // <App>.app/Contents/MacOS/<App> → <App>.app/Contents/Frameworks/...
      'macos' => File(
        '${_parent(directory, separator)}/Frameworks/fl_crashpad.framework/'
        'Versions/A/Helpers/crashpad_handler',
      ),
      _ => throw UnsupportedError('fl_crashpad has no handler for $os'),
    };
  }

  static File? werModuleFor({required String os, required String executable}) {
    if (os != 'windows') return null;
    return File('${_parent(executable, r'\')}\\crashpad_wer.dll');
  }

  /// The handler in the per-user artifact cache for this machine, as the
  /// build hook left it, or null when there is none to find.
  static File? _cachedHandler(String os) {
    try {
      final target = hostTarget();
      final root = Isolate.resolvePackageUriSync(
        Uri.parse('package:fl_crashpad/'),
      );
      if (target == null || root == null) return null;
      return ArtifactResolver(
        lock: ArtifactLock.read(
          File.fromUri(root.resolve('../native/artifacts.lock.json')),
        ),
        cacheRoot: artifactCacheRoot(os: os, environment: Platform.environment),
      ).cached(target).handler;
    } on Object {
      return null;
    }
  }

  static String _parent(String path, String separator) {
    // Windows paths may arrive with either separator.
    final normalised = separator == r'\' ? path.replaceAll('/', r'\') : path;
    final cut = normalised.lastIndexOf(separator);
    return cut <= 0 ? normalised : normalised.substring(0, cut);
  }
}
