#!/bin/bash

if ! command -v dialog &> /dev/null; then
    pacman -Sy dialog --noconfirm
fi

BT="ALBI configuration wizard"

get_status() {
    if [ "$1" = "$2" ]; then echo "ON"; else echo "OFF"; fi
}

# Detect boot mode
if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
else
    boot_mode="BIOS"
fi

root_part=""
root_part_filesystem="ext4"
separate_home_part="none"
separate_home_part_filesystem="ext4"
separate_boot_part="none"
separate_boot_part_filesystem="ext4"
separate_var_part="none"
separate_var_part_filesystem="ext4"
separate_tmp_part="none"
separate_tmp_part_filesystem="ext4"
luks_encryption="no"
luks_passphrase=""
efi_part=""
efi_part_mountpoint="/boot/efi"
grub_disk=""
network_management="network-manager"
kernel_variant="normal"
mirror_location="none"
timezone="Europe/Prague"
hostname=$(dmidecode -s system-product-name 2>/dev/null | sed 's/[[:space:]]*$//' || echo "archlinux")
username="archuser"
full_username=""
password=""
language="en_US.UTF-8"
tty_keyboard_layout="us"
install_pipewire="yes"
gpu="amd"
de="gnome"
install_cups="yes"
create_swapfile="yes"
swapfile_size_gb="4"
keep_config="no"

