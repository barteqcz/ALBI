#!/bin/bash

set -o pipefail

interrupt_handler() {
    echo
    echo "Interruption signal received. Aborting..."
    exit 130
}

trap interrupt_handler SIGINT SIGTERM

cwd="$(pwd)"

if [[ -d /sys/firmware/efi ]]; then
    boot_mode="UEFI"
else
    boot_mode="BIOS"
fi

# ------------------------------------------------------------
# Configuration handling
# ------------------------------------------------------------

if [[ -e "$cwd/config.conf" ]]; then

    if ! bash -n "$cwd/config.conf" 2>/dev/null; then
        echo "Syntax errors found in config.conf."
        exit 1
    fi

    while IFS='=' read -r key value; do
        key="$(echo "$key" | sed 's/[[:space:]]*#.*$//' | xargs)"
        value="$(echo "$value" | sed 's/[[:space:]]*#.*$//' | xargs)"

        [[ -z "$key" ]] && continue

        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"

        declare "$key=$value"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$cwd/config.conf")

    clear

    echo "Are these information correct?"
    echo

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
        echo "Disk encryption is enabled."
        echo "LUKS passphrase: [hidden]"
    else
        echo "Disk encryption is disabled."
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

    if [[ -n "$full_username" ]]; then
        echo "Full username: $full_username"
    else
        echo "Full username was not set."
    fi

    echo "User password: [hidden]"
    echo "Language: $language"
    echo "TTY keyboard layout: $tty_keyboard_layout"

    if [[ "$install_pipewire" == "yes" ]]; then
        echo "PipeWire installation is enabled."
    else
        echo "PipeWire installation is disabled."
    fi

    echo "GPU driver: $gpu"
    echo "Desktop environment: $de"

    if [[ "$install_cups" == "yes" ]]; then
        echo "CUPS installation is enabled."
    else
        echo "CUPS installation is disabled."
    fi

    if [[ "$create_swapfile" == "yes" ]]; then
        echo "Swapfile creation is enabled, size: $swapfile_size_gb GB"
    else
        echo "Swapfile creation is disabled."
    fi

    if [[ "$keep_config" == "yes" ]]; then
        echo "Config file will be kept in the user directory."
    else
        echo "Config file will not be kept in the user directory."
    fi

    echo

    while true; do
        read -rp "Do you want to start the installation? [Y/n] " response

        case "$response" in
            ""|Y|y)
                clear
                break
                ;;
            N|n)
                echo "Aborting..."
                exit 0
                ;;
            *)
                echo "Error: incorrect option. Please try again."
                ;;
        esac
    done

else

    cat > "$cwd/config.conf" <<EOF
## Installation Configuration

### Formatting
root_part_filesystem="btrfs"
separate_home_part_filesystem="none"
separate_boot_part_filesystem="ext4"
separate_var_part_filesystem="none"
separate_tmp_part_filesystem="none"

### Mounting
root_part="/dev/sdX#"
separate_home_part="none"
separate_boot_part="/dev/sdX#"
separate_var_part="none"
separate_tmp_part="none"

### Encryption
luks_encryption="yes"
luks_passphrase="CHANGE_THIS_PASSWORD"
EOF

    if [[ "$boot_mode" == "UEFI" ]]; then
        cat >> "$cwd/config.conf" <<EOF

### EFI partition settings
efi_part="/dev/sdX#"
efi_part_mountpoint="/boot/efi"
EOF
    else
        cat >> "$cwd/config.conf" <<EOF

### GRUB installation disk settings
grub_disk="/dev/sdX"
EOF
    fi

    cat >> "$cwd/config.conf" <<EOF

### Connectivity
network_management="network-manager"

### Kernel Variant
kernel_variant="normal"

### Mirror Servers Location
mirror_location="none"

### Timezone
timezone="Europe/Prague"

### Hostname and User
EOF

    if command -v dmidecode >/dev/null 2>&1; then
        generated_hostname="$(dmidecode -s system-product-name 2>/dev/null | sed 's/[[:space:]]*$//')"
    else
        generated_hostname=""
    fi

    [[ -z "$generated_hostname" ]] && generated_hostname="archlinux"

    printf 'hostname="%s"\n' "$generated_hostname" >> "$cwd/config.conf"

    cat >> "$cwd/config.conf" <<EOF
