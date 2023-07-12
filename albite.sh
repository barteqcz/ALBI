#!/bin/bash

# Interruption handler
interrupt_handler() {
    echo "Interruption signal received. Aborting... "
}

trap interrupt_handler SIGINT

# Detect current working directory and save it to a variable
cwd=$(pwd)

# Detect the system boot mode
if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
else
    boot_mode="BIOS"
fi

# Create configuration file based on the boot mode
if [ -e "config.conf" ]; then
    output=$(bash -n "$cwd"/config.conf 2>&1)
    if [[ -n $output ]]; then
        echo "Syntax errors found in the configuration file."
        exit
    else
        source "$cwd"/config.conf
    fi
else
    touch config.conf
    cat <<EOF > config.conf
# Here is the configuration for the installation. For any needed help, refer to the documentation in docs/manual.md or docs/manual.txt.

# Kernel variant
kernel_variant="normal"

# Timezone setting
timezone="Europe/Prague"

# User configuration
username="exampleusername"
password="examplepasswd"

# Locales settings
language="en_US.UTF-8"
console_keyboard_layout="us"

# Hostname
hostname="examplehostname"

# GRUB settings
EOF

if [[ $boot_mode == "UEFI" ]]; then
    echo 'efi_partition="/boot/efi"' >> config.conf
else
    echo 'grub_disk="/dev/sda"' >> config.conf
fi

cat <<EOF >> config.conf

# Audio server setting
audio_server="pipewire"

# GPU driver
gpu_driver="nvidia"

# DE settings
de="plasma"

# CUPS installation
cups_installation="yes"

# Full HP support installation (HPLIP) + CUPS plugin for HPLIP from AUR (UNTESTED)
full_hp_support="no"

# Swapfile settings
create_swapfile="yes"
swapfile_size_gb="4"

# Custom packages (separated by spaces)
custom_packages="firefox git neofetch papirus-icon-theme"
EOF

echo "config.conf was generated successfully. Edit it to customize the installation."
exit
fi

# Check the config file values
if [[ $kernel_variant == "normal" || $kernel_variant == "lts" || $kernel_variant == "zen" ]]; then
    :
else
    echo "Error: invalid value for the kernel variant. Check the manual for possible values."
    exit
fi

if [[ $audio_server == "pipewire" || $audio_server == "pulseaudio" || $audio_server == "none" ]]; then
    :
else
    echo "Error: invalid value for the audio server. Check the manual for possible values."
    exit
fi

if [[ $gpu_driver == "nvidia" || $gpu_driver == "amd" || $gpu_driver == "intel" || $gpu_driver == "vm" || $gpu_driver == "nouveau" || $gpu_driver == "none" ]]; then
    :
else
    echo "Error: invalid value for the GPU driver. Check the manual for possible values."
    exit
fi

if [[ $de == "gnome" || $de == "plasma" || $de == "xfce" || $de == "none" ]]; then
    :
else
    echo "Error: invalid value for the DE. Check the manual for possible values."
    exit
fi

if [[ $cups_installation == "yes" || $cups_installation == "no" ]]; then
    :
else
    echo "Error: invalid value for the cups installation question. Possible values are 'yes', or 'no'."
    exit
fi

if [[ $create_swapfile == "yes" || $create_swapfile == "no" ]]; then
    :
else
    echo "Error: invalid value for the swapfile creation question. Possible values are 'yes', or 'no'."
    exit
fi

if [[ $swapfile_size_gb =~ ^[0-9]+$ ]]; then
    :
else
    echo "Error: invalid value for the swapfile size: the value isn't numeric."
fi

# Check if any custom packages were defined
if [[ -z $custom_packages ]]; then
    :
else
    pacman -Sy >/dev/null 2>&1
    
    IFS=" " read -ra packages <<< "$custom_packages"
    
    for package in "${packages[@]}"; do
        pacman_output=$(pacman -Ss "$package")
        if [[ -n "$pacman_output" ]]; then
            :
        else
            echo "Error: package '$package' not found."
            exit
        fi
    done
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
