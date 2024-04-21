#!/bin/bash

## Interruption handler
interrupt_handler() {
    echo "Interruption signal received. Aborting... "
    exit
}

trap interrupt_handler SIGINT

verbose=false

## Function to display verbose output
verbosity_control() {
    if [ "$verbose" = true ]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

## Check options
if [[ "$#" -gt 0 ]]; then
    case $1 in
        -h|--help)
            echo "ALBI - Arch Linux Bash Installer"
            echo ""
            echo "-h --help - show this help and exit."
            echo "-v --verbose - enable verbose mode."
            echo ""
            exit 0
            ;;
        -v|--verbose)
            verbose=true
            ;;
        *)
            echo "Error: Unknown option '$1'"
            exit 1
            ;;
    esac
fi

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

## Partitioning helper
# If you don't want to use the partitioning helper, set none to all the partitions.
# Possible values are disk paths (e.g. /dev/sda1, /dev/sdc4)
root_part="/dev/sdX#"
separate_home_part="none"
separate_boot_part="none"
separate_var_part="none"
separate_usr_part="none"
separate_tmp_part="none"

EOF

if [[ $boot_mode == "UEFI" ]]; then
    echo 'efi_part="/dev/sdX#"  # Enter path to the EFI partition' >> config.conf
    echo 'efi_part_mountpoint="/boot/efi"  # Enter mountpoint of the EFI partition.' >> config.conf
else
    echo 'grub_disk="/dev/sdX"  # Enter path to the disk meant for grub installation.' >> config.conf
fi

cat <<EOF >> config.conf

## Formatting helper
# If you don't want to use the formatting helper, set none to all the partitions.
# Possible values: btrfs, ext4, ext3, ext2, xfs.
root_part_filesystem="ext4"
separate_home_part_filesystem="none"
separate_boot_part_filesystem="none"
separate_var_part_filesystem="none"
separate_usr_part_filesystem="none"
separate_tmp_part_filesystem="none"

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

## System settings
create_swapfile="yes"  # Creates swapfile. Valid values: yes, no.
swapfile_size_gb="4"  # Defines size of the swapfile. Valid values are only numbers.
pcspkr_disable="yes"  # Disables onboard pc beeper. Valid values: yes, no.

## Script settings
keep_config="yes"  # Lets you to choose whether you want to keep a copy of this file in /home/<your_username> after the installation. Valid values: yes, no.
EOF

echo "config.conf was generated successfully. Edit it to customize the installation."
exit
fi

## Check the config file values
echo "Verifying the config file..."

## Check if the given partitions exist
mount_output=$(df -h)
mnt_partition=$(echo "$mount_output" | awk '$6=="/mnt" {print $1}')

if [ "$root_part" != "none" ]; then
    if [[ -n "$mnt_partition" ]]; then
        echo "Error: /mnt is already mounted, however you specified another partition to mount it on."
        exit
    else
        if [ -e "$root_part" ]; then
            echo "Formatting and mounting specified partitions..."
            if [[ $root_part_filesystem == "ext4" ]]; then
                yes | verbosity_control mkfs.ext4 "$root_part"
            elif [[ $root_part_filesystem == "ext3" ]]; then
                yes | verbosity_control mkfs.ext3 "$root_part"
            elif [[ $root_part_filesystem == "ext2" ]]; then
                yes | verbosity_control mkfs.ext2 "$root_part"
            elif [[ $root_part_filesystem == "btrfs" ]]; then
                yes | verbosity_control mkfs.btrfs "$root_part"
            elif [[ $root_part_filesystem == "xfs" ]]; then
                yes | verbosity_control mkfs.xfs "$root_part"
            else
                echo "Error: wrong filesystem for the / partition."
                exit
            fi
            verbosity_control mount "$root_part" /mnt
        else
            echo "Error: partition $root_part isn't a valid path - it doesn't exist or isn't accessible."
            exit
        fi
    fi
elif [[ "$root_part" == "none" ]]; then
    if [ -n "$mnt_partition" ]; then
        :
    else
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