username="changeme"
full_username="Changeme Please"
password="changeme"

### Locales
language="en_US.UTF-8"
tty_keyboard_layout="us"

### Software Selection
install_pipewire="yes"
gpu="amd"
de="gnome"
install_cups="yes"

### Swapfile
create_swapfile="yes"
swapfile_size_gb="4"

### Script Settings
keep_config="no"
EOF

    echo "config.conf was generated successfully."
    echo "Edit it to customize the installation."
    exit 0
fi

# ------------------------------------------------------------
# Basic variables
# ------------------------------------------------------------

passwd_length=${#password}
username_length=${#username}
luks_passphrase_length=${#luks_passphrase}

# ------------------------------------------------------------
# Internet
# ------------------------------------------------------------

echo "Checking the Internet connection..."

if ! ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 &&
   ! ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
    echo "Error: no Internet connection."
    exit 1
fi

if ! ping -c 2 -W 3 google.com >/dev/null 2>&1 &&
   ! ping -c 2 -W 3 one.one.one.one >/dev/null 2>&1; then
    echo "Error: DNS isn't working."
    exit 1
fi

# ------------------------------------------------------------
# Configuration validation
# ------------------------------------------------------------

if [[ "$network_management" != "network-manager" &&
      "$network_management" != "systemd-networkd" &&
      "$network_management" != "none" ]]; then
    echo "Error: invalid network management tool: $network_management"
    exit 1
fi

if [[ "$network_management" == "systemd-networkd" && "$de" != "none" ]]; then
    echo "Error: systemd-networkd cannot currently be used with a desktop environment."
    echo "Use Network Manager instead."
    exit 1
fi

if [[ "$kernel_variant" != "normal" &&
      "$kernel_variant" != "lts" &&
      "$kernel_variant" != "zen" ]]; then
    echo "Error: invalid kernel variant: $kernel_variant"
    exit 1
fi

if [[ "$passwd_length" -eq 0 ]]; then
    echo "Error: user password not set."
    exit 1
fi

if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Error: invalid username."
    echo "The username must start with a lowercase letter or underscore."
    exit 1
fi

if [[ "$install_pipewire" != "yes" && "$install_pipewire" != "no" ]]; then
    echo "Error: invalid PipeWire setting: $install_pipewire"
    exit 1
fi

if [[ "$install_cups" != "yes" && "$install_cups" != "no" ]]; then
    echo "Error: invalid CUPS setting: $install_cups"
    exit 1
fi

if [[ "$gpu" != "amd" &&
      "$gpu" != "intel" &&
      "$gpu" != "nvidia" &&
      "$gpu" != "other" &&
      "$gpu" != "none" ]]; then
    echo "Error: invalid GPU driver: $gpu"
    exit 1
fi

if [[ "$de" != "cinnamon" &&
      "$de" != "gnome" &&
      "$de" != "mate" &&
      "$de" != "plasma" &&
      "$de" != "xfce" &&
      "$de" != "none" ]]; then
    echo "Error: invalid desktop environment: $de"
    exit 1
fi

if [[ "$gpu" == "none" && "$de" != "none" ]]; then
    echo "Error: a desktop environment requires a GPU driver."
    exit 1
fi

if [[ "$luks_encryption" != "yes" && "$luks_encryption" != "no" ]]; then
    echo "Error: invalid LUKS encryption setting: $luks_encryption"
    exit 1
fi

if [[ "$luks_encryption" == "yes" && "$luks_passphrase_length" -eq 0 ]]; then
    echo "Error: LUKS passphrase not set."
    exit 1
fi

if [[ "$create_swapfile" != "yes" && "$create_swapfile" != "no" ]]; then
    echo "Error: invalid swapfile setting: $create_swapfile"
    exit 1
fi

if ! [[ "$swapfile_size_gb" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "Error: invalid swapfile size: $swapfile_size_gb"
    exit 1
fi

# ------------------------------------------------------------
# Filesystem validation
# ------------------------------------------------------------

valid_filesystem() {
    case "$1" in
        ext2|ext3|ext4|btrfs|xfs)
            return 0
            ;;
        none)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

if ! valid_filesystem "$root_part_filesystem"; then
    echo "Error: unsupported root filesystem: $root_part_filesystem"
    exit 1
fi

if ! valid_filesystem "$separate_home_part_filesystem"; then
    echo "Error: unsupported /home filesystem: $separate_home_part_filesystem"
    exit 1
fi

if ! valid_filesystem "$separate_boot_part_filesystem"; then
    echo "Error: unsupported /boot filesystem: $separate_boot_part_filesystem"
    exit 1
fi

if ! valid_filesystem "$separate_var_part_filesystem"; then
    echo "Error: unsupported /var filesystem: $separate_var_part_filesystem"
    exit 1
fi

if ! valid_filesystem "$separate_tmp_part_filesystem"; then
    echo "Error: unsupported /tmp filesystem: $separate_tmp_part_filesystem"
    exit 1
fi

# ------------------------------------------------------------
# Locale validation
# ------------------------------------------------------------

if ! grep -qE "^#?[[:space:]]*${language}[[:space:]]+UTF-8" /etc/locale.gen; then
    echo "Error: selected language does not exist in /etc/locale.gen: $language"
    exit 1
fi

if ! localectl list-keymaps | grep -Fxq "$tty_keyboard_layout"; then
    echo "Error: selected TTY keymap is unavailable: $tty_keyboard_layout"
    exit 1
fi

# ------------------------------------------------------------
# Partition validation
# ------------------------------------------------------------

mount_partition="$(findmnt -n -o SOURCE /mnt 2>/dev/null || true)"

if [[ "$root_part" != "none" ]]; then
    if [[ -n "$mount_partition" ]]; then
        echo "Error: /mnt is already mounted."
        exit 1
    fi

    if [[ ! -e "$root_part" ]]; then
        echo "Error: root partition does not exist: $root_part"
        exit 1
    fi
elif [[ -z "$mount_partition" ]]; then
    echo "Error: no root partition is mounted on /mnt."
    exit 1
fi

boot_part_exists=false
home_part_exists=false
var_part_exists=false
tmp_part_exists=false

if [[ "$separate_boot_part" != "none" ]]; then
    if [[ -e "$separate_boot_part" ]]; then
        boot_part_exists=true
    else
        echo "Error: /boot partition does not exist: $separate_boot_part"
        exit 1
    fi
fi

if [[ "$separate_home_part" != "none" ]]; then
    if [[ -e "$separate_home_part" ]]; then
        home_part_exists=true
    else
        echo "Error: /home partition does not exist: $separate_home_part"
        exit 1
    fi
fi

if [[ "$separate_var_part" != "none" ]]; then
    if [[ -e "$separate_var_part" ]]; then
        var_part_exists=true
    else
        echo "Error: /var partition does not exist: $separate_var_part"
        exit 1
    fi
fi

if [[ "$separate_tmp_part" != "none" ]]; then
    if [[ -e "$separate_tmp_part" ]]; then
        tmp_part_exists=true
    else
        echo "Error: /tmp partition does not exist: $separate_tmp_part"
        exit 1
    fi
fi

if [[ "$luks_encryption" == "yes" && "$boot_part_exists" != "true" ]]; then
    echo "Error: encrypted root requires a separate /boot partition."
    exit 1
fi

if [[ "$boot_mode" == "UEFI" ]]; then

    if [[ -z "$efi_part" || ! -e "$efi_part" ]]; then
        echo "Error: EFI partition does not exist: $efi_part"
        exit 1
    fi

    if [[ "$efi_part_mountpoint" != "/boot/efi" &&
          "$efi_part_mountpoint" != "/efi" ]]; then
        echo "Error: invalid EFI mount point: $efi_part_mountpoint"
        echo "Use /boot/efi or /efi."
        exit 1
    fi

    if [[ "$separate_boot_part" == "$efi_part" ]]; then
        echo "Error: EFI partition cannot also be the /boot partition."
        exit 1
    fi

else

    if [[ ! -b "$grub_disk" ]]; then
        echo "Error: GRUB disk does not exist: $grub_disk"
        exit 1
    fi

fi

# ------------------------------------------------------------
# Root filesystem
# ------------------------------------------------------------

if [[ "$root_part" != "none" ]]; then

    if [[ "$luks_encryption" == "yes" ]]; then

        echo "WARNING: $root_part will be completely erased."
        read -rp "Continue with LUKS formatting? [y/N] " confirm

        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Aborting."
            exit 0
        fi

        root_part_orig="$root_part"
        root_part_basename="$(basename "$root_part")"
        root_part_encrypted_name="${root_part_basename}_crypt"

        echo "Creating LUKS container..."

        if ! printf '%s' "$luks_passphrase" |
            cryptsetup luksFormat "$root_part" -; then
            echo "Error: LUKS formatting failed."
            exit 1
        fi

        if ! printf '%s' "$luks_passphrase" |
            cryptsetup luksOpen "$root_part" "$root_part_encrypted_name" -; then
            echo "Error: failed to open LUKS container."
            exit 1
        fi

        root_part="/dev/mapper/$root_part_encrypted_name"

        cat > "$cwd/tmpfile.sh" <<EOF
root_part_orig="$root_part_orig"
root_part_encrypted_name="$root_part_encrypted_name"
EOF

    fi

    case "$root_part_filesystem" in

        ext4)
            mkfs.ext4 -F "$root_part"
            mount "$root_part" /mnt
            ;;

        ext3)
            mkfs.ext3 -F "$root_part"
            mount "$root_part" /mnt
            ;;

        ext2)
            mkfs.ext2 -F "$root_part"
            mount "$root_part" /mnt
            ;;

        btrfs)
            mkfs.btrfs -f "$root_part"

            mount -t btrfs -o subvolid=5 "$root_part" /mnt

            btrfs subvolume create /mnt/root

            if [[ "$separate_home_part" == "none" ]]; then
                btrfs subvolume create /mnt/home
            fi

            umount /mnt

            mount -t btrfs \
                -o subvol=root,compress=zstd:1 \
                "$root_part" /mnt

            if [[ "$separate_home_part" == "none" ]]; then
                mkdir -p /mnt/home
                mount -t btrfs \
                    -o subvol=home,compress=zstd:1 \
                    "$root_part" /mnt/home
            fi
            ;;

        xfs)
            mkfs.xfs -f "$root_part"
            mount "$root_part" /mnt
            ;;

        *)
            echo "Error: unsupported root filesystem."
            exit 1
            ;;
    esac
