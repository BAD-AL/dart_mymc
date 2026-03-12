// dart_mymc.dart
//
// Library entry point — web-safe public API.

library dart_mymc;

// Public API — stable facade layer
export 'src/ps2card_io.dart'; // Ps2CardIo, SaveIo, MemoryCardIo, MemorySaveIo
export 'src/ps2card.dart'; // Ps2Card, Ps2Save, Ps2SaveInfo, Ps2CardInfo, Ps2SaveFormat

// Exception types — consumers need to catch these
export 'src/ps2mc.dart'
    show
        Ps2McError,
        Ps2McCorrupt,
        Ps2McEccError,
        Ps2McPathNotFound,
        Ps2McFileNotFound,
        Ps2McDirNotFound,
        Ps2McIoError,
        Ps2McNoSpace;

// CLI runner lives in dart_mymc_cli.dart (dart:io / native only).