if [ "$separate_boot_part" != "none" ]; then
    if [ -e "$separate_boot_part" ]; then
        boot_part_exists="true"
    else
        echo "Error: partition $separate_boot_part isn't a valid path - it doesn't exist or isn't accessible."
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
        yes | verbosity_control mkfs.ext4 "$separate_home_part"
    elif [[ $separate_home_part_filesystem == "ext3" ]]; then
        yes | verbosity_control mkfs.ext3 "$separate_home_part"
    elif [[ $separate_home_part_filesystem == "ext2" ]]; then
        yes | verbosity_control mkfs.ext2 "$separate_home_part"
    elif [[ $separate_home_part_filesystem == "btrfs" ]]; then
        yes | verbosity_control mkfs.btrfs "$separate_home_part"
    elif [[ $separate_home_part_filesystem == "xfs" ]]; then
        yes | verbosity_control mkfs.xfs "$separate_home_part"
    else
        echo "Error: wrong filesystem for the /home partition."
    fi
    mkdir -p /mnt/home
    verbosity_control mount "$separate_home_part" /mnt/home
else
    :
fi

if [[ $boot_part_exists == "true" ]]; then
    if [[ $separate_boot_part_filesystem == "ext4" ]]; then
        yes | verbosity_control mkfs.ext4 "$boot_part"
    elif [[ $separate_boot_part_filesystem == "ext3" ]]; then
        yes | verbosity_control mkfs.ext3 "$boot_part"
    elif [[ $separate_boot_part_filesystem == "ext2" ]]; then
        yes | verbosity_control mkfs.ext2 "$boot_part"
    elif [[ $separate_boot_part_filesystem == "btrfs" ]]; then
        yes | verbosity_control mkfs.btrfs "$boot_part"
    elif [[ $separate_boot_part_filesystem == "xfs" ]]; then
        yes | verbosity_control mkfs.xfs "$boot_part"
    else
        echo "Error: wrong filesystem for the /boot partition."
    fi
    verbosity_control mount "$separate_boot_part" /mnt/boot
else
    :
fi

if [[ $var_part_exists == "true" ]]; then
    if [[ $separate_var_part_filesystem == "ext4" ]]; then
        yes | verbosity_control mkfs.ext4 "$separate_var_part"
    elif [[ $separate_var_part_filesystem == "ext3" ]]; then
        yes | verbosity_control mkfs.ext3 "$separate_var_part"
    elif [[ $separate_var_part_filesystem == "ext2" ]]; then
        yes | verbosity_control mkfs.ext2 "$separate_var_part"
    elif [[ $separate_var_part_filesystem == "btrfs" ]]; then
        yes | verbosity_control mkfs.btrfs "$separate_var_part"
    elif [[ $separate_var_part_filesystem == "xfs" ]]; then
        yes | verbosity_control mkfs.xfs "$separate_var_part"
    else
        echo "Error: wrong filesystem for the /var partition."
    fi
    verbosity_control mount "$separate_var_part" /mnt/var
else
    :
fi

if [[ $separate_usr_part_exists == "true" ]]; then
    if [[ $separate_usr_part_filesystem == "ext4" ]]; then
        yes | verbosity_control mkfs.ext4 "$separate_usr_part"
    elif [[ $separate_usr_part_filesystem == "ext3" ]]; then
        yes | verbosity_control mkfs.ext3 "$separate_usr_part"
    elif [[ $separate_usr_part_filesystem == "ext2" ]]; then
        yes | verbosity_control mkfs.ext2 "$separate_usr_part"
    elif [[ $separate_usr_part_filesystem == "btrfs" ]]; then
        yes | verbosity_control mkfs.btrfs "$separate_usr_part"
    elif [[ $separate_usr_part_filesystem == "xfs" ]]; then
        yes | verbosity_control mkfs.xfs "$separate_usr_part"
    else
        echo "Error: wrong filesystem for the /usr partition."
    fi
    verbosity_control mount "$separate_usr_part" /mnt/usr
else
    :
fi