fi

# ------------------------------------------------------------
# Additional partitions
# ------------------------------------------------------------

format_and_mount() {
    local partition="$1"
    local filesystem="$2"
    local mountpoint="$3"

    mkdir -p "$mountpoint"

    case "$filesystem" in

        ext4)
            mkfs.ext4 -F "$partition"
            mount "$partition" "$mountpoint"
            ;;

        ext3)
            mkfs.ext3 -F "$partition"
            mount "$partition" "$mountpoint"
            ;;

        ext2)
            mkfs.ext2 -F "$partition"
            mount "$partition" "$mountpoint"
            ;;

        btrfs)
            mkfs.btrfs -f "$partition"
            mount -t btrfs -o compress=zstd:1 "$partition" "$mountpoint"
            ;;

        xfs)
            mkfs.xfs -f "$partition"
            mount "$partition" "$mountpoint"
            ;;

        *)
            echo "Error: unsupported filesystem '$filesystem' for $mountpoint."
            exit 1
            ;;
    esac
}

if [[ "$home_part_exists" == "true" ]]; then
    format_and_mount \
        "$separate_home_part" \
        "$separate_home_part_filesystem" \
        /mnt/home
fi

if [[ "$boot_part_exists" == "true" ]]; then
    format_and_mount \
        "$separate_boot_part" \
        "$separate_boot_part_filesystem" \
        /mnt/boot
