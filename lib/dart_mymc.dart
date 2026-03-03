// dart_mymc.dart
//
// Library entry point.  runMain() mirrors mymc.py's main().

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

/// `add` — add raw files to the memory card.
int doAdd(String cmd, Ps2MemoryCard mc, List<String> args) {
  String? directory;
  final files = <String>[];
  int i = 0;
  while (i < args.length) {
    if ((args[i] == '-d' || args[i] == '--directory') &&
        i + 1 < args.length) {
      directory = args[i + 1];
      i += 2;
    } else {
      files.add(args[i]);
      i++;
    }
  }
  if (files.isEmpty) {
    stderr.writeln('$cmd: filename required.');
    return 1;
  }
  if (directory != null) mc.chdir(directory);
  int rc = 0;
  for (final src in files) {
    final srcFile = File(src);
    if (!srcFile.existsSync()) {
      stderr.writeln('$src: file not found.');
      rc = 1;
      continue;
    }
    final dest = src.split(Platform.pathSeparator).last;
    final data = srcFile.readAsBytesSync();
    try {
      final f = mc.open(dest, mode: 'wb');
      f.write(data);
      f.close();
    } on Ps2McError catch (e) {
      stderr.writeln(e.toString());
      rc = 1;
    }
  }
  return rc;
}

/// `extract` — extract files from the memory card.
int doExtract(String cmd, Ps2MemoryCard mc, List<String> args) {
  String? directory;
  String? outputFile;
  bool useStdout = false;
  final files = <String>[];
  int i = 0;
  while (i < args.length) {
    if ((args[i] == '-d' || args[i] == '--directory') &&
        i + 1 < args.length) {
      directory = args[i + 1];
      i += 2;
    } else if ((args[i] == '-o' || args[i] == '--output') &&
        i + 1 < args.length) {
      outputFile = args[i + 1];
      i += 2;
    } else if (args[i] == '-p' || args[i] == '--stdout') {
      useStdout = true;
      i++;
    } else {
      files.add(args[i]);
      i++;
    }
  }
  if (files.isEmpty) {
    stderr.writeln('$cmd: filename required.');
    return 1;
  }
  if (outputFile != null && useStdout) {
    stderr.writeln('$cmd: -o and -p are mutually exclusive.');
    return 1;
  }
  if (directory != null) mc.chdir(directory);

  int rc = 0;
  for (final pattern in files) {
    for (final filename in mc.glob(pattern)) {
      try {
        final f = mc.open(filename);
        final data = f.read();
        f.close();
        if (useStdout) {
          stdout.add(data);
        } else if (outputFile != null) {
          File(outputFile).writeAsBytesSync(data);
        } else {
          final dest = filename.split('/').last;
          File(dest).writeAsBytesSync(data);
        }
      } on Ps2McError catch (e) {
        stderr.writeln(e.toString());
        rc = 1;
      }
    }
  }
  return rc;
}

/// `mkdir` — create directories.
int doMkdir(String cmd, Ps2MemoryCard mc, List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('$cmd: directory required.');
    return 1;
  }
  int rc = 0;
  for (final dir in args) {
    try {
      mc.mkdir(dir);
    } on Ps2McError catch (e) {
      stderr.writeln(e.toString());
      rc = 1;
    }
  }
  return rc;
}

/// `remove` — remove files and empty directories.
int doRemove(String cmd, Ps2MemoryCard mc, List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('$cmd: filename required.');
    return 1;
  }
  int rc = 0;
  for (final name in args) {
    try {
      mc.remove(name);
    } on Ps2McError catch (e) {
      stderr.writeln(e.toString());
      rc = 1;
    }
  }
  return rc;
}

/// `delete` — recursively delete save directories.
int doDelete(String cmd, Ps2MemoryCard mc, List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('$cmd: directory required.');
    return 1;
  }
  int rc = 0;
  for (final dir in args) {
    try {
      mc.rmdir(dir);
    } on Ps2McError catch (e) {
      stderr.writeln(e.toString());
      rc = 1;
    }
  }
  return rc;
}

