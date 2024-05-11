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
if [ -e "config.conf" ]; then
    output=$(bash -n "$cwd"/config.conf 2>&1)
    if [[ -n $output ]]; then
        echo "Syntax errors found in the configuration file."
        exit
    else
        source "$cwd"/config.conf
    fi
else
    touch config.conf
    cat <<EOF > config.conf
## Here is the configuration for the installation.

## Formatting
# If you pick 'none' for a partition, it's left without doing anything. Remember to format it yourself if you choose this option.
# Possible values: btrfs, ext4, ext3, ext2, xfs, none.
root_part_filesystem="ext4"  # This sets the filesystem for the / partition.
separate_home_part_filesystem="none"  # This sets the filesystem for the /home partition.
separate_boot_part_filesystem="ext4"  # This sets the filesystem for the /boot partition.
separate_var_part_filesystem="none"  # This sets the filesystem for the /var partition.
separate_usr_part_filesystem="none"  # This sets the filesystem for the /usr partition.
separate_tmp_part_filesystem="none"  # This sets the filesystem for the /tmp partition.

## Mounting
# If you choose 'none' for a partition, it's ignored and left without doing anything. Remember to mount it yourself if you choose this option.
# Possible values are disk paths (e.g. /dev/sda1, /dev/sdc4).
root_part="/dev/sdX#"  # This sets the path for the / partition.
separate_home_part="none"  # This sets the path for the /home partition.
separate_boot_part="/dev/sdX#"  # This sets the path for the /boot partition.
separate_var_part="none"  # This sets the path for the /var partition.
separate_usr_part="none"  # This sets the path for the /usr partition.
separate_tmp_part="none"  # This sets the path for the /tmp partition.

## Encryption
luks_encryption="yes"  # Lets you to decide whether you want to encrypt the system. Valid values: yes, no.
luks_passphrase="4V3ryH@rdP4ssphr@s3!"  # Applies only when the encryption is set to yes.

EOF

if [[ $boot_mode == "UEFI" ]]; then
    echo "## EFI partition settings" >> config.conf
    echo "efi_part=\"/dev/sdX#\"  # Enter path to the EFI partition." >> config.conf
    echo "efi_part_mountpoint=\"/boot/efi\"  # Enter mountpoint of the EFI partition. This is also needed" >> config.conf
else
    echo "## GRUB installation disk settings" >> config.conf
    echo 'grub_disk="/dev/sdX"  # Enter path to the disk meant for grub installation.' >> config.conf
fi

cat <<EOF >> config.conf

## Kernel variant
kernel_variant="normal"  # Lets you to choose the kernel variant. Valid values: normal, lts, zen.

## Mirror servers location
mirror_location="Czechia"  # Lets you to choose country for mirror servers in your system. Valid values are english country names. You can select multiple countries - separate them with comma.

## Timezone setting
timezone="Europe/Prague"  # Defines the timezone for your system. Full list can be cound in the docs folder.

## Hostname and user
hostname="changeme"  # Defines the hostname of the machine.
username="changeme"  # Lets you to select an username for the user.
password="changeme"  # Lets you to select password for that user.

## Locales settings
language="en_US.UTF-8"  # Lets you to select the language of the system. Full list can be found in the docs folder.
console_keyboard_layout="us"  # Lets you to select the keyboard layout for the TTY. Full list can be found in the docs folder.

## Software selection
audio_server="pipewire"  # Lets you to select the audio server. Valid values: pulseaudio, pipewire, none.
nvidia_proprietary="no"  # Defines whether you want to use properietary Nvidia driver. Valid values: yes, no.
de="gnome"  # Lets you to select the desktop environment. Valid values: gnome, plasma, xfce, mate, cinnamon, none.
install_cups="yes"  # Lets you to decide whether CUPS should be installed, or not. Valid values: yes, no.
custom_packages="firefox htop neofetch papirus-icon-theme"  # Custom packages (separated by spaces). If you don't need any, leave the list empty.

## Swapfile settings
create_swapfile="yes"  # Creates swapfile. Valid values: yes, no.
swapfile_size_gb="4"  # Defines size of the swapfile. Valid values are only numbers.

