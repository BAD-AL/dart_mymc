import 'dart:io';
import 'dart:typed_data';
import 'package:dart_mymc/dart_mymc.dart';
import 'package:dart_mymc/dart_mymc_cli.dart';
import 'package:dart_mymc/src/ps2card_io_native.dart';
import 'package:dart_mymc/src/lzari.dart';
import 'package:dart_mymc/src/ps2mc.dart';
import 'package:dart_mymc/src/ps2mc_ecc.dart';
import 'package:dart_mymc/src/ps2save.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

const String testCard = 'test/test_files/Mcd001.ps2';

// Expected root directory entry names (from Python: ls /)
const List<String> expectedRootNames = [
  '.',
  '..',
  'BASLUS-20956Game 1',
  'BADATA-SYSTEM',
  'BASLUS-20919NFL26Fra',
  'BASLUS-20919NFL2K16',
  'BASLUS-20919VIP1',
];

void main() {
  group('Ps2MemoryCard — Mcd001.ps2', () {
    late Ps2MemoryCard mc;

    setUp(() {
      mc = openCardFile(testCard);
    });

    tearDown(() => mc.close());

    // -------------------------------------------------------------------------
    // df
    // -------------------------------------------------------------------------

    test('getFreeSpace matches Python reference (6494208 bytes)', () {
      // Python: dart_mymc.ps2 test/test_files/Mcd001.ps2 df → 6494208 bytes free.
      expect(mc.getFreeSpace(), equals(6494208));
    });

    // -------------------------------------------------------------------------
    // ls /
    // -------------------------------------------------------------------------

    test('root directory has expected entry names', () {
      final dir = mc.dirOpen('/');
      final names = dir.map((e) => e.name).toList();
      dir.close();
      expect(names, equals(expectedRootNames));
    });

    test('root "." entry is a directory with DF_EXISTS set', () {
      final dir = mc.dirOpen('/');
      final dot = dir.first;
      dir.close();
      expect(dot.name, equals('.'));
      expect(dot.isDir, isTrue);
      expect(dot.exists, isTrue);
    });

    test('root ".." entry is a directory', () {
      final dir = mc.dirOpen('/');
      final entries = dir.toList();
      dir.close();
      expect(entries[1].name, equals('..'));
      expect(entries[1].isDir, isTrue);
    });

    test('root directory has 5 save directories (excluding . and ..)', () {
      final dir = mc.dirOpen('/');
      final saveDirs =
          dir.where((e) => e.isDir && e.name != '.' && e.name != '..').toList();
      dir.close();
      expect(saveDirs.length, equals(5));
    });

    test('BASLUS-20919NFL2K16 save directory is present', () {
      final dir = mc.dirOpen('/');
      final names = dir.map((e) => e.name).toList();
      dir.close();
      expect(names, contains('BASLUS-20919NFL2K16'));
    });

    test('BADATA-SYSTEM save directory is present', () {
      final dir = mc.dirOpen('/');
      final names = dir.map((e) => e.name).toList();
      dir.close();
      expect(names, contains('BADATA-SYSTEM'));
    });

    test('mode bits for BASLUS-20919NFL2K16 include DF_EXISTS and DF_DIR', () {
      final dir = mc.dirOpen('/');
      final nfl = dir.firstWhere((e) => e.name == 'BASLUS-20919NFL2K16');
      dir.close();
      expect(nfl.isDir, isTrue);
      expect(nfl.exists, isTrue);
    });

    // -------------------------------------------------------------------------
    // chdir + dirOpen on sub-directories
    // -------------------------------------------------------------------------

    test('can chdir into a save directory', () {
      expect(() => mc.chdir('/BASLUS-20919NFL2K16'), returnsNormally);
    });

    test('save directory contents include icon.sys', () {
      mc.chdir('/BASLUS-20919NFL2K16');
      final dir = mc.dirOpen('.');
      final names = dir.map((e) => e.name).toList();
      dir.close();
      expect(names, contains('icon.sys'));
    });

    // -------------------------------------------------------------------------
    // getIconSys + icon title
    // -------------------------------------------------------------------------

    test('getIconSys returns 964 bytes for NFL2K16 save', () {
      mc.chdir('/BASLUS-20919NFL2K16');
      final raw = mc.getIconSys('.');
      expect(raw, isNotNull);
      expect(raw!.length, equals(IconSys.size));
    });

    test('getIconSys starts with PS2D magic', () {
      mc.chdir('/BASLUS-20919NFL2K16');
      final raw = mc.getIconSys('.');
      expect(raw, isNotNull);
      expect(raw![0], equals(0x50)); // P
      expect(raw[1], equals(0x53)); // S
      expect(raw[2], equals(0x32)); // 2
      expect(raw[3], equals(0x44)); // D
    });

    test('icon.sys title line 1 for NFL2K16 is "ESPN NFL 2K5"', () {
      // Python reference: dir output → 'ESPN NFL 2K5'
      mc.chdir('/BASLUS-20919NFL2K16');
      final raw = mc.getIconSys('.');
      expect(raw, isNotNull);
      final iconSys = IconSys.unpack(raw!);
      expect(iconSys, isNotNull);
      final (t1, _) = iconSys!.title();
      expect(t1, equals('ESPN NFL 2K5'));
    });

    // -------------------------------------------------------------------------
    // dirSize
    // -------------------------------------------------------------------------

    test('dirSize for BASLUS-20919NFL2K16 is approximately 747 KB', () {
      // Python reference: dir output shows "747KB"
      mc.chdir('/BASLUS-20919NFL2K16');
      final size = mc.dirSize('.');
      // Allow ±1 cluster (1024 bytes) tolerance.
      expect(size, greaterThanOrEqualTo(747 * 1024 - 1024));
      expect(size, lessThanOrEqualTo(747 * 1024 + 1024));
    });

    test('dirSize for BADATA-SYSTEM is approximately 5 KB', () {
      // Python reference: dir output shows "5KB"
      mc.chdir('/BADATA-SYSTEM');
      final size = mc.dirSize('.');
      expect(size, greaterThanOrEqualTo(5 * 1024 - 1024));
      expect(size, lessThanOrEqualTo(5 * 1024 + 2048));
    });

    // -------------------------------------------------------------------------
    // ECC
    // -------------------------------------------------------------------------

    test('eccCalculate round-trip on all-zero block is correct', () {
      final block = Uint8List(128);
      final ecc = eccCalculate(block);
      final eccCopy = List<int>.from(ecc);
      expect(eccCheck(block, eccCopy), equals(eccCheckOk));
    });

    test('eccCheck detects and corrects a single-bit data error', () {
      final block = Uint8List(128);
      final ecc = eccCalculate(block);
      final corrupt = Uint8List.fromList(block);
      corrupt[42] ^= 0x08; // flip one bit
      final eccCopy = List<int>.from(ecc);
      final result = eccCheck(corrupt, eccCopy);
      expect(result, equals(eccCheckCorrected));
      expect(corrupt[42], equals(block[42])); // corrected in place
    });
  });

  // -------------------------------------------------------------------------
  // CLI integration test via Process.run
  // -------------------------------------------------------------------------

  group('CLI integration', () {
    test('df output matches Python golden file', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/dart_mymc.dart', testCard, 'df'],
      );
      expect(result.exitCode, equals(0));
      final golden = File('test/test_files/golden_df.txt').readAsStringSync();
      expect(result.stdout.toString(), equals(golden));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('ls output matches Python golden file', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/dart_mymc.dart', testCard, 'ls'],
      );
      expect(result.exitCode, equals(0));
      final golden = File('test/test_files/golden_ls.txt').readAsStringSync();
      expect(result.stdout.toString(), equals(golden));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('dir output matches Python golden file', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/dart_mymc.dart', testCard, 'dir'],
      );
      expect(result.exitCode, equals(0));
      final golden = File('test/test_files/golden_dir.txt').readAsStringSync();
      expect(result.stdout.toString(), equals(golden));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  // -------------------------------------------------------------------------
  // Phase 3 — write operations (unit tests on a fresh formatted card)
  // -------------------------------------------------------------------------

  group('Phase 3 — write operations', () {
    late Directory tmpDir;
    late String freshCard;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_test_');
      freshCard = p.join(tmpDir.path, 'fresh.ps2');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    // -------------------------------------------------------------------------
    // format
    // -------------------------------------------------------------------------

    test('format creates a valid card with free space', () {
      final mc = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      final free = mc.getFreeSpace();
      mc.close();
      expect(free, greaterThan(0));
    });

    test('format: root dir has "." and ".." entries', () {
      final mc = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      final dir = mc.dirOpen('/');
      final entries = dir.toList();
      dir.close();
      mc.close();
      expect(entries[0].name, equals('.'));
      expect(entries[1].name, equals('..'));
    });

    test('format: 16MB card has double the capacity of 8MB', () {
      final mc8 = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      final free8 = mc8.getFreeSpace();
      mc8.close();

      final fresh16 = p.join(tmpDir.path, 'fresh16.ps2');
      final mc16 = openCardFile(fresh16,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard * 2,
          ]);
      final free16 = mc16.getFreeSpace();
      mc16.close();

      expect(free16, greaterThan(free8 * 1.9));
    });

    test('format: 64MB card has approx 8x capacity of 8MB', () {
      final mc8 = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      final free8 = mc8.getFreeSpace();
      mc8.close();

      final fresh64 = p.join(tmpDir.path, 'fresh64.ps2');
      final mc64 = openCardFile(fresh64,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard * 8,
          ]);
      final free64 = mc64.getFreeSpace();
      mc64.close();

      expect(free64, greaterThan(free8 * 7.5));
    });

    // -------------------------------------------------------------------------
    // mkdir
    // -------------------------------------------------------------------------

    test('mkdir creates a directory visible in ls', () {
      final mc = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      mc.mkdir('/TESTDIR');
      final dir = mc.dirOpen('/');
      final names = dir.map((e) => e.name).toList();
      dir.close();
      mc.close();
      expect(names, contains('TESTDIR'));
    });

    test('mkdir: directory not found error for bad parent', () {
      final mc = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      mc.close();
      // Open read-only; trying to mkdir should fail gracefully when parent
      // doesn't exist — re-open and test via pathSearch.
      final mc2 = openCardFile(freshCard);
      expect(
        () => mc2.mkdir('/NONEXIST/SUBDIR'),
        throwsA(isA<Ps2McError>()),
      );
      mc2.close();
    });

    // -------------------------------------------------------------------------
    // write / read round-trip
    // -------------------------------------------------------------------------

    test('write and read file round-trip', () {
      final mc = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      mc.mkdir('/SAVEDATA');
      mc.chdir('/SAVEDATA');
      final content = Uint8List.fromList(
          List.generate(1024 + 256, (i) => i & 0xFF));
      final wf = mc.open('data.bin', mode: 'wb');
      wf.write(content);
      wf.close();

      final rf = mc.open('data.bin');
      final readBack = rf.read();
      rf.close();
      mc.close();

      expect(readBack, equals(content));
    });

    // -------------------------------------------------------------------------
    // remove
    // -------------------------------------------------------------------------

    test('remove deletes a file; it no longer appears in ls', () {
      final mc = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      mc.mkdir('/SAVEDATA');
      mc.chdir('/SAVEDATA');
      final wf = mc.open('tmp.bin', mode: 'wb');
      wf.write(Uint8List(64));
      wf.close();
      mc.remove('/SAVEDATA/tmp.bin');
      final dir = mc.dirOpen('/SAVEDATA');
      final names = dir
          .where((e) => e.exists)
          .map((e) => e.name)
          .toList();
      dir.close();
      mc.close();
      expect(names, isNot(contains('tmp.bin')));
    });

    // -------------------------------------------------------------------------
    // delete (rmdir)
    // -------------------------------------------------------------------------

    test('delete removes a save directory and frees space', () {
      final mc = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      final freeBefore = mc.getFreeSpace();
      mc.mkdir('/SAVEDATA');
      mc.chdir('/SAVEDATA');
      final wf = mc.open('data.bin', mode: 'wb');
      wf.write(Uint8List(1024));
      wf.close();
      mc.rmdir('/SAVEDATA');
      final freeAfter = mc.getFreeSpace();
      mc.close();
      // Space should be close to original (root dir extension cluster not reclaimed).
      expect(freeAfter, greaterThanOrEqualTo(freeBefore - 1024));
    });

    // -------------------------------------------------------------------------
    // export / import round-trip (PSU)
    // -------------------------------------------------------------------------

    test('exportSaveFile / importSaveFile PSU round-trip', () {
      // Export NFL2K16 from test card.
      final mc = openCardFile(testCard);
      final sf = mc.exportSaveFile('/BASLUS-20919NFL2K16');
      mc.close();

      // Import into fresh card.
      final mc2 = openCardFile(freshCard,
          formatParams: [
            1,
            ps2mcStandardPageSize,
            ps2mcStandardPagesPerEraseBlock,
            ps2mcStandardPagesPerCard,
          ]);
      final ok = mc2.importSaveFile(sf, false);
      expect(ok, isTrue);

      // Verify title.
      mc2.chdir('/BASLUS-20919NFL2K16');
      final raw = mc2.getIconSys('.');
      expect(raw, isNotNull);
      final iconSys = IconSys.unpack(raw!)!;
      final (t1, _) = iconSys.title();
      mc2.close();
      expect(t1, equals('ESPN NFL 2K5'));
    });

    test('saveEms / loadEms round-trip via file', () {
      // Export NFL2K16 from test card to a .psu file.
      final mc = openCardFile(testCard);
      final sf = mc.exportSaveFile('/BASLUS-20919NFL2K16');
      mc.close();

      final psuPath = p.join(tmpDir.path, 'NFL2K16.psu');
      final wraf = File(psuPath).openSync(mode: FileMode.write);
      sf.saveEms(FileSaveIo(wraf));
      wraf.closeSync();

      // Load it back.
      final sf2 = Ps2SaveFile();
      final rraf = File(psuPath).openSync();
      sf2.loadEms(FileSaveIo(rraf));
      rraf.closeSync();

      expect(sf2.getDirectory().name, equals(sf.getDirectory().name));
      expect(sf2.getDirectory().length, equals(sf.getDirectory().length));
      // Verify file data matches for first file.
      final (ent1, data1) = sf.getFile(0);
      final (ent2, data2) = sf2.getFile(0);
      expect(ent2.name, equals(ent1.name));
      expect(data2, equals(data1));
    });
  });

  // -------------------------------------------------------------------------
  // Phase 3 CLI integration tests
  // -------------------------------------------------------------------------

  group('Phase 3 CLI integration', () {
    late Directory tmpDir;
    late String freshCard;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_cli_test_');
      freshCard = p.join(tmpDir.path, 'fresh.ps2');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('format command creates a card with non-zero free space', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/dart_mymc.dart', freshCard, 'format'],
      );
      expect(result.exitCode, equals(0));
      final df = await Process.run(
        'dart',
        ['run', 'bin/dart_mymc.dart', freshCard, 'df'],
      );
      expect(df.exitCode, equals(0));
      expect(df.stdout.toString(), contains('bytes free'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('export then import round-trip via CLI', () async {
      // Format fresh card.
      final fmt = await Process.run('dart',
          ['run', 'bin/dart_mymc.dart', freshCard, 'format']);
      expect(fmt.exitCode, equals(0));

      // Export NFL2K16 from test card.
      final psuPath = p.join(tmpDir.path, 'NFL2K16.psu');
      final exp = await Process.run('dart', [
        'run',
        'bin/dart_mymc.dart',
        testCard,
        'export',
        '-o',
        psuPath,
        '/BASLUS-20919NFL2K16',
      ]);
      expect(exp.exitCode, equals(0));
      expect(File(psuPath).existsSync(), isTrue);

      // Import into fresh card.
      final imp = await Process.run('dart', [
        'run',
        'bin/dart_mymc.dart',
        freshCard,
        'import',
        psuPath,
      ]);
      expect(imp.exitCode, equals(0));

      // Check that dir shows the title.
      final dir = await Process.run('dart',
          ['run', 'bin/dart_mymc.dart', freshCard, 'dir']);
      expect(dir.exitCode, equals(0));
      expect(dir.stdout.toString(), contains('ESPN NFL 2K5'));
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  // -------------------------------------------------------------------------
  // Phase 4 — LZARI codec (unit tests, no external files)
  // -------------------------------------------------------------------------

  group('Phase 4 — LZARI codec', () {
    test('lzariDecode + lzariEncode round-trip on sequential bytes', () {
      final src = Uint8List.fromList(List.generate(200, (i) => i % 256));
      final compressed = lzariEncode(src);
      final decompressed = lzariDecode(compressed, src.length);
      expect(decompressed, equals(src));
    });

    test('lzariDecode + lzariEncode round-trip on repetitive data', () {
      final src = Uint8List.fromList(
          List.generate(1024, (i) => i % 8 < 4 ? 0x41 : 0x20));
      final compressed = lzariEncode(src);
      // Repetitive data should compress significantly
      expect(compressed.length, lessThan(src.length));
      final decompressed = lzariDecode(compressed, src.length);
      expect(decompressed, equals(src));
    });

    test('lzariEncode empty input returns empty output', () {
      expect(lzariEncode(Uint8List(0)).length, equals(0));
    });

    test('lzariDecode empty output returns empty output', () {
      // Any input with outLength=0 returns empty
      expect(lzariDecode(Uint8List(0), 0).length, equals(0));
    });
  });

  // -------------------------------------------------------------------------
  // Phase 4 — MAX Drive format (unit tests)
  // -------------------------------------------------------------------------

  group('Phase 4 — MAX Drive format', () {
    const String maxFile = 'test/test_files/NFL2K16.max';

    test('loadMax reads directory name correctly', () {
      final raf = File(maxFile).openSync();
      final sf = Ps2SaveFile();
      try {
        sf.loadMax(FileSaveIo(raf));
      } finally {
        raf.closeSync();
      }
      expect(sf.getDirectory().name, equals('BASLUS-20919NFL2K16'));
    });

    test('loadMax reads correct file count', () {
      final raf = File(maxFile).openSync();
      final sf = Ps2SaveFile();
      try {
        sf.loadMax(FileSaveIo(raf));
      } finally {
        raf.closeSync();
      }
      expect(sf.getDirectory().length, equals(5));
    });

    test('loadMax icon.sys title is "ESPN NFL 2K5"', () {
      final raf = File(maxFile).openSync();
      final sf = Ps2SaveFile();
      try {
        sf.loadMax(FileSaveIo(raf));
      } finally {
        raf.closeSync();
      }
      final iconSys = sf.getIconSys();
      expect(iconSys, isNotNull);
      final (t1, _) = iconSys!.title();
      expect(t1, equals('ESPN NFL 2K5'));
    });

    test('saveMax / loadMax round-trip preserves title and file data', () {
      late Directory tmpDir;
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_max_');
      try {
        // Load original
        final raf1 = File(maxFile).openSync();
        final sf1 = Ps2SaveFile();
        try {
          sf1.loadMax(FileSaveIo(raf1));
        } finally {
          raf1.closeSync();
        }

        // Save as MAX
        final outPath = p.join(tmpDir.path, 'test.max');
        final wraf = File(outPath).openSync(mode: FileMode.write);
        try {
          sf1.saveMax(FileSaveIo(wraf));
        } finally {
          wraf.closeSync();
        }

        // Reload
        final raf2 = File(outPath).openSync();
        final sf2 = Ps2SaveFile();
        try {
          sf2.loadMax(FileSaveIo(raf2));
        } finally {
          raf2.closeSync();
        }

        // Verify directory
        expect(sf2.getDirectory().name, equals(sf1.getDirectory().name));
        expect(sf2.getDirectory().length, equals(sf1.getDirectory().length));

        // Verify file data matches for each file
        for (int i = 0; i < sf1.getDirectory().length; i++) {
          final (e1, d1) = sf1.getFile(i);
          final (e2, d2) = sf2.getFile(i);
          expect(e2.name, equals(e1.name));
          expect(d2, equals(d1));
        }

        // Verify title
        final iconSys = sf2.getIconSys();
        expect(iconSys, isNotNull);
        final (t1, _) = iconSys!.title();
        expect(t1, equals('ESPN NFL 2K5'));
      } finally {
        tmpDir.deleteSync(recursive: true);
      }
    });
  });

  // -------------------------------------------------------------------------
  // Phase 4 CLI integration — MAX export/import
  // -------------------------------------------------------------------------

  group('Phase 4 CLI integration — MAX format', () {
    late Directory tmpDir;
    late String freshCard;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_max_cli_');
      freshCard = p.join(tmpDir.path, 'fresh.ps2');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('export -t max then import round-trip via CLI', () async {
      // Format fresh card
      final fmt = await Process.run('dart',
          ['run', 'bin/dart_mymc.dart', freshCard, 'format']);
      expect(fmt.exitCode, equals(0));

      // Export NFL2K16 as .max
      final maxPath = p.join(tmpDir.path, 'NFL2K16.max');
      final exp = await Process.run('dart', [
        'run', 'bin/dart_mymc.dart', testCard, 'export',
        '-t', 'max', '-o', maxPath, '/BASLUS-20919NFL2K16',
      ]);
      expect(exp.exitCode, equals(0));
      expect(File(maxPath).existsSync(), isTrue);

      // Import into fresh card
      final imp = await Process.run('dart',
          ['run', 'bin/dart_mymc.dart', freshCard, 'import', maxPath]);
      expect(imp.exitCode, equals(0));

      // Verify title appears in dir
      final dir = await Process.run('dart',
          ['run', 'bin/dart_mymc.dart', freshCard, 'dir']);
      expect(dir.exitCode, equals(0));
      expect(dir.stdout.toString(), contains('ESPN NFL 2K5'));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  // -------------------------------------------------------------------------
  // Phase 5 — format conversion (unit)
  //
  // These tests verify PSU↔MAX conversion using the already-implemented
  // saveEms / saveMax methods.  They also serve as the oracle check:
  // loading the Python-generated NFL2K16.max → converting to PSU → comparing
  // file data with the Python-generated NFL2K16.psu must match byte-for-byte.
  // -------------------------------------------------------------------------

  group('Phase 5 — format conversion (unit)', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_p5_conv_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('PSU → MAX round-trip preserves dir name, file names, and data', () {
      // Load Python-generated PSU.
      final sf1 = Ps2SaveFile();
      final raf1 = File('test/test_files/NFL2K16.psu').openSync();
      try {
        sf1.loadEms(FileSaveIo(raf1));
      } finally {
        raf1.closeSync();
      }

      // Convert to MAX.
      final maxPath = p.join(tmpDir.path, 'converted.max');
      final wraf = File(maxPath).openSync(mode: FileMode.write);
      try {
        sf1.saveMax(FileSaveIo(wraf));
      } finally {
        wraf.closeSync();
      }

      // Reload as MAX.
      final sf2 = Ps2SaveFile();
      final raf2 = File(maxPath).openSync();
      try {
        sf2.loadMax(FileSaveIo(raf2));
      } finally {
        raf2.closeSync();
      }

      expect(sf2.getDirectory().name, equals(sf1.getDirectory().name));
      expect(sf2.getDirectory().length, equals(sf1.getDirectory().length));
      for (int i = 0; i < sf1.getDirectory().length; i++) {
        final (e1, d1) = sf1.getFile(i);
        final (e2, d2) = sf2.getFile(i);
        expect(e2.name, equals(e1.name), reason: 'file $i name');
        expect(d2, equals(d1), reason: 'file $i data');
      }
    });

    test('MAX → PSU file data matches Python-generated PSU (oracle check)', () {
      // Load Python-generated MAX.
      final sfMax = Ps2SaveFile();
      final raf1 = File('test/test_files/NFL2K16.max').openSync();
      try {
        sfMax.loadMax(FileSaveIo(raf1));
      } finally {
        raf1.closeSync();
      }

      // Convert to PSU via Dart.
      final psuPath = p.join(tmpDir.path, 'dart.psu');
      final wraf = File(psuPath).openSync(mode: FileMode.write);
      try {
        sfMax.saveEms(FileSaveIo(wraf));
      } finally {
        wraf.closeSync();
      }

      // Load both the Dart-produced PSU and the Python-produced PSU.
      final sfDart = Ps2SaveFile();
      final fd = File(psuPath).openSync();
      try {
        sfDart.loadEms(FileSaveIo(fd));
      } finally {
        fd.closeSync();
      }

      final sfPy = Ps2SaveFile();
      final fp = File('test/test_files/NFL2K16.psu').openSync();
      try {
        sfPy.loadEms(FileSaveIo(fp));
      } finally {
        fp.closeSync();
      }

      // Oracle: directory name and file data must match.
      expect(sfDart.getDirectory().name, equals(sfPy.getDirectory().name));
      expect(sfDart.getDirectory().length, equals(sfPy.getDirectory().length));
      for (int i = 0; i < sfPy.getDirectory().length; i++) {
        final (ep, dp) = sfPy.getFile(i);
        final (ed, dd) = sfDart.getFile(i);
        expect(ed.name, equals(ep.name), reason: 'file $i name');
        expect(dd, equals(dp), reason: 'file $i data byte-for-byte');
      }
    });
  });

  // -------------------------------------------------------------------------
  // Phase 5 — create command (unit)
  //
  // doCreate formats a fresh card and imports the given save file(s).
  // These tests will FAIL until doCreate is implemented.
  // -------------------------------------------------------------------------

  group('Phase 5 — create command (unit)', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_p5_create_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('doCreate from PSU: card has correct save title', () {
      final cardPath = p.join(tmpDir.path, 'from_psu.ps2');

      // Will throw UnimplementedError until doCreate is implemented.
      final exitCode = doCreate('create', cardPath,
          ['test/test_files/NFL2K16.psu']);
      expect(exitCode, equals(0));

      // Verify the card contains the save.
      final mc = openCardFile(cardPath);
      mc.chdir('/BASLUS-20919NFL2K16');
      final raw = mc.getIconSys('.');
      mc.close();
      expect(raw, isNotNull);
      final (t1, _) = IconSys.unpack(raw!)!.title();
      expect(t1, equals('ESPN NFL 2K5'));
    });

    test('doCreate from MAX: card has the save directory', () {
      final cardPath = p.join(tmpDir.path, 'from_max.ps2');

      final exitCode = doCreate('create', cardPath,
          ['test/test_files/NFL2K16.max']);
      expect(exitCode, equals(0));

      final mc = openCardFile(cardPath);
      mc.chdir('/BASLUS-20919NFL2K16');
      final raw = mc.getIconSys('.');
      mc.close();
      expect(raw, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // Phase 5 CLI integration — create and convert commands
  //
  // These tests use Process.run and will FAIL until the commands are wired up.
  // -------------------------------------------------------------------------

  group('Phase 5 CLI integration — create and convert', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_p5_cli_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('create command: new card from PSU shows correct title in dir',
        () async {
      final cardPath = p.join(tmpDir.path, 'new.ps2');
      final create = await Process.run('dart', [
        'run', 'bin/dart_mymc.dart',
        cardPath, 'create',
        'test/test_files/NFL2K16.psu',
      ]);
      expect(create.exitCode, equals(0),
          reason: 'stderr: ${create.stderr}');

      final dir = await Process.run('dart',
          ['run', 'bin/dart_mymc.dart', cardPath, 'dir']);
      expect(dir.exitCode, equals(0));
      expect(dir.stdout.toString(), contains('ESPN NFL 2K5'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('create command: new card from MAX shows correct title in dir',
        () async {
      final cardPath = p.join(tmpDir.path, 'new.ps2');
      final create = await Process.run('dart', [
        'run', 'bin/dart_mymc.dart',
        cardPath, 'create',
        'test/test_files/NFL2K16.max',
      ]);
      expect(create.exitCode, equals(0),
          reason: 'stderr: ${create.stderr}');

      final dir = await Process.run('dart',
          ['run', 'bin/dart_mymc.dart', cardPath, 'dir']);
      expect(dir.exitCode, equals(0));
      expect(dir.stdout.toString(), contains('ESPN NFL 2K5'));
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('convert command: PSU → MAX contains correct save data', () async {
      final outMax = p.join(tmpDir.path, 'out.max');
      final convert = await Process.run('dart', [
        'run', 'bin/dart_mymc.dart',
        'convert',
        'test/test_files/NFL2K16.psu',
        outMax,
      ]);
      expect(convert.exitCode, equals(0),
          reason: 'stderr: ${convert.stderr}');
      expect(File(outMax).existsSync(), isTrue);

      // Verify the output is loadable and has the right title.
      final sf = Ps2SaveFile();
      final raf = File(outMax).openSync();
      try {
        sf.loadMax(FileSaveIo(raf));
      } finally {
        raf.closeSync();
      }
      expect(sf.getDirectory().name, equals('BASLUS-20919NFL2K16'));
      expect(sf.getIconSys()?.title().$1, equals('ESPN NFL 2K5'));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('convert command: MAX → PSU file data matches Python PSU', () async {
      final outPsu = p.join(tmpDir.path, 'out.psu');
      final convert = await Process.run('dart', [
        'run', 'bin/dart_mymc.dart',
        'convert',
        'test/test_files/NFL2K16.max',
        outPsu,
      ]);
      expect(convert.exitCode, equals(0),
          reason: 'stderr: ${convert.stderr}');
      expect(File(outPsu).existsSync(), isTrue);

      // Load Dart-converted PSU.
      final sfDart = Ps2SaveFile();
      final fd = File(outPsu).openSync();
      try {
        sfDart.loadEms(FileSaveIo(fd));
      } finally {
        fd.closeSync();
      }

      // Load Python-generated PSU as oracle.
      final sfPy = Ps2SaveFile();
      final fp = File('test/test_files/NFL2K16.psu').openSync();
      try {
        sfPy.loadEms(FileSaveIo(fp));
      } finally {
        fp.closeSync();
      }

      expect(sfDart.getDirectory().name, equals(sfPy.getDirectory().name));
      expect(sfDart.getDirectory().length, equals(sfPy.getDirectory().length));
      for (int i = 0; i < sfPy.getDirectory().length; i++) {
        final (ep, dp) = sfPy.getFile(i);
        final (ed, dd) = sfDart.getFile(i);
        expect(ed.name, equals(ep.name), reason: 'file $i name');
        expect(dd, equals(dp), reason: 'file $i data');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // -------------------------------------------------------------------------
  // Phase 7 — Ps2Card public API (no dart:io in test code, no internal types)
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // Phase 8 — import folder + import-all (unit)
  // -------------------------------------------------------------------------

  group('Phase 8 — import folder and import-all (unit)', () {
    late Directory tmpDir;
    late String freshCard;

    // Export all saves from the test card to a temp dir; returns the dir path.
    String _exportAll() {
      final exportDir =
          Directory.systemTemp.createTempSync('dart_mymc_imp_setup_');
      final srcMc = openCardFile(testCard);
      doExportAll('export-all', srcMc, ['-d', exportDir.path]);
      srcMc.close();
      return exportDir.path;
    }

    // Return an open fresh card (formatted, no ECC).
    Ps2MemoryCard _freshMc() => openCardFile(freshCard);

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_import_test_');
      freshCard = p.join(tmpDir.path, 'fresh.ps2');
      doFormat('format', freshCard, ['-e']);
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    int _saveCount(Ps2MemoryCard mc) {
      final root = mc.dirOpen('/');
      final count =
          root.where((e) => e.isDir && e.name != '.' && e.name != '..').length;
      root.close();
      return count;
    }

    test('import folder round-trips a single save', () {
      final srcMc = openCardFile(testCard);
      doExportFiles('export-files', srcMc,
          ['-d', tmpDir.path, '/BASLUS-20919NFL2K16']);
      srcMc.close();

      final mc = _freshMc();
      try {
        final rc = doImport(
            'import', mc, [p.join(tmpDir.path, 'BASLUS-20919NFL2K16')]);
        expect(rc, equals(0));
        expect(_saveCount(mc), equals(1));
      } finally {
        mc.close();
      }
    });

    test('import folder -i skips when save already exists on card', () {
      final srcMc = openCardFile(testCard);
      doExportFiles('export-files', srcMc,
          ['-d', tmpDir.path, '/BASLUS-20919NFL2K16']);
      srcMc.close();

      final mc = _freshMc();
      try {
        final folderPath = p.join(tmpDir.path, 'BASLUS-20919NFL2K16');
        expect(doImport('import', mc, [folderPath]), equals(0));
        expect(doImport('import', mc, [folderPath]), equals(1));
        expect(doImport('import', mc, ['-i', folderPath]), equals(0));
        expect(_saveCount(mc), equals(1)); // still just the one save
      } finally {
        mc.close();
      }
    });

    test('import-all imports all 5 saves from exported folder', () {
      final exportDir = _exportAll();
      final mc = _freshMc();
      try {
        final rc = doImportAll('import-all', mc, [exportDir]);
        expect(rc, equals(0));
        expect(_saveCount(mc), equals(5));
      } finally {
        mc.close();
        Directory(exportDir).deleteSync(recursive: true);
      }
    });

    test('import-all -i skips already-imported saves', () {
      final exportDir = _exportAll();
      final mc = _freshMc();
      try {
        doImportAll('import-all', mc, [exportDir]);
        final rc = doImportAll('import-all', mc, ['-i', exportDir]);
        expect(rc, equals(0));
        expect(_saveCount(mc), equals(5));
      } finally {
        mc.close();
        Directory(exportDir).deleteSync(recursive: true);
      }
    });

    test('import-all skips non-directory entries with a warning', () {
      // Put a stray file alongside a real save dir.
      File(p.join(tmpDir.path, 'readme.txt')).writeAsStringSync('stray');
      final srcMc = openCardFile(testCard);
      doExportFiles('export-files', srcMc,
          ['-d', tmpDir.path, '/BASLUS-20919NFL2K16']);
      srcMc.close();

      final mc = _freshMc();
      try {
        final rc = doImportAll('import-all', mc, [tmpDir.path]);
        expect(rc, equals(0));
        // Only the directory was imported; stray file and fresh.ps2 skipped.
        expect(_saveCount(mc), equals(1));
      } finally {
        mc.close();
      }
    });

    test('import-all errors when source folder does not exist', () {
      final mc = _freshMc();
      try {
        expect(doImportAll('import-all', mc, ['/nonexistent_xyz']), equals(1));
      } finally {
        mc.close();
      }
    });

    test('import-all requires a source folder argument', () {
      final mc = _freshMc();
      try {
        expect(doImportAll('import-all', mc, []), equals(1));
      } finally {
        mc.close();
      }
    });
  });

  // -------------------------------------------------------------------------
  // Phase 8 CLI — import-all
  // -------------------------------------------------------------------------

  group('Phase 8 CLI integration — import-all', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_cli_impall_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('import-all CLI round-trips all saves via export-all', () async {
      // Export all saves to a temp folder.
      final expResult = await Process.run('dart', [
        'run', 'bin/dart_mymc.dart', testCard,
        'export-all', '-d', tmpDir.path,
      ]);
      expect(expResult.exitCode, equals(0));

      // Format a fresh card.
      final freshCard = p.join(tmpDir.path, 'fresh.ps2');
      await Process.run('dart',
          ['run', 'bin/dart_mymc.dart', freshCard, 'format']);

      // Import all back in.
      final impResult = await Process.run('dart', [
        'run', 'bin/dart_mymc.dart', freshCard,
        'import-all', tmpDir.path,
      ]);
      expect(impResult.exitCode, equals(0));

      // Check dir shows the NFL title.
      final dirResult = await Process.run('dart',
          ['run', 'bin/dart_mymc.dart', freshCard, 'dir']);
      expect(dirResult.exitCode, equals(0));
      expect(dirResult.stdout.toString(), contains('ESPN NFL 2K5'));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  // -------------------------------------------------------------------------
  // Phase 8 — export-files and export-all (unit)
  // -------------------------------------------------------------------------

  group('Phase 8 — export-files and export-all (unit)', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_expfiles_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('export-files extracts save files to a host folder', () {
      final mc = openCardFile(testCard);
      try {
        final rc = doExportFiles(
            'export-files', mc, ['-d', tmpDir.path, '/BASLUS-20919NFL2K16']);
        expect(rc, equals(0));
        final outDir =
            Directory(p.join(tmpDir.path, 'BASLUS-20919NFL2K16'));
        expect(outDir.existsSync(), isTrue);
        expect(outDir.listSync().whereType<File>().toList(), isNotEmpty);
      } finally {
        mc.close();
      }
    });

    test('export-files -i skips save when folder already exists', () {
      final mc = openCardFile(testCard);
      try {
        final outDir =
            Directory(p.join(tmpDir.path, 'BASLUS-20919NFL2K16'))
              ..createSync();
        final rc = doExportFiles('export-files', mc,
            ['-i', '-d', tmpDir.path, '/BASLUS-20919NFL2K16']);
        expect(rc, equals(0));
        // Folder still empty — nothing was written.
        expect(outDir.listSync().whereType<File>().toList(), isEmpty);
      } finally {
        mc.close();
      }
    });

    test('export-files errors when folder exists without -f or -i', () {
      final mc = openCardFile(testCard);
      try {
        Directory(p.join(tmpDir.path, 'BASLUS-20919NFL2K16')).createSync();
        final rc = doExportFiles('export-files', mc,
            ['-d', tmpDir.path, '/BASLUS-20919NFL2K16']);
        expect(rc, equals(1));
      } finally {
        mc.close();
      }
    });

    test('export-files -f overwrites into existing folder', () {
      final mc = openCardFile(testCard);
      try {
        final outDir =
            Directory(p.join(tmpDir.path, 'BASLUS-20919NFL2K16'))
              ..createSync();
        final rc = doExportFiles('export-files', mc,
            ['-f', '-d', tmpDir.path, '/BASLUS-20919NFL2K16']);
        expect(rc, equals(0));
        expect(outDir.listSync().whereType<File>().toList(), isNotEmpty);
      } finally {
        mc.close();
      }
    });

    test('export-files rejects mutually exclusive -f and -i', () {
      final mc = openCardFile(testCard);
      try {
        final rc = doExportFiles('export-files', mc,
            ['-f', '-i', '/BASLUS-20919NFL2K16']);
        expect(rc, equals(1));
      } finally {
        mc.close();
      }
    });

    test('export-files requires at least one save directory argument', () {
      final mc = openCardFile(testCard);
      try {
        final rc = doExportFiles('export-files', mc, []);
        expect(rc, equals(1));
      } finally {
        mc.close();
      }
    });

    test('export-all extracts all 5 saves to host folders', () {
      final mc = openCardFile(testCard);
      try {
        final rc =
            doExportAll('export-all', mc, ['-d', tmpDir.path]);
        expect(rc, equals(0));
        final extracted =
            tmpDir.listSync().whereType<Directory>().toList();
        expect(extracted.length, equals(5));
        // Every extracted folder should contain at least one file.
        for (final dir in extracted) {
          expect(dir.listSync().whereType<File>().toList(), isNotEmpty,
              reason: '${dir.path} should contain files');
        }
      } finally {
        mc.close();
      }
    });

    test('export-all -i skips existing folders', () {
      final mc = openCardFile(testCard);
      try {
        // Pre-create one save folder.
        Directory(p.join(tmpDir.path, 'BASLUS-20919NFL2K16')).createSync();
        final rc =
            doExportAll('export-all', mc, ['-i', '-d', tmpDir.path]);
        expect(rc, equals(0));
        // 5 folders total: 4 newly created + 1 skipped (still empty).
        final dirs = tmpDir.listSync().whereType<Directory>().toList();
        expect(dirs.length, equals(5));
        final skipped =
            Directory(p.join(tmpDir.path, 'BASLUS-20919NFL2K16'));
        expect(skipped.listSync().whereType<File>().toList(), isEmpty);
      } finally {
        mc.close();
      }
    });
  });

  // -------------------------------------------------------------------------
  // Phase 8 CLI integration — export-files and export-all
  // -------------------------------------------------------------------------

  group('Phase 8 CLI integration — export-files and export-all', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('dart_mymc_cli_expfiles_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('export-files CLI extracts save to a folder', () async {
      final result = await Process.run('dart', [
        'run',
        'bin/dart_mymc.dart',
        testCard,
        'export-files',
        '-d',
        tmpDir.path,
        '/BASLUS-20919NFL2K16',
      ]);
      expect(result.exitCode, equals(0));
      final outDir =
          Directory(p.join(tmpDir.path, 'BASLUS-20919NFL2K16'));
      expect(outDir.existsSync(), isTrue);
      expect(outDir.listSync().whereType<File>().toList(), isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('export-all CLI extracts all 5 saves', () async {
      final result = await Process.run('dart', [
        'run',
        'bin/dart_mymc.dart',
        testCard,
        'export-all',
        '-d',
        tmpDir.path,
      ]);
      expect(result.exitCode, equals(0));
      final dirs = tmpDir.listSync().whereType<Directory>().toList();
      expect(dirs.length, equals(5));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('Phase 7 — Ps2Card public API', () {
    test('format: card has free space and no saves', () {
      final card = Ps2Card.format();
      try {
        final info = card.info;
        expect(info.freeBytes, greaterThan(0));
        expect(info.saves, isEmpty);
      } finally {
        card.close();
      }
    });

    test('format: 64MB card via API has 8x capacity', () {
      final card8 = Ps2Card.format(sizeMb: 8);
      final free8 = card8.info.freeBytes;
      card8.close();

      final card64 = Ps2Card.format(sizeMb: 64);
      final free64 = card64.info.freeBytes;
      card64.close();

      expect(free64, greaterThan(free8 * 7.5));
    });

    test('openMemory: listSaves returns correct count and titles', () {
      final card = Ps2Card.openMemory(File(testCard).readAsBytesSync());
      try {
        final saves = card.listSaves();
        expect(saves.length, equals(5)); // excludes . and ..
        final nfl = saves.firstWhere((s) => s.dirName == 'BASLUS-20919NFL2K16');
        expect(nfl.title, contains('ESPN NFL 2K5'));
      } finally {
        card.close();
      }
    });

    test('importSave + exportSave round-trip preserves content', () {
      // Load a reference PSU as raw bytes, import into a fresh card, re-export.
      final psuBytes = File('test/test_files/NFL2K16.psu').readAsBytesSync();
      final original = Ps2Save.fromBytes(psuBytes);

      final card = Ps2Card.format();
      try {
        card.importSave(psuBytes);
        final exportedBytes = card.exportSave('BASLUS-20919NFL2K16');
        final roundTripped = Ps2Save.fromBytes(exportedBytes);

        // Directory name and title must be preserved.
        expect(roundTripped.dirName, equals(original.dirName));
        expect(roundTripped.title, equals(original.title));
      } finally {
        card.close();
      }
    });

    test('Ps2Save.fromFiles: round-trips a save via export-files', () {
      // Export a save to a host folder, then reload via fromFiles.
      final tmpDir =
          Directory.systemTemp.createTempSync('dart_mymc_fromfiles_');
      try {
        final srcMc = openCardFile(testCard);
        doExportFiles('export-files', srcMc,
            ['-d', tmpDir.path, '/BASLUS-20919NFL2K16']);
        srcMc.close();

        // Build the map from the exported folder.
        final hostDir =
            Directory(p.join(tmpDir.path, 'BASLUS-20919NFL2K16'));
        final fileMap = <String, Uint8List>{};
        for (final f in hostDir.listSync().whereType<File>()) {
          fileMap[p.basename(f.path)] = f.readAsBytesSync();
        }

        final save = Ps2Save.fromFiles('BASLUS-20919NFL2K16', fileMap);
        expect(save.dirName, equals('BASLUS-20919NFL2K16'));
        expect(save.title, contains('ESPN NFL 2K5'));

        // Round-trip: import into a fresh card and verify.
        final card = Ps2Card.format();
        try {
          card.importSave(save.toBytes());
          expect(card.listSaves().map((s) => s.dirName),
              contains('BASLUS-20919NFL2K16'));
        } finally {
          card.close();
        }
      } finally {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('deleteSave: save no longer appears in listSaves', () {
      final psuBytes = File('test/test_files/NFL2K16.psu').readAsBytesSync();
      final card = Ps2Card.format();
      try {
        card.importSave(psuBytes);
        expect(card.listSaves().map((s) => s.dirName),
            contains('BASLUS-20919NFL2K16'));
        card.deleteSave('BASLUS-20919NFL2K16');
        expect(card.listSaves().map((s) => s.dirName),
            isNot(contains('BASLUS-20919NFL2K16')));
      } finally {
        card.close();
      }
    });
  });
}
