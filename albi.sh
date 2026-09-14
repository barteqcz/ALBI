#!/bin/bash

set -Eeuo pipefail

readonly SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME="$(basename "$SCRIPT_FILE")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_FILE")" && pwd)"
readonly CONFIG_FILE_HOST="$SCRIPT_DIR/config.conf"
readonly TARGET_MOUNT="/mnt"
readonly CHROOT_INSTALLER="/usr/local/lib/albi-installer.sh"

boot_mode=""
root_part_orig=""
root_part_encrypted_name=""
root_part=""

error_handler() {
    local exit_code=$?
    local failed_line="${BASH_LINENO[0]:-unknown}"
    local failed_command="${BASH_COMMAND:-unknown}"
    printf 'ERROR: command failed on line %s (exit status %s): %s\n' \
        "$failed_line" "$exit_code" "$failed_command" >&2
    exit "$exit_code"
}

interrupt_handler() {
    echo
    echo "Interruption signal received. Aborting..."
    exit 130
}

trap error_handler ERR
trap interrupt_handler SIGINT SIGTERM

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This installer must be run as root."
}

detect_boot_mode() {
    if [[ -d /sys/firmware/efi ]]; then
        boot_mode="UEFI"
    else
        boot_mode="BIOS"
    fi
}

# Parse only simple KEY="value", KEY='value', or KEY=value assignments.
# This deliberately avoids executing config.conf as shell code.
load_config() {
    local file=$1
    local line key value
    local re_double='^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*"([^"]*)"[[:space:]]*(#.*)?$'
    local re_single="^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*'([^']*)'[[:space:]]*(#.*)?$"
    local re_unquoted='^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*([^[:space:]#]+)[[:space:]]*(#.*)?$'

    [[ -f "$file" ]] || die "Configuration file not found: $file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ $re_double ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ $re_single ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ $re_unquoted ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        else
            die "Invalid configuration line: $line"
        fi

        case "$key" in
            root_part_filesystem|separate_home_part_filesystem|separate_boot_part_filesystem|separate_var_part_filesystem|separate_tmp_part_filesystem| \
            root_part|separate_home_part|separate_boot_part|separate_var_part|separate_tmp_part| \
            luks_encryption|luks_passphrase|efi_part|efi_part_mountpoint|grub_disk| \
            network_management|kernel_variant|mirror_location|timezone| \
            hostname|username|full_username|password|language|tty_keyboard_layout| \
            install_pipewire|gpu|de|install_cups|create_swapfile|swapfile_size_gb|keep_config)
                declare -g "$key=$value"
                ;;
            *)
                die "Unknown configuration option: $key"
                ;;
        esac
    done < "$file"
}

has_value() {
    local name=$1
    [[ -n "${!name:-}" ]]
}

validate_yes_no() {
    local name=$1
    local value=${!name:-}
    case "$value" in
        yes|no) ;;
        *) die "Invalid value for $name: ${value:-<empty>} (expected yes/no)." ;;
    esac
}

validate_filesystem() {
    local name=$1
    local value=${!name:-}
    case "$value" in
        ext2|ext3|ext4|btrfs|xfs|none) ;;
        *) die "Invalid filesystem for $name: ${value:-<empty>}." ;;
    esac
}

validate_partition_setting() {
    local name=$1
    local value=${!name:-}

    [[ "$value" == "none" ]] && return 0
    [[ -b "$value" ]] || die "$name does not point to a block device: $value"
}

partition_is_mounted() {
    local part=$1
    findmnt -n -S "$part" >/dev/null 2>&1
}

validate_not_mounted() {
    local part=$1
    if partition_is_mounted "$part"; then
        die "Partition is already mounted; refusing to format it: $part"
    fi
}

validate_distinct_partitions() {
    local -A seen=()
    local name value

    for name in root_part separate_home_part separate_boot_part separate_var_part separate_tmp_part efi_part; do
        value="${!name:-none}"
        [[ "$value" == "none" ]] && continue
        if [[ -n "${seen[$value]:-}" ]]; then
            die "The same partition/device is assigned to both $name and ${seen[$value]}: $value"
        fi
        seen[$value]="$name"
    done
}

