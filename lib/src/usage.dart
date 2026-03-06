
// ignore_for_file: unused_element

String usage =
"""
# ===========================================================================
# dart_mymc usage guide
# All examples use 'mymc' (compiled binary: dart compile exe bin/dart_mymc.dart -o mymc)
# ===========================================================================

# ---------------------------------------------------------------------------
# Card information
# ---------------------------------------------------------------------------

# Show all saves on a card with their titles and free space (dir)
\$ mymc card.ps2 dir

# List entries in the root directory (ls)
\$ mymc card.ps2 ls

# List entries in a specific save directory (ls)
\$ mymc card.ps2 ls BASLUS-20919NFL2K16

# List entries in the root directory, showing creation times (ls)
\$ mymc card.ps2 ls -c

# List entries in a save directory, showing creation times (ls)
\$ mymc card.ps2 ls -c BASLUS-20919NFL2K16

# Show free space on the card in bytes (df)
\$ mymc card.ps2 df

# Check the card filesystem for structural errors (check)
\$ mymc card.ps2 check

# ---------------------------------------------------------------------------
# Format a new card
# ---------------------------------------------------------------------------

# Format a new card image, fails if card.ps2 already exists (format)
\$ mymc card.ps2 format

# Format a new card image, overwriting an existing file (format)
\$ mymc card.ps2 format -f

# Format a new card without ECC data (format)
\$ mymc card.ps2 format -e

# Format a new card without ECC data, overwriting an existing file (format)
\$ mymc card.ps2 format -e -f

# Format a new card with a custom cluster count, default is 8192 (format)
\$ mymc card.ps2 format -c 4096

# ---------------------------------------------------------------------------
# Directory and file management
# ---------------------------------------------------------------------------

# Create a save directory on the card (mkdir)
\$ mymc card.ps2 mkdir BASLUS-20919NFL2K16

# Remove a file from a save directory (remove)
\$ mymc card.ps2 remove BASLUS-20919NFL2K16/datafile

# Remove an empty directory from the card (remove)
\$ mymc card.ps2 remove BASLUS-20919NFL2K16

# Rename a file or directory on the card (rename)
\$ mymc card.ps2 rename BASLUS-20919NFL2K16 BASLUS-20919NFL2K16_bak

# Add a raw file to the card root (add)
\$ mymc card.ps2 add rawfile.bin

# Add a raw file into a specific save directory on the card (add)
\$ mymc card.ps2 add -d BASLUS-20919NFL2K16 rawfile.bin

# Extract a raw file from the card to the current host directory (extract)
\$ mymc card.ps2 extract BASLUS-20919NFL2K16/icon.sys

# Extract a raw file from the card to a specific output file (extract)
\$ mymc card.ps2 extract -o icon.sys BASLUS-20919NFL2K16/icon.sys

# Extract a raw file from the card into a specific host directory (extract)
\$ mymc card.ps2 extract -d output_dir BASLUS-20919NFL2K16/icon.sys

# Extract multiple raw files from a save directory to the current host directory (extract)
\$ mymc card.ps2 extract BASLUS-20919NFL2K16/*

# Extract a raw file and pipe it to standard output (extract)
\$ mymc card.ps2 extract -p BASLUS-20919NFL2K16/icon.sys

# ---------------------------------------------------------------------------
# Import saves onto a card
# ---------------------------------------------------------------------------

# Import a PSU save file onto the card (import)
\$ mymc card.ps2 import NFL2K16.psu

# Import a MAX Drive save file onto the card (import)
\$ mymc card.ps2 import NFL2K16.max

# Import a SharkPort save file onto the card (import)
\$ mymc card.ps2 import NFL2K16.sps

# Import a CodeBreaker save file onto the card (import)
\$ mymc card.ps2 import NFL2K16.cbs

# Import a save, skipping silently if it already exists on the card (import)
\$ mymc card.ps2 import -i NFL2K16.psu

# Import a packaged save to a specific destination directory name on the card (import)
\$ mymc card.ps2 import -d MY_SAVE_DIR NFL2K16.psu

# Import multiple save files at once (import)
\$ mymc card.ps2 import save1.psu save2.max save3.psu

# Import a raw save folder directly onto the card (import)
\$ mymc card.ps2 import my_saves/BASLUS-20919NFL2K16

# Import a raw save folder, skipping if it already exists on the card (import)
\$ mymc card.ps2 import -i my_saves/BASLUS-20919NFL2K16

# Import all save folders from a host directory onto the card (import-all)
\$ mymc card.ps2 import-all my_saves

# Import all save folders, skipping any that already exist on the card (import-all)
\$ mymc card.ps2 import-all -i my_saves

# ---------------------------------------------------------------------------
# Export saves from a card (packaged formats)
# ---------------------------------------------------------------------------

# Export a save as a PSU file, filename derived from save directory name (export)
\$ mymc card.ps2 export /BASLUS-20919NFL2K16

# Export a save as a PSU file with a specific output filename (export)
\$ mymc card.ps2 export -o NFL2K16.psu /BASLUS-20919NFL2K16

# Export a save as MAX Drive format (export)
\$ mymc card.ps2 export -t max /BASLUS-20919NFL2K16

# Export a save as MAX Drive format with a specific output filename (export)
\$ mymc card.ps2 export -t max -o NFL2K16.max /BASLUS-20919NFL2K16

# Export a save to a specific output directory (export)
\$ mymc card.ps2 export -d output_dir /BASLUS-20919NFL2K16

# Export a save using a long descriptive filename that includes the save title (export)
\$ mymc card.ps2 export -l /BASLUS-20919NFL2K16

# Export a save, overwriting the output file if it already exists (export)
\$ mymc card.ps2 export -f -o NFL2K16.psu /BASLUS-20919NFL2K16

# Export a save, skipping silently if the output file already exists (export)
\$ mymc card.ps2 export -i /BASLUS-20919NFL2K16

# Export multiple saves at once as PSU files (export)
\$ mymc card.ps2 export /BASLUS-20919NFL2K16 /BASLUS-20956Game1

# Export all saves on the card as PSU files using a glob pattern (export)
\$ mymc card.ps2 export '*'

# ---------------------------------------------------------------------------
# Export saves from a card (raw folders)
# ---------------------------------------------------------------------------

# Extract raw files from a save directory into a host folder named after the save (export-files)
\$ mymc card.ps2 export-files /BASLUS-20919NFL2K16

# Extract raw files from a save into a specific host directory (export-files)
\$ mymc card.ps2 export-files -d my_saves /BASLUS-20919NFL2K16

# Extract raw files, overwriting the output folder if it already exists (export-files)
\$ mymc card.ps2 export-files -f -d my_saves /BASLUS-20919NFL2K16

# Extract raw files, skipping if the output folder already exists (export-files)
\$ mymc card.ps2 export-files -i -d my_saves /BASLUS-20919NFL2K16

# Extract raw files from multiple saves at once (export-files)
\$ mymc card.ps2 export-files -d my_saves /BASLUS-20919NFL2K16 /BASLUS-20956Game1

# Extract raw files from all saves on the card to the current directory (export-all)
\$ mymc card.ps2 export-all

# Extract all saves to host folders inside a specific directory (export-all)
\$ mymc card.ps2 export-all -d my_saves

# Extract all saves, overwriting any existing output folders (export-all)
\$ mymc card.ps2 export-all -f -d my_saves

# Extract all saves, skipping any whose output folder already exists (export-all)
\$ mymc card.ps2 export-all -i -d my_saves

# ---------------------------------------------------------------------------
# Delete a save
# ---------------------------------------------------------------------------

# Delete a save directory and all its files from the card (delete)
\$ mymc card.ps2 delete /BASLUS-20919NFL2K16

# ---------------------------------------------------------------------------
# Mode flags (set / clear)
# ---------------------------------------------------------------------------

# Set the read-allowed flag on a file (set)
\$ mymc card.ps2 set -r /BASLUS-20919NFL2K16/datafile

# Set the write-allowed flag on a file (set)
\$ mymc card.ps2 set -w /BASLUS-20919NFL2K16/datafile

# Set the execute flag on a file (set)
\$ mymc card.ps2 set -x /BASLUS-20919NFL2K16/datafile

# Set multiple permission flags at once (set)
\$ mymc card.ps2 set -r -w -x /BASLUS-20919NFL2K16/datafile

# Set the copy-protected flag on a save directory (set)
\$ mymc card.ps2 set -p /BASLUS-20919NFL2K16

# Set the PSX flag on a save directory (set)
\$ mymc card.ps2 set -s /BASLUS-20919NFL2K16

# Set the PocketStation flag on a save directory (set)
\$ mymc card.ps2 set -k /BASLUS-20919NFL2K16

# Set the hidden flag on a save directory (set)
\$ mymc card.ps2 set -H /BASLUS-20919NFL2K16

# Set mode flags using a raw hex value (set)
\$ mymc card.ps2 set -X 0x8427 /BASLUS-20919NFL2K16

# Clear the read-allowed flag on a file (clear)
\$ mymc card.ps2 clear -r /BASLUS-20919NFL2K16/datafile

# Clear the write-allowed flag on a file (clear)
\$ mymc card.ps2 clear -w /BASLUS-20919NFL2K16/datafile

# Clear the execute flag on a file (clear)
\$ mymc card.ps2 clear -x /BASLUS-20919NFL2K16/datafile

# Clear the copy-protected flag on a save directory (clear)
\$ mymc card.ps2 clear -p /BASLUS-20919NFL2K16

# Clear the PSX flag on a save directory (clear)
\$ mymc card.ps2 clear -s /BASLUS-20919NFL2K16

# Clear the PocketStation flag on a save directory (clear)
\$ mymc card.ps2 clear -k /BASLUS-20919NFL2K16

# Clear the hidden flag on a save directory (clear)
\$ mymc card.ps2 clear -H /BASLUS-20919NFL2K16

# ---------------------------------------------------------------------------
# Format conversion (no card needed)
# ---------------------------------------------------------------------------

# Convert a PSU save to MAX Drive format (convert)
\$ mymc convert NFL2K16.psu NFL2K16.max

# Convert a MAX Drive save to PSU format (convert)
\$ mymc convert NFL2K16.max NFL2K16.psu

# ---------------------------------------------------------------------------
# Create a new card pre-loaded with saves (no separate format step needed)
# ---------------------------------------------------------------------------

# Create a new card pre-loaded with a single save file (create)
\$ mymc new.ps2 create NFL2K16.psu

# Create a new card pre-loaded with multiple save files (create)
\$ mymc new.ps2 create save1.psu save2.max save3.psu

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

# Show the full command list (help)
\$ mymc --help

# Show detailed help for a specific command (help)
\$ mymc help export

# Show detailed help for a command using the --help flag (help)
\$ mymc card.ps2 export --help
""";

