# Arch Linux Bash Installer Text Edition
It's actually an Arch Linux installer which doesn't use semi-gui configuration - everyrthing is set in a config file and you just adjust it to your needs

### Downloading
You'll need to download this repo. 

You can do it using `git`:

```git clone https://github.com/barteqcz/albite```

But also manually, for example from some other PC, then put it on an USB drive, and mount so that it will be available in Arch installation medium

### Configuration and running
To get into the script directory, you can run `cd albite`. To run the program, run `sh albite.sh`. On the first run, the script will create a configuration file depending on the boot mode (UEFI or BIOS), and its name will be `config.conf`. You can use nano or vim, etc. to edit it and adjust to your needs
Manual is available [here](https://github.com/barteqcz/albite/blob/main/docs/manual.md)

For semi-graphical installation, see [ALBI](https://github.com/barteqcz/albi)
