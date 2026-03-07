/*
Using the Public API.
Read in a .max|.psu gamesave file into a Ps2Save object.
List the contents and size of every file in the save, 
save files to current folder.
*/

import 'dart:io';
import 'dart:typed_data';
import 'package:dart_mymc/dart_mymc.dart';

void main(List<String> args) {

  if (args.isEmpty) {
    stderr.writeln('Usage: dart run maxExample.dart <save.(max|psu)>'); // this should also work with .psu
    exit(1);
  }

  String path = args[0];
  Uint8List bytes = File(path).readAsBytesSync();
  Ps2Save save = Ps2Save.fromBytes(bytes);

  print('Save directory : ${save.dirName}');
  print('Title          : ${save.title}');
  print('');
  print('Files:');

  int totalBytes = 0;
  for (Ps2FileInfo f in save.files) {
    print('  ${f.name.padRight(32)} ${f.sizeBytes} bytes');
    totalBytes += f.sizeBytes;
    File(f.name).writeAsBytesSync(f.toBytes());
  }

  print('');
  print('${save.files.length} file(s), $totalBytes bytes total');
}
