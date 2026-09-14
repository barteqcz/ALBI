#!/bin/bash

# ALBI Arch Linux installer - hardened revision
# This script is destructive: it can format partitions and create LUKS containers.

set -Eeuo pipefail

interrupt_handler() {
    echo
    echo "Interruption signal received. Aborting..."
    exit 130
}

error_handler() {
    local line="$1"
    local command="$2"
    echo "Error: command failed on line ${line}: ${command}" >&2
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    if mountpoint -q /mnt 2>/dev/null; then
        umount -R /mnt 2>/dev/null || true
    fi

    if [[ -n "${root_part_encrypted_name:-}" ]] && cryptsetup status "$root_part_encrypted_name" &>/dev/null; then
        cryptsetup close "$root_part_encrypted_name" 2>/dev/null || true
    fi

    return "$status"
}

trap 'error_handler "$LINENO" "$BASH_COMMAND"' ERR
trap interrupt_handler SIGINT SIGTERM
trap cleanup EXIT

# These are initialized so the state file can be created in either BIOS or UEFI mode.
root_part_orig=""
root_part_encrypted_name=""
grub_disk=""
efi_part=""
efi_part_mountpoint=""

cwd=$(pwd)

if [[ -d /sys/firmware/efi ]]; then
    boot_mode="UEFI"
else
    boot_mode="BIOS"
fi

# -----------------------------------------------------------------------------
# First run: create a safe template configuration and stop.
# -----------------------------------------------------------------------------
if [[ ! -e "$cwd/config.conf" ]]; then
    cat > "$cwd/config.conf" <<EOF
## Installation Configuration

### Formatting (ignored when the corresponding partition is "none")
root_part_filesystem="btrfs"
separate_home_part_filesystem="none"
separate_boot_part_filesystem="btrfs"
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
luks_passphrase=""
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

    cat >> "$cwd/config.conf" <<'EOF'

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
    printf 'hostname="%s"\n' "$(dmidecode -s system-product-name 2>/dev/null | sed 's/[[:space:]]*$//' || true)" >> "$cwd/config.conf"
    cat >> "$cwd/config.conf" <<'EOF'
username="changeme"
full_username="Changeme Please"
password=""

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
    echo "Edit it to customize the installation, then run this script again."
    exit 0
fi

# -----------------------------------------------------------------------------
# Read the config as shell because bash -n has already validated its syntax.
# This preserves quoted values and values containing '='.
# -----------------------------------------------------------------------------
if ! bash -n "$cwd/config.conf"; then
    echo "Error: syntax errors found in $cwd/config.conf."
    exit 1
fi

# shellcheck disable=SC1090
source "$cwd/config.conf"

: "${root_part_filesystem:=}"
: "${separate_home_part_filesystem:=none}"
: "${separate_boot_part_filesystem:=none}"
: "${separate_var_part_filesystem:=none}"
: "${separate_tmp_part_filesystem:=none}"
: "${root_part:=}"
: "${separate_home_part:=none}"
: "${separate_boot_part:=none}"
: "${separate_var_part:=none}"
: "${separate_tmp_part:=none}"
: "${luks_encryption:=no}"
: "${luks_passphrase:=}"
: "${network_management:=network-manager}"
: "${kernel_variant:=normal}"
: "${mirror_location:=none}"
: "${timezone:=}"
: "${hostname:=}"
: "${username:=}"
: "${full_username:=}"
: "${password:=}"
: "${language:=}"
: "${tty_keyboard_layout:=}"
: "${install_pipewire:=no}"
: "${gpu:=none}"
: "${de:=none}"
: "${install_cups:=no}"
: "${create_swapfile:=no}"
: "${swapfile_size_gb:=}"
: "${keep_config:=no}"

filesystem_is_valid() {
    case "$1" in
        ext2|ext3|ext4|btrfs|xfs) return 0 ;;
        *) return 1 ;;
    esac
}

partition_is_configured() {
    [[ -n "$1" && "$1" != "none" ]]
}

assert_block_device() {
    local name="$1" value="$2"
    if ! [[ -b "$value" ]]; then
        echo "Error: $name is not an accessible block device: $value"
        exit 1
    fi
}

assert_not_mounted() {
    local device="$1"
    if findmnt -rn -S "$device" >/dev/null 2>&1; then
        echo "Error: device is already mounted: $device"
        findmnt -rn -S "$device" || true
        exit 1
    fi
}

