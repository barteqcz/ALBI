#!/bin/bash

set -Eeo pipefail

# =============================================================================
# Installer setup, helpers, and cleanup
# =============================================================================
die() {
    echo "Error: $*" >&2
    exit 1
}

installation_started="false"
installation_mounts=()
staged_config="false"
stage_dir_host=""
stage_dir_chroot=""
config_cleanup_armed="false"
installation_successful="false"
installer_tmpdir=""
lvm_used="no"
declare -A lvm_volume_groups=()
declare -A lvm_target_groups=()
main_script=""
tmpfile_script=""
mirror_tmp=""
cwd=$(pwd)
config_path="$cwd/config.conf"

# The installer modifies disks and the target system; require root before doing anything.
if (( EUID != 0 )); then
    die "Run this installer as root."
fi

# Track only mounts made by this installer, leaving pre-existing mounts untouched.
mount_install() {
    local target="${@: -1}"
    mount "$@"
    installation_mounts+=("$target")
}

# Format and mount a regular data partition. Root Btrfs is handled separately
# because it needs dedicated root/home subvolumes.
format_and_mount_partition() {
    local filesystem="$1" device="$2" target="$3" mount_options="${4:-}"

    case "$filesystem" in
        ext2) mkfs.ext2 -F "$device" ;;
        ext3) mkfs.ext3 -F "$device" ;;
        ext4) mkfs.ext4 -F "$device" ;;
        btrfs) mkfs.btrfs -f "$device" ;;
        xfs) mkfs.xfs -f "$device" ;;
        *) die "Unsupported filesystem '$filesystem' for $target." ;;
    esac

    mkdir -p -- "$target"
    if [[ "$filesystem" == "btrfs" ]]; then
        if [[ -n "$mount_options" ]]; then
            mount_install -t btrfs -o "$mount_options" "$device" "$target"
        else
            mount_install -t btrfs "$device" "$target"
        fi
    else
        mount_install "$device" "$target"
    fi
}

