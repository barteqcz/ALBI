#!/bin/bash

# Ensure dialog is installed
if ! command -v dialog &> /dev/null; then
    pacman -Sy dialog --noconfirm
fi

# Function to capture dialog input
run_dialog() {
    dialog --backtitle "ALBI Arch Linux Installer Configuration" "$@" 3>&1 1>&2 2>&3
}

# --- Part 1: Partitions and Filesystems ---
root_part=$(run_dialog --title "Root Partition" --inputbox "Enter the path for the / partition (e.g., /dev/sda1):" 10 60 "/dev/sda1")
root_part_filesystem=$(run_dialog --title "Root Filesystem" --radiolist "Select the filesystem for /:" 15 50 5 "ext4" "" ON "btrfs" "" OFF "xfs" "" OFF "ext3" "" OFF "ext2" "" OFF)

separate_home_part=$(run_dialog --title "Home Partition" --inputbox "Enter the path for /home, or leave as 'none':" 10 60 "none")
if [[ "$separate_home_part" != "none" ]]; then
    separate_home_part_filesystem=$(run_dialog --title "Home Filesystem" --radiolist "Select the filesystem for /home:" 15 50 5 "ext4" "" ON "btrfs" "" OFF "xfs" "" OFF)
else
    separate_home_part_filesystem="none"
fi

separate_boot_part=$(run_dialog --title "Boot Partition" --inputbox "Enter the path for /boot, or leave as 'none':" 10 60 "none")
if [[ "$separate_boot_part" != "none" ]]; then
    separate_boot_part_filesystem=$(run_dialog --title "Boot Filesystem" --radiolist "Select the filesystem for /boot:" 15 50 5 "ext4" "" ON "ext2" "" OFF "ext3" "" OFF)
else
    separate_boot_part_filesystem="none"
fi

separate_var_part=$(run_dialog --title "Var Partition" --inputbox "Enter the path for /var, or leave as 'none':" 10 60 "none")
if [[ "$separate_var_part" != "none" ]]; then
    separate_var_part_filesystem=$(run_dialog --title "Var Filesystem" --radiolist "Select the filesystem for /var:" 15 50 5 "ext4" "" ON "btrfs" "" OFF "xfs" "" OFF)
else
    separate_var_part_filesystem="none"
fi

separate_tmp_part=$(run_dialog --title "Tmp Partition" --inputbox "Enter the path for /tmp, or leave as 'none':" 10 60 "none")
if [[ "$separate_tmp_part" != "none" ]]; then
    separate_tmp_part_filesystem=$(run_dialog --title "Tmp Filesystem" --radiolist "Select the filesystem for /tmp:" 15 50 5 "ext4" "" ON "btrfs" "" OFF "xfs" "" OFF)
else
    separate_tmp_part_filesystem="none"
fi

# --- Part 2: Encryption ---
luks_encryption=$(run_dialog --title "Disk Encryption" --yesno "Do you want to encrypt the system with LUKS?" 10 50 && echo "yes" || echo "no")
if [[ "$luks_encryption" == "yes" ]]; then
    luks_passphrase=$(run_dialog --title "LUKS Passphrase" --passwordbox "Enter your encryption passphrase:" 10 50)
else
    luks_passphrase="none"
fi

# --- Part 3: Bootloader Variables ---
if [[ -d "/sys/firmware/efi/" ]]; then
    efi_part=$(run_dialog --title "EFI Partition" --inputbox "UEFI mode detected. Enter EFI partition path (e.g., /dev/sda1):" 10 60 "/dev/sda1")
    efi_part_mountpoint=$(run_dialog --title "EFI Mountpoint" --radiolist "Select EFI mountpoint:" 15 50 2 "/boot/efi" "Recommended" ON "/efi" "Alternative" OFF)
else
    grub_disk=$(run_dialog --title "GRUB Disk" --inputbox "BIOS mode detected. Enter disk for GRUB installation (e.g., /dev/sda):" 10 60 "/dev/sda")
fi

# --- Part 4: System Base ---
network_management=$(run_dialog --title "Network Management" --radiolist "Select a network manager:" 15 50 3 "network-manager" "" ON "systemd-networkd" "" OFF "none" "" OFF)
kernel_variant=$(run_dialog --title "Kernel Variant" --radiolist "Select kernel variant:" 15 50 3 "normal" "Standard Arch Kernel" ON "lts" "Long Term Support" OFF "zen" "Zen Kernel" OFF)
mirror_location=$(run_dialog --title "Mirrors" --inputbox "Enter mirror country (e.g., Germany, France) or 'none':" 10 60 "none")
timezone=$(run_dialog --title "Timezone" --inputbox "Enter timezone (Region/City):" 10 60 "Europe/Prague")