if ! [[ "$luks_encryption" == yes || "$luks_encryption" == no ]]; then
    echo "Error: luks_encryption must be yes or no."
    exit 1
fi

if ! [[ "$network_management" == network-manager || "$network_management" == systemd-networkd || "$network_management" == none ]]; then
    echo "Error: invalid network_management: $network_management"
    exit 1
fi

if ! [[ "$kernel_variant" == normal || "$kernel_variant" == lts || "$kernel_variant" == zen ]]; then
    echo "Error: invalid kernel_variant: $kernel_variant"
    exit 1
fi

if ! [[ "$install_pipewire" == yes || "$install_pipewire" == no ]]; then
    echo "Error: invalid install_pipewire: $install_pipewire"
    exit 1
fi

if ! [[ "$install_cups" == yes || "$install_cups" == no ]]; then
    echo "Error: invalid install_cups: $install_cups"
    exit 1
fi

if ! [[ "$create_swapfile" == yes || "$create_swapfile" == no ]]; then
    echo "Error: invalid create_swapfile: $create_swapfile"
    exit 1
fi

if ! [[ "$keep_config" == yes || "$keep_config" == no ]]; then
    echo "Error: invalid keep_config: $keep_config"
    exit 1
fi

if ! [[ "$gpu" == amd || "$gpu" == intel || "$gpu" == nvidia || "$gpu" == other || "$gpu" == none ]]; then
    echo "Error: invalid GPU setting: $gpu"
    exit 1
fi

if ! [[ "$de" == gnome || "$de" == plasma || "$de" == xfce || "$de" == mate || "$de" == cinnamon || "$de" == none ]]; then
    echo "Error: invalid desktop environment: $de"
    exit 1
fi

if [[ "$gpu" == none && "$de" != none ]]; then
    echo "Error: a desktop environment requires a GPU driver setting."
    exit 1
fi

if [[ -z "$password" ]]; then
    echo "Error: user password is not set."
    exit 1
fi

if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Error: invalid username: $username"
    exit 1
fi

