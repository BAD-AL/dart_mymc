// round.dart
//
// Ported from round.py by Ross Ridge (Public Domain)
// Simple rounding functions.

int divRoundUp(int a, int b) => (a + b - 1) ~/ b;
int roundUp(int a, int b) => (a + b - 1) ~/ b * b;
int roundDown(int a, int b) => a ~/ b * b;
