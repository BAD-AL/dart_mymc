/*
Using the Public API to format a new memory card.
Demonstrates creating cards of different sizes (8MB, 16MB, 32MB, 64MB).
*/

import 'package:dart_mymc/dart_mymc.dart';

void main() {
  print('--- Formatting a standard 8MB card ---');
  Ps2Card card8 = Ps2Card.format(); // Default is 8MB
  printCardInfo(card8);
  card8.close();

  print('\n--- Formatting a large 64MB card ---');
  Ps2Card card64 = Ps2Card.format(sizeMb: 64);
  printCardInfo(card64);

  // You can then save the finished image to disk:
  // File('my_64mb_card.ps2').writeAsBytesSync(card64.toBytes());
  
  card64.close();
}

void printCardInfo(Ps2Card card) {
  final info = card.info;
  final totalMb = info.totalBytes / (1024 * 1024);
  final freeKb = info.freeBytes ~/ 1024;
  
  print('Capacity: ${totalMb.toStringAsFixed(0)} MB');
  print('Free Space: $freeKb KB');
}