if [[ -z "$hostname" || ! "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$ ]]; then
    echo "Error: invalid or empty hostname: $hostname"
    exit 1
fi

if [[ -z "$timezone" || ! -f "/usr/share/zoneinfo/$timezone" ]]; then
    echo "Error: timezone does not exist: $timezone"
    exit 1
fi

if [[ -z "$language" ]]; then
    echo "Error: language is empty."
    exit 1
fi

if ! sed 's/^[[:space:]]*#//' /etc/locale.gen | awk -v loc="$language" '$1 == loc {found=1} END {exit !found}'; then
    echo "Error: selected locale is not available in /etc/locale.gen: $language"
    exit 1
fi

if ! localectl list-keymaps | grep -Fxq "$tty_keyboard_layout"; then
    echo "Error: selected TTY keymap is not available: $tty_keyboard_layout"
    exit 1
fi

if [[ "$create_swapfile" == yes ]]; then
    if ! [[ "$swapfile_size_gb" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "Error: invalid swapfile size: $swapfile_size_gb"
        exit 1
    fi
    if ! awk -v size="$swapfile_size_gb" 'BEGIN { exit !(size > 0) }'; then
        echo "Error: swapfile size must be greater than zero."
        exit 1
    fi
fi

for fs_name in root_part_filesystem separate_home_part_filesystem separate_boot_part_filesystem separate_var_part_filesystem separate_tmp_part_filesystem; do
    fs_value="${!fs_name}"
    if [[ "$fs_value" != none && "$fs_value" != "" ]] && ! filesystem_is_valid "$fs_value"; then
        echo "Error: invalid filesystem in $fs_name: $fs_value"
        exit 1
    fi
done

if [[ "$root_part" == none || -z "$root_part" ]]; then
    if [[ "$luks_encryption" == yes ]]; then
        echo "Error: LUKS encryption requires root_part to be specified."
        exit 1
    fi
    if ! mountpoint -q /mnt; then
        echo "Error: root_part=none but /mnt is not already mounted."
        exit 1
    fi
else
    assert_block_device "root_part" "$root_part"
    assert_not_mounted "$root_part"
fi

for pair in \
    "separate_home_part:$separate_home_part" \
    "separate_boot_part:$separate_boot_part" \
    "separate_var_part:$separate_var_part" \
    "separate_tmp_part:$separate_tmp_part"; do
    name="${pair%%:*}"
    value="${pair#*:}"
    if partition_is_configured "$value"; then
        assert_block_device "$name" "$value"
        assert_not_mounted "$value"
    fi
done

if [[ "$luks_encryption" == yes && "$separate_boot_part" == none ]]; then
    echo "Error: an unencrypted separate /boot partition is required when LUKS encrypts /."
    exit 1
fi

if [[ "$separate_home_part" != none && "$separate_home_part_filesystem" == none ]]; then
    echo "Error: /home partition is configured but its filesystem is none."
    exit 1
fi
if [[ "$separate_boot_part" != none && "$separate_boot_part_filesystem" == none ]]; then
    echo "Error: /boot partition is configured but its filesystem is none."
    exit 1
fi
if [[ "$separate_var_part" != none && "$separate_var_part_filesystem" == none ]]; then
    echo "Error: /var partition is configured but its filesystem is none."
    exit 1
fi
if [[ "$separate_tmp_part" != none && "$separate_tmp_part_filesystem" == none ]]; then
    echo "Error: /tmp partition is configured but its filesystem is none."
    exit 1
fi

declare -A seen_devices=()
for device in "$root_part" "$separate_home_part" "$separate_boot_part" "$separate_var_part" "$separate_tmp_part"; do
    [[ "$device" == none || -z "$device" ]] && continue
    if [[ -n "${seen_devices[$device]:-}" ]]; then
        echo "Error: the same partition is assigned to multiple mount points: $device"
        exit 1
    fi
    seen_devices[$device]=1
done

if [[ "$boot_mode" == UEFI ]]; then
    : "${efi_part:=}"
    : "${efi_part_mountpoint:=/boot/efi}"

    if ! [[ "$efi_part_mountpoint" == /boot/efi || "$efi_part_mountpoint" == /efi ]]; then
        echo "Error: invalid EFI mount point: $efi_part_mountpoint"
        exit 1
    fi
    assert_block_device "efi_part" "$efi_part"
    assert_not_mounted "$efi_part"

    if [[ "$separate_boot_part" != none && "$separate_boot_part" == "$efi_part" ]]; then
        echo "Error: EFI and /boot must use different partitions."
        exit 1
    fi

    for device in "$root_part" "$separate_home_part" "$separate_boot_part" "$separate_var_part" "$separate_tmp_part"; do
        [[ "$device" == none || -z "$device" ]] && continue
        if [[ "$device" == "$efi_part" ]]; then
            echo "Error: EFI partition is also assigned to another mount point: $efi_part"
            exit 1
        fi
    done
else
    : "${grub_disk:=}"
    assert_block_device "grub_disk" "$grub_disk"
fi

if [[ "$network_management" == systemd-networkd ]]; then
    default_route=$(ip route | awk '$1 == "default" {print; exit}')
    iface=$(awk '{print $5}' <<< "$default_route")
    if [[ -z "$iface" ]]; then
        echo "Error: could not determine the active network interface for systemd-networkd."
        exit 1
    fi
    if [[ -d "/sys/class/net/$iface/wireless" ]]; then
        echo "Error: this installer does not support systemd-networkd for wireless connections."
        echo "Use network_management=network-manager instead."
        exit 1
    fi
    if [[ "$de" != none ]]; then
        echo "Error: systemd-networkd mode requires de=none in this installer."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Confirmation. Secrets are deliberately not printed.
# -----------------------------------------------------------------------------
clear
printf '%s\n\n' "Are these installation settings correct?"
printf '/: %s on %s\n' "$root_part_filesystem" "$root_part"
[[ "$separate_home_part" != none ]] && printf '/home: %s on %s\n' "$separate_home_part_filesystem" "$separate_home_part"
[[ "$separate_boot_part" != none ]] && printf '/boot: %s on %s\n' "$separate_boot_part_filesystem" "$separate_boot_part"
[[ "$separate_var_part" != none ]] && printf '/var: %s on %s\n' "$separate_var_part_filesystem" "$separate_var_part"
[[ "$separate_tmp_part" != none ]] && printf '/tmp: %s on %s\n' "$separate_tmp_part_filesystem" "$separate_tmp_part"
[[ "$luks_encryption" == yes ]] && echo "Disk encryption: enabled" || echo "Disk encryption: disabled"
if [[ "$boot_mode" == UEFI ]]; then
    printf 'EFI partition: %s at %s\n' "$efi_part" "$efi_part_mountpoint"
else
    printf 'GRUB disk: %s\n' "$grub_disk"
fi
printf 'Kernel variant: %s\n' "$kernel_variant"
printf 'Mirror country: %s\n' "$mirror_location"
printf 'Time zone: %s\n' "$timezone"
printf 'Hostname: %s\n' "$hostname"
printf 'Username: %s\n' "$username"
[[ -n "$full_username" ]] && printf 'Full username: %s\n' "$full_username" || echo "Full username: not set"
echo "User password: configured"
printf 'Language: %s\n' "$language"
printf 'TTY keyboard layout: %s\n' "$tty_keyboard_layout"
[[ "$install_pipewire" == yes ]] && echo "PipeWire: enabled" || echo "PipeWire: disabled"
printf 'GPU driver: %s\n' "$gpu"
printf 'Desktop environment: %s\n' "$de"
[[ "$install_cups" == yes ]] && echo "CUPS: enabled" || echo "CUPS: disabled"
[[ "$create_swapfile" == yes ]] && printf 'Swapfile: enabled (%s GiB)\n' "$swapfile_size_gb" || echo "Swapfile: disabled"
[[ "$keep_config" == yes ]] && echo "Config retention: enabled (credentials will be removed)" || echo "Config retention: disabled"

echo
read -rp "Do you want to start the installation? [Y/n] " response
case "$response" in
    ""|Y|y) ;;
    N|n) echo "Aborting..."; exit 0 ;;
    *) echo "Error: incorrect option."; exit 1 ;;
esac
clear

# -----------------------------------------------------------------------------
# Connectivity checks.
# -----------------------------------------------------------------------------
echo "Checking the Internet connection..."
if ! ping -c 4 8.8.8.8 >/dev/null 2>&1 && ! ping -c 4 1.1.1.1 >/dev/null 2>&1; then
    echo "Error: no Internet connection."
    exit 1
fi
if ! ping -c 4 google.com >/dev/null 2>&1 && ! ping -c 4 one.one.one.one >/dev/null 2>&1; then
    echo "Error: DNS isn't working. Check your network configuration."
    exit 1
fi

# -----------------------------------------------------------------------------
# Partitioning and mounts.
# -----------------------------------------------------------------------------
format_partition() {
    local filesystem="$1"
    local device="$2"
    case "$filesystem" in
        ext2)  mkfs.ext2 -F "$device" ;;
        ext3)  mkfs.ext3 -F "$device" ;;
        ext4)  mkfs.ext4 -F "$device" ;;
        btrfs) mkfs.btrfs -f "$device" ;;
        xfs)   mkfs.xfs -f "$device" ;;
        *) echo "Error: unsupported filesystem: $filesystem"; exit 1 ;;
    esac
}

