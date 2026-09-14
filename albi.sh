#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config.conf"
CHROOT_SCRIPT="$SCRIPT_DIR/main.sh"
TMPFILE="$SCRIPT_DIR/tmpfile.sh"
BOOT_MODE="$(test -d /sys/firmware/efi && echo UEFI || echo BIOS)"

cleanup() {
    set +e
    for m in /mnt/home /mnt/var /mnt/tmp /mnt/usr "/mnt${efi_part_mountpoint:-/boot/efi}" /mnt/boot /mnt; do
        mountpoint -q "$m" 2>/dev/null && umount -R "$m" 2>/dev/null || true
    done
    if [[ -n "${root_part_encrypted_name:-}" ]] && cryptsetup status "$root_part_encrypted_name" &>/dev/null; then
        cryptsetup close "$root_part_encrypted_name" || true
    fi
}
trap 'echo; echo "Interruption signal received. Aborting..."; cleanup; exit 130' INT TERM
trap 'rc=$?; echo "ERROR: command failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2; cleanup; exit "$rc"' ERR

require() { command -v "$1" >/dev/null 2>&1 || { echo "Error: missing command: $1" >&2; exit 1; }; }
valid_fs() { case "$1" in ext2|ext3|ext4|btrfs|xfs) return 0;; *) return 1;; esac; }
valid_yn() { [[ "$1" == yes || "$1" == no ]]; }