prompt_for_secret() {
    local var_name=$1
    local label=$2
    local confirmation
    local secret

    read -r -s -p "$label: " secret
    echo
    read -r -s -p "Confirm $label: " confirmation
    echo

    [[ "$secret" == "$confirmation" ]] || die "The two values do not match."
    [[ -n "$secret" ]] || die "$label must not be empty."
    printf -v "$var_name" '%s' "$secret"
}

prompt_for_missing_secrets() {
    if [[ -z "${password:-}" ]]; then
        prompt_for_secret password "Enter the user password"
    fi

    if [[ "${luks_encryption:-no}" == "yes" && -z "${luks_passphrase:-}" ]]; then
        prompt_for_secret luks_passphrase "Enter the LUKS passphrase"
    fi
}

validate_config() {
    local mode=${1:-host}
    local required
    for required in \
        root_part_filesystem separate_home_part_filesystem separate_boot_part_filesystem \
        separate_var_part_filesystem separate_tmp_part_filesystem root_part separate_home_part \
        separate_boot_part separate_var_part separate_tmp_part luks_encryption network_management \
        kernel_variant mirror_location timezone hostname username language \
        tty_keyboard_layout install_pipewire gpu de install_cups create_swapfile swapfile_size_gb keep_config; do
        has_value "$required" || die "Missing configuration option: $required"
    done

    validate_filesystem root_part_filesystem
    validate_filesystem separate_home_part_filesystem
    validate_filesystem separate_boot_part_filesystem
    validate_filesystem separate_var_part_filesystem
    validate_filesystem separate_tmp_part_filesystem

    validate_yes_no luks_encryption
    validate_yes_no install_pipewire
    validate_yes_no install_cups
    validate_yes_no create_swapfile
    validate_yes_no keep_config

    case "$network_management" in
        network-manager|systemd-networkd|none) ;;
        *) die "Invalid network management tool: $network_management" ;;
    esac

    case "$kernel_variant" in
        normal|lts|zen) ;;
        *) die "Invalid kernel variant: $kernel_variant" ;;
    esac

    case "$gpu" in
        amd|intel|nvidia|other|none) ;;
        *) die "Invalid GPU driver selection: $gpu" ;;
    esac

    case "$de" in
        gnome|plasma|xfce|mate|cinnamon|none) ;;
        *) die "Invalid desktop environment: $de" ;;
    esac

    if [[ "$gpu" == "none" && "$de" != "none" ]]; then
        die "A desktop environment requires a GPU driver selection."
    fi

    if [[ "$luks_encryption" == "yes" && "$root_part" != "none" && "$separate_boot_part" == "none" ]]; then
        die "Encrypted / requires a separate /boot partition."
    fi

    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid username: $username"
    [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "Invalid hostname: $hostname"

    [[ -f "/usr/share/zoneinfo/$timezone" ]] || die "Invalid timezone: $timezone"
    [[ -n "$password" ]] || die "User password is not set."
    if [[ "$luks_encryption" == "yes" ]]; then
        [[ -n "${luks_passphrase:-}" ]] || die "LUKS passphrase is not set."
    fi
    awk -v locale="$language" '
        { candidate=$1; sub(/^#/, "", candidate); if (candidate == locale && $2 == "UTF-8") found=1 }
        END { exit !found }
    ' /etc/locale.gen || die "Selected locale does not exist in /etc/locale.gen: $language"

    local keymap_list
    keymap_list=$(localectl list-keymaps 2>/dev/null || true)
    grep -Fxq "$tty_keyboard_layout" <<< "$keymap_list" || die "Selected TTY keymap is unavailable: $tty_keyboard_layout"

    [[ "$swapfile_size_gb" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Invalid swapfile size: $swapfile_size_gb"
    awk -v size="$swapfile_size_gb" 'BEGIN { exit !(size > 0) }' || die "Swapfile size must be greater than zero."

    if [[ "$mode" == "host" ]]; then
        if [[ "$boot_mode" == "UEFI" ]]; then
            has_value efi_part || die "Missing EFI partition configuration."
            has_value efi_part_mountpoint || die "Missing EFI partition mount point."
            [[ "$efi_part_mountpoint" == "/boot/efi" || "$efi_part_mountpoint" == "/efi" ]] || die "Invalid EFI mount point: $efi_part_mountpoint"
            validate_partition_setting efi_part
        else
            has_value grub_disk || die "Missing GRUB disk configuration."
            [[ -b "$grub_disk" ]] || die "GRUB target is not a block device: $grub_disk"
        fi

        validate_partition_setting root_part
        validate_partition_setting separate_home_part
        validate_partition_setting separate_boot_part
        validate_partition_setting separate_var_part
        validate_partition_setting separate_tmp_part

        validate_distinct_partitions

        local part value
        for part in root_part separate_home_part separate_boot_part separate_var_part separate_tmp_part; do
            value="${!part:-none}"
            [[ "$value" == "none" ]] || validate_not_mounted "$value"
        done

        if [[ "$boot_mode" == "UEFI" ]]; then
            validate_not_mounted "$efi_part"
            [[ "$efi_part" != "${separate_boot_part:-none}" ]] || die "EFI and /boot cannot use the same partition."
        fi

        if [[ "$network_management" == "systemd-networkd" ]]; then
            local iface
            iface="$(ip -o route show default 2>/dev/null | awk 'NR==1 {print $5}')"
            [[ -n "$iface" ]] || die "Could not determine the active network interface."
            if [[ -d "/sys/class/net/$iface/wireless" ]]; then
                die "systemd-networkd configuration for wireless is not supported by ALBI; use NetworkManager."
            fi
            if [[ "$de" != "none" ]]; then
                die "systemd-networkd mode is only supported here for installs without a desktop environment."
            fi
        fi
    fi
}

show_config() {
    local secret_state="not set"
    [[ -n "${password:-}" ]] && secret_state="set"
    local luks_state="disabled"
    [[ "$luks_encryption" == "yes" ]] && luks_state="enabled"

    echo "Are these information correct?"
    echo
    echo "/: $root_part_filesystem on $root_part"

    [[ "$separate_home_part" != "none" ]] && echo "/home: $separate_home_part_filesystem on $separate_home_part"
    [[ "$separate_boot_part" != "none" ]] && echo "/boot: $separate_boot_part_filesystem on $separate_boot_part"
    [[ "$separate_var_part" != "none" ]] && echo "/var: $separate_var_part_filesystem on $separate_var_part"
    [[ "$separate_tmp_part" != "none" ]] && echo "/tmp: $separate_tmp_part_filesystem on $separate_tmp_part"

    echo "Disk encryption: $luks_state"

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
    echo "Full username: ${full_username:-not set}"
    echo "User password: $secret_state"
    echo "Language: $language"
    echo "TTY keyboard layout: $tty_keyboard_layout"
    echo "PipeWire: $install_pipewire"
    echo "GPU driver: $gpu"
    echo "Desktop environment: $de"
    echo "CUPS: $install_cups"
    if [[ "$create_swapfile" == "yes" ]]; then
        echo "Swapfile: enabled (size: $swapfile_size_gb GB)"
    else
        echo "Swapfile: disabled"
    fi
    echo "Keep config: $keep_config"
    echo
}

confirm_installation() {
    local response
    while true; do
        read -r -p "Do you want to start the installation? [Y/n] " response
        case "$response" in
            ""|Y|y) return 0 ;;
            N|n) echo "Aborting..."; exit 0 ;;
            *) echo "Error: incorrect option. Please try again." ;;
        esac
    done
}

check_internet() {
    echo "Checking the Internet connection..."
    if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && \
       ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        die "No Internet connection."
    fi

    if ! ping -c 1 -W 3 google.com >/dev/null 2>&1 && \
       ! ping -c 1 -W 3 one.one.one.one >/dev/null 2>&1; then
        die "DNS isn't working. Check your network configuration."
    fi
}

format_and_mount() {
    local part=$1
    local filesystem=$2
    local mountpoint=$3

    [[ -b "$part" ]] || die "Not a block device: $part"
    validate_not_mounted "$part"
    mkdir -p "$mountpoint"

    case "$filesystem" in
        ext2)
            mkfs.ext2 -F "$part"
            mount "$part" "$mountpoint"
            ;;
        ext3)
            mkfs.ext3 -F "$part"
            mount "$part" "$mountpoint"
            ;;
        ext4)
            mkfs.ext4 -F "$part"
            mount "$part" "$mountpoint"
            ;;
        btrfs)
            mkfs.btrfs -f "$part"
            mount -t btrfs -o compress=zstd:1 "$part" "$mountpoint"
            ;;
        xfs)
            mkfs.xfs -f "$part"
            mount "$part" "$mountpoint"
            ;;
        *)
            die "Unsupported filesystem for $mountpoint: $filesystem"
            ;;
    esac
}