fi

if [[ "$var_part_exists" == "true" ]]; then
    format_and_mount \
        "$separate_var_part" \
        "$separate_var_part_filesystem" \
        /mnt/var
fi

if [[ "$tmp_part_exists" == "true" ]]; then
    format_and_mount \
        "$separate_tmp_part" \
        "$separate_tmp_part_filesystem" \
        /mnt/tmp
fi

# ------------------------------------------------------------
# EFI
# ------------------------------------------------------------

if [[ "$boot_mode" == "UEFI" ]]; then

    efi_part_filesystem="$(blkid -s TYPE -o value "$efi_part" 2>/dev/null || true)"

    if [[ "$efi_part_filesystem" != "vfat" ]]; then
        echo "EFI partition is not FAT32 and will be formatted."
        mkfs.fat -F 32 "$efi_part"
    fi

    mkdir -p "/mnt$efi_part_mountpoint"
    mount -t vfat "$efi_part" "/mnt$efi_part_mountpoint"

fi

# ------------------------------------------------------------
# Mirrors
# ------------------------------------------------------------

if [[ "$mirror_location" != "none" ]]; then

    echo "Updating mirror list..."

    if ! reflector \
        --country "$mirror_location" \
        --sort rate \
        --save /etc/pacman.d/mirrorlist; then

        echo "Error: reflector could not find valid mirrors for:"
        echo "$mirror_location"
        exit 1
    fi