unmount_install() {
    local i
    for ((i=${#installation_mounts[@]}-1; i>=0; i--)); do
        if mountpoint -q -- "${installation_mounts[i]}"; then
            if ! umount -- "${installation_mounts[i]}"; then
                echo "Warning: could not unmount ${installation_mounts[i]}." >&2
            fi
        fi
    done
    installation_mounts=()
}

cleanup_install() {
    local exit_status=$?

    if [[ "$installation_started" == "true" ]]; then
        # Remove only this installer's unique staging directory; never overwrite
        # or delete files that may already belong to an existing target system.
        if [[ "$staged_config" == "true" && -n "$stage_dir_host" ]]; then
            case "$stage_dir_host" in
                /mnt/.albi-installer.*) rm -rf -- "$stage_dir_host" || true ;;
            esac
        fi
        unmount_install

        # Close child encrypted mappings before the root mapping.
        if [[ -n "${home_part_encrypted_name:-}" ]]; then
            cryptsetup close "$home_part_encrypted_name" 2>/dev/null || true
        fi
        if [[ -n "${root_part_encrypted_name:-}" ]]; then
            cryptsetup close "$root_part_encrypted_name" 2>/dev/null || true
        fi
    fi

    # Delete the source config only after a successful installation. On failure,
    # retain it so the user can inspect or correct the settings before retrying.
    if [[ "$config_cleanup_armed" == "true" && "$installation_successful" == "true" ]]; then
        rm -f -- "$config_path" || echo "Warning: could not remove $config_path." >&2
    fi

    if [[ -n "$mirror_tmp" ]]; then
        rm -f -- "$mirror_tmp" || true
    fi
    if [[ -n "$installer_tmpdir" && -d "$installer_tmpdir" ]]; then
        rm -rf -- "$installer_tmpdir" || true
    fi

    return "$exit_status"
}

interrupt_handler() {
    echo "Interruption signal received. Aborting... "
    exit 130
}

trap interrupt_handler SIGINT SIGTERM
trap cleanup_install EXIT

# =============================================================================
# Configuration parsing
# =============================================================================
# Read the existing key=value format without xargs changing passwords or quotes.
# Values may be quoted and contain spaces, #, $, backslashes or = characters.
read_config() {
    local path="$1" line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue

        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*([^[:space:]#]+)[[:space:]]*(#.*)?$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        else
            echo 'Error: invalid configuration entry (expected key="value").' >&2
            return 1
        fi
        case "$key" in
            root_part_filesystem|separate_home_part_filesystem|separate_boot_part_filesystem|\
            root_part|separate_home_part|separate_boot_part|\
            luks_encryption|luks_passphrase|efi_part|efi_part_mountpoint|grub_install_fallback|grub_disk|\
            kernel_variant|mirror_location|timezone|hostname|username|full_username|password|\
            language|tty_keyboard_layout|install_pipewire|install_nm|gpu|de|install_cups|create_swap) ;;
            *)
                echo "Error: unsupported configuration key: $key" >&2
                return 1
                ;;
        esac
        printf -v "$key" '%s' "$value"
    done < "$path"
}

# =============================================================================
# Configuration review and default generation
# =============================================================================
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
        exit 1
    else
        read_config "$cwd/config.conf"
        hostname="${hostname,,}"
        clear
        echo "Please review these installation settings."
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

        if [[ "$luks_encryption" == "yes" ]]; then
            echo "Disk encryption is enabled for the root partition"
            if [[ "$separate_home_part" != "none" ]]; then
                echo "Separate /home partition: encrypted with the same passphrase as / (unlocked during the same boot stage)."
            fi
            if [[ "$separate_boot_part" != "none" ]]; then
                echo "Note: separate /boot partition is not encrypted (required for this boot setup)."
            fi
            if [[ "$boot_mode" == "UEFI" ]]; then
                echo "Note: the EFI System Partition is not encrypted."
            fi
        else
            echo "Disk encryption is disabled; root and any separate /home partition will remain unencrypted."
        fi

        if [[ "$boot_mode" == "UEFI" ]]; then
            echo "EFI partition: $efi_part at $efi_part_mountpoint"
            echo "Install GRUB to UEFI fallback path: ${grub_install_fallback-yes}"
        else
            echo "GRUB disk: $grub_disk"
        fi

        echo "Kernel variant: $kernel_variant"
        echo "Mirror country: $mirror_location"
        echo "Time zone: $timezone"
        echo "Hostname: $hostname"
        echo "Username: $username"
        echo "LVM: existing logical volumes may be selected; ALBI will not create or resize PVs, VGs, or LVs."

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

        echo ""
        echo "A final destructive-operation summary and explicit confirmation will be shown after preflight checks."

        hostname="${hostname,,}"
    fi
else
    touch config.conf
    cat <<EOF > config.conf
## Installation Configuration

### Formatting (will be ignored even if not set to "none", unless the corresponding partition is enabled)
root_part_filesystem="btrfs"  #### Filesystem for the / partition
separate_home_part_filesystem="none"  #### Filesystem for the /home partition
separate_boot_part_filesystem="btrfs"  #### Filesystem for the /boot partition

### Mounting
root_part="/dev/sdX#"  #### Device or existing LVM logical volume for / (e.g. /dev/VG/root)
separate_home_part="none"  #### Device or existing LVM logical volume for /home (e.g. /dev/VG/home)
separate_boot_part="/dev/sdX#"  #### Device or existing LVM logical volume for /boot (e.g. /dev/VG/boot)

### Encryption
luks_encryption="yes"  #### Encrypt / and, when separate, /home with the same passphrase (yes/no); LUKS is placed on selected devices/LVs; /boot remains unencrypted
luks_passphrase=""  #### Passphrase for encryption
EOF

if [[ "$boot_mode" == "UEFI" ]]; then
    echo "" >> config.conf
    echo "### EFI partition settings" >> config.conf
    echo "efi_part=\"/dev/sdX#\"  #### EFI partition path" >> config.conf
    echo "efi_part_mountpoint=\"/boot/efi\"  #### EFI partition mountpoint" >> config.conf
    echo "grub_install_fallback=\"yes\"  #### Install GRUB to the UEFI fallback boot path (yes/no)" >> config.conf
else
    echo "" >> config.conf
    echo "### GRUB installation disk settings" >> config.conf
    echo "grub_disk=\"/dev/sdX\"  #### Disk for GRUB installation" >> config.conf
fi

cat <<EOF >> config.conf
### Kernel Variant
kernel_variant="normal"  #### Kernel variant (normal/lts/zen)

### Mirror Servers Location
mirror_location="none"  #### Country for mirror servers (comma-separated list of countries or none)

### Timezone
timezone="Europe/Prague"  #### System time zone

### Hostname and User
EOF
hostname_default=""
if command -v dmidecode >/dev/null 2>&1; then
    hostname_default=$(dmidecode -s system-product-name 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-63 | sed -E 's/-+$//' || true)
fi
[[ -n "$hostname_default" ]] || hostname_default="archlinux"
printf 'hostname="%s"  #### Machine name\n' "$hostname_default" >> config.conf
cat <<EOF >> config.conf
username="changeme"  #### User name
full_username="Changeme Please"  #### Full user name (optional - leave empty if you don't want it)
password=""  #### User password

### Locales
language="en_US.UTF-8"  #### System language
tty_keyboard_layout="us"  #### TTY keyboard layout

### Software Selection
install_pipewire="yes"  #### Install PipeWire (yes/no)
install_nm="yes"  #### Install NetworkManager (yes/no) (warning: without NM you won't have the Internet connection)
gpu="amd"  #### GPU driver (amd/intel/nvidia/other/none/intel+nvidia/amd+nvidia/intel+amd/amd+amd)
de="gnome"  #### Desktop environment (gnome/plasma/xfce/none)
install_cups="yes"  #### Install CUPS (yes/no)

### Swap
create_swap="yes"  #### Create swap (yes/no)
EOF

chmod 600 config.conf
echo "config.conf was generated successfully. Edit it to customize the installation."
exit
fi

# =============================================================================
# Configuration and environment validation
# =============================================================================
passwd_length=${#password}
username_length=${#username}
luks_passphrase_length=${#luks_passphrase}

echo "Checking the Internet connection..."
if ! ping -c 4 8.8.8.8 > /dev/null 2>&1; then
    if ! ping -c 4 1.1.1.1 > /dev/null 2>&1; then
        echo "Error: no Internet connection."
        exit 1
    fi
fi

if ! ping -c 4 google.com > /dev/null 2>&1; then
    if ! ping -c 4 one.one.one.one > /dev/null 2>&1; then
        echo "Error: DNS isn't working. Check your network configuration"
        exit 1
    fi
fi

if ! [[ $install_nm == "yes" || $install_nm == "no" ]]; then
    echo "Error: invalid value for the NetworkManager installation settings: $install_nm"
    exit 1
fi

if ! [[ "$kernel_variant" == "normal" || "$kernel_variant" == "lts" || "$kernel_variant" == "zen" ]]; then
    echo "Error: invalid value for the kernel variant: $kernel_variant"
    exit 1
fi

if [[ "$passwd_length" == 0 ]]; then
    echo "Error: user password not set."
    exit 1
fi

if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "The username is incorrect. It can't begin with a number nor with an uppercase character."
fi

hostname="${hostname,,}"
if ! [[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    die "Invalid hostname '$hostname'. Use 1-63 lowercase letters, numbers, and internal hyphens."
fi

if [[ "$timezone" == /* || "$timezone" == *".."* || ! -f "/usr/share/zoneinfo/$timezone" ]]; then
    die "Invalid timezone: $timezone"
fi
timezone_real=$(readlink -f -- "/usr/share/zoneinfo/$timezone") || die "Cannot resolve timezone: $timezone"
case "$timezone_real" in
    /usr/share/zoneinfo/*) ;;
    *) die "Timezone resolves outside /usr/share/zoneinfo: $timezone" ;;
esac

if ! [[ "$install_pipewire" == "yes" || "$install_pipewire" == "no" ]]; then
    echo "Error: invalid value for the PipeWire installation seting: $install_pipewire"
    exit 1
fi

if ! [[ "$install_cups" == "yes" || "$install_cups" == "no" ]]; then
    echo "Error: invalid value for the CUPS installation setting: $install_cups"
    exit 1
fi

if ! [[ "$gpu" == "amd" || "$gpu" == "intel" || "$gpu" == "nvidia" || "$gpu" == "other" || "$gpu" == "none" || "$gpu" == "intel+nvidia" || "$gpu" == "amd+nvidia" || "$gpu" == "intel+amd" || "$gpu" == "amd+amd" ]]; then
    echo "Error: invalid value for the GPU driver: $gpu"
    echo "Supported GPU values: amd, intel, nvidia, other"
    echo "Supported hybrid GPU values: intel+nvidia, amd+nvidia, intel+amd, amd+amd"
    exit 1
fi

if [[ "$gpu" == "none" ]]; then
    if ! [[ "$de" == "none" ]]; then
        echo "Error: desktop environment requires a GPU driver to be installed."
        exit 1
    fi
fi

if ! [[ "$de" == "gnome" || "$de" == "plasma" || "$de" == "xfce" || "$de" == "none" ]]; then
    echo "Error: invalid value for the desktop environment: $de"
    exit 1
fi

if ! [[ "$luks_encryption" == "yes" || "$luks_encryption" == "no" ]]; then
    echo "Error: invalid value for disk encryption: $luks_encryption"
    exit 1
fi

if [[ "$luks_encryption" == "yes" ]]; then
    if [[ "$luks_passphrase_length" == 0 ]]; then
        echo "Error: the encryption passphrase not set."
        exit 1
    fi
fi

if ! [[ "$create_swap" == "yes" || "$create_swap" == "no" ]]; then
    echo "Error: invalid value for the swap creation question."
    exit 1
fi

if [[ "$boot_mode" == "UEFI" ]]; then
    if ! [[ "$efi_part_mountpoint" == "/boot/efi" || "$efi_part_mountpoint" == "/efi" ]]; then
        echo "Error: invalid EFI partition mount point detected: $efi_part_mountpoint"
        echo "For maximized system compatibility, ALBI only supports the following mount points: /boot/efi (recommended) and /efi."
        exit 1
    fi
    if ! [[ "${grub_install_fallback-yes}" == "yes" || "${grub_install_fallback-yes}" == "no" ]]; then
        echo "Error: invalid GRUB fallback option: $grub_install_fallback (expected yes/no)."
        exit 1
    fi
fi

if ! [[ "$language" =~ ^[A-Za-z0-9_@.+-]+$ ]]; then
    die "Invalid locale name: $language"
fi
if ! awk -v wanted="$language" '
    {
        candidate = $0
        sub(/^[[:space:]]*#[[:space:]]*/, "", candidate)
        sub(/^[[:space:]]*/, "", candidate)
        split(candidate, fields, /[[:space:]]+/)
        if (fields[1] == wanted) found = 1
    }
    END { exit !found }
' /etc/locale.gen; then
    die "Selected locale was not found in /etc/locale.gen: $language"
fi

if ! localectl list-keymaps | grep -Fxq "$tty_keyboard_layout"; then
    echo "Selected TTY keymap isn't available: $tty_keyboard_layout"
    exit 1
fi

# Check all host-side utilities before any partition can be formatted.
required_commands=(
    ping mount mountpoint umount findmnt lsblk readlink blkid swapon
    grep awk sed tr cut basename head mktemp install mkdir cp rm chmod cat
    pacman pacstrap genfstab arch-chroot localectl
)
[[ "$luks_encryption" == "yes" ]] && required_commands+=(cryptsetup)
[[ "$mirror_location" != "none" ]] && required_commands+=(reflector)
[[ "$boot_mode" == "UEFI" ]] && required_commands+=(mkfs.fat)
filesystem_checks=()
[[ "$root_part" != "none" ]] && filesystem_checks+=("$root_part_filesystem")
[[ "$separate_home_part" != "none" ]] && filesystem_checks+=("$separate_home_part_filesystem")
[[ "$separate_boot_part" != "none" ]] && filesystem_checks+=("$separate_boot_part_filesystem")
for filesystem in "${filesystem_checks[@]}"; do
    case "$filesystem" in
        ext2) required_commands+=(mkfs.ext2) ;;
        ext3) required_commands+=(mkfs.ext3) ;;
        ext4) required_commands+=(mkfs.ext4) ;;
        btrfs) required_commands+=(mkfs.btrfs btrfs) ;;
        xfs) required_commands+=(mkfs.xfs) ;;
        none) ;;
    esac
done

# Detect existing LVM targets. ALBI only activates existing volume groups and
# formats selected logical volumes; it never creates, removes, or resizes PVs,
# VGs, or LVs. For an inactive LV, use the canonical /dev/<VG>/<LV> path so
# the required VG can be activated without guessing mapper-name escaping.
mount_partition=$(findmnt -rn -M /mnt -o SOURCE || true)
mount_partition="${mount_partition%%\[*}"
lvm_activation_needed="false"
selected_storage_targets=()
active_lvm_targets=()
[[ "$root_part" != "none" ]] && selected_storage_targets+=("$root_part")
[[ "$separate_home_part" != "none" ]] && selected_storage_targets+=("$separate_home_part")
[[ "$separate_boot_part" != "none" ]] && selected_storage_targets+=("$separate_boot_part")

for storage_target in "${selected_storage_targets[@]}"; do
    if [[ -b "$storage_target" ]]; then
        storage_type=$(lsblk -dn -o TYPE "$storage_target" 2>/dev/null | tr -d '[:space:]')
        if [[ "$storage_type" == "lvm" ]]; then
            lvm_activation_needed="true"
            lvm_used="yes"
            active_lvm_targets+=("$storage_target")
        elif [[ "$storage_type" == "crypt" ]] &&
             lsblk -s -nr -o TYPE "$storage_target" 2>/dev/null | grep -Fxq 'lvm'; then
            die "$storage_target is an already-open encrypted mapping backed by LVM. Select its underlying /dev/<VG>/<LV> logical volume instead; ALBI creates LUKS on selected LVs itself and does not support LVM-on-LUKS or pre-existing encrypted-LV mappings."
        fi
    elif [[ "$storage_target" =~ ^/dev/([^/]+)/([^/]+)$ && "$storage_target" != /dev/mapper/* ]]; then
        # A direct /dev/VG/LV path lets ALBI identify and activate an inactive VG.
        candidate_vg="${BASH_REMATCH[1]}"
        case "$candidate_vg" in
            disk|dri|pts) ;;
            *)
                [[ "$candidate_vg" =~ ^[A-Za-z0-9+_.-]+$ ]] ||
                    die "Invalid volume-group name in logical-volume path: $candidate_vg"
                lvm_activation_needed="true"
                lvm_used="yes"
                lvm_volume_groups["$candidate_vg"]=1
                lvm_target_groups["$storage_target"]="$candidate_vg"
                ;;
        esac
    elif [[ "$storage_target" == /dev/mapper/* ]]; then
        die "Device-mapper path $storage_target is not active or does not exist. For an inactive LVM logical volume, use /dev/<VG>/<LV> so ALBI can activate its existing volume group."
    fi
done

# An already-mounted root can itself reside on an LV, even when root_part=none.
if [[ "$root_part" == "none" && -b "$mount_partition" ]]; then
    root_mount_chain=$(lsblk -s -nr -p -o NAME,TYPE "$mount_partition" 2>/dev/null || true)
    if awk '$2 == "crypt" { crypt=1 } $2 == "lvm" { lvm=1 } END { exit !(crypt && lvm) }' <<< "$root_mount_chain"; then
        die "The already-mounted root at /mnt is an encrypted mapping backed by LVM. This installer mode supports creating LUKS inside a selected existing LV, not reusing an already-encrypted LVM root. Select an unencrypted LV as root_part and let ALBI format it, or use another installation method."
    fi
    while read -r ancestor_device ancestor_type; do
        if [[ "$ancestor_type" == "lvm" ]]; then
            lvm_used="yes"
            lvm_activation_needed="true"
            active_lvm_targets+=("$ancestor_device")
        fi
    done <<< "$root_mount_chain"
fi

if [[ "$lvm_activation_needed" == "true" ]]; then
    required_commands+=(vgscan vgchange vgs lvs pvs)
fi

for required_command in "${required_commands[@]}"; do
    command -v "$required_command" >/dev/null 2>&1 ||
        die "Required command '$required_command' is missing from the installation environment."
done

if [[ "$lvm_activation_needed" == "true" ]]; then
    vgscan --mknodes || die "Could not scan existing LVM metadata."

    # Resolve volume groups for already-active LV paths after lvm2 utilities
    # have been checked. This also handles /dev/mapper and /dev/dm-* aliases.
    for active_lv in "${active_lvm_targets[@]}"; do
        active_vg=$(lvs --noheadings --options vg_name "$active_lv" 2>/dev/null | awk 'NF { print $1; exit }' || true)
        [[ -n "$active_vg" ]] || die "Could not identify the volume group for existing logical volume $active_lv."
        lvm_volume_groups["$active_vg"]=1
        lvm_target_groups["$active_lv"]="$active_vg"
    done

    ((${#lvm_volume_groups[@]})) ||
        die "An LVM target was detected, but ALBI could not identify its existing volume group. Use /dev/<VG>/<LV> for inactive logical volumes."

    for candidate_vg in "${!lvm_volume_groups[@]}"; do
        vgs "$candidate_vg" >/dev/null 2>&1 ||
            die "Existing LVM volume group '$candidate_vg' was not found."

        # This mode supports plain PVs followed by VG/LV and optional LUKS on
        # the selected LV. It deliberately rejects LVM-on-LUKS and RAID PVs,
        # which need additional initramfs unlock/assembly configuration.
        vg_pvs=$(pvs --noheadings --options pv_name --select "vg_name=$candidate_vg" 2>/dev/null) ||
            die "Could not list physical volumes for volume group '$candidate_vg'."
        [[ -n "${vg_pvs//[[:space:]]/}" ]] ||
            die "Volume group '$candidate_vg' has no readable physical volumes."
        while IFS= read -r pv_device; do
            [[ -n "$pv_device" ]] || continue
            pv_real=$(readlink -f -- "$pv_device")
            pv_type=$(lsblk -dn -o TYPE "$pv_real" 2>/dev/null | tr -d '[:space:]')
            case "$pv_type" in
                part|disk) ;;
                *) die "Volume group '$candidate_vg' uses $pv_device (device type: ${pv_type:-unknown}) as a physical volume. ALBI supports existing LVM groups backed directly by ordinary disks/partitions; LVM-on-LUKS and RAID-backed PVs are not supported." ;;
            esac
        done <<< "$(printf '%s\n' "$vg_pvs" | awk 'NF { print $1 }')"

        vgchange -ay "$candidate_vg" ||
            die "Could not activate existing LVM volume group '$candidate_vg'."
    done

    # Confirm that each configured LVM target now resolves to an actual LV.
    for storage_target in "${!lvm_target_groups[@]}"; do
        [[ -b "$storage_target" ]] ||
            die "Logical volume $storage_target did not become available after activating volume group ${lvm_target_groups[$storage_target]}."
        storage_type=$(lsblk -dn -o TYPE "$storage_target" | tr -d '[:space:]')
        [[ "$storage_type" == "lvm" ]] ||
            die "$storage_target is not an LVM logical volume (detected block-device type: ${storage_type:-unknown})."
    done
fi

# =============================================================================
# Storage preflight: device, filesystem, and boot-layout validation
# =============================================================================
declare -A used_partitions

check_partition() {
    local mount_name="$1"
    local partition="$2"

    [[ "$partition" == "none" ]] && return

    if ! [[ -b "$partition" ]]; then
        echo "Error: partition $partition selected for $mount_name is not a valid block device."
        exit 1
    fi

    local real_partition device_type current_id prior prior_id swap_device swap_real swap_id signature_type
    real_partition=$(readlink -f "$partition")
    current_id=$(lsblk -dn -o MAJ:MIN "$real_partition" | tr -d '[:space:]')

    signature_type=$(blkid -s TYPE -o value "$real_partition" 2>/dev/null || true)
    if [[ "$signature_type" == "LVM2_member" ]]; then
        die "$partition is an LVM physical volume (PV). Select an existing logical volume such as /dev/<VG>/<LV>; ALBI will not format PVs."
    fi

    device_type=$(lsblk -dn -o TYPE "$real_partition" | tr -d '[:space:]')
    if [[ "$device_type" == "lvm" ]]; then
        lvm_used="yes"
    fi
    case "$device_type" in
        part|lvm|crypt|raid*) ;;
        *) echo "Error: $partition for $mount_name is not a partition or logical volume (type: $device_type)."; exit 1 ;;
    esac
    if lsblk -nl -o MOUNTPOINTS "$real_partition" | grep -q '[^[:space:]]'; then
        die "$partition for $mount_name (or a child device) is already mounted or in use."
    fi

    while IFS= read -r swap_device; do
        [[ -n "$swap_device" && -b "$swap_device" ]] || continue
        swap_real=$(readlink -f -- "$swap_device")
        swap_id=$(lsblk -dn -o MAJ:MIN "$swap_real" | tr -d '[:space:]')
        if [[ "$swap_id" == "$current_id" ]] || \
           lsblk -nl -o MAJ:MIN "$real_partition" | grep -Fxq "$swap_id" || \
           lsblk -nl -o MAJ:MIN "$swap_real" | grep -Fxq "$current_id"; then
            die "$partition for $mount_name overlaps active swap device $swap_device. Disable swap before continuing."
        fi
    done < <(swapon --show --noheadings --raw --output NAME 2>/dev/null || true)

    if [[ -n "${used_partitions[$real_partition]:-}" ]]; then
        echo "Error: partition $partition is selected for both ${used_partitions[$real_partition]} and $mount_name."
        exit 1
    fi

    for prior in "${!used_partitions[@]}"; do
        prior_id=$(lsblk -dn -o MAJ:MIN "$prior")
        if lsblk -nl -o MAJ:MIN "$prior" | grep -Fxq "$current_id" || \
           lsblk -nl -o MAJ:MIN "$real_partition" | grep -Fxq "$prior_id"; then
            echo "Error: $partition and $prior overlap as parent/child devices."
            exit 1
        fi
    done

    used_partitions["$real_partition"]="$mount_name"
}

check_partition "/" "$root_part"
check_partition "/home" "$separate_home_part"
check_partition "/boot" "$separate_boot_part"

validate_filesystem() {
    local mount_name="$1"
    local partition="$2"
    local filesystem="$3"

    [[ "$partition" == "none" ]] && return 0
    case "$filesystem" in
        ext2|ext3|ext4|btrfs|xfs) ;;
        *) die "Unsupported filesystem '$filesystem' for $mount_name on $partition." ;;
    esac
}

validate_filesystem "/" "$root_part" "$root_part_filesystem"
validate_filesystem "/home" "$separate_home_part" "$separate_home_part_filesystem"
validate_filesystem "/boot" "$separate_boot_part" "$separate_boot_part_filesystem"

if [[ "$boot_mode" == "UEFI" ]]; then
    check_partition "EFI" "$efi_part"

    efi_device_type=$(lsblk -dn -o TYPE "$efi_part" | tr -d '[:space:]')
    [[ "$efi_device_type" == "part" ]] || die "EFI device must be a partition, not $efi_device_type: $efi_part"
    efi_parent_name=$(lsblk -dn -o PKNAME "$efi_part" | tr -d '[:space:]')
    [[ -n "$efi_parent_name" ]] || die "Could not determine the disk containing EFI partition $efi_part."
    efi_disk="/dev/$efi_parent_name"
    efi_disk_pttype=$(lsblk -dn -o PTTYPE "$efi_disk" | tr -d '[:space:]')
    efi_partition_type=$(lsblk -dn -o PARTTYPE "$efi_part" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$efi_disk_pttype" in
        gpt)
            [[ "$efi_partition_type" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] ||
                die "EFI partition $efi_part does not have the GPT EFI System Partition type GUID."
            ;;
        dos)
            [[ "$efi_partition_type" == "0xef" || "$efi_partition_type" == "ef" ]] ||
                die "EFI partition $efi_part does not have the MBR EFI (0xEF) partition type."
            ;;
        *)
            die "Unsupported partition table '$efi_disk_pttype' for EFI disk $efi_disk."
            ;;
    esac
else
    if [[ "$(lsblk -dn -o TYPE "$grub_disk" 2>/dev/null | tr -d '[:space:]')" != "disk" ]]; then
        die "GRUB installation target must be a whole disk: $grub_disk"
    fi
    grub_disk_pttype=$(lsblk -dn -o PTTYPE "$grub_disk" | tr -d '[:space:]')
    if [[ "$grub_disk_pttype" == "gpt" ]]; then
        bios_boot_partition_found="false"
        while read -r candidate_parttype candidate_type; do
            candidate_parttype="${candidate_parttype,,}"
            if [[ "$candidate_type" == "part" && "$candidate_parttype" == "21686148-6449-6e6f-744e-656564454649" ]]; then
                bios_boot_partition_found="true"
                break
            fi
        done < <(lsblk -nl -o PARTTYPE,TYPE "$grub_disk")
        [[ "$bios_boot_partition_found" == "true" ]] ||
            die "BIOS installation to GPT disk $grub_disk requires a BIOS Boot Partition (EF02 / 21686148-6449-6e6f-744e-656564454649)."
    fi
fi

if [[ "$luks_encryption" == "yes" && "$root_part" == "none" ]]; then
    die "LUKS encryption requires a selected root partition."
fi
if [[ "$luks_encryption" == "yes" && "$separate_boot_part" == "none" ]]; then
    die "LUKS encryption requires a separate, unencrypted /boot partition with this GRUB configuration."
fi
if [[ "$boot_mode" == "UEFI" && "$separate_boot_part" == "$efi_part" ]]; then
    die "The EFI System Partition must not also be selected as the separate /boot partition."
fi

boot_part_exists="false"
home_part_exists="false"
[[ "$separate_boot_part" != "none" ]] && boot_part_exists="true"
[[ "$separate_home_part" != "none" ]] && home_part_exists="true"

# =============================================================================
# Mirror preflight (safe to run before formatting)
# =============================================================================
if [[ "$mirror_location" != "none" ]]; then
    mirror_tmp=$(mktemp) || die "Could not create a temporary mirror list."
    if ! reflector --country "$mirror_location" --latest 20 --protocol https --sort rate --save "$mirror_tmp"; then
        rm -f -- "$mirror_tmp"
        die "Reflector could not generate a mirror list for: $mirror_location"
    fi
    if [[ ! -s "$mirror_tmp" ]]; then
        rm -f -- "$mirror_tmp"
        die "Reflector returned no usable mirrors for: $mirror_location"
    fi
fi

# =============================================================================
# Destructive-operation summary and mountpoint preflight
# =============================================================================
# Show the exact devices that will be formatted before asking for final approval.
format_targets=()
modified_targets=()
if [[ "$root_part" != "none" ]]; then
    if [[ "$luks_encryption" == "yes" ]]; then
        format_targets+=("/: LUKS + $root_part_filesystem on $root_part")
    else
        format_targets+=("/: $root_part_filesystem on $root_part")
    fi
fi
if [[ "$separate_home_part" != "none" ]]; then
    if [[ "$luks_encryption" == "yes" ]]; then
        format_targets+=("/home (LUKS + $separate_home_part_filesystem): $separate_home_part")
    else
        format_targets+=("/home: $separate_home_part")
    fi
fi
[[ "$separate_boot_part" != "none" ]] && format_targets+=("/boot: $separate_boot_part")

if [[ "$boot_mode" == "UEFI" ]]; then
    efi_part_filesystem=$(blkid -s TYPE -o value "$efi_part" 2>/dev/null || true)
    format_targets+=("EFI (always reformatted as FAT32): $efi_part [currently: ${efi_part_filesystem:-unformatted}]")
fi

if [[ "$root_part" != "none" && -n "$mount_partition" ]]; then
    die "/mnt is already mounted, but a different root partition was selected. Unmount /mnt first."
fi
if [[ "$root_part" == "none" && -z "$mount_partition" ]]; then
    die "No root partition is selected and nothing is mounted at /mnt."
fi

if [[ "$lvm_used" == "yes" ]]; then
    echo "Existing LVM detected. ALBI will not create, remove, or resize any PV, VG, or LV."
    if (( ${#lvm_volume_groups[@]} )); then
        printf 'Volume groups to activate: %s\n' "${!lvm_volume_groups[*]}"
    fi
fi
if (( ${#format_targets[@]} )); then
    printf 'WARNING: These devices will be ERASED and formatted:\n'
    printf '  %s\n' "${format_targets[@]}"
else
    echo "No partition filesystems are scheduled for formatting."
fi
if [[ "$root_part" == "none" ]]; then
    echo "Existing installation target mounted at /mnt: $mount_partition"
fi
if [[ "$boot_mode" == "UEFI" ]]; then
    modified_targets+=("EFI boot files will be written to the freshly formatted FAT32 partition $efi_part at $efi_part_mountpoint")
fi
if [[ "$boot_mode" == "BIOS" ]]; then
    modified_targets+=("GRUB will be installed to the boot sector of $grub_disk")
fi
if (( ${#modified_targets[@]} )); then
    printf 'The following existing boot locations will also be modified:\n'
    printf '  %s\n' "${modified_targets[@]}"
fi

mountpoint_targets=()
if [[ "$separate_home_part" != "none" || ( "$root_part" != "none" && "$root_part_filesystem" == "btrfs" ) ]]; then
    mountpoint_targets+=("/mnt/home")
fi
[[ "$separate_boot_part" != "none" ]] && mountpoint_targets+=("/mnt/boot")
[[ "$boot_mode" == "UEFI" ]] && mountpoint_targets+=("/mnt$efi_part_mountpoint")
for mount_target in "${mountpoint_targets[@]}"; do
    if findmnt -rn -M "$mount_target" >/dev/null 2>&1; then
        die "Target mountpoint $mount_target is already mounted. Unmount it before starting the installation."
    fi
done

printf '\n'
echo "This operation will modify the selected target system and may permanently destroy the listed filesystems."
read -rp "Type ERASE (in uppercase) to authorize the installation: " erase_confirmation
if [[ "$erase_confirmation" != "ERASE" ]]; then
    echo "Confirmation did not match. Aborting without formatting any partitions."
    exit 1
fi

# Apply the pre-generated mirror list only after explicit authorization.
if [[ -n "$mirror_tmp" ]]; then
    install -m 644 "$mirror_tmp" /etc/pacman.d/mirrorlist
    rm -f -- "$mirror_tmp"
    mirror_tmp=""
fi

# Prepare private temporary files and arm credential cleanup only after approval.
installer_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/albi-installer.XXXXXX") || die "Could not create a temporary working directory."
main_script="$installer_tmpdir/main.sh"
tmpfile_script="$installer_tmpdir/tmpfile.sh"
config_cleanup_armed="true"
printf 'lvm_used=%q\n' "$lvm_used" > "$tmpfile_script"

# =============================================================================
# Disk formatting and mount setup
# =============================================================================
installation_started="true"

if [[ "$root_part" != "none" ]]; then
    if [[ -n "$mount_partition" ]]; then
        echo "Error: /mnt is already mounted, however you specified another partition to mount it on."
        exit 1
    else
        if [[ -b "$root_part" ]]; then
            if [[ "$luks_encryption" == "yes" ]]; then
                if [[ "$boot_part_exists" == "true" ]]; then
                    echo "Setting up root encryption..."
                    root_part_orig="$root_part"
                    root_part_encrypted_name="albi-root-${BASHPID}_crypt"
                    printf '%s' "$luks_passphrase" | cryptsetup luksFormat --batch-mode "$root_part_orig" -
                    printf '%s' "$luks_passphrase" | cryptsetup luksOpen "$root_part_orig" "$root_part_encrypted_name" -
                    root_part="/dev/mapper/${root_part_encrypted_name}"
                    printf 'root_part_orig=%q\n' "$root_part_orig" >> "$tmpfile_script"
                    printf 'root_part_encrypted_name=%q\n' "$root_part_encrypted_name" >> "$tmpfile_script"
                else
                    echo "Error: you haven't defined a separate /boot partition. It is needed in order to encrypt the / partition."
                    exit 1
                fi
            fi

            if [[ "$root_part_filesystem" == "ext4" ]]; then
                mkfs.ext4 -F "$root_part"
                mount_install "$root_part" /mnt
            elif [[ "$root_part_filesystem" == "ext3" ]]; then
                mkfs.ext3 -F "$root_part"
                mount_install "$root_part" /mnt
            elif [[ "$root_part_filesystem" == "ext2" ]]; then
                mkfs.ext2 -F "$root_part"
                mount_install "$root_part" /mnt
            elif [[ "$root_part_filesystem" == "btrfs" ]]; then
                mkfs.btrfs -f "$root_part"

                mount_install -t btrfs -o subvolid=5 "$root_part" /mnt
                btrfs subvolume create /mnt/root

                if [[ "$separate_home_part" == "none" ]]; then
                    btrfs subvolume create /mnt/home
                fi

                umount /mnt
                installation_mounts=()

                mount_install -t btrfs -o subvol=root,compress=zstd:1 "$root_part" /mnt

                if [[ "$separate_home_part" == "none" ]]; then
                    mkdir -p /mnt/home
                    mount_install -t btrfs -o subvol=home,compress=zstd:1 "$root_part" /mnt/home
                fi
            elif [[ "$root_part_filesystem" == "xfs" ]]; then
                mkfs.xfs -f "$root_part"
                mount_install "$root_part" /mnt
            else
                echo "Error: wrong filesystem for the / partition: $root_part_filesystem"
                exit 1
            fi
        else
            echo "Error: partition $root_part isn't a valid path - it doesn't exist or isn't accessible."
            exit 1
        fi
    fi
elif [[ "$root_part" == "none" ]]; then
    if ! [[ -n "$mount_partition" ]]; then
        echo "Error: no partition is mounted to / and you didn't define any in the config file."
        exit 1
    fi
fi

if [[ "$home_part_exists" == "true" ]]; then
    if [[ "$luks_encryption" == "yes" ]]; then
        echo "Setting up /home encryption with the same passphrase as root..."
        home_part_orig="$separate_home_part"
        home_part_encrypted_name="albi-home-${BASHPID}_crypt"
        printf '%s' "$luks_passphrase" | cryptsetup luksFormat --batch-mode "$home_part_orig" -
        printf '%s' "$luks_passphrase" | cryptsetup luksOpen "$home_part_orig" "$home_part_encrypted_name" -
        separate_home_part="/dev/mapper/${home_part_encrypted_name}"
        printf 'home_part_orig=%q\n' "$home_part_orig" >> "$tmpfile_script"
        printf 'home_part_encrypted_name=%q\n' "$home_part_encrypted_name" >> "$tmpfile_script"
    fi

    format_and_mount_partition "$separate_home_part_filesystem" "$separate_home_part" /mnt/home "compress=zstd:1"
fi

if [[ "$boot_part_exists" == "true" ]]; then
    format_and_mount_partition "$separate_boot_part_filesystem" "$separate_boot_part" /mnt/boot
fi

if [[ "$boot_mode" == "UEFI" ]]; then
    mkfs.fat -F 32 "$efi_part"
    mkdir -p /mnt"$efi_part_mountpoint"
    mount_install -t vfat "$efi_part" /mnt"$efi_part_mountpoint"
fi

# =============================================================================
# Base-system installation
# =============================================================================
base_packages=(base linux linux-firmware)
if [[ "$kernel_variant" == "lts" ]]; then
    base_packages=(base linux-lts linux-firmware)
elif [[ "$kernel_variant" == "zen" ]]; then
    base_packages=(base linux-zen linux-firmware)
fi
[[ "$lvm_used" == "yes" ]] && base_packages+=(lvm2)
pacstrap -K /mnt "${base_packages[@]}"

generated_fstab="$installer_tmpdir/fstab.generated"
genfstab -U /mnt > "$generated_fstab"
if [[ "$root_part" == "none" && -s /mnt/etc/fstab ]]; then
    merged_fstab="$installer_tmpdir/fstab.merged"
    awk -v generated_file="$generated_fstab" '
        FILENAME == generated_file {
            if ($0 !~ /^[[:space:]]*#/ && NF >= 2) generated_mountpoints[$2] = 1
            next
        }
        /^[[:space:]]*#/ || NF < 2 || !($2 in generated_mountpoints) { print }
    ' "$generated_fstab" /mnt/etc/fstab > "$merged_fstab"
    cat "$generated_fstab" >> "$merged_fstab"
    cat "$merged_fstab" > /mnt/etc/fstab
    rm -f -- "$merged_fstab"
else
    cat "$generated_fstab" > /mnt/etc/fstab
fi
rm -f -- "$generated_fstab"

# =============================================================================
# Build the installed-system configuration script
# =============================================================================
cat > "$main_script" <<'EOFile'
#!/bin/bash

set -Eeo pipefail

# Helpers and configuration loading
die() {
    echo "Error: $*" >&2
    exit 1
}

interrupt_handler() {
    echo "Interruption signal received. Aborting..."
    exit 130
}

trap interrupt_handler SIGINT SIGTERM

# Read the existing key=value format without xargs changing passwords or quotes.
# Values may be quoted and contain spaces, #, $, backslashes or = characters.
read_config() {
    local path="$1" line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue

        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*([^[:space:]#]+)[[:space:]]*(#.*)?$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
        else
            echo 'Error: invalid configuration entry (expected key="value").' >&2
            return 1
        fi
        case "$key" in
            root_part_filesystem|separate_home_part_filesystem|separate_boot_part_filesystem|\
            root_part|separate_home_part|separate_boot_part|\
            luks_encryption|luks_passphrase|efi_part|efi_part_mountpoint|grub_install_fallback|grub_disk|\
            kernel_variant|mirror_location|timezone|hostname|username|full_username|password|\
            language|tty_keyboard_layout|install_pipewire|install_nm|gpu|de|install_cups|create_swap) ;;
            *)
                echo "Error: unsupported configuration key: $key" >&2
                return 1
                ;;
        esac
        printf -v "$key" '%s' "$value"
    done < "$path"
}

config_file="${1:?Missing staged configuration file path}"
tmpfile_file="${2:?Missing staged installer state file path}"
[[ -f "$tmpfile_file" ]] || die "Staged installer state file is missing."
read_config "$config_file"
source "$tmpfile_file"
[[ "$lvm_used" == "yes" || "$lvm_used" == "no" ]] ||
    die "Invalid LVM state in staged installer metadata."
if [[ "$luks_encryption" == "yes" ]]; then
    [[ -n "${root_part_orig:-}" && -n "${root_part_encrypted_name:-}" ]] ||
        die "Encrypted installation is missing its staged root LUKS mapping data."
fi

# Configure timezone, locale, keyboard layout, and hostname.
ln -sf -- "/usr/share/zoneinfo/$timezone" /etc/localtime
systemctl enable systemd-timesyncd
hwclock --systohc

enable_locale() {
    local wanted="$1" locale_gen_tmp
    locale_gen_tmp=$(mktemp)
    awk -v wanted="$wanted" '
        {
            line = $0
            candidate = $0
            sub(/^[[:space:]]*#[[:space:]]*/, "", candidate)
            sub(/^[[:space:]]*/, "", candidate)
            split(candidate, fields, /[[:space:]]+/)
            if (fields[1] == wanted) {
                sub(/^[[:space:]]*#[[:space:]]*/, "", line)
            }
            print line
        }
    ' /etc/locale.gen > "$locale_gen_tmp"
    cat "$locale_gen_tmp" > /etc/locale.gen
    rm -f -- "$locale_gen_tmp"
}
if [[ "$language" != "en_US.UTF-8" ]]; then
    enable_locale "en_US.UTF-8"
fi
enable_locale "$language"
echo "LANG=$language" > /etc/locale.conf
echo "KEYMAP=$tty_keyboard_layout" > /etc/vconsole.conf
echo "$hostname" > /etc/hostname
locale-gen

# Install base packages and enable system services.
pacman -S sudo cryptsetup bluez btrfs-progs dosfstools dnsmasq inetutils xfsprogs base-devel polkit bash-completion nano grub ntfs-3g sshfs exfatprogs usbutils xdg-utils xdg-user-dirs unzip unrar zip 7zip os-prober plymouth man-db --noconfirm

systemctl enable bluetooth

if [[ "$install_nm" == "yes" ]]; then
    pacman -S networkmanager --noconfirm
    systemctl enable NetworkManager
fi

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

cat <<EOF > /etc/hosts
# Static table lookup for hostnames.
# See hosts(5) for details.

# IPv4 loopback
127.0.0.1       localhost

# Local hostname
127.0.1.1       $hostname

# IPv6 loopback
::1             localhost ip6-localhost ip6-loopback

# IPv6 multicast
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Create the user and apply system-wide defaults.
useradd -m "$username"
printf '%s:%s\n' "$username" "$password" | chpasswd
if [[ "$full_username" != "" ]]; then
    usermod -c "$full_username" "$username"
fi

usermod -aG wheel "$username"

sed -i 's/^# include \/usr\/share\/nano\/\*\.nanorc/include \/usr\/share\/nano\/\*\.nanorc/' /etc/nanorc
sed -i '/Color/s/^#//g' /etc/pacman.conf
mkdir -p /etc/sudoers.d
printf '%s\n' 'Defaults pwfeedback' > /etc/sudoers.d/10-pwfeedback
chmod 440 /etc/sudoers.d/10-pwfeedback
sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^# //g' /etc/sudoers
visudo -cf /etc/sudoers

# Install GRUB and verify the selected boot device.
# Verify the normal UEFI entry against the actual GPT EFI partition rather
# than trusting an old NVRAM entry with the same "archlinux" label.
# Exposes arch_efi_bootnum only if both the ESP PARTUUID and EFI path match.
find_arch_efi_entry() {
    local expected_uuid="${1,,}" entries line entry_lower entry_num
    arch_efi_bootnum=""

    entries=$(efibootmgr -v 2>/dev/null) || return 1
    while IFS= read -r line; do
        if [[ "$line" =~ ^Boot([[:xdigit:]]{4})\*[[:space:]]+archlinux[[:space:]] ]]; then
            entry_num="${BASH_REMATCH[1]}"
            entry_lower="${line,,}"
            # efibootmgr may display the loader as /File(\EFI\...) or
            # directly as /\EFI\... depending on its version/firmware.
            if [[ "$entry_lower" == *"gpt,$expected_uuid,"* &&
                  "$entry_lower" == *'\efi\archlinux\grubx64.efi'* ]]; then
                arch_efi_bootnum="${entry_num^^}"
                return 0
            fi
        fi
    done <<< "$entries"
    return 1
}

# Put the verified Arch entry first, retaining every existing entry in BootOrder.
prioritize_arch_efi_entry() {
    local id="$1" current new_order candidate updated_order
    local -a order_entries
    current=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n 1) || current=""
    if [[ ! "$current" =~ ^[[:xdigit:]]{4}(,[[:xdigit:]]{4})*$ ]]; then
        echo 'Warning: could not read UEFI BootOrder; leaving boot priority unchanged.' >&2
        return 0
    fi
    IFS=',' read -r -a order_entries <<< "$current"
    new_order="$id"
    for candidate in "${order_entries[@]}"; do
        [[ "${candidate^^}" == "$id" ]] && continue
        new_order+=",${candidate^^}"
    done
    if [[ "${order_entries[0]^^}" != "$id" ]]; then
        if ! efibootmgr --bootorder "$new_order"; then
            echo 'Warning: firmware refused to set Arch first in UEFI BootOrder.' >&2
        else
            updated_order=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n 1) || updated_order=""
            if [[ "${updated_order%%,*}" != "$id" ]]; then
                echo 'Warning: UEFI BootOrder did not retain Arch as the first entry.' >&2
            fi
        fi
    fi
}

