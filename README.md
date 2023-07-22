# Arch Linux Bash Installer Text Edition
It's actually an Arch Linux installer, where everything is set in a config file and you just adjust it to your needs.

### Capabilities
- speed* - the script does its work very fast, but overall speed will vary based on your internet connection speed and mirrors capabilities, but also on your disk (SSDs will be much faster than HDDs).
- full CUPS implementation support - driverless printing and network printers will work by default, HPLIP is installed with is CUPS plugin.
- low-resource requirements - the installer is text-only, the code is written in Bash - it's very straight and simple, so it will run even on weak hardware.
- automatization & flexibility - you set all the settings in a config file before the installation, so that then the installation is 'hands-free' - you don't have to do anything during the installation. Additionally, you can even copy that config file and use on other machines. ALBITE also handles custom packages installation - there is a special variable, in which you can write down all the custom packages that you wanna install in the system.
- config error checker (beta) - checks the configuration file for mistakes in the values and syntax errors.
- useful tweaks - ALBITE applies some useful tweaks by default - visible '*' characters when inputting passwords, colored Pacman prompt, animated Pacman prompt, nano languages detection, customized /etc/nsswitch.conf file to automatically detect network, driverless printers, etc.

### Downloading
You'll need to download this repo. 

You can do it using `git`:

`git clone https://github.com/barteqcz/albite`

But also manually, for example from some other PC, then put it on an USB drive, and mount so that it will be available in Arch installation media.

### Preparation
Before running the script, mount all the partitions you wanna use. Otherwise the script won't be able to run. I haven't implemented any partitioning helper, because I don't know how to solve the biggest problem - differences in configurations - someone will wanna use '/' as the only partition (as I do), but someone will wanna use /home, /boot or /var separately - I don't know what partitions will be used by various users.

### Configuration and running
To get into the script directory, you can run `cd albite`. To run the program, run `sh albite.sh`. On the first run, the script will create a configuration file depending on the boot mode (UEFI or BIOS), and its name will be `config.conf`. You can use nano or vim, etc. to edit it and adjust to your needs.

Manual is available [here](https://github.com/barteqcz/albite/blob/main/docs/manual.txt).
