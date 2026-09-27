#!/usr/bin/env bash

CONFIG_KEYS=(root_part_filesystem separate_home_part_filesystem
    separate_boot_part_filesystem separate_var_part_filesystem separate_tmp_part_filesystem
    root_part separate_home_part separate_boot_part separate_var_part separate_tmp_part
    luks_encryption luks_passphrase efi_part efi_part_mountpoint grub_disk
    network_management network_interface network_method network_address network_gateway network_dns
    kernel_variant mirror_location timezone hostname username full_username password
    language tty_keyboard_layout install_pipewire gpu de install_cups create_swap keep_config)
STATE_KEYS=(boot_mode root_uuid root_mapper net_iface)

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
run_checked() {
    local description=$1 status
    shift
    if "$@"; then return 0; else
        status=$?
        printf 'Error: %s failed (status %s).\n' "$description" "$status" >&2
        exit "$status"
    fi
}
report_error() {
    local status=$1 line=$2
    printf 'Error: installation stopped at line %s (status %s).\n' "$line" "$status" >&2
    return "$status"
}

defaults() {
    root_part_filesystem=btrfs
    separate_home_part_filesystem=none
    separate_boot_part_filesystem=btrfs
    separate_var_part_filesystem=none
    separate_tmp_part_filesystem=none
    root_part=/dev/CHANGE_ME_ROOT
    separate_home_part=none
    separate_boot_part=/dev/CHANGE_ME_BOOT
    separate_var_part=none
    separate_tmp_part=none
    luks_encryption=yes
    luks_passphrase=
    efi_part=/dev/CHANGE_ME_EFI
    efi_part_mountpoint=/boot/efi
    grub_disk=/dev/CHANGE_ME_DISK
    network_management=network-manager
    network_interface=auto
    network_method=dhcp
    network_address=
    network_gateway=
    network_dns=1.1.1.1
    kernel_variant=normal
    mirror_location=none
    timezone=Europe/Prague
    hostname=archlinux
    username=changeme
    full_username=
    password=
    language=en_US.UTF-8
    tty_keyboard_layout=us
    install_pipewire=yes
    gpu=amd
    de=plasma
    install_cups=yes
    create_swap=yes
    keep_config=no
    root_uuid=
    root_mapper=albi-root
    net_iface=
}