if [[ $tmp_part_exists == "true" ]]; then
    if [[ $separate_tmp_part_filesystem == "ext4" ]]; then
        yes | verbosity_control mkfs.ext4 "$separate_tmp_part"
    elif [[ $separate_tmp_part_filesystem == "ext3" ]]; then
        yes | verbosity_control mkfs.ext3 "$separate_tmp_part"
    elif [[ $separate_tmp_part_filesystem == "ext2" ]]; then
        yes | verbosity_control mkfs.ext2 "$separate_tmp_part"
    elif [[ $separate_tmp_part_filesystem == "btrfs" ]]; then
        yes | verbosity_control mkfs.btrfs "$separate_tmp_part"
    elif [[ $separate_tmp_part_filesystem == "xfs" ]]; then
        yes | verbosity_control mkfs.xfs "$separate_tmp_part"
    else
        echo "Error: wrong filesystem for the /tmp partition."
    fi
    verbosity_control mount "$separate_tmp_part" /mnt/tmp
else
    :
fi

if [[ $boot_mode == "UEFI" ]]; then
    efi_part_filesystem=$(blkid -s TYPE -o value $efi_part)
    if [[ $efi_part_filesystem != "vfat" ]]; then
        yes | verbosity_control mkfs.fat -F32 "$efi_part"
        mkdir -p /mnt"$efi_part_mountpoint"
        mount $efi_part /mnt"$efi_part_mountpoint"
    else
        mkdir -p /mnt"$efi_part_mountpoint"
        mount $efi_part /mnt"$efi_part_mountpoint"
    fi
elif [[ $boot_mode == "BIOS" ]]; then
    if [ -b "$grub_disk" ]; then
        :
    else
        echo "Error: disk path $grub_disk is not accessible or does not exist."
        exit
    fi
fi

## Check variables values
if [[ $kernel_variant == "normal" || $kernel_variant == "lts" || $kernel_variant == "zen" ]]; then
    :
else
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

if [[ $audio_server == "pipewire" || $audio_server == "pulseaudio" || $audio_server == "none" ]]; then
    :
else
    echo "Error: invalid value for the audio server."
    exit
fi

if [[ $install_cups == "yes" || $install_cups == "no" ]]; then
    :
else
    echo "Error: invalid value for the CUPS installation setting."
    exit
fi

if [[ $nvidia_proprietary == "yes" || $nvidia_proprietary == "no" ]]; then
    :
else
    echo "Error: invalid value for the GPU driver."
    exit
fi

if [[ $de == "cinnamon" || $de == "gnome" || $de == "mate" || $de == "plasma" || $de == "xfce" || $de == "none" ]]; then
    :
else
    echo "Error: invalid value for the desktop environment."
    exit
fi

if [[ $create_swapfile == "yes" || $create_swapfile == "no" ]]; then
    :
else
    echo "Error: invalid value for the swapfile creation question."
    exit
fi

if [[ $swapfile_size_gb =~ ^[0-9]+$ ]]; then
    :
else
    echo "Error: invalid value for the swapfile size - the value isn't numeric."
    exit
fi

if [[ $pcspkr_disable == "yes" || $pcspkr_disable == "no" ]]; then
    :
else
    echo "Error: invalid value for the onboard PC speaker setting."
    exit
fi

## Check if any custom packages were defined
if [[ -z $custom_packages ]]; then
    :
else
    pacman -Sy
    
    IFS=" " read -ra packages <<< "$custom_packages"
    
    for package in "${packages[@]}"; do
        pacman_output=$(pacman -Ss "$package")
        if [[ -n "$pacman_output" ]]; then
            :
        else
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

## Run Reflector
echo "Running Reflector..."
reflector --sort rate --protocol https --protocol rsync --country $mirror_location --save /etc/pacman.d/mirrorlist

## Install base system
echo "Installing base system..."
if [[ $kernel_variant == "normal" ]]; then
    verbosity_control pacstrap -K /mnt base linux linux-firmware linux-headers
elif [[ $kernel_variant == "lts" ]]; then
    verbosity_control pacstrap -K /mnt base linux-lts linux-firmware linux-lts-headers
elif [[ $kernel_variant == "zen" ]]; then
    verbosity_control pacstrap -K /mnt base linux-zen linux-firmware linux-zen-headers
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

## Set timezone
echo "Setting the timezone..."
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc

