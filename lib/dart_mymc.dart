// dart_mymc.dart
//
// Library entry point.  run_main() mirrors mymc.py's main().

library dart_mymc;

export 'src/ps2mc.dart';
export 'src/ps2mc_dir.dart';
export 'src/ps2mc_ecc.dart';
export 'src/ps2save.dart';
export 'src/round.dart';
export 'src/sjistab.dart';

import 'dart:io';

import 'src/ps2mc.dart';
import 'src/ps2mc_dir.dart';
import 'src/ps2save.dart';

// ---------------------------------------------------------------------------
// Subcommand helpers
// ---------------------------------------------------------------------------

const String _modeBits = 'rwxpfdD81C+KPH4';

String _formatMode(int mode) {
  final sb = StringBuffer();
  for (int bit = 0; bit < 15; bit++) {
    sb.write((mode & (1 << bit)) != 0 ? _modeBits[bit] : '-');
  }
  return sb.toString();
}

String _formatFreeKb(int freeKb) {
  if (freeKb > 999999) {
    return '${freeKb ~/ 1000000},${(freeKb ~/ 1000 % 1000).toString().padLeft(3, '0')},${(freeKb % 1000).toString().padLeft(3, '0')}';
  } else if (freeKb > 999) {
    return '${freeKb ~/ 1000},${(freeKb % 1000).toString().padLeft(3, '0')}';
  } else {
    return '$freeKb';
  }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// `ls [directory ...]` — list directory contents.
int doLs(String cmd, Ps2MemoryCard mc, List<String> args,
    {bool creationTime = false}) {
  final dirs = args.isEmpty ? ['/'] : args;

  for (final dirname in dirs) {
    final globs = mc.glob(dirname);
    for (final d in globs) {
      Ps2McDirectory dir;
      try {
        dir = mc.dirOpen(d);
      } on Ps2McError catch (e) {
        stderr.writeln('$d: ${e.message}');
        continue;
      }
      if (dirs.length > 1 || globs.length > 1) stdout.writeln('\n$d:');
      for (final ent in dir) {
        if (!ent.exists) continue;
        final modeStr = _formatMode(ent.mode);
        final tod = creationTime ? ent.created : ent.modified;
        final dt = tod.toLocalDateTime();
        stdout.write('$modeStr ${ent.length.toString().padLeft(7)} '
            '${dt.year.toString().padLeft(4, '0')}-'
            '${dt.month.toString().padLeft(2, '0')}-'
            '${dt.day.toString().padLeft(2, '0')} '
            '${dt.hour.toString().padLeft(2, '0')}:'
            '${dt.minute.toString().padLeft(2, '0')}:'
            '${dt.second.toString().padLeft(2, '0')} '
            '${ent.name}\n');
      }
      dir.close();
    }
  }
  return 0;
}

/// `dir` — display save file information (human-readable summary).
int doDir(String cmd, Ps2MemoryCard mc, List<String> args) {
  if (args.isNotEmpty) {
    stderr.writeln('$cmd: incorrect number of arguments.');
    return 1;
  }

  final dir = mc.dirOpen('/');
  final entries = dir.toList();
  dir.close();

  for (final ent in entries.skip(2)) {
    final dirmode = ent.mode;
    if (!modeIsDir(dirmode)) continue;
    final dirname = '/${ent.name}';
    mc.chdir(dirname);
    final length = mc.dirSize('.');

    // Determine title from icon.sys.
    (String, String) titlePair = ('Corrupt', '');
    if (dirmode & dfPsx != 0) {
      // PSX save: read title from first 128 bytes of the save file.
      titlePair = _getPsxTitle(mc, ent.name) ?? ('Corrupt', '');
    } else {
      titlePair = _getPs2Title(mc) ?? ('Corrupt', '');
    }

    // Protection status.
    String protection;
    final protBits = dirmode & (dfProtected | dfWrite);
    if (protBits == 0) {
      protection = 'Delete Protected';
    } else if (protBits == dfWrite) {
      protection = 'Not Protected';
    } else if (protBits == dfProtected) {
      protection = 'Copy & Delete Protected';
    } else {
      protection = 'Copy Protected';
    }

    // Override protection label for PSX/PocketStation saves.
    if (dirmode & dfPsx != 0) {
      protection = dirmode & dfPocketstn != 0 ? 'PocketStation' : 'PlayStation';
    }

    final kb = length ~/ 1024;
    stdout.writeln('${ent.name.padRight(32)} ${titlePair.$1}');
    stdout.writeln('${kb.toString().padLeft(4)}KB ${protection.padRight(25)} ${titlePair.$2}');
    stdout.writeln();
  }

  final freeKb = mc.getFreeSpace() ~/ 1024;
  stdout.writeln('${_formatFreeKb(freeKb)} KB Free');
  return 0;
}

(String, String)? _getPs2Title(Ps2MemoryCard mc) {
  final raw = mc.getIconSys('.');
  if (raw == null) return null;
  final iconSys = IconSys.unpack(raw);
  if (iconSys == null) return null;
  return iconSys.title();
}

(String, String)? _getPsxTitle(Ps2MemoryCard mc, String savename) {
  final mode = mc.getMode(savename);
  if (mode == null || !modeIsFile(mode)) return null;
  try {
    final f = mc.open(savename);
    final raw = f.read(128);
    f.close();
    if (raw.length < 128) return null;
    if (raw[0] != 0x53 || raw[1] != 0x43) return null; // "SC"
    // title is at offset 4, 64 bytes, Shift-JIS
    final titleBytes = raw.sublist(4, 4 + 64);
    final null0 = titleBytes.indexOf(0);
    final title = String.fromCharCodes(
        null0 >= 0 ? titleBytes.sublist(0, null0) : titleBytes);
    return (title, '');
  } catch (_) {
    return null;
  }
}

/// `df` — display free space.
int doDf(String cmd, Ps2MemoryCard mc, List<String> args, String mcPath) {
  if (args.isNotEmpty) {
    stderr.writeln('$cmd: incorrect number of arguments.');
    return 1;
  }
  stdout.writeln('$mcPath: ${mc.getFreeSpace()} bytes free.');
  return 0;
}

/// `check` — check for filesystem errors.
int doCheck(String cmd, Ps2MemoryCard mc, List<String> args) {
  if (args.isNotEmpty) {
    stderr.writeln('$cmd: incorrect number of arguments.');
    return 1;
  }
  try {
    final ok = mc.check();
    if (ok) {
      stdout.writeln('No errors found.');
      return 0;
    }
    return 1;
  } catch (_) {
    return 1;
  }
}

// ---------------------------------------------------------------------------
// Option parsing helpers
// ---------------------------------------------------------------------------

class _ParsedArgs {
  final bool ignoreEcc;
  final bool debug;
  final String? mcPath;
  final String? command;
  final List<String> subArgs;

  _ParsedArgs({
    required this.ignoreEcc,
    required this.debug,
    required this.mcPath,
    required this.command,
    required this.subArgs,
  });
}

_ParsedArgs _parseArgs(List<String> argv) {
  bool ignoreEcc = false;
  bool debug = false;
  final rest = <String>[];

  int i = 0;
  while (i < argv.length) {
    final arg = argv[i];
    if (arg == '--ignore-ecc' || arg == '-i') {
      ignoreEcc = true;
    } else if (arg == '-D') {
      debug = true;
    } else if (arg == '--help' || arg == '-h') {
      _printHelp();
      exit(0);
    } else if (arg == '--version') {
      stdout.writeln('dart_mymc 1.0.0');
      exit(0);
    } else if (arg.startsWith('-')) {
      stderr.writeln('Unknown option: $arg');
      exit(1);
    } else {
      rest.add(arg);
    }
    i++;
  }

  if (rest.isEmpty) {
    return _ParsedArgs(
        ignoreEcc: ignoreEcc,
        debug: debug,
        mcPath: null,
        command: null,
        subArgs: []);
  }

  final mcPath = rest[0];
  final command = rest.length > 1 ? rest[1] : null;
  final subArgs = rest.length > 2 ? rest.sublist(2) : <String>[];

  return _ParsedArgs(
      ignoreEcc: ignoreEcc,
      debug: debug,
      mcPath: mcPath,
      command: command,
      subArgs: subArgs);
}

void _printHelp() {
  stdout.writeln('Usage: dart_mymc [-ih] memcard.ps2 command [...]');
  stdout.writeln('');
  stdout.writeln('Manipulate PS2 memory card images.');
  stdout.writeln('');
  stdout.writeln('Supported commands:');
  for (final entry in _commandDescriptions.entries) {
    stdout.writeln('   ${entry.key}: ${entry.value}');
  }
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln('  -h, --help        show this help message and exit');
  stdout.writeln('  --version         show version and exit');
  stdout.writeln('  -i, --ignore-ecc  Ignore ECC errors while reading.');
}

const _commandDescriptions = {
  'add': 'Add files to the memory card.',
  'check': 'Check for file system errors.',
  'clear': 'Clear mode flags on files and directories',
  'delete': 'Recursively delete a directory (save file).',
  'df': 'Display the amount free space.',
  'dir': 'Display save file information.',
  'export': 'Export save files from the memory card.',
  'extract': 'Extract files from the memory card.',
  'format': 'Creates a new memory card image.',
  'import': 'Import save files into the memory card.',
  'ls': 'List the contents of a directory.',
  'mkdir': 'Make directories.',
  'remove': 'Remove files and directories.',
  'rename': 'Rename a file or directory',
  'set': 'Set mode flags on files and directories',
};

// ---------------------------------------------------------------------------
// Main entry point (called from bin/dart_mymc.dart)
// ---------------------------------------------------------------------------

int runMain(List<String> arguments) {
  final parsed = _parseArgs(arguments);

  if (parsed.mcPath == null || parsed.command == null) {
    _printHelp();
    return 1;
  }

  final mcPath = parsed.mcPath!;
  final cmd = parsed.command!;
  final subArgs = parsed.subArgs;

  // Commands that do not need to open the memory card image.
  if (cmd == 'format') {
    stderr.writeln('format: not yet implemented.');
    return 1;
  }

  Ps2MemoryCard? mc;
  try {
    mc = Ps2MemoryCard(mcPath, ignoreEcc: parsed.ignoreEcc);

    switch (cmd) {
      case 'dir':
        return doDir(cmd, mc, subArgs);

      case 'ls':
        bool creationTime = false;
        final lsArgs = <String>[];
        for (final a in subArgs) {
          if (a == '-c' || a == '--creation-time') {
            creationTime = true;
          } else {
            lsArgs.add(a);
          }
        }
        return doLs(cmd, mc, lsArgs, creationTime: creationTime);

      case 'df':
        return doDf(cmd, mc, subArgs, mcPath);

      case 'check':
        return doCheck(cmd, mc, subArgs);

      case 'add':
      case 'extract':
      case 'mkdir':
      case 'remove':
      case 'import':
      case 'export':
      case 'delete':
      case 'set':
      case 'clear':
      case 'rename':
        stderr.writeln('$cmd: not yet implemented.');
        return 1;

      default:
        stderr.writeln('Command "$cmd" not recognized.');
        return 1;
    }
  } on Ps2McError catch (e) {
    stderr.writeln(e.toString());
    return 1;
  } on FileSystemException catch (e) {
    stderr.writeln('${e.path ?? mcPath}: ${e.message}');
    return 1;
  } finally {
    mc?.close();
  }
}
