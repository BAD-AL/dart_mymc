import 'dart:io';
import 'dart:typed_data';
import 'package:dart_mymc/dart_mymc.dart';
import 'package:test/test.dart';

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
      mc = Ps2MemoryCard(testCard);
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
    test('df command prints correct free space', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/dart_mymc.dart', testCard, 'df'],
      );
      expect(result.exitCode, equals(0));
      expect(result.stdout.toString().trim(),
          equals('$testCard: 6494208 bytes free.'));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('ls / shows all expected save directory names', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/dart_mymc.dart', testCard, 'ls'],
      );
      expect(result.exitCode, equals(0));
      final output = result.stdout.toString();
      for (final name in expectedRootNames) {
        expect(output, contains(name));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('dir shows correct save titles and free space', () async {
      final result = await Process.run(
        'dart',
        ['run', 'bin/dart_mymc.dart', testCard, 'dir'],
      );
      expect(result.exitCode, equals(0));
      final output = result.stdout.toString();
      expect(output, contains('ESPN NFL 2K5'));
      expect(output, contains('KB Free'));
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
