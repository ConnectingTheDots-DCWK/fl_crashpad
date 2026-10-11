// The Dart API against the real native library, short of starting Crashpad —
// which would install crash handlers in the test runner itself. Starting is
// crash_test.dart's job, in a child process.
@TestOn('linux || mac-os || windows')
library;

import 'dart:io';

import 'package:fl_crashpad/fl_crashpad.dart';
import 'package:test/test.dart';

import 'support/artifacts.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('fl_crashpad_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('the library is present, speaks this ABI and names its revision', () {
    expect(Crashpad.isAvailable, isTrue);
    expect(Crashpad.isStarted, isFalse);
    expect(Crashpad.crashpadRevision, matches(RegExp(r'^[0-9a-f]{40}$')));
  });

  group('handler location', () {
    test('Linux: lib/ beside the executable', () {
      expect(
        CrashpadHandler.pathFor(os: 'linux', executable: '/opt/app/app').path,
        '/opt/app/lib/crashpad_handler',
      );
    });

    test('Windows: beside the executable, either separator', () {
      expect(
        CrashpadHandler.pathFor(
          os: 'windows',
          executable: r'C:\Program Files\App/app.exe',
        ).path,
        r'C:\Program Files\App\crashpad_handler.exe',
      );
      expect(
        CrashpadHandler.werModuleFor(
          os: 'windows',
          executable: r'C:\App\app.exe',
        )!.path,
        r'C:\App\crashpad_wer.dll',
      );
    });

    test('a `dart build cli` bundle is tried after the Flutter place, and the '
        "cache only when the program is the Dart VM itself", () {
      File cached() => File('/cache/crashpad_handler');
      List<String> paths(String os, String executable) => [
        for (final file in CrashpadHandler.candidates(
          os: os,
          executable: executable,
          cached: cached,
        ))
          file.path,
      ];
      expect(
        paths('linux', '/opt/tool/bundle/bin/tool'),
        [
          '/opt/tool/bundle/bin/lib/crashpad_handler',
          '/opt/tool/bundle/lib/crashpad_handler',
        ],
        reason: 'a shipped app never falls back on this machine',
      );
      expect(paths('linux', '/sdk/bin/dart'), [
        '/sdk/bin/lib/crashpad_handler',
        '/sdk/lib/crashpad_handler',
        '/cache/crashpad_handler',
      ]);
      expect(paths('windows', r'C:\Tool\bundle\bin\tool.exe'), [
        r'C:\Tool\bundle\bin\crashpad_handler.exe',
        r'C:\Tool\bundle\lib\crashpad_handler.exe',
      ]);
      expect(paths('windows', r'C:\sdk\bin\DART.EXE'), hasLength(3));
    });

    test('macOS: the Helpers directory of the pod framework', () {
      expect(
        CrashpadHandler.pathFor(
          os: 'macos',
          executable: '/Applications/App.app/Contents/MacOS/App',
        ).path,
        '/Applications/App.app/Contents/Frameworks/fl_crashpad.framework/'
        'Versions/A/Helpers/crashpad_handler',
      );
    });
  });

  group('runtime annotations', () {
    final annotations = Crashpad.annotations;
    tearDown(annotations.clear);

    test('refuse what Crashpad would silently truncate', () {
      final long = 'é' * 128; // 256 bytes of UTF-8 in 128 characters.
      expect(() => annotations['k'] = long, throwsArgumentError);
      expect(() => annotations[long] = 'v', throwsArgumentError);
      expect(() => annotations[''] = 'v', throwsArgumentError);
      expect(() => annotations['k\u0000'] = 'v', throwsArgumentError);
      annotations['k'] = 'é' * 127; // 254 bytes: fits.
    });

    test('hold 64 entries, replace in place, and refuse a 65th', () {
      for (var i = 0; i < CrashpadAnnotations.maxEntries; i++) {
        annotations['key$i'] = 'value';
      }
      annotations['key0'] = 'replaced';
      expect(
        () => annotations['one-too-many'] = 'value',
        throwsA(
          isA<CrashpadException>().having(
            (e) => e.code,
            'code',
            CrashpadErrorCode.limitExceeded,
          ),
        ),
      );
      annotations.remove('key1');
      annotations['one-too-many'] = 'value';
    });
  });

  group('start refuses a handler it cannot trust', () {
    final built = hostArtifacts().handler!;

    CrashpadErrorCode startWith(File handler) {
      try {
        Crashpad.start(
          CrashpadOptions(
            databaseDirectory: Directory('${temp.path}/db'),
            handler: handler,
          ),
        );
      } on CrashpadException catch (e) {
        return e.code;
      }
      fail('start succeeded and installed handlers in the test runner');
    }

    test('one that is not there', () {
      expect(
        startWith(File('${temp.path}/nowhere/crashpad_handler')),
        CrashpadErrorCode.handlerMissing,
      );
    });

    test('one that lost its executable bit', () {
      final copy = built.copySync('${temp.path}/crashpad_handler');
      Process.runSync('chmod', ['644', copy.path]);
      expect(startWith(copy), CrashpadErrorCode.handlerNotExecutable);
    }, testOn: '!windows');

    test('one from a different Crashpad build', () {
      final copy = built.copySync(
        '${temp.path}/${built.uri.pathSegments.last}',
      );
      File(
        '${temp.path}/crashpad_handler.rev',
      ).writeAsStringSync('0000000000000000000000000000000000000000\n');
      expect(startWith(copy), CrashpadErrorCode.revisionMismatch);
    });

    test('and none of those left Crashpad started', () {
      expect(Crashpad.isStarted, isFalse);
    });
  });

  group('database', () {
    test('consent is off until turned on, and stays as it was set', () {
      final database = CrashReportDatabase(temp);
      expect(database.uploadConsent, isFalse);
      database.uploadConsent = true;
      expect(CrashReportDatabase(temp).uploadConsent, isTrue);
    });

    test('consent given under 0.1 is still consent', () {
      // The name changed and the stored key did not: renaming the key would
      // quietly withdraw every yes a user had already given.
      Directory('${temp.path}/fl_crashpad').createSync(recursive: true);
      File('${temp.path}/fl_crashpad/settings.json').writeAsStringSync(
        '{"version": 1, "uploadsEnabled": true, "sanitize": true}',
      );
      expect(CrashReportDatabase(temp).uploadConsent, isTrue);
    });

    test('a report that is not there, or an id that is not one', () async {
      final database = CrashReportDatabase(temp);
      expect(await database.reports(), isEmpty);
      expect(
        () => database.delete('01234567-89ab-cdef-0123-456789abcdef'),
        throwsA(
          isA<CrashpadException>().having(
            (e) => e.code,
            'code',
            CrashpadErrorCode.reportNotFound,
          ),
        ),
      );
      await expectLater(
        database.requestUpload('not-a-uuid'),
        throwsA(
          isA<CrashpadException>().having(
            (e) => e.code,
            'code',
            CrashpadErrorCode.reportNotFound,
          ),
        ),
      );
    });
  });
}