if [[ "$boot_mode" == "UEFI" ]]; then
    # Ensure GRUB is written to the ESP ALBI was told to use.
    esp_device=$(readlink -f -- "$efi_part")
    mounted_esp=$(findmnt -rn -M "$efi_part_mountpoint" -o SOURCE || true)
    if [[ -z "$mounted_esp" || "$(readlink -f -- "$mounted_esp")" != "$esp_device" ]]; then
        echo "Error: $efi_part_mountpoint does not have the selected EFI partition mounted." >&2
        exit 1
    fi

    grub_lvm_args=()
    if [[ "$lvm_used" == "yes" ]]; then
        grub_lvm_args+=(--modules=lvm)
    fi
    if ! grub-install --target=x86_64-efi --efi-directory="$efi_part_mountpoint" --bootloader-id="archlinux" "${grub_lvm_args[@]}"; then
        echo 'Warning: normal GRUB installation failed to register the UEFI entry; retrying file installation without NVRAM.' >&2
        grub-install --target=x86_64-efi --efi-directory="$efi_part_mountpoint" --bootloader-id="archlinux" --no-nvram "${grub_lvm_args[@]}"
    fi
    if [[ ! -s "$efi_part_mountpoint/EFI/archlinux/grubx64.efi" ]]; then
        echo 'Error: normal GRUB EFI executable is missing.' >&2
        exit 1
    fi

    esp_disk=$(lsblk -dn -p -o PKNAME "$esp_device" 2>/dev/null | head -n 1) || esp_disk=""
    esp_part_num=$(lsblk -dn -o PARTN "$esp_device" 2>/dev/null | head -n 1) || esp_part_num=""
    esp_partuuid=$(blkid -s PARTUUID -o value "$esp_device" 2>/dev/null) || esp_partuuid=""
    esp_pttype=$(lsblk -dn -o PTTYPE "$esp_disk" 2>/dev/null || true)
    if [[ "$esp_pttype" == 'gpt' && -n "$esp_partuuid" &&
          "$esp_part_num" =~ ^[0-9]+$ && -b "$esp_disk" ]]; then
        if ! find_arch_efi_entry "$esp_partuuid"; then
            echo 'Normal Arch UEFI entry missing or stale; creating an entry for the selected EFI partition...'
            if ! efibootmgr --create --disk "$esp_disk" --part "$esp_part_num" \
                --label 'archlinux' --loader '\EFI\archlinux\grubx64.efi'; then
                echo 'Warning: firmware did not accept the new Arch UEFI entry.' >&2
            fi
        fi
        if find_arch_efi_entry "$esp_partuuid"; then
            echo "Verified Arch UEFI entry Boot$arch_efi_bootnum for ESP $esp_partuuid."
            prioritize_arch_efi_entry "$arch_efi_bootnum"
        else
            echo 'Warning: could not verify a correct Arch UEFI boot entry in firmware NVRAM.' >&2
            if [[ "${grub_install_fallback-yes}" != 'yes' ]]; then
                echo 'Error: no verified UEFI entry and fallback installation is disabled.' >&2
                exit 1
            fi
        fi
    else
        echo 'Warning: cannot automatically verify UEFI boot entry (requires a GPT EFI partition).' >&2
        if [[ "${grub_install_fallback-yes}" != 'yes' ]]; then
            echo 'Error: no verified UEFI entry and fallback installation is disabled.' >&2
            exit 1
        fi
    fi

    if [[ "${grub_install_fallback-yes}" == "yes" ]]; then
        grub-install --target=x86_64-efi --efi-directory="$efi_part_mountpoint" --removable "${grub_lvm_args[@]}"
    fi
