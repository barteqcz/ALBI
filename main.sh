#!/bin/bash

# Interruption handler
interrupt_handler() {
    echo "Interruption signal received. Aborting... "
}

trap interrupt_handler SIGINT

# Source variables from config file
source /config.conf

# Set timezone
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc

# Fix potential archlinux-keyring problem
while ! pacman -Sy --noconfirm >/dev/null 2>&1; do
    killall gpg-agent >/dev/null 2>&1
    rm -rf /etc/pacman.d/gnupg/ >/dev/null 2>&1
    pacman-key --init >/dev/null 2>&1
    pacman-key --populate >/dev/null 2>&1
    pacman -Sy archlinux-keyring --noconfirm >/dev/null 2>&1
done

# Install basic packages
echo "Installing basic packages..."
pacman -Sy base-devel bash-completion nano grub ntfs-3g sshfs networkmanager wget exfat-utils xdg-utils xdg-user-dirs unzip unrar --noconfirm >/dev/null 2>&1

# Detect the system boot mode
if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
    pacman -S efibootmgr --noconfirm >/dev/null 2>&1
else
    boot_mode="BIOS"
fi

# Detect CPU vendor and install appropiate ucode package
vendor=$(grep -m1 vendor_id /proc/cpuinfo | cut -d ':' -f2 | tr -d '[:space:]')
if [[ $vendor == "GenuineIntel" ]]; then
    echo "Installing Intel microcode package..."
    pacman -Sy intel-ucode --noconfirm >/dev/null 2>&1
elif [[ $vendor == "AuthenticAMD" ]]; then
    echo "Installing AMD microcode package..."
    pacman -Sy amd-ucode --noconfirm >/dev/null 2>&1
fi

# Configure locales and hostname
echo "Configuring locales and hostname..."
sed -i "/$language/s/^#//" /etc/locale.gen
echo "LANG=$language" > /etc/locale.conf
echo "KEYMAP=$console_keyboard_layout" > /etc/vconsole.conf
locale-gen >/dev/null 2>&1
echo "$hostname" > /etc/hostname

# Configure the /etc/hosts file
echo "# The following lines are desirable for IPv4 capable hosts" > /etc/hosts
echo "127.0.0.1       localhost" >> /etc/hosts
echo "" >> /etc/hosts
echo "# The following lines are desirable for IPv6 capable hosts" >> /etc/hosts
echo "::1             localhost ip6-localhost ip6-loopback" >> /etc/hosts
echo "ff02::1         ip6-allnodes" >> /etc/hosts
echo "ff02::2         ip6-allrouters" >> /etc/hosts

# Configure the user
useradd -m $username >/dev/null 2>&1
echo "$username:$password" | chpasswd
usermod -aG wheel $username
sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^#//g' /etc/sudoers

# Apply useful tweaks
sed -i 's/^# include "\/usr\/share\/nano\/\*\.nanorc"/include "\/usr\/share\/nano\/\*\.nanorc"/' /etc/nanorc
sed -i '/Color/s/^#//g' /etc/pacman.conf
cln=$(grep -n "Color" /etc/pacman.conf | cut -d ':' -f1)
sed -i "${cln}s/$/\nILoveCandy/" /etc/pacman.conf
dln=$(grep -n "## Defaults specification" /etc/sudoers | cut -d ':' -f1)
sed -i "${dln}s/$/\nDefaults    pwfeedback/" /etc/sudoers
sed -i "${dln}s/$/\n##/" /etc/sudoers

# Install GRUB
if [[ $boot_mode == "UEFI" ]]; then
    echo "Installing GRUB (UEFI)..."
    grub-install --target=x86_64-efi --efi-directory=$efi_partition --bootloader-id="Arch Linux" >/dev/null 2>&1
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
elif [[ $boot_mode == "BIOS" ]]; then
    echo "Installing GRUB (BIOS)..."
    grub-install --target=i386-pc $grub_disk >/dev/null 2>&1
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
fi

# Install audio server
if [[ $audio_server == "pipewire" ]]; then
    echo "Installing PipeWire..."
    pacman -S pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol --noconfirm >/dev/null 2>&1
    systemctl enable --global pipewire pipewire-pulse >/dev/null 2>&1
elif [[ $audio_server == "pulseaudio" ]]; then
    echo "Installing Pulseaudio..."
    pacman -S pulseaudio pavucontrol --noconfirm >/dev/null 2>&1
    systemctl enable --global pulseaudio >/dev/null 2>&1
fi