# --- Part 5: Users and Locales ---
default_hostname=$(dmidecode -s system-product-name 2>/dev/null | sed 's/[[:space:]]*$//' || echo "archlinux")
hostname=$(run_dialog --title "Hostname" --inputbox "Enter machine hostname:" 10 60 "$default_hostname")
username=$(run_dialog --title "Username" --inputbox "Enter the primary username:" 10 60 "archuser")
full_username=$(run_dialog --title "Full Name" --inputbox "Enter full name (optional, leave blank to skip):" 10 60 "")
password=$(run_dialog --title "User Password" --passwordbox "Enter user password:" 10 60)
language=$(run_dialog --title "System Language" --inputbox "Enter system language:" 10 60 "en_US.UTF-8")
tty_keyboard_layout=$(run_dialog --title "TTY Keyboard Layout" --inputbox "Enter TTY keyboard layout:" 10 60 "us")

# --- Part 6: Software & GUI ---
install_pipewire=$(run_dialog --title "Audio" --yesno "Install PipeWire for audio?" 10 50 && echo "yes" || echo "no")
gpu=$(run_dialog --title "GPU Drivers" --radiolist "Select GPU driver:" 15 50 5 "amd" "" ON "intel" "" OFF "nvidia" "" OFF "other" "" OFF "none" "" OFF)
de=$(run_dialog --title "Desktop Environment" --radiolist "Select Desktop Environment:" 15 50 6 "gnome" "" ON "plasma" "" OFF "xfce" "" OFF "cinnamon" "" OFF "mate" "" OFF "none" "" OFF)
install_cups=$(run_dialog --title "Printing" --yesno "Install CUPS (Printing support)?" 10 50 && echo "yes" || echo "no")

# --- Part 7: Extras ---
create_swapfile=$(run_dialog --title "Swapfile" --yesno "Create a swapfile?" 10 50 && echo "yes" || echo "no")
if [[ "$create_swapfile" == "yes" ]]; then
    swapfile_size_gb=$(run_dialog --title "Swapfile Size" --inputbox "Enter swapfile size in GB (e.g., 4):" 10 50 "4")
else
    swapfile_size_gb="0"
fi
keep_config=$(run_dialog --title "Keep Config" --yesno "Keep a copy of config.conf in user's home directory after install?" 10 60 && echo "yes" || echo "no")

# --- Part 8: Generate config.conf ---
cat <<EOF > config.conf
## Installation Configuration

### Formatting (will be ignored even if not set to "none", unless the corresponding partition is enabled)
root_part_filesystem="$root_part_filesystem"
separate_home_part_filesystem="$separate_home_part_filesystem"
separate_boot_part_filesystem="$separate_boot_part_filesystem"
separate_var_part_filesystem="$separate_var_part_filesystem"
separate_tmp_part_filesystem="$separate_tmp_part_filesystem"

### Mounting
root_part="$root_part"
separate_home_part="$separate_home_part"
separate_boot_part="$separate_boot_part"
separate_var_part="$separate_var_part"
separate_tmp_part="$separate_tmp_part"

### Encryption
luks_encryption="$luks_encryption"
luks_passphrase="$luks_passphrase"
EOF

# Append boot specific configurations
if [[ -d "/sys/firmware/efi/" ]]; then
    cat <<EOF >> config.conf

### EFI partition settings
efi_part="$efi_part"
efi_part_mountpoint="$efi_part_mountpoint"
EOF
else
    cat <<EOF >> config.conf

### GRUB installation disk settings
grub_disk="$grub_disk"
EOF
fi

# Append the rest
cat <<EOF >> config.conf

### Connectivity
network_management="$network_management"

### Kernel Variant
kernel_variant="$kernel_variant"

### Mirror Servers Location
mirror_location="$mirror_location"

### Timezone
timezone="$timezone"

### Hostname and User
hostname="$hostname"
username="$username"
full_username="$full_username"
password="$password"

### Locales
language="$language"
tty_keyboard_layout="$tty_keyboard_layout"

### Software Selection
install_pipewire="$install_pipewire"
gpu="$gpu"
de="$de"
install_cups="$install_cups"

### Swapfile
create_swapfile="$create_swapfile"
swapfile_size_gb="$swapfile_size_gb"

### Script Settings
keep_config="$keep_config"
EOF

dialog --title "Complete" --msgbox "Configuration generated successfully! You can now run albi.sh to begin your installation." 10 50
clear