validate_config() {
    local v
    for v in root_part root_part_filesystem separate_home_part separate_home_part_filesystem \
        separate_boot_part separate_boot_part_filesystem separate_var_part separate_var_part_filesystem \
        separate_tmp_part separate_tmp_part_filesystem luks_encryption luks_passphrase network_management \
        kernel_variant mirror_location timezone hostname username full_username password language \
        tty_keyboard_layout install_pipewire gpu de install_cups create_swapfile swapfile_size_gb keep_config; do
        [[ -v "$v" ]] || { echo "Error: $v is not set in config.conf"; exit 1; }
    done

    valid_fs "$root_part_filesystem" || { echo "Error: invalid root filesystem: $root_part_filesystem"; exit 1; }
    for pair in \
        "$separate_home_part|$separate_home_part_filesystem" \
        "$separate_boot_part|$separate_boot_part_filesystem" \
        "$separate_var_part|$separate_var_part_filesystem" \
        "$separate_tmp_part|$separate_tmp_part_filesystem"; do
        part="${pair%%|*}"; fs="${pair#*|}"
        if [[ "$part" != none ]]; then valid_fs "$fs" || { echo "Error: invalid filesystem $fs for $part"; exit 1; }; fi
    done

    valid_yn "$luks_encryption" || { echo "Error: invalid luks_encryption: $luks_encryption"; exit 1; }
    valid_yn "$install_pipewire" || { echo "Error: invalid install_pipewire: $install_pipewire"; exit 1; }
    valid_yn "$install_cups" || { echo "Error: invalid install_cups: $install_cups"; exit 1; }
    valid_yn "$create_swapfile" || { echo "Error: invalid create_swapfile: $create_swapfile"; exit 1; }
    valid_yn "$keep_config" || { echo "Error: invalid keep_config: $keep_config"; exit 1; }
    case "$network_management" in network-manager|systemd-networkd|none) ;; *) echo "Error: invalid network_management: $network_management"; exit 1;; esac
    case "$kernel_variant" in normal|lts|zen) ;; *) echo "Error: invalid kernel_variant: $kernel_variant"; exit 1;; esac
    case "$gpu" in amd|intel|nvidia|other|none) ;; *) echo "Error: invalid gpu: $gpu"; exit 1;; esac
    case "$de" in gnome|plasma|xfce|mate|cinnamon|none) ;; *) echo "Error: invalid desktop environment: $de"; exit 1;; esac
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Error: invalid username: $username"; exit 1; }
    [[ -n "$password" ]] || { echo "Error: empty user password"; exit 1; }
    [[ "$password" != "CHANGE_THIS" ]] || { echo "Error: change the default user password in config.conf before installing."; exit 1; }
    if [[ "$luks_encryption" == yes ]]; then
        [[ "$root_part" != none ]] || { echo "Error: LUKS encryption requires root_part"; exit 1; }
        [[ -n "$luks_passphrase" ]] || { echo "Error: empty LUKS passphrase"; exit 1; }
        [[ "$luks_passphrase" != "CHANGE_THIS" ]] || { echo "Error: change the default LUKS passphrase in config.conf before installing."; exit 1; }
        [[ "$separate_boot_part" != none ]] || { echo "Error: encrypted installations require a separate /boot partition."; exit 1; }
    fi
    [[ "$swapfile_size_gb" =~ ^[1-9][0-9]*(\.[0-9]+)?$ ]] || { echo "Error: invalid swapfile_size_gb: $swapfile_size_gb"; exit 1; }
    [[ "$hostname" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || { echo "Error: invalid hostname: $hostname"; exit 1; }
    [[ "$gpu" != none || "$de" == none ]] || { echo "Error: desktop environment requires gpu != none"; exit 1; }

    if [[ "$root_part" != none ]]; then [[ -b "$root_part" ]] || { echo "Error: root_part is not a block device: $root_part"; exit 1; }; fi
    for x in separate_home_part separate_boot_part separate_var_part separate_tmp_part; do
        p="${!x}"; [[ "$p" == none ]] || [[ -b "$p" ]] || { echo "Error: $x is not a block device: $p"; exit 1; }
    done

    if [[ "$BOOT_MODE" == UEFI ]]; then
        : "${efi_part:?Error: efi_part is not set}"
        : "${efi_part_mountpoint:?Error: efi_part_mountpoint is not set}"
        [[ -b "$efi_part" ]] || { echo "Error: efi_part is not a block device: $efi_part"; exit 1; }
        [[ "$efi_part_mountpoint" == /boot/efi || "$efi_part_mountpoint" == /efi ]] || { echo "Error: invalid EFI mountpoint"; exit 1; }
    else
        : "${grub_disk:?Error: grub_disk is not set}"
        [[ -b "$grub_disk" ]] || { echo "Error: grub_disk is not a block device: $grub_disk"; exit 1; }
    fi

    declare -A used=()
    for entry in "root=$root_part" "home=$separate_home_part" "boot=$separate_boot_part" "var=$separate_var_part" "tmp=$separate_tmp_part"; do
        role="${entry%%=*}"; p="${entry#*=}"; [[ "$p" == none ]] && continue
        [[ -z "${used[$p]:-}" ]] || { echo "Error: $p is assigned to both ${used[$p]} and $role"; exit 1; }
        used[$p]="$role"
    done
    if [[ "$BOOT_MODE" == UEFI ]]; then
        [[ -z "${used[$efi_part]:-}" ]] || { echo "Error: EFI partition $efi_part is also assigned to ${used[$efi_part]}"; exit 1; }
    fi
    if [[ "$root_part" == none ]]; then
        [[ -n "$(findmnt -no SOURCE /mnt 2>/dev/null || true)" ]] || { echo "Error: root_part=none but /mnt is not mounted"; exit 1; }
    fi
}

format_fs() {
    local dev="$1" fs="$2"
    case "$fs" in
        ext2) mkfs.ext2 -F "$dev";;
        ext3) mkfs.ext3 -F "$dev";;
        ext4) mkfs.ext4 -F "$dev";;
        btrfs) mkfs.btrfs -f "$dev";;
        xfs) mkfs.xfs -f "$dev";;
    esac
}

mount_selected() {
    local dev="$1" fs="$2" mp="$3"
    mkdir -p "$mp"
    format_fs "$dev" "$fs"
    case "$fs" in
        btrfs) mount -t btrfs -o compress=zstd:1 "$dev" "$mp";;
        *) mount "$dev" "$mp";;
    esac
}

format_root() {
    if [[ "$root_part" == none ]]; then mountpoint -q /mnt || { echo "Error: /mnt is not mounted"; exit 1; }; return; fi
    if [[ "$luks_encryption" == yes ]]; then
        root_part_orig="$root_part"
        root_part_encrypted_name="$(basename "$root_part")_crypt"
        cryptsetup luksFormat --type luks2 --batch-mode "$root_part" <<<"$luks_passphrase"
        cryptsetup open "$root_part" "$root_part_encrypted_name" --key-file=- <<<"$luks_passphrase"
        root_part="/dev/mapper/$root_part_encrypted_name"
    fi
    if [[ "$root_part_filesystem" == btrfs ]]; then
        mkfs.btrfs -f "$root_part"
        mount -t btrfs -o subvolid=5 "$root_part" /mnt
        btrfs subvolume create /mnt/root
        [[ "$separate_home_part" != none ]] || btrfs subvolume create /mnt/home
        umount /mnt
        mount -t btrfs -o subvol=root,compress=zstd:1 "$root_part" /mnt
        if [[ "$separate_home_part" == none ]]; then mkdir -p /mnt/home; mount -t btrfs -o subvol=home,compress=zstd:1 "$root_part" /mnt/home; fi
    else
        format_fs "$root_part" "$root_part_filesystem"
        mount "$root_part" /mnt
    fi
}

