# Arch Linux Bash Installer
An Arch Linux Bash Installer, with an easily customizable installation process using a config file.

### Capabilities

- Partitioning Helper: The script includes a helpful feature that allows you to select the appropriate partition for each mountpoint. It's important to note that the script exclusively utilizes **existing partitions**; **it doesn't create new ones**. Therefore, before using the script, **make sure you have prepared your desired partition scheme.**

- Formatting Helper: The script also includes a feature that allows you to select the appropriate filesystem for each partition.

- High-Speed Performance: The script operates with remarkable speed, leveraging the efficiency of your internet connection and mirror capabilities. For optimum results, utilizing SSDs is recommended due to their significantly faster processing speed compared to HDDs.

- Seamless Printing Experience: Enjoy full CUPS implementation support, which includes hassle-free driverless printing and seamless network printer compatibility. Additionally, the installation includes the essential HPLIP with its CUPS plugin for enhanced functionality and full support for HP printers.

- Automated Configuration and Flexibility: Before installation, all settings are conveniently configured in a user-friendly file. Once initiated, the installation becomes completely 'hands-free,' requiring no further user intervention. Moreover, the configuration file can be easily replicated across multiple machines, streamlining the setup process. ALBI also offers custom package installation support, allowing you to specify additional packages you wish to install into your system.

- Error-Proof Configuration Checker: ALBI features a configuration error checker, diligently scanning the configuration file for any errors or syntax issues. This ensures a flawless installation process with minimal chances of unexpected problems.

- Enhanced User Experience: ALBI enhances overall user experience by implementing useful tweaks by default. These include visible '*' characters when inputting passwords, a colorfully animated Pacman prompt, nano language detection for improved code editing, and a custom /etc/nsswitch.conf file that automatically detects network printers.

- Security matters: ALBI is able to fully encrypt your system, using the efficient LUKS encryption method. Additionally, firewall is being installed by default to protect your system.

### Downloading
To download the entire repository, including both the source file and documentation, you can reach it using `git` (remember to install it first).

`git clone https://github.com/barteqcz/albi`

If you prefer a more 'hands-on' approach, you have the option to manually download the desired files. With this method, you can also create and maintain a single adjusted configuration file that can be easily transferred between different PCs using a USB drive, or using a network server (what is more convenient than using an USB drive). This way, you can streamline the installation process across multiple machines, saving time and effort during the installation process.

### Preparation
Before running the script, ensure that you have created all the partitions you intend to use. Then, you have to specify their paths in the configuration file. The script will then proceed to create a filesystem on each partition and automatically mount them as specified.

### Configuration and running
Launching the program is a breeze; just type `bash albi.sh`, but ensure you are in the same directory as the script. On its first run, the script generates a configuration file named `config.conf`, tailored to your system's boot mode (UEFI or BIOS). For customizing variable values in the configuration file, use tools like nano or vim and refer to the documentation for possible variable values.