elif [[ "$boot_mode" == "BIOS" ]]; then
    if [[ "$lvm_used" == "yes" ]]; then
        grub-install --target=i386-pc --modules=lvm "$grub_disk"
    else
        grub-install --target=i386-pc "$grub_disk"
    fi
fi

# Verify the separate /home mount and configure encrypted-root boot parameters.
if [[ -n "${home_part_orig:-}" ]] && ! grep -qE '^[^#]+[[:space:]]/home[[:space:]]' /etc/fstab; then
    die "The generated /etc/fstab does not contain the separate /home mount."
fi

if [[ "$luks_encryption" == "yes" ]]; then
    cryptdevice_grub=$(blkid -s UUID -o value "$root_part_orig")
    [[ -n "$cryptdevice_grub" ]] || die "Could not read the LUKS UUID for root partition $root_part_orig."
    crypt_kernel_params="rd.luks.uuid=$cryptdevice_grub"

    if [[ -n "${home_part_orig:-}" ]]; then
        home_crypt_uuid=$(blkid -s UUID -o value "$home_part_orig")
        [[ -n "$home_crypt_uuid" ]] || die "Could not read the LUKS UUID for /home partition $home_part_orig."
        crypt_kernel_params+=" rd.luks.uuid=$home_crypt_uuid"
    fi

    if [[ "$lvm_used" == "yes" ]]; then
        # LVM provides the selected LV device; sd-encrypt then unlocks LUKS
        # formatted inside that LV. This is LUKS-on-LVM, not LVM-on-LUKS.
        sed -i 's/HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block lvm2 plymouth sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    else
        sed -i 's/HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    fi
    if grep -q '^GRUB_CMDLINE_LINUX="' /etc/default/grub; then
        sed -i "s|^\(GRUB_CMDLINE_LINUX=\".*\)\"$|\1 $crypt_kernel_params\"|" /etc/default/grub
    else
        printf 'GRUB_CMDLINE_LINUX="%s"\n' "$crypt_kernel_params" >> /etc/default/grub
    fi