mount_partition() {
    local filesystem="$1"
    local device="$2"
    local target="$3"
    local options="${4:-}"
    mkdir -p "$target"
    if [[ -n "$options" ]]; then
        mount -o "$options" -t "$filesystem" "$device" "$target"
    else
        mount -t "$filesystem" "$device" "$target"
    fi
}

mount_separate_fs() {
    local part="$1"
    local filesystem="$2"
    local mountpoint="$3"
    [[ "$part" == none ]] && return 0
    format_partition "$filesystem" "$part"
    if [[ "$filesystem" == btrfs ]]; then
        mount_partition "$filesystem" "$part" "$mountpoint" "compress=zstd:1"
    else
        # In particular, do not use Btrfs's compress=zstd option on XFS.
        mount_partition "$filesystem" "$part" "$mountpoint"
    fi
}

if [[ "$root_part" != none && -n "$root_part" ]]; then
    if [[ "$luks_encryption" == yes ]]; then
        root_part_orig="$root_part"
        root_part_basename=$(basename "$root_part")
        root_part_encrypted_name="${root_part_basename}_crypt"

        echo "Setting up LUKS encryption on $root_part..."
        printf '%s' "$luks_passphrase" | cryptsetup luksFormat --batch-mode "$root_part" -
        printf '%s' "$luks_passphrase" | cryptsetup open "$root_part" "$root_part_encrypted_name" --key-file=-
        root_part="/dev/mapper/$root_part_encrypted_name"
    fi

    case "$root_part_filesystem" in
        ext4|ext3|ext2|xfs)
            format_partition "$root_part_filesystem" "$root_part"
            mount_partition "$root_part_filesystem" "$root_part" /mnt
            ;;
        btrfs)
            mkfs.btrfs -f "$root_part"
            mount -t btrfs -o subvolid=5 "$root_part" /mnt
            btrfs subvolume create /mnt/root
            if [[ "$separate_home_part" == none ]]; then
                btrfs subvolume create /mnt/home
            fi
            umount /mnt
            mount -t btrfs -o subvol=root,compress=zstd:1 "$root_part" /mnt
            if [[ "$separate_home_part" == none ]]; then
                mkdir -p /mnt/home
                mount -t btrfs -o subvol=home,compress=zstd:1 "$root_part" /mnt/home
            fi
            ;;
        *)
            echo "Error: unsupported root filesystem: $root_part_filesystem"
            exit 1
            ;;
    esac