write_chroot() {
cat > "$CHROOT_SCRIPT" <<'CHROOTSCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; echo "ERROR in chroot at line $LINENO: $BASH_COMMAND" >&2; exit "$rc"' ERR
source /config.conf
source /tmpfile.sh
ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
systemctl enable systemd-timesyncd
hwclock --systohc

grep -qE "^#?[[:space:]]*${language}[[:space:]]+UTF-8" /etc/locale.gen || { echo "Error: locale not found: $language"; exit 1; }
sed -i -E "s|^#[[:space:]]*(${language}[[:space:]]+UTF-8)|\1|" /etc/locale.gen
echo "LANG=$language" > /etc/locale.conf
echo "KEYMAP=$tty_keyboard_layout" > /etc/vconsole.conf
echo "$hostname" > /etc/hostname
locale-gen

pacman -S --noconfirm btrfs-progs dosfstools dnsmasq inetutils xfsprogs base-devel polkit bash-completion nano grub ntfs-3g sshfs exfatprogs usbutils xdg-utils xdg-user-dirs unzip unrar zip 7zip os-prober plymouth sudo
case "$network_management" in
 network-manager) pacman -S --noconfirm networkmanager; systemctl enable NetworkManager ;;
 systemd-networkd)
   default_route=$(ip route | awk '$1=="default"{print; exit}'); iface=$(awk '{print $5}' <<<"$default_route"); gateway=$(awk '{print $3}' <<<"$default_route")
   mkdir -p /etc/systemd/network
   { echo '[Match]'; echo "Name=$iface"; echo; echo '[Link]'; echo 'RequiredForOnline=routable'; echo; echo '[Network]'; echo 'DHCP=yes'; } > /etc/systemd/network/20-wired.network
   systemctl enable systemd-networkd systemd-resolved ;;
esac
pacman -S --noconfirm bluez
systemctl enable bluetooth
[[ "$boot_mode" != UEFI ]] || pacman -S --noconfirm efibootmgr
vendor=$(awk -F: '/vendor_id/{print $2; exit}' /proc/cpuinfo | tr -d '[:space:]')
[[ "$vendor" != GenuineIntel ]] || pacman -S --noconfirm intel-ucode
[[ "$vendor" != AuthenticAMD ]] || pacman -S --noconfirm amd-ucode
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
127.0.1.1 $hostname
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS
useradd -m -s /bin/bash "$username"
printf '%s:%s\n' "$username" "$password" | chpasswd
[[ -z "$full_username" ]] || usermod -c "$full_username" "$username"
usermod -aG wheel "$username"
sed -i 's/^# include \/usr\/share\/nano\/\*\.nanorc/include \/usr\/share\/nano\/\*\.nanorc/' /etc/nanorc
sed -i '/^#Color/s/^#//' /etc/pacman.conf
grep -q '^ILoveCandy$' /etc/pacman.conf || sed -i '/^Color$/a ILoveCandy' /etc/pacman.conf
sed -i '/^# %wheel ALL=(ALL:ALL) ALL$/s/^# //' /etc/sudoers

if [[ "$boot_mode" == UEFI ]]; then grub-install --target=x86_64-efi --efi-directory="$efi_part_mountpoint" --bootloader-id=archlinux; else grub-install --target=i386-pc "$grub_disk"; fi
if [[ "$luks_encryption" == yes ]]; then
  crypt_uuid=$(blkid -s UUID -o value "$root_part_orig")
  sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
  sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"rd.luks.name=$crypt_uuid=$root_part_encrypted_name\"|" /etc/default/grub
else sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth filesystems fsck)/' /etc/mkinitcpio.conf; fi
[[ "$de" == none ]] || sed -i -E 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"|' /etc/default/grub
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub

if [[ "$install_pipewire" == yes ]]; then pacman -S --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber; fi
case "$gpu" in
 amd) pacman -S --noconfirm mesa vulkan-radeon; sed -i 's/^MODULES=()/MODULES=(amdgpu)/' /etc/mkinitcpio.conf ;;
 intel) pacman -S --noconfirm mesa vulkan-intel intel-media-driver ;;
 nvidia)
   case "$kernel_variant" in normal) pacman -S --noconfirm nvidia-open nvidia-settings;; lts) pacman -S --noconfirm nvidia-open-lts nvidia-settings;; zen) pacman -S --noconfirm nvidia-open-dkms nvidia-settings dkms;; esac
   ;;
 other) pacman -S --noconfirm mesa;;