fi

# ------------------------------------------------------------
# Base system
# ------------------------------------------------------------

echo "Installing base system..."

case "$kernel_variant" in
    normal)
        pacstrap -K /mnt base linux linux-firmware linux-headers
        ;;
    lts)
        pacstrap -K /mnt base linux-lts linux-firmware linux-lts-headers
        ;;
    zen)
        pacstrap -K /mnt base linux-zen linux-firmware linux-zen-headers
        ;;
esac

# ------------------------------------------------------------
# fstab
# ------------------------------------------------------------

genfstab -U /mnt >> /mnt/etc/fstab

# ------------------------------------------------------------
# Generate chroot script
# ------------------------------------------------------------

cat > "$cwd/main.sh" <<'EOFILE'
#!/bin/bash

set -o pipefail

interrupt_handler() {
    echo
    echo "Interruption signal received."
    echo "Attempting to unmount filesystems..."

    sync

    umount -R /boot/efi 2>/dev/null || true
    umount -R /efi 2>/dev/null || true
    umount -R /home 2>/dev/null || true
    umount -R /var 2>/dev/null || true
    umount -R /tmp 2>/dev/null || true
    umount -R /boot 2>/dev/null || true
    umount / 2>/dev/null || true

    exit 130
}

trap interrupt_handler SIGINT SIGTERM

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------

while IFS='=' read -r key value; do

    key="$(echo "$key" | sed 's/[[:space:]]*#.*$//' | xargs)"
    value="$(echo "$value" | sed 's/[[:space:]]*#.*$//' | xargs)"

    [[ -z "$key" ]] && continue

    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    declare "$key=$value"

done < <(grep -vE '^[[:space:]]*(#|$)' /config.conf)

if [[ "$luks_encryption" == "yes" ]]; then
    source /tmpfile.sh
fi

# ------------------------------------------------------------
# Time
# ------------------------------------------------------------

ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
systemctl enable systemd-timesyncd
hwclock --systohc

# ------------------------------------------------------------
# Locale
# ------------------------------------------------------------

sed -i "s/^#\(${language}[[:space:]]*UTF-8\)/\1/" /etc/locale.gen

if [[ "$language" != "en_US.UTF-8" ]]; then
    sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
fi

echo "LANG=$language" > /etc/locale.conf
echo "KEYMAP=$tty_keyboard_layout" > /etc/vconsole.conf

locale-gen

# ------------------------------------------------------------
# Hostname
# ------------------------------------------------------------

echo "$hostname" > /etc/hostname

cat > /etc/hosts <<EOF
127.0.0.1       localhost
127.0.1.1       $hostname

::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# ------------------------------------------------------------
# Packages
# ------------------------------------------------------------

pacman -Syu --noconfirm

pacman -S --noconfirm \
    btrfs-progs \
    dosfstools \
    dnsmasq \
    inetutils \
    xfsprogs \
    base-devel \
    polkit \
    bash-completion \
    nano \
    grub \
    ntfs-3g \
    sshfs \
    exfatprogs \
    usbutils \
    xdg-utils \
    xdg-user-dirs \
    unzip \
    unrar \
    zip \
    7zip \
    os-prober \
    plymouth \
    bluez

systemctl enable bluetooth

# ------------------------------------------------------------
# Network
# ------------------------------------------------------------

if [[ "$network_management" == "network-manager" ]]; then

    pacman -S --noconfirm networkmanager
    systemctl enable NetworkManager

elif [[ "$network_management" == "systemd-networkd" ]]; then

    systemctl enable systemd-networkd
    systemctl enable systemd-resolved

    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

fi

# ------------------------------------------------------------
# Microcode
# ------------------------------------------------------------

vendor="$(grep -m1 vendor_id /proc/cpuinfo | cut -d ':' -f2 | tr -d '[:space:]')"