else
    mountpoint -q /mnt || { echo "Error: /mnt is not mounted."; exit 1; }
fi

mountpoint -q /mnt || { echo "Error: failed to mount root filesystem on /mnt."; exit 1; }

mount_separate_fs "$separate_home_part" "$separate_home_part_filesystem" /mnt/home
mount_separate_fs "$separate_boot_part" "$separate_boot_part_filesystem" /mnt/boot
mount_separate_fs "$separate_var_part" "$separate_var_part_filesystem" /mnt/var
mount_separate_fs "$separate_tmp_part" "$separate_tmp_part_filesystem" /mnt/tmp

if [[ "$boot_mode" == UEFI ]]; then
    efi_part_filesystem=$(blkid -s TYPE -o value "$efi_part" || true)
    if [[ "$efi_part_filesystem" != vfat ]]; then
        echo "Error: EFI partition $efi_part is not already FAT32/vfat."
        echo "Refusing to format it automatically. Format the intended EFI system partition as FAT32 and rerun."
        exit 1
    fi
    mkdir -p "/mnt$efi_part_mountpoint"
    mount -t vfat "$efi_part" "/mnt$efi_part_mountpoint"
else
    [[ -b "$grub_disk" ]] || { echo "Error: GRUB disk is not accessible: $grub_disk"; exit 1; }
fi

if [[ "$mirror_location" != none ]]; then
    echo "Selecting mirrors for: $mirror_location"
    if ! reflector --country "$mirror_location" --sort rate --protocol https --save /etc/pacman.d/mirrorlist; then
        echo "Error: Reflector could not find usable mirrors for: $mirror_location"
        exit 1
    fi
fi

case "$kernel_variant" in
    normal) pacstrap -K /mnt base linux linux-firmware linux-headers ;;
    lts)    pacstrap -K /mnt base linux-lts linux-firmware linux-lts-headers ;;
    zen)    pacstrap -K /mnt base linux-zen linux-firmware linux-zen-headers ;;
esac

genfstab -U /mnt > /mnt/etc/fstab

# This file contains no passwords.
cat > /mnt/install-state.sh <<EOF
root_part_orig=${root_part_orig@Q}
root_part_encrypted_name=${root_part_encrypted_name@Q}
boot_mode=${boot_mode@Q}
grub_disk=${grub_disk@Q}
efi_part=${efi_part@Q}
efi_part_mountpoint=${efi_part_mountpoint@Q}
EOF

# -----------------------------------------------------------------------------
# Chroot configuration phase.
# -----------------------------------------------------------------------------
cat > /mnt/main.sh <<'CHROOT_SCRIPT_END'
#!/bin/bash
set -Eeuo pipefail
trap 'echo "Error: chroot command failed on line $LINENO: $BASH_COMMAND" >&2' ERR

source /config.conf
source /install-state.sh

# Keep package operations on a synchronized database; do not use pacman -Sy
# by itself, which risks partial upgrades.
pacman -Syu --noconfirm

ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
systemctl enable systemd-timesyncd
hwclock --systohc

if ! sed 's/^[[:space:]]*#//' /etc/locale.gen | awk -v loc="$language" '$1 == loc {found=1} END {exit !found}'; then
    echo "Error: locale $language does not exist in the installed locale database."
    exit 1
fi