/// `rename` — rename a file or directory.
int doRename(String cmd, Ps2MemoryCard mc, List<String> args) {
  if (args.length != 2) {
    stderr.writeln('$cmd: old and new names required.');
    return 1;
  }
  try {
    mc.rename(args[0], args[1]);
    return 0;
  } on Ps2McError catch (e) {
    stderr.writeln(e.toString());
    return 1;
  }
}

Ps2SaveFile _loadSaveFile(String filename) {
  final f = File(filename).openSync();
  try {
    final header = f.readSync(16);
    f.setPositionSync(0);
    final ftype = detectFileType(header);
    final sf = Ps2SaveFile();
    if (ftype == 'psu') {
      sf.loadEms(f);
    } else if (ftype == 'max') {
      sf.loadMax(f);
    } else if (ftype == 'cbs') {
      sf.loadCbs(f);
    } else if (ftype == 'sps') {
      sf.loadSps(f);
    } else if (ftype == 'npo') {
      throw UnsupportedError('nPort saves not supported.');
    } else {
      throw FormatException('Save file format not recognized: $filename');
    }
    return sf;
  } finally {
    f.closeSync();
  }
}

/// `import` — import save files into the memory card.
int doImport(String cmd, Ps2MemoryCard mc, List<String> args) {
  bool ignoreExisting = false;
  String? destDir;
  final files = <String>[];
  int i = 0;
  while (i < args.length) {
    if (args[i] == '-i' || args[i] == '--ignore-existing') {
      ignoreExisting = true;
      i++;
    } else if ((args[i] == '-d' || args[i] == '--directory') &&
        i + 1 < args.length) {
      destDir = args[i + 1];
      i += 2;
    } else {
      files.add(args[i]);
      i++;
    }
  }
  if (files.isEmpty) {
    stderr.writeln('$cmd: filename required.');
    return 1;
  }
  if (destDir != null && files.length > 1) {
    stderr.writeln('$cmd: -d can only be used with a single save file.');
    return 1;
  }
  int rc = 0;
  for (final filename in files) {
    try {
      final sf = _loadSaveFile(filename);
      final dirName =
          destDir ?? sf.getDirectory().name;
      stdout.writeln('Importing $filename to $dirName');
      if (!mc.importSaveFile(sf, ignoreExisting, dirname: destDir)) {
        stdout.writeln('$filename: already in memory card image, ignored.');
      }
    } on Ps2McError catch (e) {
      stderr.writeln(e.toString());
      rc = 1;
    } on FormatException catch (e) {
      stderr.writeln('$filename: ${e.message}');
      rc = 1;
    } on UnsupportedError catch (e) {
      stderr.writeln('$filename: ${e.message}');
      rc = 1;
    }
  }
  return rc;
}

/// `export` — export save files from the memory card.
int doExport(String cmd, Ps2MemoryCard mc, List<String> args) {
  bool overwriteExisting = false;
  bool ignoreExisting = false;
  bool useLongnames = false;
  String? outputFile;
  String? destDir;
  String type = 'psu';
  final dirs = <String>[];
  int i = 0;
  while (i < args.length) {
    if (args[i] == '-f' || args[i] == '--overwrite') {
      overwriteExisting = true;
      i++;
    } else if (args[i] == '-i' || args[i] == '--ignore-existing') {
      ignoreExisting = true;
      i++;
    } else if (args[i] == '-l' || args[i] == '--longnames') {
      useLongnames = true;
      i++;
    } else if ((args[i] == '-o' || args[i] == '--output') &&
        i + 1 < args.length) {
      outputFile = args[i + 1];
      i += 2;
    } else if ((args[i] == '-d' || args[i] == '--directory') &&
        i + 1 < args.length) {
      destDir = args[i + 1];
      i += 2;
    } else if ((args[i] == '-t' || args[i] == '--type') &&
        i + 1 < args.length) {
      type = args[i + 1];
      i += 2;
    } else {
      dirs.add(args[i]);
      i++;
    }
  }
  if (dirs.isEmpty) {
    stderr.writeln('$cmd: directory name required.');
    return 1;
  }
  if (overwriteExisting && ignoreExisting) {
    stderr.writeln('$cmd: -f and -i are mutually exclusive.');
    return 1;
  }
  if (outputFile != null && dirs.length > 1) {
    stderr.writeln('$cmd: only one directory can be exported with -o.');
    return 1;
  }
  if (outputFile != null && useLongnames) {
    stderr.writeln('$cmd: -o and -l are mutually exclusive.');
    return 1;
  }

  int rc = 0;
  for (final dirname in dirs) {
    for (final d in mc.glob(dirname)) {
      try {
        final sf = mc.exportSaveFile(d);
        String filename;
        if (useLongnames) {
          final longname = sf.makeLongname(d.split('/').last);
          filename = '$longname.$type';
        } else {
          filename = outputFile ?? '${d.split('/').last}.$type';
        }
        if (destDir != null) filename = '$destDir/$filename';

        if (!overwriteExisting) {
          if (File(filename).existsSync()) {
            if (ignoreExisting) continue;
            stderr.writeln('$filename: file exists.');
            rc = 1;
            continue;
          }
        }

        stdout.writeln('Exporting $d to $filename');
        final f = File(filename).openSync(mode: FileMode.write);
        try {
          if (type == 'psu') {
            sf.saveEms(f);
          } else if (type == 'max') {
            sf.saveMax(f);
          } else {
            stderr.writeln('$cmd: unsupported export type: $type');
            rc = 1;
          }
        } finally {
          f.closeSync();
        }
      } on Ps2McError catch (e) {
        stderr.writeln(e.toString());
        rc = 1;
      }
    }
  }
  return rc;
}