esac

grub-mkconfig -o /boot/grub/grub.cfg
case "$de" in
 gnome) pacman -S --noconfirm gnome noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gnome-tweaks gnome-shell-extensions gnome-browser-connector power-profiles-daemon ptyxis; systemctl enable gdm;;
 plasma) pacman -S --noconfirm plasma plasma-login-manager noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra ufw dolphin konsole power-profiles-daemon; systemctl enable plasmalogin;;
 xfce) pacman -S --noconfirm xfce4 xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs network-manager-applet power-profiles-daemon; systemctl enable lightdm;;
 cinnamon) pacman -S --noconfirm blueman cinnamon cinnamon-translations nemo-fileroller gnome-terminal lightdm lightdm-slick-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon; systemctl enable lightdm; sed -i 's/^#greeter-session=example-gtk-gnome/greeter-session=lightdm-slick-greeter/' /etc/lightdm/lightdm.conf;;
 mate) pacman -S --noconfirm mate mate-extra blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon; systemctl enable lightdm;;
esac
if [[ "$install_cups" == yes ]]; then pacman -S --noconfirm cups cups-filters cups-pk-helper cups-browsed bluez-cups ghostscript gutenprint hplip nss-mdns avahi system-config-printer; systemctl enable cups cups-browsed avahi-daemon; sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' /etc/nsswitch.conf; fi
if [[ "$create_swapfile" == yes ]]; then truncate -s 0 /swapfile; [[ "$root_part_filesystem" != btrfs ]] || chattr +C /swapfile; fallocate -l "${swapfile_size_gb}G" /swapfile; chmod 600 /swapfile; mkswap /swapfile; echo '/swapfile none swap defaults 0 0' >> /etc/fstab; fi
mkinitcpio -P
orphans=$(pacman -Qdtq 2>/dev/null || true); [[ -z "$orphans" ]] || pacman -Rns --noconfirm $orphans || true
pacman -Sc --noconfirm || true
if [[ "$keep_config" == yes ]]; then sed -i -E 's/^(password=).*/\1""/; s/^(luks_passphrase=).*/\1""/' /config.conf; install -o "$username" -g "$username" -m 600 /config.conf "/home/$username/config.conf"; fi
rm -f /main.sh /tmpfile.sh
[[ "$keep_config" == yes ]] || rm -f /config.conf
CHROOTSCRIPT
chmod 700 "$CHROOT_SCRIPT"
}

generate_config() {
cat > "$CONFIG_FILE" <<CFG
## ALBI configuration -- selected partitions are ALWAYS formatted.
root_part_filesystem="btrfs"
separate_home_part_filesystem="none"
separate_boot_part_filesystem="ext4"
separate_var_part_filesystem="none"
separate_tmp_part_filesystem="none"
root_part="/dev/sdX3"
separate_home_part="none"
separate_boot_part="/dev/sdX2"
separate_var_part="none"
separate_tmp_part="none"
luks_encryption="yes"
luks_passphrase="CHANGE_THIS"
CFG
if [[ "$BOOT_MODE" == UEFI ]]; then cat >> "$CONFIG_FILE" <<CFG
efi_part="/dev/sdX1"
efi_part_mountpoint="/boot/efi"
CFG
else cat >> "$CONFIG_FILE" <<CFG
grub_disk="/dev/sdX"
CFG
fi
cat >> "$CONFIG_FILE" <<CFG
network_management="network-manager"
kernel_variant="normal"
mirror_location="none"
timezone="Europe/Prague"
hostname="changeme"
username="changeme"
full_username="Changeme Please"
password="CHANGE_THIS"
language="en_US.UTF-8"
tty_keyboard_layout="us"
install_pipewire="yes"
gpu="amd"
de="gnome"
install_cups="yes"
create_swapfile="yes"
swapfile_size_gb="4"
keep_config="no"
CFG
}