// Standard Colors (Darker)
String _black(String text)   => '\x1B[30m$text\x1B[0m';
String _red(String text)     => '\x1B[31m$text\x1B[0m';
String _green(String text)   => '\x1B[32m$text\x1B[0m';
String _yellow(String text)  => '\x1B[33m$text\x1B[0m';
String _blue(String text)    => '\x1B[34m$text\x1B[0m';
String _magenta(String text) => '\x1B[35m$text\x1B[0m';
String _cyan(String text)    => '\x1B[36m$text\x1B[0m';
String _white(String text)   => '\x1B[37m$text\x1B[0m';

// Bright Colors (Vivid)
String _brightBlack(String text)   => '\x1B[90m$text\x1B[0m'; // Often "Gray"
String _brightRed(String text)     => '\x1B[91m$text\x1B[0m';
String _brightGreen(String text)   => '\x1B[92m$text\x1B[0m';
String _brightYellow(String text)  => '\x1B[93m$text\x1B[0m';
String _brightBlue(String text)    => '\x1B[94m$text\x1B[0m';
String _brightMagenta(String text) => '\x1B[95m$text\x1B[0m';
String _brightCyan(String text)    => '\x1B[96m$text\x1B[0m';
String _brightWhite(String text)   => '\x1B[97m$text\x1B[0m';