setup_root() {
    local mount_partition
    mount_partition="$(findmnt -n -o SOURCE --target "$TARGET_MOUNT" 2>/dev/null || true)"

    if [[ "$root_part" == "none" ]]; then
        [[ -n "$mount_partition" ]] || die "No root partition is mounted at $TARGET_MOUNT and root_part is set to none."
        return 0
    fi

    [[ -z "$mount_partition" ]] || die "$TARGET_MOUNT is already mounted by $mount_partition."
    [[ -b "$root_part" ]] || die "Root partition isn't a block device: $root_part"
    validate_not_mounted "$root_part"

    if [[ "$luks_encryption" == "yes" ]]; then
        [[ "$separate_boot_part" != "none" ]] || die "A separate /boot partition is required for encrypted root."
        echo "Setting up LUKS encryption..."
        root_part_orig="$root_part"
        root_part_encrypted_name="$(basename "$root_part")_crypt"

        printf '%s' "$luks_passphrase" | cryptsetup luksFormat --batch-mode --type luks2 "$root_part" -
        printf '%s' "$luks_passphrase" | cryptsetup open "$root_part" "$root_part_encrypted_name" -
        root_part="/dev/mapper/$root_part_encrypted_name"
    fi

    if [[ "$root_part_filesystem" == "btrfs" ]]; then
        mkfs.btrfs -f "$root_part"
        mount -t btrfs -o subvolid=5 "$root_part" "$TARGET_MOUNT"
        btrfs subvolume create "$TARGET_MOUNT/root"

        if [[ "$separate_home_part" == "none" ]]; then
            btrfs subvolume create "$TARGET_MOUNT/home"
        fi

        umount "$TARGET_MOUNT"
        mount -t btrfs -o subvol=root,compress=zstd:1 "$root_part" "$TARGET_MOUNT"

        if [[ "$separate_home_part" == "none" ]]; then
            mkdir -p "$TARGET_MOUNT/home"
            mount -t btrfs -o subvol=home,compress=zstd:1 "$root_part" "$TARGET_MOUNT/home"
        fi
    else
        format_and_mount "$root_part" "$root_part_filesystem" "$TARGET_MOUNT"
    fi
}