else
    if [[ "$lvm_used" == "yes" ]]; then
        sed -i 's/HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block lvm2 plymouth filesystems fsck)/' /etc/mkinitcpio.conf
    else
        sed -i 's/HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth filesystems fsck)/' /etc/mkinitcpio.conf
    fi
fi

if [[ "$de" != "none" ]]; then
    sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)\(quiet\)\(.*\)"/\1\2 splash\3"/' /etc/default/grub
fi

sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/g' /etc/default/grub

if grep -qE '^[[:space:]]*#?[[:space:]]*GRUB_DISABLE_BOOTNEXT=' /etc/default/grub; then
    sed -i -E 's|^[[:space:]]*#?[[:space:]]*GRUB_DISABLE_BOOTNEXT=.*|GRUB_DISABLE_BOOTNEXT=true|' /etc/default/grub
else
    echo "" >> /etc/default/grub
    echo 'GRUB_DISABLE_BOOTNEXT=true' >> /etc/default/grub
fi

# Install optional audio and graphics packages.
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

# Install the selected desktop environment.
if [[ "$de" == "gnome" ]]; then
    pacman -S gnome noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gnome-tweaks gnome-shell-extensions gnome-browser-connector power-profiles-daemon --noconfirm
    systemctl enable gdm
elif [[ "$de" == "plasma" ]]; then
    pacman -S plasma-meta plasma-login-manager libcec speech-dispatcher qrca noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ufw dolphin konsole power-profiles-daemon ark --noconfirm
    systemctl enable plasmalogin
