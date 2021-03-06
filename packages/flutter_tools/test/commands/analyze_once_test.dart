// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/analyze.dart';
import 'package:flutter_tools/src/commands/create.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:test/test.dart';

import '../src/common.dart';
import '../src/context.dart';

/// Test case timeout for tests involving project analysis.
const Timeout allowForSlowAnalyzeTests = const Timeout.factor(5.0);

void main() {
  final String analyzerSeparator = platform.isWindows ? '-' : '•';

  group('analyze once', () {
    Directory tempDir;
    String projectPath;
    File libMain;

    setUpAll(() {
      Cache.disableLocking();
      tempDir = fs.systemTempDirectory.createTempSync('analyze_once_test_').absolute;
      projectPath = fs.path.join(tempDir.path, 'flutter_project');
      libMain = fs.file(fs.path.join(projectPath, 'lib', 'main.dart'));
    });

    tearDownAll(() {
      try {
        tempDir?.deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        // ignore errors deleting the temporary directory
        print('Ignored exception during tearDown: $e');
      }
    });

    // Create a project to be analyzed
    testUsingContext('flutter create', () async {
      await runCommand(
        command: new CreateCommand(),
        arguments: <String>['create', projectPath],
        statusTextContains: <String>[
          'All done!',
          'Your main program file is lib/main.dart',
        ],
      );
      expect(libMain.existsSync(), isTrue);
    }, timeout: allowForRemotePubInvocation);

    // Analyze in the current directory - no arguments
    testUsingContext('working directory', () async {
      await runCommand(
        command: new AnalyzeCommand(workingDirectory: fs.directory(projectPath)),
        arguments: <String>['analyze'],
        statusTextContains: <String>['No issues found!'],
      );
    }, timeout: allowForSlowAnalyzeTests);

    // Analyze a specific file outside the current directory
    testUsingContext('passing one file throws', () async {
      await runCommand(
        command: new AnalyzeCommand(),
        arguments: <String>['analyze', libMain.path],
        toolExit: true,
        exitMessageContains: 'is not a directory',
      );
    });

    // Analyze in the current directory - no arguments
    testUsingContext('working directory with errors', () async {
      // Break the code to produce the "The parameter 'onPressed' is required" hint
      // that is upgraded to a warning in package:flutter/analysis_options_user.yaml
      // to assert that we are using the default Flutter analysis options.
      // Also insert a statement that should not trigger a lint here
      // but will trigger a lint later on when an analysis_options.yaml is added.
      String source = await libMain.readAsString();
      source = source.replaceFirst(
        'onPressed: _incrementCounter,',
        '// onPressed: _incrementCounter,',
      );
      source = source.replaceFirst(
        '_counter++;',
        '_counter++; throw "an error message";',
      );
      await libMain.writeAsString(source);

      // Analyze in the current directory - no arguments
      await runCommand(
        command: new AnalyzeCommand(workingDirectory: fs.directory(projectPath)),
        arguments: <String>['analyze'],
        statusTextContains: <String>[
          'Analyzing',
          'warning $analyzerSeparator The parameter \'onPressed\' is required',
          'info $analyzerSeparator The method \'_incrementCounter\' isn\'t used',
          '2 issues found.',
        ],
        toolExit: true,
      );
    }, timeout: allowForSlowAnalyzeTests);

    // Analyze in the current directory - no arguments
    testUsingContext('working directory with local options', () async {
      // Insert an analysis_options.yaml file in the project
      // which will trigger a lint for broken code that was inserted earlier
      final File optionsFile = fs.file(fs.path.join(projectPath, 'analysis_options.yaml'));
      await optionsFile.writeAsString('''
  include: package:flutter/analysis_options_user.yaml
  linter:
    rules:
      - only_throw_errors
  ''');

      // Analyze in the current directory - no arguments
      await runCommand(
        command: new AnalyzeCommand(workingDirectory: fs.directory(projectPath)),
        arguments: <String>['analyze'],
        statusTextContains: <String>[
          'Analyzing',
          'warning $analyzerSeparator The parameter \'onPressed\' is required',
          'info $analyzerSeparator The method \'_incrementCounter\' isn\'t used',
          'info $analyzerSeparator Only throw instances of classes extending either Exception or Error',
          '3 issues found.',
        ],
        toolExit: true,
      );
    }, timeout: allowForSlowAnalyzeTests);

    testUsingContext('no duplicate issues', () async {
      final Directory tempDir = fs.systemTempDirectory.createTempSync('analyze_once_test_').absolute;

      try {
        final File foo = fs.file(fs.path.join(tempDir.path, 'foo.dart'));
        foo.writeAsStringSync('''
import 'bar.dart';

void foo() => bar();
''');

        final File bar = fs.file(fs.path.join(tempDir.path, 'bar.dart'));
        bar.writeAsStringSync('''
import 'dart:async'; // unused

void bar() {
}
''');

        // Analyze in the current directory - no arguments
        await runCommand(
          command: new AnalyzeCommand(workingDirectory: tempDir),
          arguments: <String>['analyze'],
          statusTextContains: <String>[
            'Analyzing',
            '1 issue found.',
          ],
          toolExit: true,
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    testUsingContext('analyze', () async {
      const String contents = '''
StringBuffer bar = StringBuffer('baz');
''';
      final Directory tempDir = fs.systemTempDirectory.createTempSync();
      tempDir.childFile('main.dart').writeAsStringSync(contents);
      try {
        await runCommand(
          command: new AnalyzeCommand(workingDirectory: fs.directory(tempDir)),
          arguments: <String>['analyze'],
          statusTextContains: <String>['No issues found!'],
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

void assertContains(String text, List<String> patterns) {
  if (patterns == null) {
    expect(text, isEmpty);
  } else {
    for (String pattern in patterns) {
      expect(text, contains(pattern));
    }
  }
}

Future<Null> runCommand({
  FlutterCommand command,
  List<String> arguments,
  List<String> statusTextContains,
  List<String> errorTextContains,
  bool toolExit = false,
  String exitMessageContains,
}) async {
  try {
    arguments.insert(0, '--flutter-root=${Cache.flutterRoot}');
    await createTestCommandRunner(command).run(arguments);
    expect(toolExit, isFalse, reason: 'Expected ToolExit exception');
  } on ToolExit catch (e) {
    if (!toolExit) {
      testLogger.clear();
      rethrow;
    }
    if (exitMessageContains != null) {
      expect(e.message, contains(exitMessageContains));
    }
  }
  assertContains(testLogger.statusText, statusTextContains);
  assertContains(testLogger.errorText, errorTextContains);

  testLogger.clear();
}