setup_optional_mounts() {
    if [[ "$separate_home_part" != "none" ]]; then
        format_and_mount "$separate_home_part" "$separate_home_part_filesystem" "$TARGET_MOUNT/home"
    fi

    if [[ "$separate_boot_part" != "none" ]]; then
        format_and_mount "$separate_boot_part" "$separate_boot_part_filesystem" "$TARGET_MOUNT/boot"
    fi

    if [[ "$separate_var_part" != "none" ]]; then
        format_and_mount "$separate_var_part" "$separate_var_part_filesystem" "$TARGET_MOUNT/var"
    fi

    if [[ "$separate_tmp_part" != "none" ]]; then
        format_and_mount "$separate_tmp_part" "$separate_tmp_part_filesystem" "$TARGET_MOUNT/tmp"
    fi
}

setup_efi() {
    [[ "$boot_mode" == "UEFI" ]] || return 0

    local efi_filesystem
    efi_filesystem="$(blkid -s TYPE -o value "$efi_part" 2>/dev/null || true)"

    if [[ "$efi_filesystem" != "vfat" ]]; then
        echo "Formatting EFI partition as FAT32: $efi_part"
        mkfs.fat -F 32 "$efi_part"
    fi

    mkdir -p "$TARGET_MOUNT$efi_part_mountpoint"
    mount -t vfat "$efi_part" "$TARGET_MOUNT$efi_part_mountpoint"
}

configure_mirrors() {
    [[ "$mirror_location" != "none" ]] || return 0
    echo "Selecting mirrors for: $mirror_location"
    reflector --country "$mirror_location" --sort rate --save /etc/pacman.d/mirrorlist
}