main() {
    [[ $EUID -eq 0 ]] || { echo "Error: run as root."; exit 1; }
    for c in bash mount umount findmnt blkid mkfs.ext2 mkfs.ext3 mkfs.ext4 mkfs.btrfs mkfs.xfs mkfs.fat btrfs cryptsetup pacstrap genfstab arch-chroot pacman localectl ping sed grep awk; do require "$c"; done
    mkdir -p /mnt
    if [[ ! -e "$CONFIG_FILE" ]]; then generate_config; echo "Generated $CONFIG_FILE. Edit it and run again."; exit 0; fi
    bash -n "$CONFIG_FILE"
    source "$CONFIG_FILE"
    validate_config
    echo "Checking Internet connection..."
    ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 || ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 || { echo "Error: no Internet connection."; exit 1; }
    ping -c 2 -W 3 google.com >/dev/null 2>&1 || ping -c 2 -W 3 one.one.one.one >/dev/null 2>&1 || { echo "Error: DNS failure."; exit 1; }
    grep -qE "^#?[[:space:]]*${language}[[:space:]]+UTF-8" /etc/locale.gen || { echo "Error: locale not found: $language"; exit 1; }
    localectl list-keymaps | grep -Fxq "$tty_keyboard_layout" || { echo "Error: keymap not found: $tty_keyboard_layout"; exit 1; }

    clear
    echo "=============================================="
    echo " ALBI - DESTRUCTIVE INSTALLATION"
    echo "=============================================="
    echo "/      $root_part_filesystem on $root_part"
    [[ "$separate_home_part" == none ]] || echo "/home  $separate_home_part_filesystem on $separate_home_part"
    [[ "$separate_boot_part" == none ]] || echo "/boot  $separate_boot_part_filesystem on $separate_boot_part"
    [[ "$separate_var_part" == none ]] || echo "/var   $separate_var_part_filesystem on $separate_var_part"
    [[ "$separate_tmp_part" == none ]] || echo "/tmp   $separate_tmp_part_filesystem on $separate_tmp_part"
    [[ "$BOOT_MODE" != UEFI ]] || echo "EFI    FAT32 on $efi_part at $efi_part_mountpoint"
    [[ "$BOOT_MODE" != BIOS ]] || echo "GRUB   $grub_disk"
    echo "LUKS   $luks_encryption"
    echo
    echo "EVERY selected partition above WILL be reformatted."
    echo
    read -r -p 'Start installation? [Y/n] ' answer
    answer=${answer:-Y}
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborting."; exit 0; }

    if [[ "$mirror_location" != none ]]; then require reflector; reflector --country "$mirror_location" --sort rate --save /etc/pacman.d/mirrorlist; fi

    format_root
    if [[ "$separate_home_part" != none ]]; then mount_selected "$separate_home_part" "$separate_home_part_filesystem" /mnt/home; fi
    if [[ "$separate_boot_part" != none ]]; then mount_selected "$separate_boot_part" "$separate_boot_part_filesystem" /mnt/boot; fi
    if [[ "$separate_var_part" != none ]]; then mount_selected "$separate_var_part" "$separate_var_part_filesystem" /mnt/var; fi
    if [[ "$separate_tmp_part" != none ]]; then mount_selected "$separate_tmp_part" "$separate_tmp_part_filesystem" /mnt/tmp; fi
    if [[ "$BOOT_MODE" == UEFI ]]; then mkdir -p "/mnt$efi_part_mountpoint"; mkfs.fat -F 32 "$efi_part"; mount -t vfat "$efi_part" "/mnt$efi_part_mountpoint"; fi

    case "$kernel_variant" in
        normal) pacstrap -K /mnt base linux linux-firmware linux-headers;;
        lts) pacstrap -K /mnt base linux-lts linux-firmware linux-lts-headers;;
        zen) pacstrap -K /mnt base linux-zen linux-firmware linux-zen-headers;;
    esac
    genfstab -U /mnt > /mnt/etc/fstab
    write_chroot
    printf 'boot_mode=%q\n' "$BOOT_MODE" > "$TMPFILE"
if [[ "$luks_encryption" == yes ]]; then printf 'root_part_orig=%q\nroot_part_encrypted_name=%q\n' "$root_part_orig" "$root_part_encrypted_name" >> "$TMPFILE"; fi
install -m 600 "$TMPFILE" /mnt/tmpfile.sh
    install -m 600 "$CONFIG_FILE" /mnt/config.conf
    install -m 700 "$CHROOT_SCRIPT" /mnt/main.sh
    arch-chroot /mnt /bin/bash /main.sh
    echo "Installation completed successfully."
    cleanup
    rm -f "$CHROOT_SCRIPT" "$TMPFILE"
    echo "Done."
}
main "$@"
