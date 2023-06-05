# Arch Linux Bash Installer Text Edition

It's actually an Arch Linux installer which doesn't use semi-gui configuration - everyrthing is set in a config file and you just adjust it to your needs.

### Configuration and running

To get into the script directory, you can run `cd albite`
To run the program, run `sh albite.sh`. On the first run, the script will create a configuration file depending on the boot mode (UEFI or BIOS), and its name will be `config.conf`. You can use nano or vim, etc. to edit it and adjust to your needs.
Manual is available [here](https://github.com/barteqcz/albite/blob/main/docs/manual.md)

That's not an interactive installer. For interactive, semi-graphical installation, see [ALBI](https://github.com/barteqcz/albi)