select_kernel_packages() {
    case "$kernel_variant" in
        normal) printf '%s\n' linux linux-firmware linux-headers ;;
        lts) printf '%s\n' linux-lts linux-firmware linux-lts-headers ;;
        zen) printf '%s\n' linux-zen linux-firmware linux-zen-headers ;;
        *) die "Unexpected kernel variant: $kernel_variant" ;;
    esac
}

install_base_system() {
    local -a kernel_packages
    mapfile -t kernel_packages < <(select_kernel_packages)
    pacstrap -K "$TARGET_MOUNT" base "${kernel_packages[@]}"
    genfstab -U "$TARGET_MOUNT" >> "$TARGET_MOUNT/etc/fstab"
}

prepare_config_for_target() {
    install -d -m 700 "$TARGET_MOUNT/usr/local/lib"
    install -m 700 "$SCRIPT_FILE" "$TARGET_MOUNT$CHROOT_INSTALLER"
    install -m 600 "$CONFIG_FILE_HOST" "$TARGET_MOUNT/config.conf"

    umask 077
    printf '%s\n%s\n' "$password" "${luks_passphrase:-}" > "$TARGET_MOUNT/.albi-secrets"
    chmod 600 "$TARGET_MOUNT/.albi-secrets"
}

load_target_secrets() {
    [[ -f /.albi-secrets ]] || return 0

    {
        IFS= read -r password || true
        IFS= read -r luks_passphrase || true
    } < /.albi-secrets

    rm -f /.albi-secrets
}

cleanup_host_mounts() {
    set +e
    rm -f "$TARGET_MOUNT/.albi-secrets"
    if mountpoint -q "$TARGET_MOUNT"; then
        umount -R "$TARGET_MOUNT"
    fi
    if [[ -n "$root_part_encrypted_name" ]] && cryptsetup status "$root_part_encrypted_name" >/dev/null 2>&1; then
        cryptsetup close "$root_part_encrypted_name"
    fi
}

host_abort_cleanup() {
    echo "Cleaning up mounted filesystems..."
    cleanup_host_mounts
    exit 1
}

host_main() {
    require_root
    detect_boot_mode

    if [[ ! -e "$CONFIG_FILE_HOST" ]]; then
        generate_config
        exit 0
    fi

    load_config "$CONFIG_FILE_HOST"
    prompt_for_missing_secrets
    validate_config
    show_config
    confirm_installation

    trap host_abort_cleanup ERR SIGINT SIGTERM

    check_internet
    if [[ "$mirror_location" != "none" ]]; then
        command -v reflector >/dev/null 2>&1 || die "reflector is required when mirror_location is not none."
    fi
    configure_mirrors
    setup_root
    setup_optional_mounts
    setup_efi
    install_base_system
    prepare_config_for_target

    echo "Entering chroot configuration..."
    if [[ -n "$root_part_orig" ]]; then
        arch-chroot "$TARGET_MOUNT" "$CHROOT_INSTALLER" --chroot "$root_part_orig" "$root_part_encrypted_name"
    else
        arch-chroot "$TARGET_MOUNT" "$CHROOT_INSTALLER" --chroot
    fi

    echo "Installation completed. Unmounting target filesystems..."
    trap - ERR SIGINT SIGTERM
    cleanup_host_mounts

    echo "ALBI installation finished successfully."
}