## Install basic packages
echo "Installing basic packages..."
verbosity_control pacman -Sy btrfs-progs dosfstools inetutils net-tools xfsprogs base-devel bash-completion bluez bluez-utils nano git grub ntfs-3g sshfs networkmanager wget exfat-utils usbutils xdg-utils xdg-user-dirs unzip unrar p7zip os-prober plymouth --noconfirm
verbosity_control systemctl enable NetworkManager
verbosity_control systemctl enable bluetooth

## Detect the system boot mode
if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
    verbosity_control pacman -S efibootmgr --noconfirm
else
    boot_mode="BIOS"
fi

## Detect CPU vendor and install appropiate ucode package
vendor=$(grep -m1 vendor_id /proc/cpuinfo | cut -d ':' -f2 | tr -d '[:space:]')
if [[ $vendor == "GenuineIntel" ]]; then
    echo "Installing Intel microcode package..."
    verbosity_control pacman -Sy intel-ucode --noconfirm
elif [[ $vendor == "AuthenticAMD" ]]; then
    echo "Installing AMD microcode package..."
    verbosity_control pacman -Sy amd-ucode --noconfirm
else
    echo "Unknown CPU vendor - skipping microcode installation..."
fi

## Configure locales and hostname
echo "Configuring locales and hostname..."
sed -i "/$language/s/^#//" /etc/locale.gen
echo "LANG=$language" > /etc/locale.conf
echo "KEYMAP=$console_keyboard_layout" > /etc/vconsole.conf
verbosity_control locale-gen
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
verbosity_control useradd -m --badname $username
verbosity_control passwd $username << EOP
$password
$password
EOP
verbosity_control usermod -aG wheel $username

## For additional security, erase the password in the /config.conf file if it's meant to be kept
if [[ $keep_config == "yes" ]]; then
    sed -i "s/^password=.*/password=\"\"/" config.conf
fi

## Apply useful tweaks
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
    verbosity_control grub-install --target=x86_64-efi --efi-directory=$efi_part_mountpoint --bootloader-id="archlinux"
    verbosity_control grub-mkconfig -o /boot/grub/grub.cfg
elif [[ $boot_mode == "BIOS" ]]; then
    echo "Installing GRUB (BIOS)..."
    verbosity_control grub-install --target=i386-pc $grub_disk
    verbosity_control grub-mkconfig -o /boot/grub/grub.cfg
fi

## Install audio server
if [[ $audio_server == "pipewire" ]]; then
    echo "Installing PipeWire..."
    verbosity_control pacman -S pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber --noconfirm
    verbosity_control systemctl enable --global pipewire pipewire-pulse
elif [[ $audio_server == "pulseaudio" ]]; then
    echo "Installing Pulseaudio..."
    verbosity_control pacman -S pulseaudio pavucontrol --noconfirm
    verbosity_control systemctl enable --global pulseaudio
fi

## Install GPU driver
if [[ $nvidia_proprietary == "yes" ]]; then
    echo "Installing proprietary NVIDIA GPU driver..."
    verbosity_control pacman -S nvidia nvidia-settings --noconfirm
    sed -i 's/^\(GRUB_CMDLINE_LINUX=".*\)"/\1 nvidia-drm.modeset=1"/' /etc/default/grub
    verbosity_control grub-mkconfig -o /boot/grub/grub.cfg
fi

## Install DE
if [[ $de == "gnome" ]]; then
    echo "Installing GNOME desktop environment..."
    verbosity_control pacman -S xorg wayland --noconfirm
    verbosity_control pacman -S gnome nautilus noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gnome-tweaks gnome-shell-extensions gvfs gdm gnome-browser-connector pavucontrol --noconfirm
    verbosity_control systemctl enable gdm
    if [[ $nvidia_proprietary == "yes" ]]; then
        ln -s /dev/null /etc/udev/rules.d/61-gdm.rules
    fi
elif [[ $de == "plasma" ]]; then
    echo "Installing KDE Plasma desktop environment..."
    verbosity_control pacman -S xorg wayland --noconfirm
    verbosity_control pacman -S sddm plasma kwalletmanager firewalld kate konsole dolphin spectacle ark noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs pavucontrol --noconfirm
    verbosity_control systemctl enable sddm