/// `set` / `clear` — set or clear mode flags.
int doSetMode(String cmd, Ps2MemoryCard mc, List<String> args, bool setting) {
  int setMask = 0;
  int clearMask = ~0;
  String? hexValue;
  final files = <String>[];

  int i = 0;
  while (i < args.length) {
    final a = args[i];
    if (a == '-r' || a == '--read') {
      if (setting) setMask |= dfRead; else clearMask ^= dfRead;
    } else if (a == '-w' || a == '--write') {
      if (setting) setMask |= dfWrite; else clearMask ^= dfWrite;
    } else if (a == '-x' || a == '--execute') {
      if (setting) setMask |= dfExecute; else clearMask ^= dfExecute;
    } else if (a == '-p' || a == '--protected') {
      if (setting) setMask |= dfProtected; else clearMask ^= dfProtected;
    } else if (a == '-s' || a == '--psx') {
      if (setting) setMask |= dfPsx; else clearMask ^= dfPsx;
    } else if (a == '-k' || a == '--pocketstation') {
      if (setting) setMask |= dfPocketstn; else clearMask ^= dfPocketstn;
    } else if (a == '-H' || a == '--hidden') {
      if (setting) setMask |= dfHidden; else clearMask ^= dfHidden;
    } else if ((a == '-X' || a == '--hex') && i + 1 < args.length) {
      hexValue = args[i + 1];
      i++;
    } else if (!a.startsWith('-')) {
      files.add(a);
    }
    i++;
  }

  if (setMask == 0 && clearMask == ~0 && hexValue == null) {
    stderr.writeln('$cmd: at least one option must be given.');
    return 1;
  }
  if (hexValue != null && (setMask != 0 || clearMask != ~0)) {
    stderr.writeln("$cmd: -X can't be combined with other options.");
    return 1;
  }
  int? rawValue;
  if (hexValue != null) {
    final h = hexValue.startsWith('0x') || hexValue.startsWith('0X')
        ? hexValue.substring(2)
        : hexValue;
    rawValue = int.tryParse(h, radix: 16);
    if (rawValue == null) {
      stderr.writeln('$cmd: invalid hex value: $hexValue');
      return 1;
    }
  }

  int rc = 0;
  for (final pattern in files) {
    for (final filename in mc.glob(pattern)) {
      try {
        final ent = mc.getDirent(filename);
        if (rawValue != null) {
          ent.mode = rawValue;
        } else {
          ent.mode = (ent.mode & clearMask) | setMask;
        }
        mc.setDirent(filename, ent);
      } on Ps2McError catch (e) {
        stderr.writeln(e.toString());
        rc = 1;
      }
    }
  }
  return rc;
}