generate_config() {
    local hostname_default
    hostname_default="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    if [[ -z "$hostname_default" ]]; then
        hostname_default="archlinux"
    fi
    hostname_default="${hostname_default,,}"
    hostname_default="$(sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-*//; s/-*$//' <<< "$hostname_default")"
    hostname_default="${hostname_default:0:63}"
    [[ -n "$hostname_default" ]] || hostname_default="archlinux"

    if [[ "$boot_mode" == "UEFI" ]]; then
        cat > "$CONFIG_FILE_HOST" <<EOF_CONFIG
## ALBI Installation Configuration

### Formatting
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

efi_part="/dev/sdX#"
efi_part_mountpoint="/boot/efi"

### Encryption
luks_encryption="yes"
luks_passphrase=""

### Connectivity
network_management="network-manager"

### Kernel Variant
kernel_variant="normal"

### Mirror Servers Location
mirror_location="none"

### Timezone
timezone="Europe/Prague"

### Hostname and User
hostname="$hostname_default"
username="changeme"
full_username=""
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
EOF_CONFIG
    else
        cat > "$CONFIG_FILE_HOST" <<EOF_CONFIG
## ALBI Installation Configuration

### Formatting
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

grub_disk="/dev/sdX"

### Encryption
luks_encryption="yes"
luks_passphrase=""

### Connectivity
network_management="network-manager"

### Kernel Variant
kernel_variant="normal"

### Mirror Servers Location
mirror_location="none"

### Timezone
timezone="Europe/Prague"

### Hostname and User
hostname="$hostname_default"
username="changeme"
full_username=""
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
EOF_CONFIG
    fi

    chmod 600 "$CONFIG_FILE_HOST"
    echo "config.conf was generated successfully: $CONFIG_FILE_HOST"
    echo "Edit it to customize the installation. Password fields may be left empty to be requested securely at runtime."
}

configure_locale() {
    local locale_regex
    locale_regex="${language//./\\.}"

    sed -i -E "s/^#?[[:space:]]*(${locale_regex}[[:space:]]+UTF-8)$/\1/" /etc/locale.gen
    grep -Eq "^${locale_regex}[[:space:]]+UTF-8$" /etc/locale.gen || die "Failed to enable locale: $language"

    printf 'LANG=%s\n' "$language" > /etc/locale.conf
    printf 'KEYMAP=%s\n' "$tty_keyboard_layout" > /etc/vconsole.conf
    printf '%s\n' "$hostname" > /etc/hostname
    locale-gen
}

configure_timezone() {
    ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
    systemctl enable systemd-timesyncd.service
    hwclock --systohc
}

install_common_packages() {
    local -a packages=(
        btrfs-progs
        cryptsetup
        dosfstools
        dnsmasq
        inetutils
        xfsprogs
        base-devel
        polkit
        bash-completion
        nano
        sudo
        grub
        ntfs-3g
        sshfs
        exfatprogs
        usbutils
        xdg-utils
        xdg-user-dirs
        unzip
        unrar
        zip
        7zip
        os-prober
        plymouth
    )

    pacman -S --needed --noconfirm "${packages[@]}"
}

configure_network() {
    case "$network_management" in
        network-manager)
            pacman -S --needed --noconfirm networkmanager
            systemctl enable NetworkManager.service
            ;;
        systemd-networkd)
            local iface
            iface="$(ip -o route show default 2>/dev/null | awk 'NR==1 {print $5}')"
            [[ -n "$iface" ]] || die "Could not determine an interface for systemd-networkd."

            install -d /etc/systemd/network
            cat > /etc/systemd/network/20-wired.network <<EOF_NETWORK
[Match]
Name=$iface

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes
EOF_NETWORK

            systemctl enable systemd-networkd.service systemd-resolved.service
            ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            ;;
        none)
            ;;
        *)
            die "Unexpected network management setting: $network_management"
            ;;
    esac
}

install_bluetooth() {
    pacman -S --needed --noconfirm bluez
    systemctl enable bluetooth.service
}

install_cpu_microcode() {
    local vendor
    vendor="$(awk -F: '/^vendor_id[[:space:]]*:/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)"

    case "$vendor" in
        GenuineIntel) pacman -S --needed --noconfirm intel-ucode ;;
        AuthenticAMD) pacman -S --needed --noconfirm amd-ucode ;;
    esac
}

configure_hosts() {
    cat > /etc/hosts <<EOF_HOSTS
127.0.0.1       localhost
127.0.1.1       $hostname

# The following lines are desirable for IPv6 capable hosts
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF_HOSTS
}

create_user() {
    id "$username" >/dev/null 2>&1 && die "User already exists: $username"

    useradd --create-home "$username"
    printf '%s:%s\n' "$username" "$password" | chpasswd

    if [[ -n "$full_username" ]]; then
        usermod -c "$full_username" "$username"
    fi

    usermod -aG wheel "$username"
}