case "$vendor" in
    GenuineIntel)
        pacman -S --noconfirm intel-ucode
        ;;
    AuthenticAMD)
        pacman -S --noconfirm amd-ucode
        ;;
esac

# ------------------------------------------------------------
# User
# ------------------------------------------------------------

useradd -m -s /bin/bash "$username"

printf '%s\n%s\n' "$password" "$password" | passwd "$username"

if [[ -n "$full_username" ]]; then
    usermod -c "$full_username" "$username"
fi

usermod -aG wheel "$username"

# ------------------------------------------------------------
# Pacman / sudo / nano
# ------------------------------------------------------------

sed -i 's/^#Color/Color/' /etc/pacman.conf

if ! grep -q '^ILoveCandy' /etc/pacman.conf; then
    sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf
fi

sed -i \
    's/^# include \/usr\/share\/nano\/\*\.nanorc/include \/usr\/share\/nano\/\*\.nanorc/' \
    /etc/nanorc

sed -i \
    's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
    /etc/sudoers

# ------------------------------------------------------------
# Bootloader
# ------------------------------------------------------------

if [[ "$boot_mode" == "UEFI" ]]; then

    pacman -S --noconfirm efibootmgr

    grub-install \
        --target=x86_64-efi \
        --efi-directory="$efi_part_mountpoint" \
        --bootloader-id=archlinux

else

    grub-install \
        --target=i386-pc \
        "$grub_disk"

fi

# ------------------------------------------------------------
# Initramfs / encryption
# ------------------------------------------------------------

if [[ "$luks_encryption" == "yes" ]]; then

    cryptdevice_grub="$(blkid -s UUID -o value "$root_part_orig")"

    sed -i \
        's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)/' \
        /etc/mkinitcpio.conf

    sed -i \
        "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"rd.luks.uuid=$cryptdevice_grub\"|" \
        /etc/default/grub

else

    sed -i \
        's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth filesystems fsck)/' \
        /etc/mkinitcpio.conf

fi

# ------------------------------------------------------------
# Desktop boot splash
# ------------------------------------------------------------

if [[ "$de" != "none" ]]; then

    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
        sed -i \
            's/^GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 splash"/' \
            /etc/default/grub
    fi

fi

sed -i \
    's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' \
    /etc/default/grub

# ------------------------------------------------------------
# PipeWire
# ------------------------------------------------------------

if [[ "$install_pipewire" == "yes" ]]; then
    pacman -S --noconfirm \
        pipewire \
        pipewire-pulse \
        pipewire-alsa \
        pipewire-jack \
        wireplumber
fi

# ------------------------------------------------------------
# GPU
# ------------------------------------------------------------

case "$gpu" in

    amd)
        pacman -S --noconfirm mesa vulkan-radeon

        if grep -q '^MODULES=()' /etc/mkinitcpio.conf; then
            sed -i 's/^MODULES=()/MODULES=(amdgpu)/' /etc/mkinitcpio.conf
        fi
        ;;

    intel)
        pacman -S --noconfirm \
            mesa \
            vulkan-intel \
            intel-media-driver
        ;;

    nvidia)
        pacman -S --noconfirm \
            nvidia \
            nvidia-settings

        if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
            sed -i \
                's/^GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 nvidia_drm.modeset=1 nvidia_drm.fbdev=1"/' \
                /etc/default/grub
        fi
        ;;

    other)
        pacman -S --noconfirm mesa
        ;;

    none)
        ;;
esac

# ------------------------------------------------------------
# Desktop environment
# ------------------------------------------------------------