# Install GPU driver
if [[ $gpu_driver == "nvidia" ]]; then
    echo "Installing NVIDIA GPU driver..."
    pacman -S nvidia nvidia-utils nvidia-settings --noconfirm >/dev/null 2>&1
elif [[ $gpu_drvier == "amd" ]]; then
    echo "Installing AMD GPU driver..."
    pacman -S mesa xf86-video-amdgpu xf86-video-ati libva-mesa-driver vulkan-radeon --noconfirm >/dev/null 2>&1
elif [[ $gpu_driver == "intel" ]]; then
    echo "Installing Intel GPU driver..."
    pacman -S mesa libva-intel-driver intel-media-driver vulkan-intel --noconfirm >/dev/null 2>&1
elif [[ $gpu_driver == "vm" ]]; then
    echo "Installing VMware GPU driver..."
    pacman -S mesa xf86-video-vmware --noconfirm >/dev/null 2>&1
elif [[ $gpu_driver == "nouveau" ]]; then
    echo "Installing Nouveau GPU driver..."
    pacman -S mesa xf86-video-nouveau libva-mesa-driver --noconfirm >/dev/null 2>&1
elif [[ $gpu_driver == "none" ]]; then
    :
fi

# Install DE
if [[ $de == "gnome" ]]; then
    echo "Installing GNOME desktop environment..."
    pacman -S xorg xorg-wayland wayland glfw-wayland gdm gnome nautilus noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs htop gnome-tweaks gnome-shell-extensions --noconfirm >/dev/null 2>&1
    systemctl enable gdm >/dev/null 2>&1
elif [[ $de == "plasma" ]]; then
    echo "Installing KDE Plasma desktop environment..."
    pacman -S xorg xorg-xwayland wayland qt5-wayland glfw-wayland sddm plasma-wayland-session plasma kwalletmanager firewalld kate konsole dolphin spectacle ark noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs htop --noconfirm >/dev/null 2>&1
    systemctl enable sddm >/dev/null 2>&1
elif [[ $de == "xfce" ]]; then
    echo "Installing XFCE desktop environment..."
    pacman -S xorg xfce4 xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools lightdm lightdm-gtk-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs network-manager-applet htop --noconfirm >/dev/null 2>&1
    systemctl enable lightdm >/dev/null 2>&1
elif [[ $de == "none" ]]; then
    :
fi

# Enable Nvidia driver KMS if it's needed
if [[ $de != "none" && $gpu_driver == "nvidia" ]]; then
    sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="nvidia_drm.modeset=1"/' /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
fi

# Enable Network Manager
systemctl enable NetworkManager >/dev/null 2>&1

# Install CUPS
if [[ $cups_installation == "yes" ]]; then
    echo "Installing CUPS..."
    pacman -S cups cups-filters cups-pk-helper bluez-cups foomatic-db foomatic-db-engine foomatic-db-gutenprint-ppds foomatic-db-nonfree foomatic-db-nonfree-ppds foomatic-db-ppds ghostscript gutenprint nss-mdns system-config-printer --noconfirm >/dev/null 2>&1
    systemctl enable cups.service >/dev/null 2>&1
    systemctl enable cups.socket >/dev/null 2>&1
    systemctl enable cups-browsed.service >/dev/null 2>&1
    systemctl enable avahi-daemon.service >/dev/null 2>&1
    systemctl enable avahi-daemon.socket >/dev/null 2>&1
    sed -i "s/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/" /etc/nsswitch.conf
elif [[ $cups_installation == "no" ]]; then
    :
fi

# Set-up swapfile
if [[ $create_swapfile == "yes" ]]; then
    echo "Creating swapfile..."
    fallocate -l "$swapfile_size_gb"G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    echo "# /swapfile" >> /etc/fstab
    echo "/swapfile    none    swap    sw    0    0" >> /etc/fstab
elif [[ $create_swapfile == "no" ]]; then
    :
fi

# Install packages defined in custom_packages variable
echo "Installing custom packages..."
pacman -S $custom_packages --noconfirm >/dev/null 2>&1

# Disable onboard PC speaker
echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf

# Re-generate initramfs
echo "Regenerating initramfs image..."
mkinitcpio -P >/dev/null 2>&1

# Clean up and exit
echo "Cleaning up..."
while pacman -Qtdq >/dev/null 2>&1; do
    pacman -R $(pacman -Qtdq) --noconfirm >/dev/null 2>&1
done
yes | pacman -Scc >/dev/null 2>&1
rm -rf /config.conf
rm -rf /main.sh
exit