configure_shell_tools() {
    if ! grep -q '^include /usr/share/nano/.*\.nanorc' /etc/nanorc 2>/dev/null; then
        sed -i 's|^# *include /usr/share/nano/\*\.nanorc|include /usr/share/nano/*.nanorc|' /etc/nanorc
    fi

    if grep -q '^#Color$' /etc/pacman.conf; then
        sed -i 's/^#Color$/Color/' /etc/pacman.conf
    fi

    if ! grep -q '^ILoveCandy$' /etc/pacman.conf; then
        printf '\nILoveCandy\n' >> /etc/pacman.conf
    fi

    install -d -m 755 /etc/sudoers.d
    cat > /etc/sudoers.d/10-wheel <<'EOF_SUDO'
%wheel ALL=(ALL:ALL) ALL
EOF_SUDO
    chmod 440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers
}

configure_grub() {
    if [[ "$boot_mode" == "UEFI" ]]; then
        grub-install --target=x86_64-efi --efi-directory="$efi_part_mountpoint" --bootloader-id=archlinux
    else
        grub-install --target=i386-pc "$grub_disk"
    fi

    if [[ "$luks_encryption" == "yes" ]]; then
        local cryptdevice_grub
        cryptdevice_grub="$(blkid -s UUID -o value "$root_part_orig")"
        [[ -n "$cryptdevice_grub" ]] || die "Could not determine the LUKS UUID."

        sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
        if grep -q '^GRUB_CMDLINE_LINUX=""' /etc/default/grub; then
            sed -i "s|^GRUB_CMDLINE_LINUX=\"\"$|GRUB_CMDLINE_LINUX=\"rd.luks.uuid=$cryptdevice_grub\"|" /etc/default/grub
        else
            sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"rd.luks.uuid=$cryptdevice_grub |" /etc/default/grub
        fi
    else
        sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth filesystems fsck)/' /etc/mkinitcpio.conf
    fi

    if [[ "$de" != "none" ]]; then
        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
            if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=".*quiet' /etc/default/grub; then
                sed -i 's/quiet/& splash/' /etc/default/grub
            else
                sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 quiet splash"/' /etc/default/grub
            fi
        fi
    fi

    if grep -q '^#GRUB_DISABLE_OS_PROBER=false$' /etc/default/grub; then
        sed -i 's/^#GRUB_DISABLE_OS_PROBER=false$/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    fi
}

configure_gpu() {
    case "$gpu" in
        amd)
            pacman -S --needed --noconfirm mesa vulkan-radeon
            if grep -q '^MODULES=()$' /etc/mkinitcpio.conf; then
                sed -i 's/^MODULES=()$/MODULES=(amdgpu)/' /etc/mkinitcpio.conf
            elif ! grep -Eq '^MODULES=.*\bamdgpu\b' /etc/mkinitcpio.conf; then
                sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 amdgpu)/' /etc/mkinitcpio.conf
            fi
            ;;
        intel)
            pacman -S --needed --noconfirm mesa vulkan-intel intel-media-driver
            ;;
        nvidia)
            pacman -S --needed --noconfirm nvidia nvidia-settings
            if grep -q '^GRUB_CMDLINE_LINUX=""' /etc/default/grub; then
                sed -i 's/^GRUB_CMDLINE_LINUX=""$/GRUB_CMDLINE_LINUX="nvidia-drm.modeset=1 nvidia-drm.fbdev=1"/' /etc/default/grub
            else
                sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/GRUB_CMDLINE_LINUX="\1 nvidia-drm.modeset=1 nvidia-drm.fbdev=1"/' /etc/default/grub
            fi
            ;;
        other)
            pacman -S --needed --noconfirm mesa
            ;;
        none)
            ;;
    esac
}