case "$de" in

    gnome)
        pacman -S --noconfirm \
            gnome \
            noto-fonts \
            noto-fonts-cjk \
            noto-fonts-emoji \
            noto-fonts-extra \
            gnome-tweaks \
            gnome-shell-extensions \
            gnome-browser-connector \
            power-profiles-daemon \
            ptyxis

        systemctl enable gdm
        ;;

    plasma)
        pacman -S --noconfirm \
            plasma \
            plasma-login-manager \
            noto-fonts \
            noto-fonts-cjk \
            noto-fonts-emoji \
            noto-fonts-extra \
            ufw \
            dolphin \
            konsole \
            power-profiles-daemon

        systemctl enable plasmalogin
        ;;

    xfce)
        pacman -S --noconfirm \
            xfce4 \
            xfce4-goodies \
            xarchiver \
            xfce4-terminal \
            xfce4-dev-tools \
            blueman \
            lightdm \
            lightdm-gtk-greeter \
            lightdm-gtk-greeter-settings \
            noto-fonts \
            noto-fonts-cjk \
            noto-fonts-emoji \
            noto-fonts-extra \
            gvfs \
            network-manager-applet \
            power-profiles-daemon

        systemctl enable lightdm
        ;;

    cinnamon)
        pacman -S --noconfirm \
            blueman \
            cinnamon \
            cinnamon-translations \
            nemo-fileroller \
            gnome-terminal \
            lightdm \
            lightdm-slick-greeter \
            noto-fonts \
            noto-fonts-cjk \
            noto-fonts-emoji \
            noto-fonts-extra \
            gvfs \
            power-profiles-daemon

        systemctl enable lightdm

        sed -i \
            's/^#greeter-session=.*/greeter-session=lightdm-slick-greeter/' \
            /etc/lightdm/lightdm.conf
        ;;

    mate)
        pacman -S --noconfirm \
            mate \
            mate-extra \
            blueman \
            lightdm \
            lightdm-gtk-greeter \
            lightdm-gtk-greeter-settings \
            noto-fonts \
            noto-fonts-cjk \
            noto-fonts-emoji \
            noto-fonts-extra \
            gvfs \
            power-profiles-daemon

        systemctl enable lightdm
        ;;

    none)
        ;;
esac

# ------------------------------------------------------------
# CUPS
# ------------------------------------------------------------

if [[ "$install_cups" == "yes" ]]; then

    pacman -S --noconfirm \
        cups \
        cups-filters \
        cups-pk-helper \
        cups-browsed \
        bluez-cups \
        ghostscript \
        gutenprint \
        hplip \
        nss-mdns

    systemctl enable cups
    systemctl enable cups-browsed
    systemctl enable avahi-daemon

    sed -i \
        's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
        /etc/nsswitch.conf

    if [[ "$de" != "none" ]]; then
        pacman -S --noconfirm system-config-printer
    fi

fi

# ------------------------------------------------------------
# Swap
# ------------------------------------------------------------

if [[ "$create_swapfile" == "yes" ]]; then

    if [[ "$root_part_filesystem" == "btrfs" ]]; then
        truncate -s 0 /swapfile
        chattr +C /swapfile
    fi

    fallocate -l "${swapfile_size_gb}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile

    if ! grep -q '^/swapfile[[:space:]]' /etc/fstab; then
        echo "/swapfile none swap defaults 0 0" >> /etc/fstab
    fi

fi

# ------------------------------------------------------------
# Initramfs
# ------------------------------------------------------------

mkinitcpio -P

# ------------------------------------------------------------
# GRUB
# ------------------------------------------------------------

grub-mkconfig -o /boot/grub/grub.cfg

# ------------------------------------------------------------
# Remove or preserve configuration
# ------------------------------------------------------------

if [[ "$keep_config" == "yes" ]]; then

    mkdir -p "/home/$username"
    mv /config.conf "/home/$username/config.conf"
    chown "$username:$username" "/home/$username/config.conf"

else

    rm -f /config.conf

fi

rm -f /main.sh
rm -f /tmpfile.sh

echo
echo "========================================"
echo "Installation inside the target system"
echo "completed successfully."
echo "========================================"

exit 0
EOFILE

chmod +x "$cwd/main.sh"

# ------------------------------------------------------------
# Copy files into target
# ------------------------------------------------------------

if [[ "$luks_encryption" == "yes" ]]; then
    cp "$cwd/tmpfile.sh" /mnt/tmpfile.sh
fi

cp "$cwd/main.sh" /mnt/main.sh
cp "$cwd/config.conf" /mnt/config.conf

# ------------------------------------------------------------
# Run installation
# ------------------------------------------------------------

echo
echo "Starting Arch Linux installation..."
echo

if ! arch-chroot /mnt /bin/bash /main.sh; then
    echo
    echo "========================================"
    echo "Installation failed."
    echo "========================================"
    exit 1
fi

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

rm -f "$cwd/main.sh"
rm -f "$cwd/tmpfile.sh"

sync

echo
echo "========================================"
echo "Arch Linux installation completed."
echo "========================================"
echo
echo "You can now unmount /mnt and reboot."