## Script settings
keep_config="no"  # Lets you to choose whether you want to keep a copy of this file in /home/<your_username> after the installation. Valid values: yes, no.
EOF

echo "config.conf was generated successfully. Edit it to customize the installation."
exit
fi

## Check the config file values
echo "Verifying the config file..."

## Check variables values
if ! [[ $kernel_variant == "normal" || $kernel_variant == "lts" || $kernel_variant == "zen" ]]; then
    echo "Error: invalid value for the kernel variant."
    exit
fi

passwd_length=${#password}
username_length=${#username}
if [[ $passwd_length == 0 ]]; then
    echo "Error: user password not set"
    exit
fi
if [[ $username_length == 0 ]]; then
    echo "Error: username not set"
    exit
fi

if ! [[ $audio_server == "pipewire" || $audio_server == "pulseaudio" || $audio_server == "none" ]]; then
    echo "Error: invalid value for the audio server."
    exit
fi

if ! [[ $install_cups == "yes" || $install_cups == "no" ]]; then
    echo "Error: invalid value for the CUPS installation setting."
    exit
fi

if ! [[ $nvidia_proprietary == "yes" || $nvidia_proprietary == "no" ]]; then
    echo "Error: invalid value for the GPU driver."
    exit
fi

if ! [[ $de == "cinnamon" || $de == "gnome" || $de == "mate" || $de == "plasma" || $de == "xfce" || $de == "none" ]]; then
    echo "Error: invalid value for the desktop environment."
    exit
fi

if ! [[ $create_swapfile == "yes" || $create_swapfile == "no" ]]; then
    echo "Error: invalid value for the swapfile creation question."
    exit
fi

if ! [[ $swapfile_size_gb =~ ^[0-9]+$ ]]; then
    echo "Error: invalid value for the swapfile size - the value isn't numeric."
    exit
fi

## Check if any custom packages were defined
if ! [[ -z $custom_packages ]]; then
    pacman -Sy >/dev/null 2>&1

    IFS=" " read -ra packages <<< "$custom_packages"

    for package in "${packages[@]}"; do
        pacman_output=$(pacman -Ss "$package")
        if ! [[ -n "$pacman_output" ]]; then
            echo "Error: package '$package' not found."
            exit
        fi
    done
fi

## Check if reflector returns any errors
reflector_output=$(reflector --country $mirror_location)
if [[ $reflector_output == *"error"* || $reflector_output == *"no mirrors found"* ]]; then
    echo "Error: invalid country name for Reflector."
    exit
fi

## Check if the given partitions exist
mount_output=$(df -h)
mnt_partition=$(echo "$mount_output" | awk '$6=="/mnt" {print $1}')

if [ "$separate_boot_part" != "none" ]; then
    if [ -e "$separate_boot_part" ]; then
        boot_part_exists="true"
    else
        echo "Error: partition $separate_boot_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [ "$root_part" != "none" ]; then
    if [[ -n "$mnt_partition" ]]; then
        echo "Error: /mnt is already mounted, however you specified another partition to mount it on."
        exit
    else
        if [ -e "$root_part" ]; then
            if [ $luks_encryption == "yes" ]; then
                if [ $boot_part_exists == "true" ]; then
                    echo "Enabling encryption..."
                    root_part_orig="$root_part"
                    root_part_basename=$(basename "$root_part")
                    root_part_encrypted_name="$root_part_basename"_crypt
                    echo "$luks_passphrase" | cryptsetup -q luksFormat "$root_part"
                    echo "$luks_passphrase" | cryptsetup -q open "$root_part" "$root_part_encrypted_name"
                    root_part=/dev/mapper/"$root_part_encrypted_name"
                    echo "root_part_orig=\"$root_part_orig\"" > tmpfile.sh
                    echo "root_part_encrypted_name=\"$root_part_encrypted_name\"" >> tmpfile.sh
                else
                    echo "Error: you haven't defined a proper separate boot partition. It is needed in order to encrypt the / partition."
                    exit
                fi
            fi

            echo "Formatting and mounting specified partitions..."
            if [[ $root_part_filesystem == "ext4" ]]; then
                yes | mkfs.ext4 "$root_part" >/dev/null 2>&1
            elif [[ $root_part_filesystem == "ext3" ]]; then
                yes | mkfs.ext3 "$root_part" >/dev/null 2>&1
            elif [[ $root_part_filesystem == "ext2" ]]; then
                yes | mkfs.ext2 "$root_part" >/dev/null 2>&1
            elif [[ $root_part_filesystem == "btrfs" ]]; then
                yes | mkfs.btrfs "$root_part" >/dev/null 2>&1
            elif [[ $root_part_filesystem == "xfs" ]]; then
                yes | mkfs.xfs "$root_part" >/dev/null 2>&1
            else
                echo "Error: wrong filesystem for the / partition."
                exit
            fi
            mount "$root_part" /mnt >/dev/null 2>&1
        else
            echo "Error: partition $root_part isn't a valid path - it doesn't exist or isn't accessible."
            exit
        fi
    fi
elif [[ "$root_part" == "none" ]]; then
    if ! [ -n "$mnt_partition" ]; then
        echo "Error: no partition is mounted to / and you didn't define any in the config file."
        exit
    fi
fi

if [ "$separate_home_part" != "none" ]; then
    if [ -e "$separate_home_part" ]; then
        home_part_exists="true"
    else
        echo "Error: partition $separate_home_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [ "$separate_var_part" != "none" ]; then
    if [ -e "$separate_var_part" ]; then
        var_part_exists="true"
    else
        echo "Error: partition $separate_var_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [ "$separate_usr_part" != "none" ]; then
    if [ -e "$separate_usr_part" ]; then
        usr_part_exists="true"
    else
        echo "Error: partition $separate_usr_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [ "$separate_tmp_part" != "none" ]; then
    if [ -e "$separate_tmp_part" ]; then
        tmp_part_exists="true"
    else
        echo "Error: partition $separate_tmp_part isn't a valid path - it doesn't exist or isn't accessible."
        exit
    fi
fi

if [[ $home_part_exists == "true" ]]; then
    if [[ $separate_home_part_filesystem == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_home_part" >/dev/null 2>&1
    elif [[ $separate_home_part_filesystem == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_home_part" >/dev/null 2>&1
    elif [[ $separate_home_part_filesystem == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_home_part" >/dev/null 2>&1
    elif [[ $separate_home_part_filesystem == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_home_part" >/dev/null 2>&1
    elif [[ $separate_home_part_filesystem == "xfs" ]]; then
        yes | mkfs.xfs "$separate_home_part" >/dev/null 2>&1
    else
        echo "Error: wrong filesystem for the /home partition."
    fi
    mkdir -p /mnt/home
    mount "$separate_home_part" /mnt/home >/dev/null 2>&1
fi

if [[ $boot_part_exists == "true" ]]; then
    if [[ $separate_boot_part_filesystem == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_boot_part" >/dev/null 2>&1
    elif [[ $separate_boot_part_filesystem == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_boot_part" >/dev/null 2>&1
    elif [[ $separate_boot_part_filesystem == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_boot_part" >/dev/null 2>&1
    elif [[ $separate_boot_part_filesystem == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_boot_part" >/dev/null 2>&1
    elif [[ $separate_boot_part_filesystem == "xfs" ]]; then
        yes | mkfs.xfs "$separate_boot_part" >/dev/null 2>&1
    else
        echo "Error: wrong filesystem for the /boot partition."
    fi
    mkdir -p /mnt/boot
    mount "$separate_boot_part" /mnt/boot >/dev/null 2>&1
fi

if [[ $var_part_exists == "true" ]]; then
    if [[ $separate_var_part_filesystem == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_var_part" >/dev/null 2>&1
    elif [[ $separate_var_part_filesystem == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_var_part" >/dev/null 2>&1
    elif [[ $separate_var_part_filesystem == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_var_part" >/dev/null 2>&1
    elif [[ $separate_var_part_filesystem == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_var_part" >/dev/null 2>&1
    elif [[ $separate_var_part_filesystem == "xfs" ]]; then
        yes | mkfs.xfs "$separate_var_part" >/dev/null 2>&1
    else
        echo "Error: wrong filesystem for the /var partition."
    fi
    mkdir -p /mnt/var
    mount "$separate_var_part" /mnt/var >/dev/null 2>&1
fi

if [[ $separate_usr_part_exists == "true" ]]; then
    if [[ $separate_usr_part_filesystem == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_usr_part" >/dev/null 2>&1
    elif [[ $separate_usr_part_filesystem == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_usr_part" >/dev/null 2>&1
    elif [[ $separate_usr_part_filesystem == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_usr_part" >/dev/null 2>&1
    elif [[ $separate_usr_part_filesystem == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_usr_part" >/dev/null 2>&1
    elif [[ $separate_usr_part_filesystem == "xfs" ]]; then
        yes | mkfs.xfs "$separate_usr_part" >/dev/null 2>&1
    else
        echo "Error: wrong filesystem for the /usr partition."
    fi
    mkdir -p /mnt/usr
    mount "$separate_usr_part" /mnt/usr >/dev/null 2>&1
fi

if [[ $tmp_part_exists == "true" ]]; then
    if [[ $separate_tmp_part_filesystem == "ext4" ]]; then
        yes | mkfs.ext4 "$separate_tmp_part" >/dev/null 2>&1
    elif [[ $separate_tmp_part_filesystem == "ext3" ]]; then
        yes | mkfs.ext3 "$separate_tmp_part" >/dev/null 2>&1
    elif [[ $separate_tmp_part_filesystem == "ext2" ]]; then
        yes | mkfs.ext2 "$separate_tmp_part" >/dev/null 2>&1
    elif [[ $separate_tmp_part_filesystem == "btrfs" ]]; then
        yes | mkfs.btrfs "$separate_tmp_part" >/dev/null 2>&1
    elif [[ $separate_tmp_part_filesystem == "xfs" ]]; then
        yes | mkfs.xfs "$separate_tmp_part" >/dev/null 2>&1
    else
        echo "Error: wrong filesystem for the /tmp partition."
    fi
    mkdir -p /mnt/tmp
    mount "$separate_tmp_part" /mnt/tmp >/dev/null 2>&1
fi

if [[ $boot_mode == "UEFI" ]]; then
    efi_part_filesystem=$(blkid -s TYPE -o value $efi_part)
    if [[ $efi_part_filesystem != "vfat" ]]; then
        mkfs.fat -F32 "$efi_part" >/dev/null 2>&1
        mkdir -p /mnt"$efi_part_mountpoint"
        mount $efi_part /mnt"$efi_part_mountpoint"
    else
        if ! findmnt --noheadings -o SOURCE "$efi_part_mountpoint" | grep -q "$efi_part"; then
            mkdir -p /mnt"$efi_part_mountpoint"
            mount $efi_part /mnt"$efi_part_mountpoint"
        else
            umount $efi_part_mountpoint
            mkdir -p /mnt"$efi_part_mountpoint"
            mount $efi_part $efi_part_mountpoint
        fi
    fi
elif [[ $boot_mode == "BIOS" ]]; then
    if ! [ -b "$grub_disk" ]; then
        echo "Error: disk path $grub_disk is not accessible or does not exist."
        exit
    fi
fi

## Run Reflector
echo "Running Reflector..."
reflector --sort rate --protocol https --protocol rsync --country $mirror_location --save /etc/pacman.d/mirrorlist >/dev/null 2>&1

## Install base system
echo "Installing base system..."
if [[ $kernel_variant == "normal" ]]; then
    pacstrap -K /mnt base linux linux-firmware linux-headers >/dev/null 2>&1
elif [[ $kernel_variant == "lts" ]]; then
    pacstrap -K /mnt base linux-lts linux-firmware linux-lts-headers >/dev/null 2>&1
elif [[ $kernel_variant == "zen" ]]; then
    pacstrap -K /mnt base linux-zen linux-firmware linux-zen-headers >/dev/null 2>&1
fi

## Generate /etc/fstab
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

## Create a second, temporary file
touch main.sh
cat <<'EOFile' > main.sh
#!/bin/bash

## Interruption handler
interrupt_handler() {
    echo "Interruption signal received. Aborting... "
    exit
}

trap interrupt_handler SIGINT

## Source variables from config file
source /config.conf
source /tmpfile.sh

## Set timezone
echo "Setting the timezone..."
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc

## Install basic packages
echo "Installing basic packages..."
pacman -Sy btrfs-progs dosfstools inetutils net-tools xfsprogs base-devel bash-completion bluez bluez-utils nano git grub ntfs-3g sshfs networkmanager wget exfat-utils usbutils xdg-utils xdg-user-dirs unzip unrar p7zip os-prober plymouth --noconfirm >/dev/null 2>&1
systemctl enable NetworkManager >/dev/null 2>&1
systemctl enable bluetooth >/dev/null 2>&1

## Detect the system boot mode
if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
    pacman -S efibootmgr --noconfirm >/dev/null 2>&1
else
    boot_mode="BIOS"
fi

## Detect CPU vendor and install appropiate ucode package
vendor=$(grep -m1 vendor_id /proc/cpuinfo | cut -d ':' -f2 | tr -d '[:space:]')
if [[ $vendor == "GenuineIntel" ]]; then
    echo "Installing Intel microcode package..."
    pacman -Sy intel-ucode --noconfirm >/dev/null 2>&1
elif [[ $vendor == "AuthenticAMD" ]]; then
    echo "Installing AMD microcode package..."
    pacman -Sy amd-ucode --noconfirm >/dev/null 2>&1
else
    echo "Unknown CPU vendor - skipping microcode installation..."
fi

## Configure locales and hostname
echo "Configuring locales and hostname..."
sed -i "/$language/s/^#//" /etc/locale.gen
echo "LANG=$language" > /etc/locale.conf
echo "KEYMAP=$console_keyboard_layout" > /etc/vconsole.conf
locale-gen >/dev/null 2>&1
echo "$hostname" > /etc/hostname

## Configure the /etc/hosts file
echo "127.0.0.1       localhost" >> /etc/hosts
echo "127.0.0.1       $hostname" >> /etc/hosts
echo "" >> /etc/hosts
echo "# The following lines are desirable for IPv6 capable hosts" >> /etc/hosts
echo "::1             localhost ip6-localhost ip6-loopback" >> /etc/hosts
echo "ff02::1         ip6-allnodes" >> /etc/hosts
echo "ff02::2         ip6-allrouters" >> /etc/hosts

## Configure the user
useradd -m --badname $username >/dev/null 2>&1
passwd $username << EOP >/dev/null 2>&1
$password
$password
EOP
usermod -aG wheel $username

## For additional security, erase the password in the /config.conf file if it's meant to be kept
if [[ $keep_config == "yes" ]]; then
    sed -i "s/^password=.*/password=\"\"/" config.conf
fi

## Apply useful/needed tweaks
sed -i 's/^# include "\/usr\/share\/nano\/\*\.nanorc"/include "\/usr\/share\/nano\/\*\.nanorc"/' /etc/nanorc
sed -i '/Color/s/^#//g' /etc/pacman.conf
cln=$(grep -n "Color" /etc/pacman.conf | cut -d ':' -f1)
sed -i "${cln}s/$/\nILoveCandy/" /etc/pacman.conf
dln=$(grep -n "## Defaults specification" /etc/sudoers | cut -d ':' -f1)
sed -i "${dln}s/$/\nDefaults    pwfeedback/" /etc/sudoers
sed -i "${dln}s/$/\n##/" /etc/sudoers
sed -i 's/\(HOOKS=([^)]*\))/\1 plymouth)/' /etc/mkinitcpio.conf

## Install GRUB
if [[ $boot_mode == "UEFI" ]]; then
    echo "Installing GRUB (UEFI)..."
    grub-install --target=x86_64-efi --efi-directory=$efi_part_mountpoint --bootloader-id="archlinux" >/dev/null 2>&1
elif [[ $boot_mode == "BIOS" ]]; then
    echo "Installing GRUB (BIOS)..."
    grub-install --target=i386-pc $grub_disk >/dev/null 2>&1
fi

if [[ $luks_encryption == "yes" ]]; then
    cryptdevice_grub="$root_part_orig":"$root_part_encrypted_name"
    sed -i 's/\(HOOKS=([^)]*\))/\1 encrypt)/' /etc/mkinitcpio.conf
    if grep -q "^GRUB_CMDLINE_LINUX=\"\"" /etc/default/grub; then
        sed -i "s|^\(GRUB_CMDLINE_LINUX=\"\)\(.*\)\"|\1cryptdevice=$cryptdevice_grub\"|" /etc/default/grub
    else
        sed -i "s|^\(GRUB_CMDLINE_LINUX=\".*\)\"|\1 cryptdevice=$cryptdevice_grub\"|" /etc/default/grub
    fi
fi

grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1

## Install audio server
if [[ $audio_server == "pipewire" ]]; then
    echo "Installing PipeWire..."
    pacman -S pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol --noconfirm >/dev/null 2>&1
    systemctl enable --global pipewire pipewire-pulse >/dev/null 2>&1
elif [[ $audio_server == "pulseaudio" ]]; then
    echo "Installing Pulseaudio..."
    pacman -S pulseaudio pavucontrol --noconfirm >/dev/null 2>&1
    systemctl enable --global pulseaudio >/dev/null 2>&1
fi

## Install GPU driver
if [[ $nvidia_proprietary == "yes" ]]; then
    echo "Installing proprietary NVIDIA GPU driver..."
    pacman -S nvidia nvidia-settings --noconfirm >/dev/null 2>&1
    if grep -q "^GRUB_CMDLINE_LINUX=\"\"" /etc/default/grub; then
        sed -i "s|^\(GRUB_CMDLINE_LINUX=\"\)\(.*\)\"|\1nvidia-drm.modeset=1\"|" /etc/default/grub
    else
        sed -i "s|^\(GRUB_CMDLINE_LINUX=\".*\)\"|\1 nvidia-drm.modeset=1\"|" /etc/default/grub
    fi
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
fi

## Install DE
if [[ $de == "gnome" ]]; then
    echo "Installing GNOME desktop environment..."
    pacman -S xorg wayland --noconfirm >/dev/null 2>&1
    pacman -S gnome nautilus noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gnome-tweaks gnome-shell-extensions gvfs gdm gnome-browser-connector --noconfirm >/dev/null 2>&1
    systemctl enable gdm >/dev/null 2>&1
    if [[ $nvidia_proprietary == "yes" ]]; then
        ln -s /dev/null /etc/udev/rules.d/61-gdm.rules
    fi
elif [[ $de == "plasma" ]]; then
    echo "Installing KDE Plasma desktop environment..."
    pacman -S xorg wayland --noconfirm >/dev/null 2>&1
    pacman -S sddm plasma kwalletmanager firewalld kate konsole dolphin spectacle ark noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs power-profiles-daemon --noconfirm >/dev/null 2>&1
    systemctl enable sddm >/dev/null 2>&1
elif [[ $de == "xfce" ]]; then
    echo "Installing XFCE desktop environment..."
    pacman -S xorg wayland --noconfirm >/dev/null 2>&1
    pacman -S xfce4 xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs network-manager-applet --noconfirm >/dev/null 2>&1
    systemctl enable lightdm >/dev/null 2>&1
elif [[ $de == "cinnamon" ]]; then
    echo "Installing Cinnamon desktop environment..."
    pacman -S xorg wayland --noconfirm >/dev/null 2>&1
    pacman -S blueman cinnamon cinnamon-translations nemo-fileroller gnome-terminal lightdm lightdm-slick-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs --noconfirm >/dev/null 2>&1
    systemctl enable lightdm >/dev/null 2>&1
    sed -i 's/#greeter-session=example-gtk-gnome/greeter-session=lightdm-slick-greeter/g' /etc/lightdm/lightdm.conf
elif [[ $de == "mate" ]]; then
    echo "Installing MATE desktop environment..."
    pacman -S xorg wayland --noconfirm >/dev/null 2>&1
    pacman -S mate mate-extra blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs --noconfirm >/dev/null 2>&1
    systemctl enable lightdm >/dev/null 2>&1
fi

##  Check if CUPS should be installed
if [[ $install_cups == yes ]]; then
    echo "Installing CUPS..."
    pacman -S cups cups-browsed cups-filters cups-pk-helper bluez-cups foomatic-db foomatic-db-engine foomatic-db-gutenprint-ppds foomatic-db-nonfree foomatic-db-nonfree-ppds foomatic-db-ppds ghostscript gutenprint hplip nss-mdns system-config-printer --noconfirm >/dev/null 2>&1
    systemctl enable cups.service >/dev/null 2>&1
    systemctl enable cups.socket >/dev/null 2>&1
    systemctl enable cups-browsed.service >/dev/null 2>&1
    systemctl enable avahi-daemon.service >/dev/null 2>&1
    systemctl enable avahi-daemon.socket >/dev/null 2>&1
    sed -i "s/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/" /etc/nsswitch.conf
    mv /usr/share/applications/hplip.desktop /usr/share/applications/hplip.desktop.old
    mv /usr/share/applications/hp-uiscan.desktop /usr/share/applications/hp-uiscan.desktop.old
fi

## Install yay
echo "Installing Yay..."
touch tmpscript.sh
cat <<'EOY' > tmpscript.sh
source /config.conf
cd
git clone https://aur.archlinux.org/yay >/dev/null 2>&1
cd yay
makepkg -si --noconfirm >/dev/null 2>&1
cd ..
rm -rf yay
yay -Sy --noconfirm >/dev/null 2>&1
if [[ $install_cups == "yes" ]]; then
    echo "Installing hplip-plugin for CUPS from AUR..."
    yay -S hplip-plugin --noconfirm >/dev/null 2>&1
fi
if [[ $de == "xfce" ]]; then
    echo "Installing mugshot from AUR..."
    yay -S mugshot --noconfirm >/dev/null 2>&1
fi
if [[ $de == "cinnamon" ]]; then
    echo "Installing lightdm-settings from AUR..."
    yay -S lightdm-settings --noconfirm >/dev/null 2>&1
fi
EOY
chown "$username":"$username" tmpscript.sh
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/tmp
sudo -u "$username" bash tmpscript.sh
rm -f /etc/sudoers.d/tmp

## Add sudo privileges for the user
sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^#//g' /etc/sudoers

## Set-up swapfile
if [[ $create_swapfile == "yes" ]]; then
    echo "Creating swapfile..."
    fallocate -l "$swapfile_size_gb"G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    echo "# /swapfile" >> /etc/fstab
    echo "/swapfile    none    swap    sw    0    0" >> /etc/fstab
fi

## Install packages defined in custom_packages variable
echo "Installing custom packages..."
pacman -S $custom_packages --noconfirm >/dev/null 2>&1

## Re-generate initramfs
echo "Regenerating initramfs image..."
mkinitcpio -P >/dev/null 2>&1

## Clean up and exit
echo "Cleaning up..."
while pacman -Qdtq >/dev/null 2>&1; do
    pacman -R $(pacman -Qdtq) --noconfirm >/dev/null 2>&1
done
yes | pacman -Scc >/dev/null 2>&1
yes | yay -Scc >/dev/null 2>&1
if [[ $keep_config == "no" ]]; then
    rm -f /config.conf
else
    mv /config.conf /home/$username/
fi
rm -f /main.sh
rm -f /tmpfile.sh
rm -f /tmpscript.sh
exit
EOFile

## Copy config file and the second part of the script to /
cp tmpfile.sh /mnt/
cp main.sh /mnt/
cp config.conf /mnt/

## Enter arch-chroot and run second part of the script
arch-chroot /mnt bash main.sh
