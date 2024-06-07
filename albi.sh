#!/bin/bash

## Interruption handler
interrupt_handler() {
    echo "Interruption signal received. Aborting... "
    exit
}

trap interrupt_handler SIGINT

## Detect current working directory and save it to a variable
cwd=$(pwd)

## Detect the system boot mode
if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
else
    boot_mode="BIOS"
fi

## Create configuration file or check the existing one for errors
if [[ -e "config.conf" ]]; then
    output=$(bash -n "$cwd"/config.conf 2>&1)
    if [[ -n "$output" ]]; then
        echo "Syntax errors found in the configuration file."
        exit
    else
        source "$cwd"/config.conf
    fi
else
    touch config.conf
    cat <<EOF > config.conf
## Installation Configuration

### Formatting
root_part_filesystem="ext4"  #### Filesystem for the / partition
separate_home_part_filesystem="none"  #### Filesystem for the /home partition
separate_boot_part_filesystem="ext4"  #### Filesystem for the /boot partition
separate_var_part_filesystem="none"  #### Filesystem for the /var partition
separate_usr_part_filesystem="none"  #### Filesystem for the /usr partition
separate_tmp_part_filesystem="none"  #### Filesystem for the /tmp partition

### Mounting
root_part="/dev/sdX#"  #### Path for the / partition
separate_home_part="none"  #### Path for the /home partition
separate_boot_part="/dev/sdX#"  #### Path for the /boot partition
separate_var_part="none"  #### Path for the /var partition
separate_usr_part="none"  #### Path for the /usr partition
separate_tmp_part="none"  #### Path for the /tmp partition

### Encryption
luks_encryption="yes"  #### Encrypt the system (yes/no)
luks_passphrase="4V3ryH@rdP4ssphr@s3!"  #### Passphrase for encryption

EOF

if [[ "$boot_mode" == "UEFI" ]]; then
    echo "### EFI partition settings" >> config.conf
    echo "efi_part=\"/dev/sdX#\"  #### EFI partition path" >> config.conf
    echo "efi_part_mountpoint=\"/boot/efi\"  #### EFI partition mount point" >> config.conf
else
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
hostname="changeme"  #### Machine name
username="changeme"  #### User name
full_username="Changeme Please"  #### Full user name (optional - leave empty if you don't want it)
password="changeme"  #### User password

### Locales
language="en_US.UTF-8"  #### System language
tty_keyboard_layout="us"  #### TTY keyboard layout

### Software Selection
audio_server="pipewire"  #### Audio server (pulseaudio/pipewire/none)
gpu="amd"  #### GPU driver (amd/intel/nvidia/other)
de="gnome"  #### Desktop environment (gnome/plasma/xfce/mate/cinnamon/none)
install_cups="yes"  #### Install CUPS (yes/no)
custom_packages="firefox htop papirus-icon-theme"  #### Custom packages (space-separated list or empty)

### Swapfile
create_swapfile="yes"  #### Create swapfile (yes/no)
swapfile_size_gb="4"  #### Swapfile size in GB

### Script Settings
keep_config="no"  #### Keep a copy of this file in /home/<your_username> after installation (yes/no)
EOF

echo "config.conf was generated successfully. Edit it to customize the installation."
exit
fi

