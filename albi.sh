#!/bin/bash

set -Eeo pipefail

installation_started="false"

cleanup_install() {
    if [[ "$installation_started" != "true" ]]; then
        return
    fi

    umount -R /mnt 2>/dev/null || true

    if [[ -n "${root_part_encrypted_name:-}" ]]; then
        cryptsetup close "$root_part_encrypted_name" 2>/dev/null || true
    fi
}

interrupt_handler() {
    echo "Interruption signal received. Aborting... "
    exit 130
}

trap interrupt_handler SIGINT SIGTERM
trap cleanup_install EXIT

cwd=$(pwd)

if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
else
    boot_mode="BIOS"
fi

if [[ -e "config.conf" ]]; then
    chmod 600 "$cwd"/config.conf
    if ! output=$(bash -n "$cwd"/config.conf 2>&1); then
        echo "Syntax errors found in the configuration file."
        echo "$output"
        exit
    else
        while IFS='=' read -r key value; do
            key=$(echo "$key" | sed 's/[[:space:]]\+#.*$//' | xargs)
            value=$(echo "$value" | sed 's/[[:space:]]\+#.*$//' | xargs)

            [[ -z "$key" ]] && continue
            
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            
            declare "$key=$value"
        done < <(grep -v '^#' "$cwd"/config.conf | grep -v '^$')
        clear
        echo "Are these information correct?"
        echo ""

        echo "/: $root_part_filesystem on $root_part"

        if [[ "$separate_home_part" != "none" ]]; then
            if [[ "$separate_home_part_filesystem" != "none" ]]; then
                echo "/home: $separate_home_part_filesystem on $separate_home_part"
            else
                echo "Error: a partition has been selected for /home, but the filesystem is not specified."
            fi
        fi
        if [[ "$separate_boot_part" != "none" ]]; then
            if [[ "$separate_boot_part_filesystem" != "none" ]]; then
                echo "/boot: $separate_boot_part_filesystem on $separate_boot_part"
            else
                echo "Error: a partition has been selected for /boot, but the filesystem is not specified."
            fi
        fi
        if [[ "$separate_var_part" != "none" ]]; then
            if [[ "$separate_var_part_filesystem" != "none" ]]; then
                echo "/var: $separate_var_part_filesystem on $separate_var_part"
            else
                echo "Error: a partition has been selected for /var, but the filesystem is not specified."
            fi
        fi
        if [[ "$separate_tmp_part" != "none" ]]; then
            if [[ "$separate_tmp_part_filesystem" != "none" ]]; then
                echo "/tmp: $separate_tmp_part_filesystem on $separate_tmp_part"
            else
                echo "Error: a partition has been selected for /tmp, but the filesystem is not specified."
            fi
        fi

        if [[ "$luks_encryption" == "yes" ]]; then
            echo "Disk encryption is enabled"
        else
            echo "Disk encryption is disabled"
        fi

        if [[ "$boot_mode" == "UEFI" ]]; then
            echo "EFI partition: $efi_part at $efi_part_mountpoint"
        else
            echo "GRUB disk: $grub_disk"
        fi

        echo "Kernel variant: $kernel_variant"
        echo "Mirror country: $mirror_location"
        echo "Time zone: $timezone"
        echo "Hostname: $hostname"
        echo "Username: $username"

        if [[ "$full_username" != "" ]]; then
            echo "Full username: $full_username"
        else
            echo "Full username was not set."
        fi
        
        echo "User password: [set]"
        echo "Language: $language"
        echo "TTY keyboard layout: $tty_keyboard_layout"

        if [[ "$install_pipewire" == "yes" ]]; then
            echo "PipeWire installation is enabled"
        else
            echo "PipeWire installation is disabled"
        fi

        echo "GPU driver: $gpu"
        echo "Desktop environment: $de"
        
        if [[ "$install_cups" == "yes" ]]; then
            echo "CUPS installation is enabled"
        else
            echo "CUPS installation is disabled"
        fi
        
        if [[ "$create_swap" == "yes" ]]; then
            echo "Swap creation is enabled"
        else
            echo "Swap creation is disabled"
        fi

        if [[ "$keep_config" == "yes" ]]; then
            echo "Config file will be kept in the user directory."
        else
            echo "Config file won't be kept in the user directory."
        fi

        echo ""

        while true; do
            read -rp "Do you want to start the installation? [Y/n] " response

            if [[ "$response" == "Y" || "$response" == "y" || "$response" == "" ]]; then
                clear
                break
            elif [[ "$response" == "N" || "$response" == "n" ]]; then
                echo "Aborting..."
                exit
            else
                echo "Error: incorrect option. Please try again"
            fi
        done

        while IFS='=' read -r key value; do
            key=$(echo "$key" | sed 's/ *#.*$//' | xargs)
            value=$(echo "$value" | sed 's/ *#.*$//' | xargs)
            
            [[ -z "$key" ]] && continue
            
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            
            declare "$key=$value"
        done < <(grep -v '^#' "$cwd"/config.conf | grep -v '^$')
    fi