/// `format` — create a new memory card image.
int doFormat(String cmd, String mcPath, List<String> args) {
  bool noEcc = false;
  bool overwrite = false;
  int? clusters;
  int i = 0;
  while (i < args.length) {
    if (args[i] == '-e' || args[i] == '--no-ecc') {
      noEcc = true;
    } else if (args[i] == '-f' || args[i] == '--overwrite') {
      overwrite = true;
    } else if ((args[i] == '-c' || args[i] == '--clusters') &&
        i + 1 < args.length) {
      clusters = int.tryParse(args[i + 1]);
      if (clusters == null) {
        stderr.writeln('$cmd: invalid cluster count: ${args[i + 1]}');
        return 1;
      }
      i++;
    }
    i++;
  }

  int pagesPerCard = ps2mcStandardPagesPerCard;
  if (clusters != null) {
    const ppc = ps2mcClusterSize ~/ ps2mcStandardPageSize;
    pagesPerCard = clusters * ppc;
  }

  if (!overwrite && File(mcPath).existsSync()) {
    stderr.writeln('$mcPath: file exists.');
    return 1;
  }

  try {
    final mc = Ps2MemoryCard(mcPath,
        formatParams: [
          noEcc ? 0 : 1,
          ps2mcStandardPageSize,
          ps2mcStandardPagesPerEraseBlock,
          pagesPerCard,
        ]);
    mc.close();
    return 0;
  } on Ps2McError catch (e) {
    stderr.writeln(e.toString());
    return 1;
  }
}

// ---------------------------------------------------------------------------
// create — create a new .ps2 card pre-loaded with one or more save files.
// Usage: dart_mymc <new.ps2> create [-f] <save.(psu|max|sps|cbs)> [...]
// ---------------------------------------------------------------------------