## Verify the values in the configuration file to ensure correct settings
passwd_length=${#password}
username_length=${#username}
luks_passphrase_length=${#luks_passphrase}

echo "Checking the Internet connection..."
ping -c 4 8.8.8.8 > /dev/null 2>&1
if ! [[ $? -eq 0 ]]; then
    ping -c 4 1.1.1.1 > /dev/null 2>&1
    if ! [[ $? -eq 0 ]]; then
        echo "Error: no Internet connection."
    fi
fi

ping -c 4 google.com > /dev/null 2>&1
if ! [[ $? -eq 0 ]]; then
    ping -c 4 one.one.one.one > /dev/null 2>&1
    if ! [[ $? -eq 0 ]]; then
        echo "Error: DNS isn't working. Check your network's configuration"
    fi
fi

if ! [[ "$kernel_variant" == "normal" || "$kernel_variant" == "lts" || "$kernel_variant" == "zen" ]]; then
    echo "Error: invalid value for the kernel variant."
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

if ! [[ "$audio_server" == "pipewire" || "$audio_server" == "pulseaudio" || "$audio_server" == "none" ]]; then
    echo "Error: invalid value for the audio server."
    exit
fi

if ! [[ "$install_cups" == "yes" || "$install_cups" == "no" ]]; then
    echo "Error: invalid value for the CUPS installation setting."
    exit
fi

if ! [[ "$gpu" == "amd" || "$gpu" == "intel" || "$gpu" == "nvidia" || "$gpu" == "other" ]]; then
    echo "Error: invalid value for the GPU driver."
    exit
fi

if ! [[ "$de" == "cinnamon" || "$de" == "gnome" || "$de" == "mate" || "$de" == "plasma" || "$de" == "xfce" || "$de" == "none" ]]; then
    echo "Error: invalid value for the desktop environment."
    exit
fi

if [[ "$luks_encryption" == "yes" ]]; then
    if [[ "$luks_passphrase_length" == 0 ]]; then
        echo "Error: the encryption passphrase not set."
        exit
    fi
fi

if ! [[ "$create_swapfile" == "yes" || "$create_swapfile" == "no" ]]; then
    echo "Error: invalid value for the swapfile creation question."
    exit
fi

if ! [[ "$swapfile_size_gb" =~ ^[0-9]+$ ]]; then
    echo "Error: invalid value for the swapfile size - the value isn't numeric."
    exit
fi

if [[ "$boot_mode" == "UEFI" ]]; then
    if ! [[ "$efi_part_mountpoint" == "/boot/efi" || "$efi_part_mountpoint" == "/efi" ]]; then
        echo "Error: invalid EFI partition mount point detected. For maximized system compatibility, ALBI only supports the following mount points: /boot/efi (recommended) and /efi."
        exit
    fi
fi

if ! grep -qF "$language" "/etc/locale.gen"; then
    echo "Error: the language you picked, doesn't exist."
    exit
fi

## Determine if there are any custom packages specified for installation
if ! [[ -z "$custom_packages" ]]; then
    pacman -Sy

    IFS=" " read -ra packages <<< "$custom_packages"

    for package in "${packages[@]}"; do
        pacman_output=$(pacman -Ss "$package")
        if ! [[ -n "$pacman_output" ]]; then
            echo "Error: package $package not found."
            exit
        fi
    done
fi

## Verify if the reflector command execution encounters any errors
if [[ "$mirror_location" != "none" ]]; then
    reflector_output=$(reflector --country "$mirror_location")
    if [[ "$reflector_output" == *"error"* || "$reflector_output" == *"no mirrors found"* ]]; then
        echo "Error: invalid country name for Reflector."
        exit
    fi
fi

## Validate the existence of the specified partitions before proceeding
mount_output=$(df -h)
mount_partition=$(echo "$mount_output" | awk '$6=="/mnt" {print $1}')

if [[ "$separate_boot_part" != "none" ]]; then
    if [[ -e "$separate_boot_part" ]]; then
        boot_part_exists="true"
    else
        echo "Error: partition $separate_boot_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ "$root_part" != "none" ]]; then
    if [[ -n "$mount_partition" ]]; then
        echo "Error: /mnt is already mounted, however you specified another partition to mount it on."
        exit
    else
        if [[ -e "$root_part" ]]; then
            if [[ "$luks_encryption" == "yes" ]]; then
                if [[ "$boot_part_exists" == "true" ]]; then
                    root_part_orig="$root_part"
                    root_part_basename=$(basename "$root_part")
                    root_part_encrypted_name="${root_part_basename}_crypt"
                    echo "$luks_passphrase" | cryptsetup -q luksFormat "$root_part"
                    echo "$luks_passphrase" | cryptsetup -q open "$root_part" "$root_part_encrypted_name"
                    root_part="/dev/mapper/${root_part_encrypted_name}"
                    echo "root_part_orig=\"$root_part_orig\"" > tmpfile.sh
                    echo "root_part_encrypted_name=\"$root_part_encrypted_name\"" >> tmpfile.sh
                else
                    echo "Error: you haven't defined a separate boot partition. It is needed in order to encrypt the / partition."
                    exit
                fi
            fi

            if [[ "$root_part_filesystem" == "ext4" ]]; then
                yes | mkfs.ext4 "$root_part"
            elif [[ "$root_part_filesystem" == "ext3" ]]; then
                yes | mkfs.ext3 "$root_part"
            elif [[ "$root_part_filesystem" == "ext2" ]]; then
                yes | mkfs.ext2 "$root_part"
            elif [[ "$root_part_filesystem" == "btrfs" ]]; then
                yes | mkfs.btrfs "$root_part"
            elif [[ "$root_part_filesystem" == "xfs" ]]; then
                yes | mkfs.xfs "$root_part"
            else
                echo "Error: wrong filesystem for the / partition."
                exit
            fi
            mount "$root_part" /mnt
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
    if [[ -e "$separate_home_part" ]]; then
        home_part_exists="true"
    else
        echo "Error: partition $separate_home_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ "$separate_var_part" != "none" ]]; then
    if [[ -e "$separate_var_part" ]]; then
        var_part_exists="true"
    else
        echo "Error: partition $separate_var_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ "$separate_usr_part" != "none" ]]; then
    if [[ -e "$separate_usr_part" ]]; then
        usr_part_exists="true"
    else
        echo "Error: partition $separate_usr_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ "$separate_tmp_part" != "none" ]]; then
    if [[ -e "$separate_tmp_part" ]]; then
        tmp_part_exists="true"
    else
        echo "Error: partition $separate_tmp_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ "$home_part_exists" == "true" ]]; then
    if [[ "$separate_home_part_filesystem" == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_home_part"
    elif [[ "$separate_home_part_filesystem" == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_home_part"
    elif [[ "$separate_home_part_filesystem" == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_home_part"
    elif [[ "$separate_home_part_filesystem" == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_home_part"
    elif [[ "$separate_home_part_filesystem" == "xfs" ]]; then
        yes | mkfs.xfs "$separate_home_part"
    else
        echo "Error: wrong filesystem for the /home partition."
    fi
    mkdir -p /mnt/home
    mount "$separate_home_part" /mnt/home
fi

if [[ "$boot_part_exists" == "true" ]]; then
    if [[ "$separate_boot_part_filesystem" == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_boot_part"
    elif [[ "$separate_boot_part_filesystem" == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_boot_part"
    elif [[ "$separate_boot_part_filesystem" == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_boot_part"
    elif [[ "$separate_boot_part_filesystem" == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_boot_part"
    elif [[ "$separate_boot_part_filesystem" == "xfs" ]]; then
        yes | mkfs.xfs "$separate_boot_part"
    else
        echo "Error: wrong filesystem for the /boot partition."
    fi
    mkdir -p /mnt/boot
    mount "$separate_boot_part" /mnt/boot
fi

if [[ "$var_part_exists" == "true" ]]; then
    if [[ "$separate_var_part_filesystem" == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_var_part"
    elif [[ "$separate_var_part_filesystem" == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_var_part"
    elif [[ "$separate_var_part_filesystem" == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_var_part"
    elif [[ "$separate_var_part_filesystem" == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_var_part"
    elif [[ "$separate_var_part_filesystem" == "xfs" ]]; then
        yes | mkfs.xfs "$separate_var_part"
    else
        echo "Error: wrong filesystem for the /var partition."
    fi
    mkdir -p /mnt/var
    mount "$separate_var_part" /mnt/var
fi

if [[ "$separate_usr_part_exists" == "true" ]]; then
    if [[ "$separate_usr_part_filesystem" == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_usr_part"
    elif [[ "$separate_usr_part_filesystem" == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_usr_part"
    elif [[ "$separate_usr_part_filesystem" == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_usr_part"
    elif [[ "$separate_usr_part_filesystem" == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_usr_part"
    elif [[ "$separate_usr_part_filesystem" == "xfs" ]]; then
        yes | mkfs.xfs "$separate_usr_part"
    else
        echo "Error: wrong filesystem for the /usr partition."
    fi
    mkdir -p /mnt/usr
    mount "$separate_usr_part" /mnt/usr
fi

if [[ $tmp_part_exists == "true" ]]; then
    if [[ "$separate_tmp_part_filesystem" == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_tmp_part"
    elif [[ "$separate_tmp_part_filesystem" == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_tmp_part"
    elif [[ "$separate_tmp_part_filesystem" == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_tmp_part"
    elif [[ "$separate_tmp_part_filesystem" == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_tmp_part"
    elif [[ "$separate_tmp_part_filesystem" == "xfs" ]]; then
        yes | mkfs.xfs "$separate_tmp_part"
    else
        echo "Error: wrong filesystem for the /tmp partition."
    fi
    mkdir -p /mnt/tmp
    mount "$separate_tmp_part" /mnt/tmp
fi

if [[ "$boot_mode" == "UEFI" ]]; then
    efi_part_filesystem=$(blkid -s TYPE -o value $efi_part)
    if [[ "$efi_part_filesystem" != "vfat" ]]; then
        mkfs.fat -F32 "$efi_part"
        mkdir -p /mnt"$efi_part_mountpoint"
        mount "$efi_part" /mnt"$efi_part_mountpoint"
    else
        if ! findmnt --noheadings -o SOURCE "$efi_part_mountpoint" | grep -q "$efi_part"; then
            mkdir -p /mnt"$efi_part_mountpoint"
            mount "$efi_part" /mnt"$efi_part_mountpoint"
        else
            umount "$efi_part_mountpoint"
            mkdir -p /mnt"$efi_part_mountpoint"
            mount "$efi_part" "$efi_part_mountpoint"
        fi
    fi
elif [[ "$boot_mode" == "BIOS" ]]; then
    if ! [[ -b "$grub_disk" ]]; then
        echo "Error: disk path $grub_disk is not accessible or does not exist."
        exit
    fi
fi

## If a mirror location is specified, run Reflector and update the mirrorlist accordingly
if [[ "$mirror_location" != "none" ]]; then
    reflector --sort rate --country "$mirror_location" --save /etc/pacman.d/mirrorlist
fi

## Install the base system packages based on the selected kernel variant
if [[ "$kernel_variant" == "normal" ]]; then
    pacstrap -K /mnt base linux linux-firmware linux-headers
elif [[ "$kernel_variant" == "lts" ]]; then
    pacstrap -K /mnt base linux-lts linux-firmware linux-lts-headers
elif [[ "$kernel_variant" == "zen" ]]; then
    pacstrap -K /mnt base linux-zen linux-firmware linux-zen-headers
fi

## Automatically generate /etc/fstab based on the mounted partitions
genfstab -U /mnt >> /mnt/etc/fstab

## Create a temporary script to handle the main part of the installation process
touch main.sh
cat <<'EOFile' > main.sh
#!/bin/bash

## Define a signal handler for interruption signals
interrupt_handler() {
    echo "Interruption signal received. Aborting... "
    exit
}

trap interrupt_handler SIGINT

## Source the configuration file
source /config.conf
if [[ "$luks_encryption" == "yes" ]]; then
    source /tmpfile.sh
fi

## Set the system timezone and synchronize hardware clock
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc

## Install essential system packages and enable services
pacman -Sy btrfs-progs dosfstools inetutils net-tools ufw xfsprogs base-devel bash-completion bluez bluez-utils nano git grub ntfs-3g sshfs networkmanager wget exfat-utils usbutils xdg-utils xdg-user-dirs unzip unrar zip p7zip os-prober plymouth --noconfirm
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable ufw
ufw enable

## Determine the system's boot mode (UEFI or BIOS)
if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
    pacman -S efibootmgr --noconfirm
else
    boot_mode="BIOS"
fi

## Identify the CPU vendor and install the corresponding microcode package
vendor=$(grep -m1 vendor_id /proc/cpuinfo | cut -d ':' -f2 | tr -d '[:space:]')
if [[ "$vendor" == "GenuineIntel" ]]; then
    pacman -Sy intel-ucode --noconfirm
elif [[ "$vendor" == "AuthenticAMD" ]]; then
    pacman -Sy amd-ucode --noconfirm
fi

## Configure system locales, console keyboard layout, and hostname
sed -i "/$language/s/^#//" /etc/locale.gen
echo "LANG=$language" > /etc/locale.conf
echo "KEYMAP=$tty_keyboard_layout" > /etc/vconsole.conf
echo "$hostname" > /etc/hostname
locale-gen

## Configure the /etc/hosts file for local hostname resolution
echo "127.0.0.1       localhost" >> /etc/hosts
echo "127.0.1.1       $hostname" >> /etc/hosts
echo "" >> /etc/hosts
echo "# The following lines are desirable for IPv6 capable hosts" >> /etc/hosts
echo "::1             localhost ip6-localhost ip6-loopback" >> /etc/hosts
echo "ff02::1         ip6-allnodes" >> /etc/hosts
echo "ff02::2         ip6-allrouters" >> /etc/hosts

## Create an user
useradd -m "$username"
echo "$password" | passwd "$username" --stdin
if [[ "$full_username" != "" ]]; then
    usermod -c "$full_username" "$username"
fi
usermod -aG wheel "$username"

## Remove the password from the configuration file if it's going to be kept
if [[ "$keep_config" == "yes" ]]; then
    sed -i "s/^password=.*/password=\"\"/" config.conf
fi

## Apply system tweaks for enhanced usability
cln=$(grep -n "Color" /etc/pacman.conf | cut -d ':' -f1)
dln=$(grep -n "## Defaults specification" /etc/sudoers | cut -d ':' -f1)
sed -i 's/^# include "\/usr\/share\/nano\/\*\.nanorc"/include "\/usr\/share\/nano\/\*\.nanorc"/' /etc/nanorc
sed -i '/Color/s/^#//g' /etc/pacman.conf
sed -i "${cln}s/$/\nILoveCandy/" /etc/pacman.conf
sed -i "${dln}s/$/\nDefaults    pwfeedback/" /etc/sudoers
sed -i "${dln}s/$/\n##/" /etc/sudoers

## Install GRUB bootloader based on the detected boot mode
if [[ "$boot_mode" == "UEFI" ]]; then
    grub-install --target=x86_64-efi --efi-directory=$efi_part_mountpoint --bootloader-id="archlinux"
elif [[ "$boot_mode" == "BIOS" ]]; then
    grub-install --target=i386-pc "$grub_disk"
fi

## Configure mkinitcpio and GRUB
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

grub-mkconfig -o /boot/grub/grub.cfg

## Install the selected audio server and enable related services
if [[ "$audio_server" == "pipewire" ]]; then
    pacman -S pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol --noconfirm
    systemctl enable --global pipewire pipewire-pulse
elif [[ "$audio_server" == "pulseaudio" ]]; then
    pacman -S pulseaudio pavucontrol --noconfirm
    systemctl enable --global pulseaudio
fi

## Install the selected graphics driver (proceed with any additional configuration if needed)
if [[ "$gpu" == "amd" ]]; then
    pacman -S mesa vulkan-radeon libva-mesa-driver --noconfirm
elif [[ "$gpu" == "intel" ]]; then
    pacman -S mesa vulkan-intel intel-media-driver --noconfirm
elif [[ "$gpu" == "nvidia" ]]; then
    pacman -S nvidia nvidia-settings --noconfirm
    if grep -q "^GRUB_CMDLINE_LINUX=\"\"" /etc/default/grub; then
        sed -i "s|^\(GRUB_CMDLINE_LINUX=\"\)\(.*\)\"|\1nvidia-drm.modeset=1\"|" /etc/default/grub
    else
        sed -i "s|^\(GRUB_CMDLINE_LINUX=\".*\)\"|\1 nvidia-drm.modeset=1\"|" /etc/default/grub
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
elif [[ "$gpu" == "other" ]]; then
    pacman -S mesa libva-mesa-driver --noconfirm
fi

## Install the selected desktop environment along with related packages
if [[ "$de" == "gnome" ]]; then
    pacman -S xorg wayland --noconfirm
    pacman -S gnome nautilus noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gnome-tweaks gnome-shell-extensions gvfs gdm gnome-browser-connector power-profiles-daemon --noconfirm
    systemctl enable gdm
    if [[ "$gpu" == "nvidia" ]]; then
        ln -s /dev/null /etc/udev/rules.d/61-gdm.rules
    fi
elif [[ "$de" == "plasma" ]]; then
    pacman -S xorg wayland --noconfirm
    pacman -S sddm plasma kwalletmanager firewalld kate konsole dolphin spectacle ark noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon --noconfirm
    systemctl enable sddm
elif [[ "$de" == "xfce" ]]; then
    pacman -S xorg wayland --noconfirm
    pacman -S xfce4 xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs network-manager-applet power-profiles-daemon --noconfirm
    systemctl enable lightdm
elif [[ "$de" == "cinnamon" ]]; then
    pacman -S xorg wayland --noconfirm
    pacman -S blueman cinnamon cinnamon-translations nemo-fileroller gnome-terminal lightdm lightdm-slick-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon --noconfirm
    systemctl enable lightdm
    sed -i 's/#greeter-session=example-gtk-gnome/greeter-session=lightdm-slick-greeter/g' /etc/lightdm/lightdm.conf
elif [[ "$de" == "mate" ]]; then
    pacman -S xorg wayland --noconfirm
    pacman -S mate mate-extra blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon --noconfirm
    systemctl enable lightdm
fi

## If required, install CUPS and its related components
if [[ "$install_cups" == yes ]]; then
    pacman -S cups cups-browsed cups-filters cups-pk-helper bluez-cups foomatic-db foomatic-db-engine foomatic-db-gutenprint-ppds foomatic-db-nonfree foomatic-db-nonfree-ppds foomatic-db-ppds ghostscript gutenprint hplip nss-mdns system-config-printer --noconfirm
    systemctl enable cups.service
    systemctl enable cups.socket
    systemctl enable cups-browsed.service
    systemctl enable avahi-daemon.service
    systemctl enable avahi-daemon.socket
    sed -i "s/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/" /etc/nsswitch.conf
    rm -f /usr/share/applications/hplip.desktop /usr/share/applications/hplip.desktop.old
    rm -f /usr/share/applications/hp-uiscan.desktop /usr/share/applications/hp-uiscan.desktop.old
fi

## Install the AUR helper and additional packages
touch tmpscript.sh
cat <<'EOY' > tmpscript.sh
source /config.conf
cd
git clone https://aur.archlinux.org/yay
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay
yay -Sy --noconfirm
if [[ "$install_cups" == "yes" ]]; then
    yay -S hplip-plugin --noconfirm
fi
if [[ "$de" == "xfce" ]]; then
    yay -S mugshot --noconfirm
fi
if [[ "$de" == "cinnamon" ]]; then
    yay -S lightdm-settings --noconfirm
fi

### Clean up yay cache and remove unnecessary files after installation
yes | yay -Sc
yes | yay -Scc
EOY
chown "$username":"$username" tmpscript.sh
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/tmp
sudo -u "$username" bash tmpscript.sh
rm -f /etc/sudoers.d/tmp

## Add sudo privileges for the user
sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^#//g' /etc/sudoers

## If enabled, set up a swapfile for the system
if [[ "$create_swapfile" == "yes" ]]; then
    fallocate -l "$swapfile_size_gb"G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    echo "# /swapfile" >> /etc/fstab
    echo "/swapfile    none    swap    sw    0    0" >> /etc/fstab
fi

## Install additional packages specified by the user
IFS=" " read -ra packages <<< "$custom_packages"

for package in "${packages[@]}"; do
    pacman -S "$package" --noconfirm
done

## Re-generate the initial ramdisk for booting the system
mkinitcpio -P

## Remove unnecessary packages and files, and exit the script
while pacman -Qdtq; do
    pacman -Runs $(pacman -Qdtq) --noconfirm
done
yes | pacman -Sc
yes | pacman -Scc
if [[ "$keep_config" == "no" ]]; then
    rm -f /config.conf
else
    mv /config.conf /home/$username/
fi
rm -f /main.sh
rm -f /tmpfile.sh
rm -f /tmpscript.sh
exit
EOFile

## Copy configuration files and the second part of the script to the target system
if [[ "$luks_encryption" == "yes" ]]; then
    cp tmpfile.sh /mnt/
fi
cp main.sh /mnt/
cp config.conf /mnt/

## Enter the chroot environment and execute the second part of the installation script
arch-chroot /mnt bash main.sh