else
    touch config.conf
    cat <<EOF > config.conf
## Installation Configuration

### Formatting (will be ignored even if not set to "none", unless the corresponding partition is enabled)
root_part_filesystem="btrfs"  #### Filesystem for the / partition
separate_home_part_filesystem="none"  #### Filesystem for the /home partition
separate_boot_part_filesystem="btrfs"  #### Filesystem for the /boot partition
separate_var_part_filesystem="none"  #### Filesystem for the /var partition
separate_tmp_part_filesystem="none"  #### Filesystem for the /tmp partition

### Mounting
root_part="/dev/sdX#"  #### Path for the / partition
separate_home_part="none"  #### Path for the /home partition
separate_boot_part="/dev/sdX#"  #### Path for the /boot partition
separate_var_part="none"  #### Path for the /var partition
separate_tmp_part="none"  #### Path for the /tmp partition

### Encryption
luks_encryption="yes"  #### Encrypt the system (yes/no)
luks_passphrase=""  #### Passphrase for encryption
EOF

if [[ "$boot_mode" == "UEFI" ]]; then
    echo "" >> config.conf
    echo "### EFI partition settings" >> config.conf
    echo "efi_part=\"/dev/sdX#\"  #### EFI partition path" >> config.conf
    echo "efi_part_mountpoint=\"/boot/efi\"  #### EFI partition mountpoint" >> config.conf
else
    echo "" >> config.conf
    echo "### GRUB installation disk settings" >> config.conf
    echo "grub_disk=\"/dev/sdX\"  #### Disk for GRUB installation" >> config.conf
fi

cat <<EOF >> config.conf

### Connectivity
network_management="network-manager"  #### Network management tool (network-manager/systemd-networkd/none)

### Kernel Variant
kernel_variant="normal"  #### Kernel variant (normal/lts/zen)

### Mirror Servers Location
mirror_location="none"  #### Country for mirror servers (comma-separated list of countries or none)

### Timezone
timezone="Europe/Prague"  #### System time zone

### Hostname and User
EOF
echo "hostname=\"$(dmidecode -s system-product-name | sed 's/[[:space:]]*$//')\"  #### Machine name" >> config.conf
cat <<EOF >> config.conf
username="changeme"  #### User name
full_username="Changeme Please"  #### Full user name (optional - leave empty if you don't want it)
password=""  #### User password

### Locales
language="en_US.UTF-8"  #### System language
tty_keyboard_layout="us"  #### TTY keyboard layout

### Software Selection
install_pipewire="yes"  #### Install PipeWire (yes/no)
gpu="amd"  #### GPU driver (amd/intel/nvidia/other/none; hybrid: intel+nvidia/amd+nvidia/intel+amd/amd+amd)
de="plasma"  #### Desktop environment (gnome/plasma/xfce/mate/cinnamon/none)
install_cups="yes"  #### Install CUPS (yes/no)

### Swap
create_swap="yes"  #### Create swap (yes/no)

### Script Settings
keep_config="no"  #### Keep a copy of this file in /home/<your_username> after installation (yes/no)
EOF

chmod 600 config.conf
echo "config.conf was generated successfully. Edit it to customize the installation."
exit
fi