trim() {
    REPLY=$1
    REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
    REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

parse_value() {
    local input=$1 line=$2 quote char next tail i closed=no
    trim "$input"; input=$REPLY; REPLY=
    quote=${input:0:1}
    if [[ $quote == '"' || $quote == "'" ]]; then
        for ((i=1; i<${#input}; i++)); do
            char=${input:i:1}
            if [[ $char == "$quote" ]]; then closed=yes; break; fi
            if [[ $char == \\ ]]; then
                next=${input:i+1:1}
                if [[ $next == "$quote" || $next == \\ ]]; then
                    char=$next; i=$((i+1))
                fi
            fi
            REPLY+=$char
        done
        [[ $closed == yes ]] || die "Unclosed quote on config line $line."
        tail=${input:i+1}
        [[ $tail =~ ^[[:space:]]*(#.*)?$ ]] || die "Unexpected text on config line $line."
    else
        [[ $input =~ ^([^[:space:]]*)([[:space:]]+\#.*)?$ ]] || die "Quote the value on config line $line."
        REPLY=${BASH_REMATCH[1]}
        [[ $REPLY != \#* ]] || REPLY=
    fi
}

load_config() {
    local path=$1 line key raw count=0 allowed_key found mode owner
    local -A seen=()
    [[ -f $path && ! -L $path ]] || die 'Config must be a regular file, not a symlink.'
    owner=$(stat -c %u -- "$path")
    mode=$(stat -c %a -- "$path")
    [[ $owner == "$EUID" ]] || die 'Config must be owned by the invoking user.'
    (( (8#$mode & 077) == 0 )) || die 'Config contains secrets: run chmod 600 on it first.'
    (( $(stat -c %s -- "$path") <= 65536 )) || die 'Config exceeds 64 KiB.'
    LC_ALL=C tr -d '\000' < "$path" | cmp -s -- "$path" - || die 'Config contains NUL bytes.'
    while IFS= read -r line || [[ -n $line ]]; do
        count=$((count+1)); line=${line%$'\r'}
        trim "$line"; line=$REPLY
        [[ -n $line && $line != \#* ]] || continue
        [[ $line =~ ^([a-z_][a-z0-9_]*)[[:space:]]*=(.*)$ ]] || die "Invalid assignment on config line $count."
        key=${BASH_REMATCH[1]}; raw=${BASH_REMATCH[2]}; found=no
        for allowed_key in "${CONFIG_KEYS[@]}"; do
            if [[ $key == "$allowed_key" ]]; then found=yes; break; fi
        done
        [[ $found == yes ]] || die "Unknown config key on line $count: $key."
        [[ ! ${seen[$key]+present} ]] || die "Duplicate config key: $key."
        seen[$key]=1
        parse_value "$raw" "$count"
        [[ ! $REPLY =~ [[:cntrl:]] ]] || die "Control character in config value on line $count."
        printf -v "$key" '%s' "$REPLY"
    done < "$path"
}

write_config() {
    local key value
    printf '# ALBI settings. Values are literal, not executable shell.\n'
    printf '# Blank passwords are requested securely at installation time.\n'
    printf '# All selected data partitions are ERASED; existing FAT EFI is preserved.\n'
    printf '# luks_encryption encrypts ONLY root; separate data partitions stay plaintext.\n'
    printf '# network_method: dhcp or static; static requires IPv4/CIDR, gateway and DNS.\n'
    for key in "${CONFIG_KEYS[@]}"; do
        value=${!key}
        case $key in password|luks_passphrase) value= ;; esac
        value=${value//\\/\\\\}; value=${value//\"/\\\"}
        printf '%s="%s"\n' "$key" "$value"
    done
}

one_of() {
    local key=$1 candidate
    shift
    for candidate in "$@"; do [[ ${!key} != "$candidate" ]] || return 0; done
    die "Invalid value for $key."
}
valid_ipv4() {
    local address=$1 octet
    local -a octets=()
    [[ $address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do ((10#$octet <= 255)) || return 1; done
}
validate_settings() {
    local key part fs suffix dns prefix address
    for key in luks_encryption install_pipewire install_cups create_swap keep_config; do one_of "$key" yes no; done
    one_of kernel_variant normal lts zen
    one_of gpu amd intel nvidia other none intel-nvidia amd-nvidia intel-amd amd-amd
    one_of de gnome plasma xfce mate cinnamon none
    one_of network_management network-manager systemd-networkd none
    one_of network_method dhcp static
    one_of efi_part_mountpoint /boot/efi /efi
    [[ $gpu != none || $de == none ]] || die 'A desktop requires a GPU driver selection.'
    [[ $username =~ ^[a-z_][a-z0-9_-]{0,31}$ && $username != root ]] || die 'Invalid username.'
    [[ $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die 'Use a hostname of 1–63 letters, digits or hyphens.'
    [[ $full_username != *:* ]] || die 'Full username cannot contain a colon.'
    [[ $timezone =~ ^[a-zA-Z0-9_+-]+(/[a-zA-Z0-9_+-]+)*$ ]] || die 'Invalid time zone path.'
    [[ $language =~ ^[a-zA-Z0-9_@.-]+$ ]] || die 'Invalid locale name.'
    [[ $tty_keyboard_layout =~ ^[a-zA-Z0-9_+.-]+$ ]] || die 'Invalid keymap name.'
    [[ $mirror_location != -* && -n $mirror_location ]] || die 'Invalid mirror country.'
    for suffix in root home boot var tmp; do
        if [[ $suffix == root ]]; then part=root_part; fs=root_part_filesystem
        else part=separate_${suffix}_part; fs=${part}_filesystem; fi
        [[ -n ${!part} ]] || die "$part must be a device path or none."
        if [[ ${!part} != none ]]; then
            [[ ${!part} == /dev/* && ${!part} != *CHANGE_ME* && ${!part} != *'#'* ]] || die "Set a real device path for $part."
            one_of "$fs" ext2 ext3 ext4 btrfs xfs
        fi
    done
    if [[ $luks_encryption == yes ]]; then
        [[ $root_part != none ]] || die 'For an already mounted root, set luks_encryption=no; ALBI cannot infer its encryption setup.'
        [[ $separate_boot_part != none ]] || die 'Root encryption requires a separate unencrypted /boot partition.'
    fi
    if [[ $network_management == systemd-networkd ]]; then
        [[ $de == none ]] || die 'Use network-manager with a desktop environment.'
        [[ $network_interface == auto || $network_interface =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || die 'Invalid network_interface.'
        if [[ $network_method == static ]]; then
            [[ $network_address == */* ]] || die 'Static network_address must include an IPv4 prefix.'
            address=${network_address%/*}; prefix=${network_address##*/}
            valid_ipv4 "$address" || die 'Invalid static IPv4 address.'
            [[ $prefix =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || die 'Invalid IPv4 prefix.'
            valid_ipv4 "$network_gateway" || die 'Invalid static IPv4 gateway.'
            [[ -n $network_dns ]] || die 'Set at least one IPv4 DNS server.'
            for dns in $network_dns; do valid_ipv4 "$dns" || die 'Invalid IPv4 DNS server.'; done
        fi
    fi
}

require_commands() {
    local command
    for command in "$@"; do command -v "$command" >/dev/null || die "Required command is missing: $command."; done
}
block_id() { lsblk -dnro MAJ:MIN -- "$1"; }
block_type() { lsblk -dnro TYPE -- "$1"; }
is_block() { [[ -b $1 ]]; }
assert_unused() {
    local device=$1 allowed_mount=${2:-} mounts mounted_at ids id swap swapid holder
    mounts=$(lsblk -nro MOUNTPOINTS -- "$device")
    while IFS= read -r mounted_at; do
        trim "$mounted_at"; mounted_at=$REPLY
        [[ -z $mounted_at || ( -n $allowed_mount && $mounted_at == "$allowed_mount" ) ]] || die "Device is mounted elsewhere: $device."
    done <<< "$mounts"
    ids=$(lsblk -nro MAJ:MIN -- "$device")
    while IFS= read -r id; do
        for holder in /sys/dev/block/"$id"/holders/*; do
            [[ ! -e $holder ]] || die "Device is in use by a device mapper or RAID holder: $device."
        done
    done <<< "$ids"
    local swaps
    swaps=$(swapon --show --noheadings --raw --output NAME)
    while IFS= read -r swap; do
        [[ -n $swap ]] || continue
        if is_block "$swap"; then
            swapid=$(block_id "$swap")
            while IFS= read -r id; do [[ $id != "$swapid" ]] || die "Device is active swap: $device."; done <<< "$ids"
        fi
    done <<< "$swaps"
}

validate_devices() {
    local key device id root_source root_id= target fs signature status types pttype
    local -A seen=()
    local -a keys=(root_part separate_home_part separate_boot_part separate_var_part separate_tmp_part)
    [[ ! -L /mnt ]] || die '/mnt must not be a symlink.'
    if [[ $root_part == none ]]; then
        mountpoint -q /mnt || die 'root_part=none requires an already mounted root at /mnt.'
        root_source=$(findmnt -nro SOURCE --mountpoint /mnt)
        root_source=${root_source%%\[*}
        is_block "$root_source" || die 'Pre-mounted root must be backed by a block device.'
        [[ $(block_type "$root_source") == part ]] || die 'Pre-mounted root must be an ordinary unencrypted partition; existing LUKS/LVM/RAID setups are not inferred.'
        root_id=$(block_id "$root_source"); seen[$root_id]=premounted_root
        fs=$(findmnt -nro FSTYPE --mountpoint /mnt)
        one_of fs ext2 ext3 ext4 btrfs xfs
        [[ $(findmnt -rnR -o TARGET --mountpoint /mnt | wc -l) -eq 1 ]] || die 'Unmount nested mounts under /mnt before installation.'
        [[ ! -e /mnt/etc && ! -e /mnt/usr && ! -e /mnt/bin ]] || die 'Pre-mounted root must be a fresh, empty filesystem.'
        for target in boot home var tmp efi; do
            [[ ! -e /mnt/$target && ! -L /mnt/$target ]] || die 'Pre-mounted root must have no existing mount directories.'
        done
    else
        ! mountpoint -q /mnt || die '/mnt is already mounted; use root_part=none only for a fresh pre-mounted root.'
        target=$(findmnt -rn -o TARGET)
        while IFS= read -r device; do [[ $device != /mnt/* ]] || die 'Unmount existing mounts below /mnt first.'; done <<< "$target"
    fi
    [[ $boot_mode != UEFI ]] || keys+=(efi_part)
    for key in "${keys[@]}"; do
        device=${!key}; [[ $device != none ]] || continue
        is_block "$device" || die "$key is not a block device."
        device=$(readlink -f -- "$device"); printf -v "$key" '%s' "$device"
        [[ $(block_type "$device") == part ]] || die "$key must be a partition; whole disks, RAID and existing mapper devices are not formatted."
        types=$(lsblk -dnro PARTTYPE -- "$device")
        [[ ${types,,} != 21686148-6449-6e6f-744e-656564454649 ]] || die 'A BIOS boot partition must never be used as a data/EFI filesystem.'
        id=$(block_id "$device")
        [[ -n $id && ! ${seen[$id]+present} ]] || die "Duplicate/aliased device selected for $key."
        seen[$id]=$key
        assert_unused "$device"
    done
    if [[ $boot_mode == UEFI ]]; then
        [[ $efi_part != none ]] || die 'Set efi_part for UEFI installation.'
        types=$(lsblk -dnro PARTTYPE -- "$efi_part")
        case ${types,,} in c12a7328-f81f-11d2-ba4b-00a0c93ec93b|0xef|ef) ;; *) die 'EFI partition must have the EFI System partition type.' ;; esac
        if signature=$(blkid -s TYPE -o value -- "$efi_part"); then :; else
            status=$?; [[ $status -eq 2 ]] || die 'Cannot inspect EFI filesystem.'
            signature=
        fi
        efi_format=yes; [[ $signature != vfat ]] || efi_format=no
    else
        is_block "$grub_disk" || die 'grub_disk is not a block device.'
        grub_disk=$(readlink -f -- "$grub_disk")
        [[ $(block_type "$grub_disk") == disk ]] || die 'grub_disk must be a whole disk.'
        if [[ $root_part != none ]]; then assert_unused "$grub_disk"
        else assert_unused "$grub_disk" /mnt; fi
        device=$separate_boot_part
        if [[ $device == none ]]; then device=$root_part; fi
        [[ $device != none ]] || device=$root_source
        types=$(lsblk -snrpo PATH -- "$device")
        grep -Fx -- "$grub_disk" <<< "$types" >/dev/null || die 'grub_disk must contain the root or separate boot partition.'
        pttype=$(lsblk -dnro PTTYPE -- "$grub_disk")
        if [[ $pttype == gpt ]]; then
            types=$(lsblk -nro PARTTYPE -- "$grub_disk")
            grep -Fix '21686148-6449-6e6f-744e-656564454649' <<< "$types" >/dev/null || die 'BIOS with GPT requires a separate BIOS boot partition.'
        elif [[ $pttype != dos ]]; then die 'Unsupported BIOS partition table.'; fi
    fi
}

validate_network_interface() {
    [[ $net_iface != lo && -d /sys/class/net/$net_iface ]] || die 'Selected network interface does not exist.'
    [[ ! -d /sys/class/net/$net_iface/wireless ]] || die 'Wireless requires network-manager.'
}
resolve_network() {
    local routes route token next candidate
    local -A interfaces=()
    local -a words=()
    net_iface=
    [[ $network_management == systemd-networkd ]] || return 0
    if [[ $network_interface == auto ]]; then
        routes=$(ip -o -4 route show default)
        while IFS= read -r route; do
            read -r -a words <<< "$route"; next=no
            for token in "${words[@]}"; do
                if [[ $next == yes ]]; then interfaces[$token]=1; next=no; fi
                [[ $token != dev ]] || next=yes
            done
        done <<< "$routes"
        [[ ${#interfaces[@]} -eq 1 ]] || die 'Cannot choose one interface; set network_interface explicitly.'
        for candidate in "${!interfaces[@]}"; do net_iface=$candidate; done
    else net_iface=$network_interface; fi
    validate_network_interface
}

write_network_config() {
    local dns
    printf '[Match]\nName=%s\n\n[Network]\n' "$net_iface"
    if [[ $network_method == dhcp ]]; then printf 'DHCP=yes\n'
    else
        printf 'Address=%s\nGateway=%s\n' "$network_address" "$network_gateway"
        for dns in $network_dns; do printf 'DNS=%s\n' "$dns"; done
    fi
}

preflight() {
    [[ $EUID -eq 0 ]] || die 'Run installation as root from the Arch live environment.'
    [[ -e /etc/arch-release && $(uname -m) == x86_64 ]] || die 'An x86_64 Arch Linux live environment is required.'
    require_commands pacstrap arch-chroot genfstab pacman mount umount mountpoint findmnt
    require_commands lsblk blkid swapon readlink stat cmp tr grep awk sed ip curl install mktemp sync
    local suffix part fs keymaps
    for suffix in root home boot var tmp; do
        if [[ $suffix == root ]]; then part=root_part; fs=root_part_filesystem
        else part=separate_${suffix}_part; fs=${part}_filesystem; fi
        [[ ${!part} == none ]] || require_commands "mkfs.${!fs}"
        if [[ ${!part} != none && ${!fs} == btrfs ]]; then require_commands btrfs; fi
    done
    if [[ $luks_encryption == yes ]]; then require_commands cryptsetup; fi
    if [[ $luks_encryption == yes && -e /dev/mapper/$root_mapper ]]; then die 'The ALBI encryption mapper already exists.'; fi
    if [[ $boot_mode == UEFI ]]; then require_commands mkfs.fat; fi
    if [[ $mirror_location != none ]]; then require_commands reflector; fi
    [[ -f /usr/share/zoneinfo/$timezone ]] || die 'Selected time zone does not exist.'
    awk -v locale="$language" '{ sub(/^#[[:space:]]*/, ""); if ($1 == locale) found=1 } END { exit !found }' /etc/locale.gen || die 'Selected locale does not exist.'
    require_commands localectl
    keymaps=$(localectl list-keymaps)
    grep -Fx -- "$tty_keyboard_layout" <<< "$keymaps" >/dev/null || die 'Selected keymap does not exist.'
    validate_devices
    resolve_network
    run_checked 'HTTPS connectivity and DNS check' curl --fail --silent --show-error --location --connect-timeout 10 --max-time 30 --output /dev/null https://archlinux.org/
}

show_plan() {
    local suffix part fs
    printf '\nInstallation plan (%s):\n' "$boot_mode"
    for suffix in root home boot var tmp; do
        if [[ $suffix == root ]]; then part=root_part; fs=root_part_filesystem
        else part=separate_${suffix}_part; fs=${part}_filesystem; fi
        if [[ ${!part} != none ]]; then
            printf '  ERASE %-22s -> /%-4s (%s)\n' "${!part}" "${suffix/root/}" "${!fs}"
        fi
    done
    [[ $root_part != none ]] || printf '  Use existing fresh mount at /mnt (no root formatting).\n'
    if [[ $boot_mode == UEFI ]]; then
        if [[ $efi_format == yes ]]; then printf '  ERASE %s -> %s (FAT32 EFI)\n' "$efi_part" "$efi_part_mountpoint"
        else printf '  Preserve EFI filesystem on %s; install GRUB under %s.\n' "$efi_part" "$efi_part_mountpoint"; fi
    else printf '  Write GRUB bootloader to %s.\n' "$grub_disk"; fi
    printf '  Root encryption: %s. Separate /home, /var, /tmp and /boot are NOT encrypted.\n' "$luks_encryption"
    printf '  Host: %s; user: %s; kernel: %s; desktop: %s; GPU: %s.\n' "$hostname" "$username" "$kernel_variant" "$de" "$gpu"
    printf '  Locale: %s; keymap: %s; time zone: %s; mirrors: %s.\n' "$language" "$tty_keyboard_layout" "$timezone" "$mirror_location"
    printf '  Network: %s; audio: %s; printing: %s; zram: %s; keep redacted config: %s.\n' "$network_management" "$install_pipewire" "$install_cups" "$create_swap" "$keep_config"
    if [[ $network_management == systemd-networkd ]]; then
        printf '  Interface: %s; method: %s; address: %s; gateway: %s; DNS: %s.\n' "$net_iface" "$network_method" "$network_address" "$network_gateway" "$network_dns"
    fi
    printf '  Passwords/passphrases are never displayed or retained in the target config.\n'
}
confirm_install() {
    local response
    printf '\nSelected partitions will be permanently erased. Type ERASE to proceed: ' >&2
    IFS= read -r response || die 'No confirmation received; aborting.'
    [[ $response == ERASE ]] || die 'Installation cancelled.'
}
prompt_secret() {
    local key=$1 label=$2 first second
    [[ -z ${!key} ]] || return 0
    [[ -t 0 ]] || die "$label is empty; use a terminal for the hidden prompt."
    printf '%s: ' "$label" >&2
    IFS= read -rs first || die 'Password input interrupted.'
    printf '\nRepeat %s: ' "$label" >&2
    IFS= read -rs second || die 'Password input interrupted.'
    printf '\n' >&2
    [[ -n $first && $first == "$second" ]] || die 'Passwords are empty or do not match.'
    printf -v "$key" '%s' "$first"
}

cleanup() {
    local status=$? failed=0 index
    trap - EXIT ERR INT TERM
    set +e
    unset password luks_passphrase
    if [[ -n ${target_stage:-} ]]; then rm -rf -- "$target_stage" || failed=1; fi
    for ((index=${#OWN_MOUNTS[@]}-1; index>=0; index--)); do
        if mountpoint -q "${OWN_MOUNTS[index]}" && ! umount -- "${OWN_MOUNTS[index]}"; then
            printf 'Cleanup: could not unmount %s.\n' "${OWN_MOUNTS[index]}" >&2; failed=1
        fi
    done
    if [[ -n ${opened_mapper:-} && -e /dev/mapper/$opened_mapper ]]; then
        if ! cryptsetup close "$opened_mapper"; then
            printf 'Cleanup: could not close %s.\n' "$opened_mapper" >&2; failed=1
        fi
    fi
    if [[ -n ${work_dir:-} ]]; then rm -rf -- "$work_dir" || failed=1; fi
    if ((status == 0 && failed)); then status=1; fi
    if ((status == 0)) && [[ ${installation_complete:-no} == yes ]]; then
        printf 'Installation completed. Installer-owned mounts and encryption mapping were released.\n'
    fi
    exit "$status"
}
mount_owned() {
    local target=${!#}
    install -d -m 755 -- "$target"
    OWN_MOUNTS+=("$target")
    mount "$@"
}
format_fs() {
    local device=$1 fs=$2
    case $fs in
        ext2|ext3|ext4) run_checked "Format $device as $fs" "mkfs.$fs" -F "$device" ;;
        btrfs|xfs) run_checked "Format $device as $fs" "mkfs.$fs" -f "$device" ;;
        *) die 'Unsupported filesystem reached formatting stage.' ;;
    esac
}
prepare_filesystems() {
    local device=$root_part suffix part fs
    if [[ $root_part != none ]]; then
        assert_unused "$root_part"
        if [[ $luks_encryption == yes ]]; then
            [[ ! -e /dev/mapper/$root_mapper ]] || die 'Encryption mapper name already exists.'
            opened_mapper=$root_mapper
            printf '%s' "$luks_passphrase" | cryptsetup luksFormat --batch-mode --type luks2 --key-file - "$root_part"
            printf '%s' "$luks_passphrase" | cryptsetup open --type luks --key-file - "$root_part" "$opened_mapper"
            root_uuid=$(cryptsetup luksUUID "$root_part")
            device=/dev/mapper/$opened_mapper
        fi
        unset luks_passphrase; luks_passphrase=
        format_fs "$device" "$root_part_filesystem"
        if [[ $root_part_filesystem == btrfs ]]; then
            mount_owned -t btrfs -o subvolid=5 "$device" /mnt
            btrfs subvolume create /mnt/root
            chmod 755 /mnt/root
            if [[ $separate_home_part == none ]]; then btrfs subvolume create /mnt/home; chmod 755 /mnt/home; fi
            umount /mnt
            unset 'OWN_MOUNTS[-1]'
            mount_owned -t btrfs -o subvol=root,compress=zstd:1 "$device" /mnt
            if [[ $separate_home_part == none ]]; then mount_owned -t btrfs -o subvol=home,compress=zstd:1 "$device" /mnt/home; fi
        else mount_owned "$device" /mnt; fi
    fi
    for suffix in boot home var tmp; do
        part=separate_${suffix}_part; fs=${part}_filesystem
        [[ ${!part} != none ]] || continue
        assert_unused "${!part}"
        format_fs "${!part}" "${!fs}"
        if [[ ${!fs} == btrfs && $suffix != boot ]]; then
            mount_owned -t btrfs -o compress=zstd:1 "${!part}" "/mnt/$suffix"
        else mount_owned "${!part}" "/mnt/$suffix"; fi
        if [[ $suffix == tmp ]]; then chmod 1777 /mnt/tmp; fi
    done
    if [[ $boot_mode == UEFI ]]; then
        assert_unused "$efi_part"
        if [[ $efi_format == yes ]]; then mkfs.fat -F 32 "$efi_part"; fi
        mount_owned -t vfat -o umask=0077 "$efi_part" "/mnt$efi_part_mountpoint"
    fi
    mountpoint -q /mnt || die 'Target root mount is missing.'
}

write_state() {
    local key
    for key in "${CONFIG_KEYS[@]}" "${STATE_KEYS[@]}"; do printf '%s\0' "${!key}"; done
}
read_state() {
    local key
    for key in "${CONFIG_KEYS[@]}" "${STATE_KEYS[@]}"; do
        IFS= read -r -d '' "$key" || die 'Incomplete installer state received.'
    done
}
pkg() { run_checked 'Package installation' pacman -S --needed --noconfirm "$@"; }
configure_target() {
    local vendor cryptdevice_grub dns launcher plasma_group package
    local -a plasma_packages=() gpu_packages=() unique_gpu_packages=()
    local -A gpu_package_seen=()
    local hybrid_graphics=no
    ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
    systemctl enable systemd-timesyncd
    hwclock --systohc

    awk -v locale="$language" '
        { text=$0; sub(/^#[[:space:]]*/, "", text); split(text, fields, /[[:space:]]+/)
          if (fields[1] == locale || fields[1] == "en_US.UTF-8") print text; else print }
    ' /etc/locale.gen > /etc/locale.gen.albi
    install -m 644 /etc/locale.gen.albi /etc/locale.gen
    rm /etc/locale.gen.albi
    printf 'LANG=%s\n' "$language" > /etc/locale.conf
    printf 'KEYMAP=%s\n' "$tty_keyboard_layout" > /etc/vconsole.conf
    printf '%s\n' "$hostname" > /etc/hostname
    locale-gen

    run_checked "System upgrade and base packages" pacman -Syu --needed btrfs-progs dosfstools dnsmasq inetutils xfsprogs base-devel polkit bash-completion nano grub ntfs-3g sshfs exfatprogs usbutils xdg-utils xdg-user-dirs unzip unrar zip 7zip os-prober plymouth --noconfirm

    if [[ $network_management == network-manager ]]; then
        pkg networkmanager
        systemctl enable NetworkManager
    elif [[ $network_management == systemd-networkd ]]; then
        install -d -m 755 /etc/systemd/network
        write_network_config > /etc/systemd/network/20-wired.network
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl enable systemd-networkd systemd-resolved
    fi

    pkg bluez
    systemctl enable bluetooth
    if [[ $boot_mode == UEFI ]]; then pkg efibootmgr; fi

    vendor=$(grep -m1 vendor_id /proc/cpuinfo | cut -d ':' -f2 | tr -d '[:space:]')
    if [[ "$vendor" == "GenuineIntel" ]]; then
        run_checked "Intel microcode installation" pacman -S --needed intel-ucode --noconfirm
    elif [[ "$vendor" == "AuthenticAMD" ]]; then
        run_checked "AMD microcode installation" pacman -S --needed amd-ucode --noconfirm
    fi

    printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' "$hostname" > /etc/hosts

    useradd -m -U -G wheel "$username"
    printf '%s:%s\n' "$username" "$password" | chpasswd
    unset password; password=
    if [[ -n $full_username ]]; then usermod -c "$full_username" "$username"; fi

    sed -i 's/^#Color$/Color/; s/^# include \/usr\/share\/nano\/\*\.nanorc/include \/usr\/share\/nano\/*.nanorc/' /etc/pacman.conf /etc/nanorc
    install -d -m 750 /etc/sudoers.d
    printf '%%wheel ALL=(ALL:ALL) ALL\nDefaults pwfeedback\n' > /etc/sudoers.d/10-albi-wheel
    chmod 440 /etc/sudoers.d/10-albi-wheel
    visudo -cf /etc/sudoers.d/10-albi-wheel
    visudo -cf /etc/sudoers
    grep -Eq '^[[:space:]]*(@|#)includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers || die 'sudoers does not include /etc/sudoers.d.'

    if [[ "$boot_mode" == "UEFI" ]]; then
        grub-install --target=x86_64-efi --efi-directory="$efi_part_mountpoint" --bootloader-id="archlinux"
    elif [[ "$boot_mode" == "BIOS" ]]; then
        grub-install --target=i386-pc "$grub_disk"
    fi

    grep -Eq '^HOOKS=' /etc/mkinitcpio.conf || die 'Missing mkinitcpio HOOKS assignment.'
    if [[ "$luks_encryption" == "yes" ]]; then
        cryptdevice_grub=$root_uuid
        [[ $cryptdevice_grub =~ ^[a-fA-F0-9-]+$ ]] || die 'Missing LUKS UUID.'
        run_checked "Initramfs hook configuration" sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
        grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub || die 'Missing GRUB kernel command line setting.'
        if grep -q "^GRUB_CMDLINE_LINUX=\"\"" /etc/default/grub; then
            sed -i "s|^\(GRUB_CMDLINE_LINUX=\"\)\(.*\)\"|\1rd.luks.name=$cryptdevice_grub=$root_mapper\"|" /etc/default/grub
        else
            sed -i "s|^\(GRUB_CMDLINE_LINUX=\".*\)\"|\1 rd.luks.name=$cryptdevice_grub=$root_mapper\"|" /etc/default/grub
        fi
    else
        run_checked "Initramfs hook configuration" sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth filesystems fsck)/' /etc/mkinitcpio.conf
    fi

    if [[ "$de" != "none" ]]; then
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)\(quiet\)\(.*\)"/\1\2 splash\3"/' /etc/default/grub
    fi

    sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/g' /etc/default/grub

    if [[ "$install_pipewire" == "yes" ]]; then
        pkg pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber
    fi

    gpu_packages=()
    hybrid_graphics=no

    if [[ "$gpu" == "amd" || "$gpu" == "amd-nvidia" || "$gpu" == "intel-amd" || "$gpu" == "amd-amd" ]]; then
        gpu_packages+=(mesa vulkan-radeon)
    fi

    if [[ "$gpu" == "intel" || "$gpu" == "intel-nvidia" || "$gpu" == "intel-amd" ]]; then
        gpu_packages+=(mesa vulkan-intel intel-media-driver)
    fi

    if [[ "$gpu" == "nvidia" || "$gpu" == "intel-nvidia" || "$gpu" == "amd-nvidia" ]]; then
        case "$kernel_variant" in
            normal) gpu_packages+=(nvidia-open) ;;
            lts) gpu_packages+=(nvidia-open-lts) ;;
            zen) gpu_packages+=(nvidia-open-dkms linux-zen-headers) ;;
            *)
                printf 'Error: unsupported NVIDIA kernel variant: %s\n' "$kernel_variant" >&2
                exit 1
                ;;
        esac
        gpu_packages+=(nvidia-settings)
    fi

    if [[ "$gpu" == "other" ]]; then
        gpu_packages+=(mesa)
    fi

    case "$gpu" in
        intel-nvidia|amd-nvidia)
            gpu_packages+=(nvidia-prime switcheroo-control)
            hybrid_graphics=yes
            ;;
        intel-amd|amd-amd)
            gpu_packages+=(switcheroo-control)
            hybrid_graphics=yes
            ;;
    esac

    gpu_package_seen=()
    unique_gpu_packages=()
    for package in "${gpu_packages[@]}"; do
        if [[ -z "${gpu_package_seen[$package]+present}" ]]; then
            unique_gpu_packages+=("$package")
            gpu_package_seen[$package]=1
        fi
    done

    if (( ${#unique_gpu_packages[@]} > 0 )); then
        run_checked "GPU driver installation" pacman -S --needed --noconfirm "${unique_gpu_packages[@]}"
    fi

    if [[ "$hybrid_graphics" == "yes" ]]; then
        run_checked "Hybrid graphics service enablement" systemctl enable switcheroo-control
    fi

    if [[ "$de" == "gnome" ]]; then
        pkg gnome noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gnome-tweaks gnome-shell-extensions gnome-browser-connector power-profiles-daemon
        systemctl enable gdm
    elif [[ "$de" == "plasma" ]]; then
        plasma_group=$(pacman -Sgq plasma)
        plasma_packages=()
        while IFS= read -r package; do
            case $package in sddm|sddm-kcm|plasma-login-manager|'') continue ;; esac
            plasma_packages+=("$package")
        done <<< "$plasma_group"
        (( ${#plasma_packages[@]} > 0 )) || die 'Plasma package group is empty.'
        pkg "${plasma_packages[@]}" plasma-login-manager libcec speech-dispatcher qrca noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ufw dolphin konsole power-profiles-daemon
        systemctl enable plasmalogin
    elif [[ "$de" == "xfce" ]]; then
        pkg xfce4 xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs network-manager-applet power-profiles-daemon
        systemctl enable lightdm
    elif [[ "$de" == "cinnamon" ]]; then
        pkg blueman cinnamon cinnamon-translations nemo-fileroller gnome-terminal lightdm lightdm-slick-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon
        systemctl enable lightdm
        sed -i 's/#greeter-session=example-gtk-gnome/greeter-session=lightdm-slick-greeter/g' /etc/lightdm/lightdm.conf
    elif [[ "$de" == "mate" ]]; then
        pkg mate mate-extra blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon
        systemctl enable lightdm
    fi

    if [[ "$install_cups" == yes ]]; then
        pkg cups cups-filters cups-pk-helper cups-browsed bluez-cups ghostscript gutenprint hplip nss-mdns
        systemctl enable cups
        systemctl enable cups-browsed
        systemctl enable avahi-daemon
        sed -i "s/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/" /etc/nsswitch.conf
        install -d -m 755 -o "$username" -g "$username" "/home/$username/.local" "/home/$username/.local/share" "/home/$username/.local/share/applications"
        for launcher in hplip.desktop hp-uiscan.desktop; do
            if [[ -f /usr/share/applications/$launcher ]]; then
                install -m 644 -o "$username" -g "$username" "/usr/share/applications/$launcher" "/home/$username/.local/share/applications/$launcher"
                printf '\nNoDisplay=true\n' >> "/home/$username/.local/share/applications/$launcher"
            fi
        done
    fi

    if [[ "$de" != "none" && "$install_cups" == yes ]]; then
        pkg system-config-printer
    fi


    if [[ "$create_swap" == "yes" ]]; then
        pkg zram-generator
        install -d -m 755 /etc/systemd
        cat <<EOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
    fi

    run_checked "Initramfs generation" mkinitcpio -P
    run_checked "GRUB configuration generation" grub-mkconfig -o /boot/grub/grub.cfg
    [[ -s /boot/grub/grub.cfg ]] || die 'GRUB configuration is empty.'

    if [[ $keep_config == yes ]]; then
        write_config > "/home/$username/config.conf"
        chmod 600 "/home/$username/config.conf"
        chown "$username:$username" "/home/$username/config.conf"
    fi
    sync

}

create_target_script() {
    printf '#!/usr/bin/env bash\nset +x\nset +v\nset -Eeuo pipefail\numask 022\nulimit -c 0\n'
    printf "trap 'report_error \"\$?\" \"\$LINENO\"' ERR\n"
    printf "trap 'exit 130' INT\ntrap 'exit 143' TERM\n"
    declare -p CONFIG_KEYS STATE_KEYS
    declare -f die run_checked report_error write_config write_network_config read_state pkg configure_target
    printf 'read_state\nconfigure_target\n'
}

install_system() {
    local kernel=linux
    work_dir=$(mktemp -d /run/albi.XXXXXXXX)
    if [[ $mirror_location != none ]]; then
        run_checked 'Mirror selection' reflector --sort rate --country "$mirror_location" --save "$work_dir/mirrorlist"
        [[ -s $work_dir/mirrorlist ]] || die 'Reflector produced an empty mirror list.'
        install -m 644 "$work_dir/mirrorlist" /etc/pacman.d/mirrorlist
    fi
    validate_devices
    prepare_filesystems
    case $kernel_variant in lts) kernel=linux-lts ;; zen) kernel=linux-zen ;; esac
    run_checked 'Base system installation' pacstrap -K /mnt base "$kernel" linux-firmware
    genfstab -U /mnt > "$work_dir/fstab"
    [[ -s $work_dir/fstab ]] || die 'Generated fstab is empty.'
    awk '$2 == "/" {found=1} END {exit !found}' "$work_dir/fstab" || die 'Generated fstab has no root entry.'
    install -m 644 "$work_dir/fstab" /mnt/etc/fstab
    target_stage=$(mktemp -d /mnt/.albi.XXXXXXXX)
    create_target_script > "$target_stage/configure.sh"
    chmod 700 "$target_stage/configure.sh"
    bash -n "$target_stage/configure.sh"
    write_state | arch-chroot /mnt /bin/bash "${target_stage#/mnt}/configure.sh"
    unset password luks_passphrase
    sync
    installation_complete=yes
}

main() {
    set +x
    set +v
    set -Eeuo pipefail
    export PATH=/usr/bin:/usr/sbin:/bin:/sbin
    umask 077
    ulimit -c 0
    trap 'report_error "$?" "$LINENO"' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local config=config.conf
    (( $# == 0 )) || die 'Run this script without arguments; edit config.conf to change settings.'
    defaults
    if [[ -d /sys/firmware/efi ]]; then boot_mode=UEFI; else boot_mode=BIOS; fi
    if [[ ! -e $config && ! -L $config ]]; then
        (set -o noclobber; write_config > "$config") || die 'Cannot create config; destination may already exist.'
        chmod 600 -- "$config"
        printf 'Created %s. Set partition paths and review settings before installation.\n' "$config"
        return 0
    fi
    require_commands stat cmp tr
    load_config "$config"
    validate_settings
    require_commands flock
    [[ $EUID -eq 0 ]] || die 'Run installation as root.'
    exec {lock_fd}> /run/albi.lock
    flock -n "$lock_fd" || die 'Another ALBI installation is running.'
    preflight
    show_plan
    confirm_install
    prompt_secret password 'User password'
    if [[ $luks_encryption == yes ]]; then prompt_secret luks_passphrase 'Root encryption passphrase'; fi
    OWN_MOUNTS=()
    opened_mapper= work_dir= target_stage= installation_complete=no
    trap cleanup EXIT
    install_system
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
