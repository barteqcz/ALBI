# Arch Linux Bash Installer
An Arch Linux Bash Installer, with an easily customizable installation process using a config file.

### Capabilities
- High-Speed Performance: The script operates with remarkable speed, leveraging the efficiency of your internet connection and mirror capabilities. For optimum results, utilizing SSDs is recommended due to their significantly faster processing speed compared to HDDs.

- Seamless Printing Experience: Enjoy full CUPS implementation support, which includes hassle-free driverless printing and seamless network printer compatibility. Additionally, the installation includes the essential HPLIP with its CUPS plugin for enhanced functionality.

- Efficient Resource Utilization: Our installer is designed with a text-only interface, utilizing the simplicity and speed of Bash scripting. As a result, ALBI runs effortlessly even on low-powered hardware, ensuring smooth performance without resource strain.

- Automated Configuration and Flexibility: Before installation, all settings are conveniently configured in a user-friendly file. Once initiated, the installation becomes completely 'hands-free,' requiring no further user intervention. Moreover, the configuration file can be easily replicated across multiple machines, streamlining the setup process. ALBI also offers custom package installation support, allowing you to specify the packages you wish to integrate into your system.

- Error-Proof Configuration Checker: ALBI features an intelligent configuration error checker, diligently scanning the configuration file for any errors or syntax issues. This ensures a flawless installation process with minimal chances of unexpected problems.

- Enhanced User Experience: ALBI enhances your overall user experience by implementing useful tweaks by default. These include visible '*' characters when inputting passwords for added security, a colorfully animated Pacman prompt, nano language detection for improved code editing, and a custom /etc/nsswitch.conf file that automatically detects networks and driverless printers, among other enhancements.

### Downloading
You have the choice of downloading the entire repository using `git`, or if you prefer a more streamlined approach, you can opt to download only the albi.sh file using `curl`.

Here's how you can download just the source code file with `curl`:

`curl -O -L https://raw.githubusercontent.com/barteqcz/albi/main/albi.sh`

To download the entire repository, including both the source file and documentation, you can reach it using `git` (remember to install it first).

`git clone https://github.com/barteqcz/albi`

If you prefer a more 'hands-on' approach, you have the option to manually download the desired files. With this method, you can also create and maintain a single adjusted configuration file that can be easily transferred between different PCs using a USB drive. This way, you can streamline the installation process across multiple machines, saving time and effort during the installation process.

### Preparation
Before running the script, mount all the partitions you wanna use. Otherwise the script won't be able to run. I haven't implemented any partitioning helper, because I don't know how to solve the biggest problem - differences in configurations - someone will wanna use '/' as the only partition (as I do), but someone will wanna use /home, /boot or /var separately - I don't know what partitions will be used by various users.

### Configuration and running
To get into the script directory, you can run `cd albi`. To run the program, run `sh albi.sh`. On the first run, the script will create a configuration file depending on the boot mode (UEFI or BIOS), and its name will be `config.conf`. You can use nano or vim, etc. to edit it and adjust to your needs.

Manual is available [here](https://github.com/barteqcz/albi/blob/main/docs/manual.txt).