locale_escaped=$(printf '%s' "$language" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
sed -i -E "s/^#([[:space:]]*${locale_escaped}[[:space:]]+UTF-8)/\1/" /etc/locale.gen
echo "LANG=$language" > /etc/locale.conf
echo "KEYMAP=$tty_keyboard_layout" > /etc/vconsole.conf
echo "$hostname" > /etc/hostname
locale-gen

pacman -S --noconfirm \
    btrfs-progs dosfstools dnsmasq inetutils xfsprogs base-devel polkit \
    bash-completion nano grub ntfs-3g sshfs exfatprogs usbutils xdg-utils \
    xdg-user-dirs unzip unrar zip 7zip os-prober plymouth bluez bluez-utils

if [[ "$network_management" == network-manager ]]; then
    pacman -S --noconfirm networkmanager
    systemctl enable NetworkManager
elif [[ "$network_management" == systemd-networkd ]]; then
    default_route=$(ip route | awk '$1 == "default" {print; exit}')
    gateway=$(awk '{print $3}' <<< "$default_route")
    iface=$(awk '{print $5}' <<< "$default_route")
    method=$(awk '{print $7}' <<< "$default_route")
    ip_info=$(ip -4 addr show "$iface" | awk '/inet / {print $2; exit}')

    [[ -n "$iface" ]] || { echo "Error: could not determine network interface in chroot."; exit 1; }
    mkdir -p /etc/systemd/network
    {
        echo "[Match]"
        echo "Name=$iface"
        echo
        echo "[Link]"
        echo "RequiredForOnline=routable"
        echo
        echo "[Network]"
        if [[ "$method" == dhcp ]]; then
            echo "DHCP=yes"
        elif [[ "$method" == static ]]; then
            echo "Address=$ip_info"
            echo "Gateway=$gateway"
            echo "DNS=1.1.1.1"
        else
            echo "DHCP=yes"
        fi
    } > /etc/systemd/network/20-wired.network

    systemctl enable systemd-networkd systemd-resolved
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi

systemctl enable bluetooth

vendor=$(awk -F: '/^vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)
case "$vendor" in
    GenuineIntel) pacman -S --noconfirm intel-ucode ;;
    AuthenticAMD) pacman -S --noconfirm amd-ucode ;;
esac

cat > /etc/hosts <<HOSTS
127.0.0.1       localhost
127.0.1.1       $hostname

::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
HOSTS

useradd -m "$username"
printf '%s:%s\n' "$username" "$password" | chpasswd
if [[ -n "$full_username" ]]; then
    usermod -c "$full_username" "$username"
fi
usermod -aG wheel "$username"

sed -i -E 's/^#?[[:space:]]*Color[[:space:]]*$/Color/' /etc/pacman.conf
if ! grep -q '^ILoveCandy$' /etc/pacman.conf; then
    sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf
fi
sed -i 's|^# include /usr/share/nano/\*\.nanorc|include /usr/share/nano/*.nanorc|' /etc/nanorc

install -d -m 0750 /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
echo 'Defaults pwfeedback' > /etc/sudoers.d/20-pwfeedback
chmod 0440 /etc/sudoers.d/10-wheel /etc/sudoers.d/20-pwfeedback

if [[ "$boot_mode" == UEFI ]]; then
    pacman -S --noconfirm efibootmgr
    grub-install --target=x86_64-efi --efi-directory="$efi_part_mountpoint" --bootloader-id=archlinux
else
    grub-install --target=i386-pc "$grub_disk"
fi

if [[ "$luks_encryption" == yes ]]; then
    cryptdevice_grub=$(blkid -s UUID -o value "$root_part_orig")
    [[ -n "$cryptdevice_grub" ]] || { echo "Error: failed to obtain LUKS UUID."; exit 1; }

    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

    if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"rd.luks.name=$cryptdevice_grub=$root_part_encrypted_name\"|" /etc/default/grub
    else
        echo "GRUB_CMDLINE_LINUX=\"rd.luks.name=$cryptdevice_grub=$root_part_encrypted_name\"" >> /etc/default/grub
    fi
else
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth filesystems fsck)/' /etc/mkinitcpio.conf
fi

if [[ "$de" != none ]]; then
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
        sed -i -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 quiet splash"/' /etc/default/grub
    else
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> /etc/default/grub
    fi
fi

if grep -q '^#*GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i -E 's/^#*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

if [[ "$install_pipewire" == yes ]]; then
    pacman -S --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
fi