elif [[ $de == "xfce" ]]; then
    echo "Installing XFCE desktop environment..."
    verbosity_control pacman -S xorg wayland --noconfirm
    verbosity_control pacman -S xfce4 xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs network-manager-applet pavucontrol --noconfirm
    verbosity_control systemctl enable lightdm
elif [[ $de == "cinnamon" ]]; then
    echo "Installing Cinnamon desktop environment..."
    verbosity_control pacman -S xorg wayland --noconfirm
    verbosity_control pacman -S blueman cinnamon cinnamon-translations nemo-fileroller gnome-terminal lightdm lightdm-slick-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs pavucontrol --noconfirm
    verbosity_control systemctl enable lightdm
    sed -i 's/#greeter-session=example-gtk-gnome/greeter-session=lightdm-slick-greeter/g' /etc/lightdm/lightdm.conf
elif [[ $de == "mate" ]]; then
    echo "Installing MATE desktop environment..."
    verbosity_control pacman -S xorg wayland --noconfirm
    verbosity_control pacman -S mate mate-extra blueman lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs pavucontrol --noconfirm
    verbosity_control systemctl enable lightdm
fi

##  Check if CUPS should be installed
if [[ $install_cups == yes ]]; then
    echo "Installing CUPS..."
    verbosity_control pacman -S cups cups-browsed cups-filters cups-pk-helper bluez-cups foomatic-db foomatic-db-engine foomatic-db-gutenprint-ppds foomatic-db-nonfree foomatic-db-nonfree-ppds foomatic-db-ppds ghostscript gutenprint hplip nss-mdns system-config-printer --noconfirm
    verbosity_control systemctl enable cups.service
    verbosity_control systemctl enable cups.socket
    verbosity_control systemctl enable cups-browsed.service
    verbosity_control systemctl enable avahi-daemon.service
    verbosity_control systemctl enable avahi-daemon.socket
    sed -i "s/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/" /etc/nsswitch.conf
    rm -f /usr/share/applications/hplip.desktop /usr/share/applications/hplip.desktop.old
    rm -f /usr/share/applications/hp-uiscan.desktop /usr/share/applications/hp-uiscan.desktop.old
fi

## Install yay
echo "Installing Yay..."
touch tmpscript.sh
cat <<'EOY' > tmpscript.sh
source /config.conf
cd
verbosity_control git clone https://aur.archlinux.org/yay
cd yay
verbosity_control makepkg -si --noconfirm
cd ..
rm -rf yay
verbosity_control yay -Sy --noconfirm
if [[ $install_cups == "yes" ]]; then
    echo "Installing hplip-plugin for CUPS from AUR..."
    verbosity_control yay -S hplip-plugin --noconfirm
fi
if [[ $de == "xfce" ]]; then
    echo "Installing mugshot from AUR..."
    verbosity_control yay -S mugshot --noconfirm
fi
if [[ $de == "cinnamon" ]]; then
    echo "Installing lightdm-settings from AUR..."
    verbosity_control yay -S lightdm-settings --noconfirm
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
    verbosity_control mkswap /swapfile
    echo "# /swapfile" >> /etc/fstab
    echo "/swapfile    none    swap    sw    0    0" >> /etc/fstab
fi

## Install packages defined in custom_packages variable
echo "Installing custom packages..."
verbosity_control pacman -S $custom_packages --noconfirm

## Onboard PC speaker setting
if [[ $pcspkr_disable == "yes" ]]; then
    echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf
fi

## Re-generate initramfs
echo "Regenerating initramfs image..."
verbosity_control mkinitcpio -P

## Clean up and exit
echo "Cleaning up..."
while pacman -Qtdq; do
    verbosity_control pacman -R $(pacman -Qtdq) --noconfirm
done
yes | verbosity_control pacman -Scc
yes | verbosity_control yay -Scc
if [[ $keep_config == "no" ]]; then
    rm -f /config.conf
else
    mv /config.conf /home/$username/
fi
rm -f /main.sh
rm -f /tmpscript.sh
exit
EOFile

## Copy config file and the second part of the script to /
cp main.sh /mnt/
cp config.conf /mnt/

## Enter arch-chroot and run second part of the script
arch-chroot /mnt bash main.sh