// print out detailed usage instructions
// command - empty for entire (huge) message, 'command name' for show only usage for a specific command
void printUsage(String command){
  final lines = usage.replaceAll("\r\n", "\n").split("\n");
  for (var line in lines) {
    if(line.isNotEmpty && line.startsWith('#')){
      if(command.isEmpty || line.contains(command)){
        print(_brightGreen(line));
      }
    } else {
      if(command.isEmpty || line.contains(command)){
        print(_brightCyan(line));
      }
    }
  }
}


/*
Index,Color,Hex (Approx),Description
0,Black,#000000,Typically the background or heavy shadows.
1,Red,#800000,"Errors, alerts, or critical stops."
2,Green,#008000,"Success, ""go,"" or positive status."
3,Yellow,#808000,"Warnings or ""in-progress"" indicators."
4,Blue,#000080,Primary information or links.
5,Magenta,#800080,Secondary highlights or commands.
6,Cyan,#008080,"File paths, constants, or data types."
7,White,#C0C0C0,Standard light-gray text.
8,Bright Black,#808080,"Often used as ""Gray"" for comments/metadata."
9,Bright Red,#FF0000,High-visibility errors.
10,Bright Green,#00FF00,Vibrant success/completion.
11,Bright Yellow,#FFFF00,High-visibility warnings.
12,Bright Blue,#0000FF,Vibrant UI elements.
13,Bright Magenta,#FF00FF,Active focus or selection.
14,Bright Cyan,#00FFFF,Vibrant data highlights.
15,Bright White,#FFFFFF,Bold headings or high-contrast text.

*/