passwd_length=${#password}
username_length=${#username}
luks_passphrase_length=${#luks_passphrase}


echo "Checking the Internet connection..."
if ! ping -c 4 8.8.8.8 > /dev/null 2>&1; then
    if ! ping -c 4 1.1.1.1 > /dev/null 2>&1; then
        echo "Error: no Internet connection."
        exit
    fi
fi

if ! ping -c 4 google.com > /dev/null 2>&1; then
    if ! ping -c 4 one.one.one.one > /dev/null 2>&1; then
        echo "Error: DNS isn't working. Check your network configuration"
        exit
    fi
fi

if ! [[ "$network_management" == "network-manager" || "$network_management" == "systemd-networkd" || "$network_management" == "none" ]]; then
    echo "Error: invalid value for the network management tool: $network_management"
    exit
fi

if [[ "$network_management" == "systemd-networkd" ]]; then
    iface=$(ip route show default | awk 'NR==1 {print $5}')
    if [[ -z "$iface" ]]; then
        echo "Error: couldn't determine the interface used for the default route."
        exit
    fi

    if [[ -d "/sys/class/net/$iface/wireless" ]]; then
        echo "Error: ALBI currently doesn't support systemd-networkd for wireless connections."
        echo "In this case, please use Network Manager."
        exit
    elif [[ "$de" != "none" ]]; then
        echo "Error: if you wish to use a desktop environment, please use Network Manager."
        exit
    fi
fi

if ! [[ "$kernel_variant" == "normal" || "$kernel_variant" == "lts" || "$kernel_variant" == "zen" ]]; then
    echo "Error: invalid value for the kernel variant: $kernel_variant"
    exit
fi

if [[ "$passwd_length" == 0 ]]; then
    echo "Error: user password not set."
    exit
fi

if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "The username is incorrect. It can't begin with a number nor with an uppercase character."
    exit
fi

if ! [[ "$install_pipewire" == "yes" || "$install_pipewire" == "no" ]]; then
    echo "Error: invalid value for the PipeWire installation seting: $install_pipewire"
    exit
fi

if ! [[ "$install_cups" == "yes" || "$install_cups" == "no" ]]; then
    echo "Error: invalid value for the CUPS installation setting: $install_cups"
    exit
fi

if ! [[ "$gpu" == "amd" || "$gpu" == "intel" || "$gpu" == "nvidia" || "$gpu" == "other" || "$gpu" == "none" || "$gpu" == "intel+nvidia" || "$gpu" == "amd+nvidia" || "$gpu" == "intel+amd" || "$gpu" == "amd+amd" ]]; then
    echo "Error: invalid value for the GPU driver: $gpu"
    echo "Supported hybrid GPU values: intel+nvidia, amd+nvidia, intel+amd, amd+amd"
    exit
fi

if [[ "$gpu" == "none" ]]; then
    if ! [[ "$de" == "none" ]]; then
        echo "Error: desktop environment requires a GPU driver to be installed."
        exit
    fi
fi

if ! [[ "$de" == "cinnamon" || "$de" == "gnome" || "$de" == "mate" || "$de" == "plasma" || "$de" == "xfce" || "$de" == "none" ]]; then
    echo "Error: invalid value for the desktop environment: $de"
    exit
fi

if ! [[ "$luks_encryption" == "yes" || "$luks_encryption" == "no" ]]; then
    echo "Error: invalid value for disk encryption: $luks_encryption"
    exit
fi

if [[ "$luks_encryption" == "yes" ]]; then
    if [[ "$luks_passphrase_length" == 0 ]]; then
        echo "Error: the encryption passphrase not set."
        exit
    fi
fi

if ! [[ "$create_swap" == "yes" || "$create_swap" == "no" ]]; then
    echo "Error: invalid value for the swap creation question"
    exit
fi

if [[ "$boot_mode" == "UEFI" ]]; then
    if ! [[ "$efi_part_mountpoint" == "/boot/efi" || "$efi_part_mountpoint" == "/efi" ]]; then
        echo "Error: invalid EFI partition mount point detected: $efi_part_mountpoint"
        echo "For maximized system compatibility, ALBI only supports the following mount points: /boot/efi (recommended) and /efi."
        exit
    fi
fi

if ! grep -qE "^#?\s*${language}" /etc/locale.gen; then
    echo "Selected language doesn't exist (not found in /etc/locale.gen.): $language"
    exit
fi

if ! localectl list-keymaps | grep -Fxq "$tty_keyboard_layout"; then
    echo "Selected TTY keymap isn't available: $tty_keyboard_layout"
    exit
fi

declare -A used_partitions

check_partition() {
    local mount_name="$1"
    local partition="$2"

    [[ "$partition" == "none" ]] && return

    if ! [[ -b "$partition" ]]; then
        echo "Error: partition $partition selected for $mount_name is not a valid block device."
        exit
    fi

    local real_partition
    real_partition=$(readlink -f "$partition")

    if [[ -n "${used_partitions[$real_partition]:-}" ]]; then
        echo "Error: partition $partition is selected for both ${used_partitions[$real_partition]} and $mount_name."
        exit
    fi

    used_partitions["$real_partition"]="$mount_name"
}

check_partition "/" "$root_part"
check_partition "/home" "$separate_home_part"
check_partition "/boot" "$separate_boot_part"
check_partition "/var" "$separate_var_part"
check_partition "/tmp" "$separate_tmp_part"

if [[ "$boot_mode" == "UEFI" ]]; then
    check_partition "EFI" "$efi_part"
fi

mount_output=$(df -h)
mount_partition=$(echo "$mount_output" | awk '$6=="/mnt" {print $1}')
installation_started="true"

if [[ "$separate_boot_part" != "none" ]]; then
    if [[ -b "$separate_boot_part" ]]; then
        boot_part_exists="true"
    else
        echo "Error: partition $separate_boot_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ "$boot_mode" == "UEFI" ]]; then
    if [[ "$separate_boot_part" != "none" ]]; then
        if [[ "$separate_boot_part" == "$efi_part" ]]; then
            echo "Error: EFI partition must not be the same as the /boot part, because of the filesystem difference."
            exit
        fi
    fi
fi

if [[ "$root_part" != "none" ]]; then
    if [[ -n "$mount_partition" ]]; then
        echo "Error: /mnt is already mounted, however you specified another partition to mount it on."
        exit
    else
        if [[ -b "$root_part" ]]; then
            if [[ "$luks_encryption" == "yes" ]]; then
                if [[ "$boot_part_exists" == "true" ]]; then
                    echo "Setting up the encryption..."
                    root_part_orig="$root_part"
                    root_part_basename=$(basename "$root_part")
                    root_part_encrypted_name="${root_part_basename}_crypt"
                    printf '%s' "$luks_passphrase" | cryptsetup luksFormat --batch-mode "$root_part" -
                    printf '%s' "$luks_passphrase" | cryptsetup luksOpen "$root_part" "$root_part_encrypted_name" -
                    root_part="/dev/mapper/${root_part_encrypted_name}"
                    echo "root_part_orig=\"$root_part_orig\"" > tmpfile.sh
                    echo "root_part_encrypted_name=\"$root_part_encrypted_name\"" >> tmpfile.sh
                else
                    echo "Error: you haven't defined a separate /boot partition. It is needed in order to encrypt the / partition."
                    exit
                fi
            fi

            if [[ "$root_part_filesystem" == "ext4" ]]; then
                mkfs.ext4 -F "$root_part"
                mount "$root_part" /mnt
            elif [[ "$root_part_filesystem" == "ext3" ]]; then
                mkfs.ext3 -F "$root_part"
                mount "$root_part" /mnt
            elif [[ "$root_part_filesystem" == "ext2" ]]; then
                mkfs.ext2 -F "$root_part"
                mount "$root_part" /mnt
            elif [[ "$root_part_filesystem" == "btrfs" ]]; then
                mkfs.btrfs -f "$root_part"

                mount -t btrfs -o subvolid=5 "$root_part" /mnt
                btrfs subvolume create /mnt/root

                if [[ "$separate_home_part" == "none" ]]; then
                    btrfs subvolume create /mnt/home
                fi

                umount /mnt

                mount -t btrfs -o subvol=root,compress=zstd:1 "$root_part" /mnt

                if [[ "$separate_home_part" == "none" ]]; then
                    mkdir -p /mnt/home
                    mount -t btrfs -o subvol=home,compress=zstd:1 "$root_part" /mnt/home
                fi
            elif [[ "$root_part_filesystem" == "xfs" ]]; then
                mkfs.xfs -f "$root_part"
                mount "$root_part" /mnt
            else
                echo "Error: wrong filesystem for the / partition: $root_part_filesystem"
                exit
            fi
        else
            echo "Error: partition $root_part isn't a valid path - it doesn't exist or isn't accessible."
            exit
        fi
    fi
elif [[ "$root_part" == "none" ]]; then
    if ! [[ -n "$mount_partition" ]]; then
        echo "Error: no partition is mounted to / and you didn't define any in the config file."
        exit
    fi
fi

if [[ "$separate_home_part" != "none" ]]; then
    if [[ -b "$separate_home_part" ]]; then
        home_part_exists="true"
    else
        echo "Error: partition $separate_home_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ "$separate_var_part" != "none" ]]; then
    if [[ -b "$separate_var_part" ]]; then
        var_part_exists="true"
    else
        echo "Error: partition $separate_var_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ "$separate_tmp_part" != "none" ]]; then
    if [[ -b "$separate_tmp_part" ]]; then
        tmp_part_exists="true"
    else
        echo "Error: partition $separate_tmp_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ "$home_part_exists" == "true" ]]; then
    if [[ "$separate_home_part_filesystem" == "ext4" ]]; then
        mkfs.ext4 -F "$separate_home_part"
        mkdir -p /mnt/home
        mount "$separate_home_part" /mnt/home
    elif [[ "$separate_home_part_filesystem" == "ext3" ]]; then
        mkfs.ext3 -F "$separate_home_part"
        mkdir -p /mnt/home
        mount "$separate_home_part" /mnt/home
    elif [[ "$separate_home_part_filesystem" == "ext2" ]]; then
        mkfs.ext2 -F "$separate_home_part"
        mkdir -p /mnt/home
        mount "$separate_home_part" /mnt/home
    elif [[ "$separate_home_part_filesystem" == "btrfs" ]]; then
        mkfs.btrfs -f "$separate_home_part"
        mkdir -p /mnt/home
        mount -t btrfs -o compress=zstd:1 "$separate_home_part" /mnt/home
    elif [[ "$separate_home_part_filesystem" == "xfs" ]]; then
        mkfs.xfs -f "$separate_home_part"
        mkdir -p /mnt/home
        mount "$separate_home_part" /mnt/home
    else
        echo "Error: wrong filesystem for the /home partition: $separate_home_part_filesystem"
        exit
    fi
fi

if [[ "$boot_part_exists" == "true" ]]; then
    if [[ "$separate_boot_part_filesystem" == "ext4" ]]; then
        mkfs.ext4 -F "$separate_boot_part"
        mkdir -p /mnt/boot
        mount "$separate_boot_part" /mnt/boot
    elif [[ "$separate_boot_part_filesystem" == "ext3" ]]; then
        mkfs.ext3 -F "$separate_boot_part"
        mkdir -p /mnt/boot
        mount "$separate_boot_part" /mnt/boot
    elif [[ "$separate_boot_part_filesystem" == "ext2" ]]; then
        mkfs.ext2 -F "$separate_boot_part"
        mkdir -p /mnt/boot
        mount "$separate_boot_part" /mnt/boot
    elif [[ "$separate_boot_part_filesystem" == "btrfs" ]]; then
        mkfs.btrfs -f "$separate_boot_part"
        mkdir -p /mnt/boot
        mount -t btrfs "$separate_boot_part" /mnt/boot
    elif [[ "$separate_boot_part_filesystem" == "xfs" ]]; then
        mkfs.xfs -f "$separate_boot_part"
        mkdir -p /mnt/boot
        mount "$separate_boot_part" /mnt/boot
    else
        echo "Error: wrong filesystem for the /boot partition: $separate_boot_part_filesystem"
        exit
    fi
fi

if [[ "$var_part_exists" == "true" ]]; then
    if [[ "$separate_var_part_filesystem" == "ext4" ]]; then
        mkfs.ext4 -F "$separate_var_part"
        mkdir -p /mnt/var
        mount "$separate_var_part" /mnt/var
    elif [[ "$separate_var_part_filesystem" == "ext3" ]]; then
        mkfs.ext3 -F "$separate_var_part"
        mkdir -p /mnt/var
        mount "$separate_var_part" /mnt/var
    elif [[ "$separate_var_part_filesystem" == "ext2" ]]; then
        mkfs.ext2 -F "$separate_var_part"
        mkdir -p /mnt/var
        mount "$separate_var_part" /mnt/var
    elif [[ "$separate_var_part_filesystem" == "btrfs" ]]; then
        mkfs.btrfs -f "$separate_var_part"
        mkdir -p /mnt/var
        mount -t btrfs -o compress=zstd:1 "$separate_var_part" /mnt/var
    elif [[ "$separate_var_part_filesystem" == "xfs" ]]; then
        mkfs.xfs -f "$separate_var_part"
        mkdir -p /mnt/var
        mount "$separate_var_part" /mnt/var
    else
        echo "Error: wrong filesystem for the /var partition: $separate_var_part_filesystem"
        exit
    fi
fi

if [[ "$tmp_part_exists" == "true" ]]; then
    if [[ "$separate_tmp_part_filesystem" == "ext4" ]]; then
        mkfs.ext4 -F "$separate_tmp_part"
        mkdir -p /mnt/tmp
        mount "$separate_tmp_part" /mnt/tmp
    elif [[ "$separate_tmp_part_filesystem" == "ext3" ]]; then
        mkfs.ext3 -F "$separate_tmp_part"
        mkdir -p /mnt/tmp
        mount "$separate_tmp_part" /mnt/tmp
    elif [[ "$separate_tmp_part_filesystem" == "ext2" ]]; then
        mkfs.ext2 -F "$separate_tmp_part"
        mkdir -p /mnt/tmp
        mount "$separate_tmp_part" /mnt/tmp
    elif [[ "$separate_tmp_part_filesystem" == "btrfs" ]]; then
        mkfs.btrfs -f "$separate_tmp_part"
        mkdir -p /mnt/tmp
        mount -t btrfs -o compress=zstd:1 "$separate_tmp_part" /mnt/tmp
    elif [[ "$separate_tmp_part_filesystem" == "xfs" ]]; then
        mkfs.xfs -f "$separate_tmp_part"
        mkdir -p /mnt/tmp
        mount "$separate_tmp_part" /mnt/tmp
    else
        echo "Error: wrong filesystem for the /tmp partition: $separate_tmp_part_filesystem"
        exit
    fi
fi
if [[ "$boot_mode" == "UEFI" ]]; then
    if ! [[ -b "$efi_part" ]]; then
        echo "Error: EFI partition $efi_part is not a valid block device."
        exit
    fi

    efi_part_filesystem=$(blkid -s TYPE -o value "$efi_part" 2>/dev/null || true)
    if [[ "$efi_part_filesystem" != "vfat" ]]; then
        mkfs.fat -F 32 "$efi_part"
        mkdir -p /mnt"$efi_part_mountpoint"
        mount -t vfat "$efi_part" /mnt"$efi_part_mountpoint"
    else
        if ! findmnt --noheadings -o SOURCE /mnt"$efi_part_mountpoint" | grep -q "$efi_part"; then
            mkdir -p /mnt"$efi_part_mountpoint"
            mount -t vfat "$efi_part" /mnt"$efi_part_mountpoint"
        else
            umount /mnt"$efi_part_mountpoint"
            mkdir -p /mnt"$efi_part_mountpoint"
            mount -t vfat "$efi_part" /mnt"$efi_part_mountpoint"
        fi
    fi
elif [[ "$boot_mode" == "BIOS" ]]; then
    if ! [[ -b "$grub_disk" ]]; then
        echo "Error: disk path $grub_disk is not accessible or does not exist."
        exit
    fi
fi

if [[ "$mirror_location" != "none" ]]; then
    if ! reflector_output=$(reflector --country "$mirror_location" 2>&1); then
        echo "Error: invalid country name for Reflector."
        exit
    elif [[ "$reflector_output" == *"error"* || "$reflector_output" == *"no mirrors found"* ]]; then
        echo "Error: invalid country name for Reflector."
        exit
    else
        reflector --sort rate --country "$mirror_location" --save /etc/pacman.d/mirrorlist
    fi
fi

if [[ "$kernel_variant" == "normal" ]]; then
    pacstrap -K /mnt base linux linux-firmware
elif [[ "$kernel_variant" == "lts" ]]; then
    pacstrap -K /mnt base linux-lts linux-firmware
elif [[ "$kernel_variant" == "zen" ]]; then
    pacstrap -K /mnt base linux-zen linux-firmware
fi

genfstab -U /mnt >> /mnt/etc/fstab

touch main.sh
cat <<'EOFile' > main.sh
#!/bin/bash

set -Eeo pipefail

interrupt_handler() {
    echo "Interruption signal received. Aborting..."
    exit 130
}

trap interrupt_handler SIGINT SIGTERM

while IFS='=' read -r key value; do
    key=$(echo "$key" | sed 's/ *#.*$//' | xargs)
    value=$(echo "$value" | sed 's/ *#.*$//' | xargs)

    [[ -z "$key" ]] && continue

    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
            
    declare "$key=$value"
done < <(grep -v '^#' /config.conf | grep -v '^$')
if [[ "$luks_encryption" == "yes" ]]; then
    source /tmpfile.sh
fi

ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
systemctl enable systemd-timesyncd
hwclock --systohc

if [[ "$language" != "en_US.UTF-8" ]]; then
    sed -i "/en_US.UTF-8 UTF-8/s/^#//" /etc/locale.gen
fi
sed -i "/$language/s/^#//" /etc/locale.gen
echo "LANG=$language" > /etc/locale.conf
echo "KEYMAP=$tty_keyboard_layout" > /etc/vconsole.conf
echo "$hostname" > /etc/hostname
locale-gen

pacman -S btrfs-progs dosfstools dnsmasq inetutils xfsprogs base-devel polkit bash-completion nano grub ntfs-3g sshfs exfatprogs usbutils xdg-utils xdg-user-dirs unzip unrar zip 7zip os-prober plymouth --noconfirm

if [[ "$network_management" == "network-manager" ]]; then
    pacman -S networkmanager --noconfirm
    systemctl enable NetworkManager
elif [[ "$network_management" == "systemd-networkd" ]]; then
    default_route=$(ip route show default | head -n 1)
    if [[ -z "$default_route" ]]; then
        echo "Error: couldn't determine the current default route."
        exit
    fi

    gateway=$(echo "$default_route" | awk '{print $3}')
    iface=$(echo "$default_route" | awk '{print $5}')
    ip_info=$(ip -4 addr show dev "$iface" scope global | awk '/inet / {print $2; exit}')

    echo "[Match]" > /etc/systemd/network/20-wired.network
    echo "Name=$iface" >> /etc/systemd/network/20-wired.network
    echo "" >> /etc/systemd/network/20-wired.network
    echo "[Link]" >> /etc/systemd/network/20-wired.network
    echo "RequiredForOnline=routable" >> /etc/systemd/network/20-wired.network
    echo "" >> /etc/systemd/network/20-wired.network
    echo "[Network]" >> /etc/systemd/network/20-wired.network

    if [[ "$default_route" == *"proto dhcp"* ]]; then
        echo "DHCP=yes" >> /etc/systemd/network/20-wired.network
    else
        if [[ -z "$gateway" || -z "$ip_info" ]]; then
            echo "Error: couldn't determine the current static IPv4 configuration."
            exit
        fi
        echo "Address=$ip_info" >> /etc/systemd/network/20-wired.network
        echo "Gateway=$gateway" >> /etc/systemd/network/20-wired.network
        echo "DNS=1.1.1.1" >> /etc/systemd/network/20-wired.network
    fi

    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    systemctl enable systemd-networkd systemd-resolved
fi

pacman -S bluez --noconfirm
systemctl enable bluetooth

if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
    pacman -S efibootmgr --noconfirm
else
    boot_mode="BIOS"
fi

vendor=$(grep -m1 vendor_id /proc/cpuinfo | cut -d ':' -f2 | tr -d '[:space:]')
if [[ "$vendor" == "GenuineIntel" ]]; then
    pacman -S intel-ucode --noconfirm
elif [[ "$vendor" == "AuthenticAMD" ]]; then
    pacman -S amd-ucode --noconfirm
fi

echo "127.0.0.1       localhost" >> /etc/hosts
echo "127.0.1.1       $hostname" >> /etc/hosts
echo "" >> /etc/hosts
echo "# The following lines are desirable for IPv6 capable hosts" >> /etc/hosts
echo "::1             localhost ip6-localhost ip6-loopback" >> /etc/hosts
echo "ff02::1         ip6-allnodes" >> /etc/hosts
echo "ff02::2         ip6-allrouters" >> /etc/hosts

useradd -m "$username"
echo "$username:$password" | chpasswd
if [[ "$full_username" != "" ]]; then
    usermod -c "$full_username" "$username"
fi

usermod -aG wheel "$username"

cln=$(grep -n "Color" /etc/pacman.conf | cut -d ':' -f1)
dln=$(grep -n "## Defaults specification" /etc/sudoers | cut -d ':' -f1)
sed -i 's/^# include \/usr\/share\/nano\/\*\.nanorc/include \/usr\/share\/nano\/\*\.nanorc/' /etc/nanorc
sed -i '/Color/s/^#//g' /etc/pacman.conf
sed -i "${cln}s/$/\nILoveCandy/" /etc/pacman.conf
sed -i "${dln}s/$/\nDefaults    pwfeedback/" /etc/sudoers
sed -i "${dln}s/$/\n##/" /etc/sudoers

if [[ "$boot_mode" == "UEFI" ]]; then
    grub-install --target=x86_64-efi --efi-directory=$efi_part_mountpoint --bootloader-id="archlinux"
elif [[ "$boot_mode" == "BIOS" ]]; then
    grub-install --target=i386-pc "$grub_disk"
fi

if [[ "$luks_encryption" == "yes" ]]; then
    cryptdevice_grub=$(blkid -s UUID -o value "$root_part_orig")
    sed -i 's/HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    if grep -q "^GRUB_CMDLINE_LINUX=\"\"" /etc/default/grub; then
        sed -i "s|^\(GRUB_CMDLINE_LINUX=\"\)\(.*\)\"|\1rd.luks.uuid=$cryptdevice_grub\"|" /etc/default/grub
    else
        sed -i "s|^\(GRUB_CMDLINE_LINUX=\".*\)\"|\1 rd.luks.uuid=$cryptdevice_grub\"|" /etc/default/grub
    fi
else
    sed -i 's/HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth filesystems fsck)/' /etc/mkinitcpio.conf
fi

if [[ "$de" != "none" ]]; then
    sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)\(quiet\)\(.*\)"/\1\2 splash\3"/' /etc/default/grub
fi

sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/g' /etc/default/grub

if [[ "$install_pipewire" == "yes" ]]; then
    pacman -S pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber --noconfirm
fi

gpu_has() {
    local wanted="$1"
    [[ "+$gpu+" == *"+$wanted+"* ]]
}

if gpu_has "amd" || gpu_has "intel" || [[ "$gpu" == "other" ]]; then
    pacman -S mesa --noconfirm
fi

if gpu_has "amd"; then
    pacman -S vulkan-radeon --noconfirm
fi

if gpu_has "intel"; then
    pacman -S vulkan-intel intel-media-driver --noconfirm
fi

if gpu_has "nvidia"; then
    if [[ "$kernel_variant" == "normal" ]]; then
        pacman -S nvidia-open --noconfirm
    elif [[ "$kernel_variant" == "lts" ]]; then
        pacman -S nvidia-open-lts --noconfirm
    elif [[ "$kernel_variant" == "zen" ]]; then
        pacman -S nvidia-open-dkms linux-zen-headers --noconfirm
    fi

    pacman -S nvidia-settings --noconfirm

    if [[ "$gpu" == *"+"* ]]; then
        pacman -S nvidia-prime --noconfirm
    fi
fi

if [[ "$gpu" == *"+"* ]]; then
    pacman -S switcheroo-control --noconfirm
    systemctl enable switcheroo-control
fi

grub-mkconfig -o /boot/grub/grub.cfg

if [[ "$de" == "gnome" ]]; then
    pacman -S gnome noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gnome-tweaks gnome-shell-extensions gnome-browser-connector power-profiles-daemon --noconfirm
    systemctl enable gdm
elif [[ "$de" == "plasma" ]]; then
    pacman -Sgq plasma | grep -v "sddm-kcm" | pacman -S - plasma-login-manager libcec speech-dispatcher qrca noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ufw dolphin konsole power-profiles-daemon --noconfirm
    systemctl enable plasmalogin
elif [[ "$de" == "xfce" ]]; then
    pacman -S xfce4 xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs network-manager-applet power-profiles-daemon --noconfirm
    systemctl enable lightdm
elif [[ "$de" == "cinnamon" ]]; then
    pacman -S blueman cinnamon cinnamon-translations nemo-fileroller gnome-terminal lightdm lightdm-slick-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon --noconfirm
    systemctl enable lightdm
    sed -i 's/#greeter-session=example-gtk-gnome/greeter-session=lightdm-slick-greeter/g' /etc/lightdm/lightdm.conf
elif [[ "$de" == "mate" ]]; then
    pacman -S mate mate-extra blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon --noconfirm
    systemctl enable lightdm
fi

if [[ "$install_cups" == yes ]]; then
    pacman -S cups cups-filters cups-pk-helper cups-browsed bluez-cups ghostscript gutenprint hplip nss-mdns --noconfirm
    systemctl enable cups
    systemctl enable cups-browsed
    systemctl enable avahi-daemon
    sed -i "s/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/" /etc/nsswitch.conf
    mkdir -p /home/"$username"/.local/share/applications
    cp /usr/share/applications/hplip.desktop /home/"$username"/.local/share/applications/
    echo "NoDisplay=true" >> /home/"$username"/.local/share/applications/hplip.desktop
    cp /usr/share/applications/hp-uiscan.desktop /home/"$username"/.local/share/applications/
    echo "NoDisplay=true" >> /home/"$username"/.local/share/applications/hp-uiscan.desktop
    chown -R "$username:$username" /home/"$username"/.local/
fi

if [[ "$de" != "none" && "$install_cups" == yes ]]; then
    pacman -S system-config-printer --noconfirm
fi

sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^# //g' /etc/sudoers

if [[ "$create_swap" == "yes" ]]; then
    pacman -S zram-generator --noconfirm
    cat <<EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
fi

mkinitcpio -P

while pacman -Qdtq; do
    pacman -Runs $(pacman -Qdtq) --noconfirm
done
pacman -Sc --noconfirm
pacman -Scc --noconfirm
if [[ "$keep_config" == "no" ]]; then
    rm -f /config.conf
else
    sed -i -E 's/^(password|luks_passphrase)=.*/\1=""/' /config.conf
    chmod 600 /config.conf
    mv /config.conf /home/$username/
    chown "$username:$username" /home/$username/config.conf
fi
rm -f /main.sh
rm -f /tmpfile.sh
rm -f /tmpscript.sh
exit
EOFile

if [[ "$luks_encryption" == "yes" ]]; then
    cp tmpfile.sh /mnt/
fi

cp main.sh /mnt/
cp config.conf /mnt/
chmod 600 /mnt/config.conf

if ! arch-chroot /mnt bash main.sh; then
    echo "Error: installation inside chroot failed."
    installation_status=1
else
    installation_status=0
fi

echo "Unmounting partitions..."
umount -R /mnt 2>/dev/null || true

if [[ "$luks_encryption" == "yes" ]]; then
    cryptsetup close "$root_part_encrypted_name" 2>/dev/null || true
fi

installation_started="false"

if [[ "$installation_status" -ne 0 ]]; then
    exit "$installation_status"
fi