case "$gpu" in
    amd)
        pacman -S --noconfirm mesa vulkan-radeon
        if grep -q '^MODULES=()' /etc/mkinitcpio.conf; then
            sed -i 's/^MODULES=()/MODULES=(amdgpu)/' /etc/mkinitcpio.conf
        fi
        ;;
    intel)
        pacman -S --noconfirm mesa vulkan-intel intel-media-driver
        ;;
    nvidia)
        # DKMS works with normal, LTS, and ZEN kernels. Current Arch uses the
        # open kernel module for supported GPUs; older Pascal/Maxwell cards
        # require a legacy driver branch instead.
        pacman -S --noconfirm dkms nvidia-open-dkms nvidia-settings
        if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
            sed -i -E 's|^GRUB_CMDLINE_LINUX="([^"]*)"|GRUB_CMDLINE_LINUX="\1 nvidia-drm.modeset=1 nvidia-drm.fbdev=1"|' /etc/default/grub
        fi
        ;;
    other)
        pacman -S --noconfirm mesa
        ;;
    none) ;;
esac

grub-mkconfig -o /boot/grub/grub.cfg

case "$de" in
    gnome)
        pacman -S --noconfirm gnome noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra \
            gnome-tweaks gnome-shell-extensions gnome-browser-connector power-profiles-daemon ptyxis
        systemctl enable gdm
        ;;
    plasma)
        pacman -S --noconfirm plasma plasma-login-manager noto-fonts noto-fonts-cjk noto-fonts-emoji \
            noto-fonts-extra ufw dolphin konsole power-profiles-daemon
        systemctl enable plasmalogin
        ;;
    xfce)
        pacman -S --noconfirm xfce4 xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools \
            blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts \
            noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs network-manager-applet \
            power-profiles-daemon
        systemctl enable lightdm
        ;;
    cinnamon)
        pacman -S --noconfirm blueman cinnamon cinnamon-translations nemo-fileroller gnome-terminal \
            lightdm lightdm-slick-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra \
            gvfs power-profiles-daemon
        systemctl enable lightdm
        sed -i 's/^#greeter-session=.*/greeter-session=lightdm-slick-greeter/' /etc/lightdm/lightdm.conf
        ;;
    mate)
        pacman -S --noconfirm mate mate-extra blueman lightdm lightdm-gtk-greeter \
            lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra \
            gvfs power-profiles-daemon
        systemctl enable lightdm
        ;;
    none) ;;
esac

if [[ "$install_cups" == yes ]]; then
    pacman -S --noconfirm cups cups-filters cups-pk-helper cups-browsed bluez-cups \
        ghostscript gutenprint hplip nss-mdns avahi system-config-printer
    systemctl enable cups cups-browsed avahi-daemon
    sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf

    install -d -m 0755 "/home/$username/.local/share/applications"
    for desktop_file in hplip.desktop hp-uiscan.desktop; do
        if [[ -f "/usr/share/applications/$desktop_file" ]]; then
            cp "/usr/share/applications/$desktop_file" "/home/$username/.local/share/applications/"
            printf '\nNoDisplay=true\n' >> "/home/$username/.local/share/applications/$desktop_file"
        fi
    done
    chown -R "$username:$username" "/home/$username/.local"
fi

if [[ "$create_swapfile" == yes ]]; then
    if [[ "$root_part_filesystem" == btrfs ]]; then
        truncate -s 0 /swapfile
        chattr +C /swapfile
    fi
    fallocate -l "${swapfile_size_gb}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    printf '%s\n' '# /swapfile' >> /etc/fstab
    printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab
fi

mkinitcpio -P

o_rphans=$(pacman -Qdtq 2>/dev/null || true)
if [[ -n "$o_rphans" ]]; then
    # shellcheck disable=SC2086
    pacman -Rns $o_rphans --noconfirm
fi

pacman -Scc --noconfirm

if [[ "$keep_config" == yes ]]; then
    # Remove both secrets before retaining the file.
    sed -i -E 's/^(password|luks_passphrase)=.*/\1=""/' /config.conf
    install -m 0600 -o "$username" -g "$username" /config.conf "/home/$username/config.conf"
fi

rm -f /install-state.sh /main.sh /tmpfile.sh /tmpscript.sh
if [[ "$keep_config" == no ]]; then
    rm -f /config.conf
fi
CHROOT_SCRIPT_END

chmod +x /mnt/main.sh
if ! arch-chroot /mnt /bin/bash /main.sh; then
    echo "Error: installation inside arch-chroot failed."
    exit 1
fi

echo "Installation completed successfully."
