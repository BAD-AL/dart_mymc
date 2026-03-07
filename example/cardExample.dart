/*
Using the Public API.
Read in a memory card file (.ps2) into a Ps2Card object.
List the contents and size of every save and file on the card.
*/

import 'dart:io';
import 'dart:typed_data';
import 'package:dart_mymc/dart_mymc.dart';

void main(List<String> args) {

  if (args.isEmpty) {
    stderr.writeln('Usage: dart run cardExample.dart <card.ps2>');
    exit(1);
  }

  String path = args[0];
  Uint8List bytes = File(path).readAsBytesSync();
  Ps2Card card = Ps2Card.openMemory(bytes);

  try {
    Ps2CardInfo info = card.info;
    print('Card: ${info.freeBytes ~/ 1024} KB free of ${info.totalBytes ~/ 1024} KB total');
    print('Saves: ${info.saves.length}');
    print('');

    for (Ps2SaveInfo save in info.saves) {
      print('  ${save.dirName.padRight(32)} "${save.title}"  ${save.sizeBytes} bytes');

      Uint8List saveBytes = card.exportSave(save.dirName);
      Ps2Save ps2Save = Ps2Save.fromBytes(saveBytes);
      for (Ps2FileInfo f in ps2Save.files) {
        print('    ${f.name.padRight(32)} ${f.sizeBytes} bytes');
      }
    }
  } finally {
    card.close();
  }
}