elif [[ "$de" == "xfce" ]]; then
    pacman -S xfce4 xfce4-goodies xarchiver xfce4-terminal blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs network-manager-applet power-profiles-daemon --noconfirm
    systemctl enable lightdm
fi

# Configure printing support when requested.
if [[ "$install_cups" == yes ]]; then
    pacman -S cups cups-filters ghostscript cups-pk-helper cups-browsed bluez-cups hplip nss-mdns --noconfirm
    systemctl enable cups cups-browsed avahi-daemon
    sed -i "s/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/" /etc/nsswitch.conf
    if [[ "$de" != "none" ]]; then
        pacman -S system-config-printer --noconfirm
    fi
fi

# Configure zram swap when requested.
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

# Rebuild initramfs and verify the resulting boot configuration.
if [[ "$lvm_used" == "yes" ]]; then
    pacman -Q lvm2 >/dev/null 2>&1 || die "LVM targets are in use, but lvm2 is not installed in the target system."
    grep -Eq '^HOOKS=.*(^|[[:space:]])lvm2([[:space:]]|\))' /etc/mkinitcpio.conf ||
        die "LVM targets are in use, but the lvm2 mkinitcpio hook is missing."
fi
mkinitcpio -P

# Check the selected kernel and initramfs before generating the final menu.
case "$kernel_variant" in
    normal) kernel_package="linux" ;;
    lts)    kernel_package="linux-lts" ;;
    zen)    kernel_package="linux-zen" ;;