install_desktop() {
    case "$de" in
        gnome)
            pacman -S --needed --noconfirm \
                gnome noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra \
                gnome-tweaks gnome-shell-extensions gnome-browser-connector \
                power-profiles-daemon ptyxis --assume-installed=gnome-console
            systemctl enable gdm.service
            ;;
        plasma)
            local -a plasma_group_packages
            mapfile -t plasma_group_packages < <(pacman -Sgq plasma | grep -v '^sddm-kcm$')
            pacman -S --needed --noconfirm \
                "${plasma_group_packages[@]}" \
                plasma-login-manager noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra \
                ufw dolphin konsole power-profiles-daemon
            systemctl enable plasmalogin.service
            ;;
        xfce)
            pacman -S --needed --noconfirm \
                xfce4 xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools \
                blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings \
                noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs \
                network-manager-applet power-profiles-daemon
            systemctl enable lightdm.service
            ;;
        cinnamon)
            pacman -S --needed --noconfirm \
                blueman cinnamon cinnamon-translations nemo-fileroller gnome-terminal \
                lightdm lightdm-slick-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji \
                noto-fonts-extra gvfs power-profiles-daemon
            systemctl enable lightdm.service
            sed -i 's/^#greeter-session=example-gtk-gnome$/greeter-session=lightdm-slick-greeter/' /etc/lightdm/lightdm.conf
            ;;
        mate)
            pacman -S --needed --noconfirm \
                mate mate-extra blueman lightdm lightdm-gtk-greeter \
                lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji \
                noto-fonts-extra gvfs power-profiles-daemon
            systemctl enable lightdm.service
            ;;
        none)
            ;;
    esac
}

install_pipewire() {
    [[ "$install_pipewire" == "yes" ]] || return 0
    pacman -S --needed --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
}

install_cups() {
    [[ "$install_cups" == "yes" ]] || return 0

    pacman -S --needed --noconfirm \
        cups cups-filters cups-pk-helper cups-browsed bluez-cups ghostscript \
        gutenprint hplip nss-mdns

    systemctl enable cups.service cups-browsed.service avahi-daemon.service

    sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf

    if [[ "$de" != "none" ]]; then
        pacman -S --needed --noconfirm system-config-printer

        install -d -m 755 "/home/$username/.local/share/applications"
        if [[ -f /usr/share/applications/hplip.desktop ]]; then
            cp /usr/share/applications/hplip.desktop "/home/$username/.local/share/applications/"
            printf '\nNoDisplay=true\n' >> "/home/$username/.local/share/applications/hplip.desktop"
        fi
        if [[ -f /usr/share/applications/hp-uiscan.desktop ]]; then
            cp /usr/share/applications/hp-uiscan.desktop "/home/$username/.local/share/applications/"
            printf '\nNoDisplay=true\n' >> "/home/$username/.local/share/applications/hp-uiscan.desktop"
        fi
        chown -R "$username:$username" "/home/$username/.local"
    fi
}

create_swapfile() {
    [[ "$create_swapfile" == "yes" ]] || return 0

    if [[ "$root_part_filesystem" == "btrfs" ]]; then
        truncate -s 0 /swapfile
        chattr +C /swapfile
    fi

    fallocate -l "${swapfile_size_gb}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    cat >> /etc/fstab <<'EOF_SWAP'

# /swapfile
/swapfile    none    swap    sw    0    0
EOF_SWAP
}

cleanup_packages() {
    local -a orphans
    mapfile -t orphans < <(pacman -Qdtq 2>/dev/null || true)
    if ((${#orphans[@]} > 0)); then
        pacman -Runs --noconfirm "${orphans[@]}"
    fi

    pacman -Sc --noconfirm
}

remove_installer_files() {
    if [[ "$keep_config" == "yes" ]]; then
        install -m 600 /config.conf "/home/$username/config.conf"
        chown "$username:$username" "/home/$username/config.conf"
        rm -f /config.conf
    else
        rm -f /config.conf
    fi

    rm -f "$CHROOT_INSTALLER"
}

chroot_main() {
    root_part_orig="${2:-}"
    root_part_encrypted_name="${3:-}"

    [[ -f /config.conf ]] || die "Missing /config.conf inside target system."
    load_config /config.conf
    load_target_secrets
    prompt_for_missing_secrets
    validate_config target

    configure_timezone
    configure_locale
    install_common_packages
    configure_network
    install_bluetooth
    install_cpu_microcode
    configure_hosts
    create_user
    configure_shell_tools
    configure_grub
    configure_gpu
    install_pipewire
    install_desktop
    install_cups
    create_swapfile

    mkinitcpio -P
    grub-mkconfig -o /boot/grub/grub.cfg

    cleanup_packages
    remove_installer_files

    echo "Chroot configuration completed successfully."
}

main() {
    case "${1:-}" in
        --chroot)
            require_root
            detect_boot_mode
            chroot_main "$@"
            ;;
        "")
            host_main
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
}

main "$@"