step=1
while true; do
    case $step in
        1)
            root_part=$(dialog --stdout --cancel-label "Exit" --backtitle "$BT" --title "Root Partition" --inputbox "Enter the path for the / partition:" 10 60 "$root_part")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then clear; echo "Configuration aborted."; exit 0; fi
            step=2
            ;;
        2)
            root_part_filesystem=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Root Filesystem" --radiolist "Select the filesystem for /:" 15 50 5 \
                "ext4" "" "$(get_status "$root_part_filesystem" "ext4")" \
                "btrfs" "" "$(get_status "$root_part_filesystem" "btrfs")" \
                "xfs" "" "$(get_status "$root_part_filesystem" "xfs")" \
                "ext3" "" "$(get_status "$root_part_filesystem" "ext3")" \
                "ext2" "" "$(get_status "$root_part_filesystem" "ext2")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=1; continue; fi
            step=3
            ;;
        3)
            separate_home_part=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Home Partition" --inputbox "Enter the path for /home, or leave as 'none':" 10 60 "$separate_home_part")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=2; continue; fi
            if [ "$separate_home_part" = "none" ]; then step=5; else step=4; fi
            ;;
        4)
            separate_home_part_filesystem=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Home Filesystem" --radiolist "Select the filesystem for /home:" 15 50 5 \
                "ext4" "" "$(get_status "$separate_home_part_filesystem" "ext4")" \
                "btrfs" "" "$(get_status "$separate_home_part_filesystem" "btrfs")" \
                "xfs" "" "$(get_status "$separate_home_part_filesystem" "xfs")" \
                "ext3" "" "$(get_status "$separate_home_part_filesystem" "ext3")" \
                "ext2" "" "$(get_status "$separate_home_part_filesystem" "ext2")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=3; continue; fi
            step=5
            ;;
        5)
            separate_boot_part=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Boot Partition" --inputbox "Enter the path for /boot, or leave as 'none':" 10 60 "$separate_boot_part")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                if [ "$separate_home_part" = "none" ]; then step=3; else step=4; fi
                continue
            fi
            if [ "$separate_boot_part" = "none" ]; then step=7; else step=6; fi
            ;;
        6)
            separate_boot_part_filesystem=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Boot Filesystem" --radiolist "Select the filesystem for /boot:" 15 50 5 \
                "ext4" "" "$(get_status "$separate_boot_part_filesystem" "ext4")" \
                "btrfs" "" "$(get_status "$separate_boot_part_filesystem" "btrfs")" \
                "xfs" "" "$(get_status "$separate_boot_part_filesystem" "xfs")" \
                "ext3" "" "$(get_status "$separate_boot_part_filesystem" "ext3")" \
                "ext2" "" "$(get_status "$separate_boot_part_filesystem" "ext2")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=5; continue; fi
            step=7
            ;;
        7)
            separate_var_part=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Var Partition" --inputbox "Enter the path for /var, or leave as 'none':" 10 60 "$separate_var_part")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                if [ "$separate_boot_part" = "none" ]; then step=5; else step=6; fi
                continue
            fi
            if [ "$separate_var_part" = "none" ]; then step=9; else step=8; fi
            ;;
        8)
            separate_var_part_filesystem=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Var Filesystem" --radiolist "Select the filesystem for /var:" 15 50 5 \
                "ext4" "" "$(get_status "$separate_var_part_filesystem" "ext4")" \
                "btrfs" "" "$(get_status "$separate_var_part_filesystem" "btrfs")" \
                "xfs" "" "$(get_status "$separate_var_part_filesystem" "xfs")" \
                "ext3" "" "$(get_status "$separate_var_part_filesystem" "ext3")" \
                "ext2" "" "$(get_status "$separate_var_part_filesystem" "ext2")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=7; continue; fi
            step=9
            ;;
        9)
            separate_tmp_part=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Tmp Partition" --inputbox "Enter the path for /tmp, or leave as 'none':" 10 60 "$separate_tmp_part")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                if [ "$separate_var_part" = "none" ]; then step=7; else step=8; fi
                continue
            fi
            if [ "$separate_tmp_part" = "none" ]; then step=11; else step=10; fi
            ;;
        10)
            separate_tmp_part_filesystem=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Tmp Filesystem" --radiolist "Select the filesystem for /tmp:" 15 50 5 \
                "ext4" "" "$(get_status "$separate_tmp_part_filesystem" "ext4")" \
                "btrfs" "" "$(get_status "$separate_tmp_part_filesystem" "btrfs")" \
                "xfs" "" "$(get_status "$separate_tmp_part_filesystem" "xfs")" \
                "ext3" "" "$(get_status "$separate_tmp_part_filesystem" "ext3")" \
                "ext2" "" "$(get_status "$separate_tmp_part_filesystem" "ext2")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=9; continue; fi
            step=11
            ;;
        11)
            luks_encryption=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Disk Encryption" --radiolist "Encrypt the system with LUKS?" 12 40 2 \
                "yes" "" "$(get_status "$luks_encryption" "yes")" \
                "no" "" "$(get_status "$luks_encryption" "no")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                if [ "$separate_tmp_part" = "none" ]; then step=9; else step=10; fi
                continue
            fi
            if [ "$luks_encryption" = "yes" ]; then step=12; else
                if [ "$boot_mode" = "UEFI" ]; then step=13; else step=15; fi
            fi
            ;;
        12)
            luks_passphrase=$(dialog --stdout --cancel-label "Back" --insecure --backtitle "$BT" --title "LUKS Passphrase" --passwordbox "Enter your encryption passphrase:" 10 50)
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=11; continue; fi
            if [ "$boot_mode" = "UEFI" ]; then step=13; else step=15; fi
            ;;
        13)
            efi_part=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "EFI Partition" --inputbox "Enter EFI partition path (e.g., /dev/sda1):" 10 60 "$efi_part")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                if [ "$luks_encryption" = "yes" ]; then step=12; else step=11; fi
                continue
            fi
            step=14
            ;;
        14)
            efi_part_mountpoint=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "EFI Mountpoint" --radiolist "Select EFI mountpoint:" 12 50 2 \
                "/boot/efi" "Recommended" "$(get_status "$efi_part_mountpoint" "/boot/efi")" \
                "/efi" "Alternative" "$(get_status "$efi_part_mountpoint" "/efi")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=13; continue; fi
            step=16
            ;;
        15)
            grub_disk=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "GRUB Disk" --inputbox "Enter disk for GRUB installation (e.g., /dev/sda):" 10 60 "$grub_disk")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                if [ "$luks_encryption" = "yes" ]; then step=12; else step=11; fi
                continue
            fi
            step=16
            ;;
        16)
            network_management=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Network Management" --radiolist "Select a network manager tool:" 14 50 3 \
                "network-manager" "" "$(get_status "$network_management" "network-manager")" \
                "systemd-networkd" "" "$(get_status "$network_management" "systemd-networkd")" \
                "none" "" "$(get_status "$network_management" "none")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                if [ "$boot_mode" = "UEFI" ]; then step=14; else step=15; fi
                continue
            fi
            step=17
            ;;
        17)
            kernel_variant=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Kernel Variant" --radiolist "Select kernel variant:" 14 50 3 \
                "normal" "Standard Arch Kernel" "$(get_status "$kernel_variant" "normal")" \
                "lts" "Long Term Support" "$(get_status "$kernel_variant" "lts")" \
                "zen" "Zen Kernel" "$(get_status "$kernel_variant" "zen")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=16; continue; fi
            step=18
            ;;
        18)
            mirror_location=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Mirrors" --inputbox "Enter mirror country (comma-separated or 'none'):" 10 60 "$mirror_location")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=17; continue; fi
            step=19
            ;;
        19)
            timezone=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Timezone" --inputbox "Enter timezone (Region/City):" 10 60 "$timezone")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=18; continue; fi
            step=20
            ;;
        20)
            hostname=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Hostname" --inputbox "Enter machine hostname:" 10 60 "$hostname")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=19; continue; fi
            step=21
            ;;
        21)
            username=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Username" --inputbox "Enter the primary username:" 10 60 "$username")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=20; continue; fi
            step=22
            ;;
        22)
            full_username=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Full Name" --inputbox "Enter full name (optional, leave empty to skip):" 10 60 "$full_username")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=21; continue; fi
            step=23
            ;;
        23)
            password=$(dialog --stdout --cancel-label "Back" --insecure --backtitle "$BT" --title "User Password" --passwordbox "Enter user password:" 10 60)
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=22; continue; fi
            step=24
            ;;
        24)
            language=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "System Language" --inputbox "Enter system language locale:" 10 60 "$language")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=23; continue; fi
            step=25
            ;;
        25)
            tty_keyboard_layout=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "TTY Keyboard Layout" --inputbox "Enter TTY keyboard layout:" 10 60 "$tty_keyboard_layout")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=24; continue; fi
            step=26
            ;;
        26)
            install_pipewire=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Audio (PipeWire)" --radiolist "Install PipeWire for audio?" 12 40 2 \
                "yes" "" "$(get_status "$install_pipewire" "yes")" \
                "no" "" "$(get_status "$install_pipewire" "no")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=25; continue; fi
            step=27
            ;;
        27)
            gpu=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "GPU Driver" --radiolist "Select GPU driver:" 16 50 5 \
                "amd" "" "$(get_status "$gpu" "amd")" \
                "intel" "" "$(get_status "$gpu" "intel")" \
                "nvidia" "" "$(get_status "$gpu" "nvidia")" \
                "other" "" "$(get_status "$gpu" "other")" \
                "none" "" "$(get_status "$gpu" "none")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=26; continue; fi
            step=28
            ;;
        28)
            de=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Desktop Environment" --radiolist "Select desktop environment:" 16 50 6 \
                "gnome" "" "$(get_status "$de" "gnome")" \
                "plasma" "" "$(get_status "$de" "plasma")" \
                "xfce" "" "$(get_status "$de" "xfce")" \
                "cinnamon" "" "$(get_status "$de" "cinnamon")" \
                "mate" "" "$(get_status "$de" "mate")" \
                "none" "" "$(get_status "$de" "none")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=27; continue; fi
            step=29
            ;;
        29)
            install_cups=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Printing (CUPS)" --radiolist "Install CUPS printing support?" 12 40 2 \
                "yes" "" "$(get_status "$install_cups" "yes")" \
                "no" "" "$(get_status "$install_cups" "no")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=28; continue; fi
            step=30
            ;;
        30)
            create_swapfile=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Swapfile" --radiolist "Create a swapfile?" 12 40 2 \
                "yes" "" "$(get_status "$create_swapfile" "yes")" \
                "no" "" "$(get_status "$create_swapfile" "no")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=29; continue; fi
            if [ "$create_swapfile" = "yes" ]; then step=31; else step=32; fi
            ;;
        31)
            swapfile_size_gb=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Swapfile Size" --inputbox "Enter swapfile size in GB:" 10 50 "$swapfile_size_gb")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then step=30; continue; fi
            step=32
            ;;
        32)
            keep_config=$(dialog --stdout --cancel-label "Back" --backtitle "$BT" --title "Keep Copy of Config" --radiolist "Keep config.conf in user home folder after installation?" 12 40 2 \
                "yes" "" "$(get_status "$keep_config" "yes")" \
                "no" "" "$(get_status "$keep_config" "no")")
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                if [ "$create_swapfile" = "yes" ]; then step=31; else step=30; fi
                continue
            fi
            break
            ;;
    esac
done

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

if [[ "$boot_mode" == "UEFI" ]]; then
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

dialog --title "Complete" --msgbox "Configuration generated successfully! You can now run albi.sh to begin your installation." 10 60
clear