esac
if [[ ! -s "/boot/vmlinuz-$kernel_package" || ! -s "/boot/initramfs-$kernel_package.img" ]]; then
    echo "Error: kernel or initramfs missing for $kernel_package."
    exit 1
fi
grub-mkconfig -o /boot/grub/grub.cfg
if [[ ! -s /boot/grub/grub.cfg ]]; then
    die "GRUB menu configuration is missing or empty."
fi
if ! grep -Fq "/vmlinuz-$kernel_package" /boot/grub/grub.cfg; then
    die "Generated GRUB configuration does not contain the selected kernel ($kernel_package)."
fi
if ! grep -Fq "/initramfs-$kernel_package.img" /boot/grub/grub.cfg; then
    die "Generated GRUB configuration does not contain the selected initramfs ($kernel_package)."
fi
if [[ "$luks_encryption" == "yes" ]]; then
    grep -Fq "rd.luks.uuid=$cryptdevice_grub" /boot/grub/grub.cfg ||
        die "Generated GRUB configuration is missing the encrypted-root UUID parameter."
    if [[ -n "${home_crypt_uuid:-}" ]]; then
        grep -Fq "rd.luks.uuid=$home_crypt_uuid" /boot/grub/grub.cfg ||
            die "Generated GRUB configuration is missing the encrypted-/home UUID parameter."
    fi
