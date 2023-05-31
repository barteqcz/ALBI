#!/bin/bash

touch config.conf
source config.conf
rm config.conf

# Detect the system boot mode
if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
else
    boot_mode="BIOS"
fi

# Create configuration file based on the boot mode
if [ -e "config.conf" ]; then
    :
else
    touch config.conf
    cat <<EOF > config.conf
# Here is the configuration for the installation. For any needed help, refer to the documentation.

# Kernel variant
kernel_variant="normal"

# Timezone setting
timezone="Europe/Prague"

# User configuration
username="exampleusername"
password="examplepasswd"

# Locales settings
language="cs_CZ.UTF-8"
console_keyboard_layout="cz"

# Hostname
hostname="examplehostname"

# GRUB settings
EOF

if [[ $boot_mode == "UEFI" ]]; then
    echo 'efi_partition="/boot/efi"' >> config.conf
else
    echo 'grub_installation_disk="/dev/sda"' >> config.conf
fi

cat <<EOF >> config.conf

# Audio server setting
audio_server="pipewire"

# GPU driver
gpu_driver="nvidia"

# DE settings
de="xfce"

# Decide whether CUPS should be installed
cups_installation="yes"

# Swapfile settings
create_swapfile="yes"
swapfile_size_gb="4"
EOF

echo "Config file was generated successfully. Edit it to adjust it to your needs."
exit
fi

# Install base system
echo "Installing base system..."
if [[ $kernel_variant == "normal" ]]; then
    pacstrap -K /mnt base linux linux-firmware linux-headers >/dev/null 2>&1
elif [[ $kernel_variant == "lts" ]]; then
    pacstrap -K /mnt base linux-lts linux-firmware linux-lts-headers >/dev/null 2>&1
elif [[ $kernel_variant == "zen" ]]; then
    pacstrap -K /mnt base linux-zen linux-firmware linux-zen-headers >/dev/null 2>&1
fi

# Generate /etc/fstab
echo "Generating /etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Copy second part of the script to /
cp main.sh /mnt/

# Copy config file to /
cp config.conf /mnt/

# Enter arch-chroot and run second part of the script
arch-chroot /mnt bash main.sh