int doCreate(String cmd, String mcPath, List<String> args) {
  bool overwrite = false;
  final files = <String>[];
  for (final a in args) {
    if (a == '-f' || a == '--overwrite-existing') {
      overwrite = true;
    } else {
      files.add(a);
    }
  }
  if (files.isEmpty) {
    stderr.writeln('$cmd: save file required.');
    return 1;
  }

  if (!overwrite && File(mcPath).existsSync()) {
    stderr.writeln('$mcPath: file exists.');
    return 1;
  }

  // Load all save files first so we fail before touching the card.
  final saves = <Ps2SaveFile>[];
  for (final filename in files) {
    try {
      saves.add(_loadSaveFile(filename));
    } on FormatException catch (e) {
      stderr.writeln('$filename: ${e.message}');
      return 1;
    } on UnsupportedError catch (e) {
      stderr.writeln('$filename: ${e.message}');
      return 1;
    }
  }

  try {
    final mc = Ps2MemoryCard(mcPath, formatParams: [
      1,
      ps2mcStandardPageSize,
      ps2mcStandardPagesPerEraseBlock,
      ps2mcStandardPagesPerCard,
    ]);
    try {
      for (int i = 0; i < files.length; i++) {
        final dirname = saves[i].getDirectory().name;
        stdout.writeln('Importing ${files[i]} to $dirname');
        mc.importSaveFile(saves[i], false);
      }
    } finally {
      mc.close();
    }
  } on Ps2McError catch (e) {
    stderr.writeln(e.toString());
    return 1;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// convert — convert a save file between formats (no memory card needed).
// Usage: dart_mymc convert [-f] <input.(psu|max|sps|cbs)> <output.(psu|max|sps|cbs)>
// ---------------------------------------------------------------------------

/// Infer the save-file format string ('psu','max','sps','cbs') from extension.
String? _typeFromExtension(String path) {
  final ext = path.toLowerCase();
  if (ext.endsWith('.psu')) return 'psu';
  if (ext.endsWith('.max')) return 'max';
  if (ext.endsWith('.sps')) return 'sps';
  if (ext.endsWith('.cbs')) return 'cbs';
  return null;
}

int doConvert(List<String> args) {
  bool overwrite = false;
  final positional = <String>[];
  for (final a in args) {
    if (a == '-f' || a == '--overwrite-existing') {
      overwrite = true;
    } else {
      positional.add(a);
    }
  }

  if (positional.length != 2) {
    stderr.writeln('convert: usage: dart_mymc convert [-f] <input> <output>');
    return 1;
  }

  final inputPath = positional[0];
  final outputPath = positional[1];

  final outType = _typeFromExtension(outputPath);
  if (outType == null) {
    stderr.writeln('convert: cannot determine output format from extension: $outputPath');
    return 1;
  }

  if (!overwrite && File(outputPath).existsSync()) {
    stderr.writeln('$outputPath: file exists.');
    return 1;
  }

  final Ps2SaveFile sf;
  try {
    sf = _loadSaveFile(inputPath);
  } on FormatException catch (e) {
    stderr.writeln('$inputPath: ${e.message}');
    return 1;
  } on UnsupportedError catch (e) {
    stderr.writeln('$inputPath: ${e.message}');
    return 1;
  }

  final f = File(outputPath).openSync(mode: FileMode.write);
  try {
    stdout.writeln('Converting $inputPath to $outputPath');
    if (outType == 'psu') {
      sf.saveEms(f);
    } else if (outType == 'max') {
      sf.saveMax(f);
    } else if (outType == 'sps') {
      sf.saveSps(f);
    } else if (outType == 'cbs') {
      sf.saveCbs(f);
    }
  } on UnimplementedError catch (e) {
    f.closeSync();
    File(outputPath).deleteSync();
    stderr.writeln('convert: $e');
    return 1;
  } finally {
    f.closeSync();
  }
  return 0;
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
    // Stop processing global flags once we have a positional argument (mcPath).
    // Everything from the first non-flag arg onward goes into rest as-is;
    // sub-command options (e.g. -o, -d) are handled by their own parsers.
    if (rest.isNotEmpty) {
      rest.add(arg);
    } else if (arg == '--ignore-ecc' || arg == '-i') {
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

void _printCommandHelp(String cmd) {
  final text = _commandHelp[cmd];
  if (text == null) {
    stderr.writeln('No help available for "$cmd".');
  } else {
    stdout.writeln(text);
  }
}

const _commandHelp = {
  'add': '''Usage: dart_mymc memcard.ps2 add [options] filename ...

Add files to the memory card.

Options:
  -d DIRECTORY, --directory=DIRECTORY
                        Add files to "directory".
  -h, --help            show this help message and exit''',

  'check': '''Usage: dart_mymc memcard.ps2 check

Check for file system errors.

Options:
  -h, --help  show this help message and exit''',

  'clear': '''Usage: dart_mymc memcard.ps2 clear [options] filename ...

Clear mode flags on files and directories

Options:
  -p, --protected      Clear copy protected flag
  -P, --psx            Clear PSX flag
  -K, --pocketstation  Clear PocketStation flag
  -H, --hidden         Clear hidden flag
  -r, --read           Clear read allowed flag
  -w, --write          Clear write allowed flag
  -x, --execute        Clear executable flag
  -h, --help           show this help message and exit''',

  'convert': '''Usage: dart_mymc convert [-f] input output

Convert a save file between formats (.psu, .max, .sps, .cbs).
The output format is inferred from the output file extension.

Options:
  -f, --overwrite-existing
                        Overwrite output file if it already exists.
  -h, --help            show this help message and exit''',

  'create': '''Usage: dart_mymc new.ps2 create [-f] savefile ...

Create a new memory card image pre-loaded with one or more save files.
Supported input formats: .psu, .max, .sps, .cbs.

Options:
  -f, --overwrite-existing
                        Overwrite the card image if it already exists.
  -h, --help            show this help message and exit''',

  'delete': '''Usage: dart_mymc memcard.ps2 delete dirname ...

Recursively delete a directory (save file).

Options:
  -h, --help  show this help message and exit''',

  'df': '''Usage: dart_mymc memcard.ps2 df

Display the amount free space.

Options:
  -h, --help  show this help message and exit''',

  'dir': '''Usage: dart_mymc memcard.ps2 dir

Display save file information.

Options:
  -h, --help  show this help message and exit''',

  'export': '''Usage: dart_mymc memcard.ps2 export [options] directory ...

Export save files from the memory card.

Options:
  -f, --overwrite-existing
                        Overwrite any save files already exported.
  -i, --ignore-existing
                        Ignore any save files already exported.
  -o filename, --output-file=filename
                        Use "filename" as the name of the save file.
  -d directory, --directory=directory
                        Export save files to "directory".
  -l, --longnames       Generate longer, more descriptive, filenames.
  -t type, --type=type  Output format: psu (default) or max.
  -h, --help            show this help message and exit''',

  'extract': '''Usage: dart_mymc memcard.ps2 extract [options] filename ...

Extract files from the memory card.

Options:
  -o FILE, --output=FILE
                        Extract file to "FILE".
  -d DIRECTORY, --directory=DIRECTORY
                        Extract files from "DIRECTORY".
  -p, --use-stdout      Extract files to standard output.
  -h, --help            show this help message and exit''',

  'format': '''Usage: dart_mymc memcard.ps2 format [options]

Creates a new memory card image.

Options:
  -c CLUSTERS, --clusters=CLUSTERS
                        Size in clusters of the memory card.
  -f, --overwrite-existing
                        Overwrite any existing file.
  -e, --no-ecc          Create an image without ECC.
  -h, --help            show this help message and exit''',

  'import': '''Usage: dart_mymc memcard.ps2 import [options] savefile ...

Import save files into the memory card.
Supported formats: .psu, .max, .sps, .cbs.

Options:
  -i, --ignore-existing
                        Ignore files that already exist on the image.
  -d DEST, --directory=DEST
                        Import to "DEST".
  -h, --help            show this help message and exit''',

  'ls': '''Usage: dart_mymc memcard.ps2 ls [options] [directory ...]

List the contents of a directory.

Options:
  -c, --creation-time  Display creation times.
  -h, --help           show this help message and exit''',

  'mkdir': '''Usage: dart_mymc memcard.ps2 mkdir directory ...

Make directories.

Options:
  -h, --help  show this help message and exit''',

  'remove': '''Usage: dart_mymc memcard.ps2 remove filename ...

Remove files and directories.

Options:
  -h, --help  show this help message and exit''',

  'rename': '''Usage: dart_mymc memcard.ps2 rename oldname newname

Rename a file or directory.

Options:
  -h, --help  show this help message and exit''',

  'set': '''Usage: dart_mymc memcard.ps2 set [options] filename ...

Set mode flags on files and directories.

Options:
  -p, --protected       Set copy protected flag
  -P, --psx             Set PSX flag
  -K, --pocketstation   Set PocketStation flag
  -H, --hidden          Set hidden flag
  -r, --read            Set read allowed flag
  -w, --write           Set write allowed flag
  -x, --execute         Set executable flag
  -X mode, --hex-value=mode
                        Set mode to "mode".
  -h, --help            show this help message and exit''',
};

const _commandDescriptions = {
  'add': 'Add files to the memory card.',
  'check': 'Check for file system errors.',
  'clear': 'Clear mode flags on files and directories',
  'convert': 'Convert a save file between formats (.psu/.max/.sps/.cbs).',
  'create': 'Create a new memory card pre-loaded with a save file.',
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

  // 'dart_mymc help <command>' — no memory card needed.
  if (mcPath == 'help') {
    _printCommandHelp(cmd);
    return 0;
  }

  // Per-command --help / -h flag.
  if (subArgs.contains('--help') || subArgs.contains('-h')) {
    _printCommandHelp(cmd);
    return 0;
  }

  // Commands that do not need to open the memory card image.
  if (cmd == 'format') {
    return doFormat(cmd, mcPath, subArgs);
  }
  if (cmd == 'create') {
    return doCreate(cmd, mcPath, subArgs);
  }

  // 'convert' takes no memory card — argv is: dart_mymc convert <in> <out>
  // The parser slots the word 'convert' into mcPath and <in> into cmd.
  if (mcPath == 'convert') {
    return doConvert([cmd, ...subArgs]);
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
        return doAdd(cmd, mc, subArgs);

      case 'extract':
        return doExtract(cmd, mc, subArgs);

      case 'mkdir':
        return doMkdir(cmd, mc, subArgs);

      case 'remove':
        return doRemove(cmd, mc, subArgs);

      case 'import':
        return doImport(cmd, mc, subArgs);

      case 'export':
        return doExport(cmd, mc, subArgs);

      case 'delete':
        return doDelete(cmd, mc, subArgs);

      case 'set':
        return doSetMode(cmd, mc, subArgs, true);

      case 'clear':
        return doSetMode(cmd, mc, subArgs, false);

      case 'rename':
        return doRename(cmd, mc, subArgs);

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