fi
if [[ "$boot_mode" == "UEFI" ]]; then
    [[ -s "$efi_part_mountpoint/EFI/archlinux/grubx64.efi" ]] ||
        die "The GRUB EFI executable is missing from the selected EFI partition."
    if [[ "${grub_install_fallback-yes}" == "yes" ]]; then
        [[ -s "$efi_part_mountpoint/EFI/BOOT/BOOTX64.EFI" ]] ||
            die "The requested UEFI fallback executable was not installed."
    fi
fi

# Remove package cache and temporary installer files.
while :; do
    mapfile -t orphan_packages < <(pacman -Qdtq || true)
    ((${#orphan_packages[@]})) || break
    pacman -Runs --noconfirm "${orphan_packages[@]}"
done
printf 'y\ny\n' | pacman -Scc
rm -f -- "$config_file"
[[ -z "$tmpfile_file" ]] || rm -f -- "$tmpfile_file"
rm -f -- "$0"
exit
EOFile

# =============================================================================
# Stage installer files, run the chroot setup, and clean up
# =============================================================================
stage_dir_host=$(mktemp -d /mnt/.albi-installer.XXXXXX) ||
    die "Could not create a private staging directory in the target root."
stage_dir_chroot="${stage_dir_host#/mnt}"
staged_config="true"

install -m 600 -- "$tmpfile_script" "$stage_dir_host/tmpfile.sh"
install -m 700 -- "$main_script" "$stage_dir_host/main.sh"
install -m 600 -- "$config_path" "$stage_dir_host/config.conf"

if ! arch-chroot /mnt bash "$stage_dir_chroot/main.sh" \
    "$stage_dir_chroot/config.conf" "$stage_dir_chroot/tmpfile.sh"; then
    echo "Error: installation inside chroot failed."
    installation_status=1
else
    installation_status=0
fi

echo "Unmounting installer-mounted partitions..."
if [[ "$staged_config" == "true" ]]; then
    rm -rf -- "$stage_dir_host"
    staged_config="false"
fi
unmount_install

if [[ -n "${home_part_encrypted_name:-}" ]]; then
    cryptsetup close "$home_part_encrypted_name" 2>/dev/null || true
fi
if [[ "$luks_encryption" == "yes" ]]; then
    cryptsetup close "$root_part_encrypted_name" 2>/dev/null || true
fi

installation_started="false"

if [[ "$installation_status" -ne 0 ]]; then
    # Keep the user's config after failure so it can be inspected and reused.
    config_cleanup_armed="false"
    exit "$installation_status"
fi

# The source config contains plaintext credentials. Mark it for deletion by the
# EXIT trap only after chroot setup, staging cleanup and normal unmount attempts.
installation_successful="true"
exit 0