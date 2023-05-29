#!/bin/bash

source config.conf

# Set timezone
ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc

# Fix potential archlinux-keyring problem
while ! pacman -Sy --noconfirm; do
    killall gpg-agent
    rm -rf /etc/pacman.d/gnupg
    pacman-key --init 
    pacman-key --populate
    pacman -Sy archlinux-keyring
done

# Install basic packages
pacman -Sy base-devel bash-completion nano grub efibootmgr ntfs-3g --noconfirm

# Detect the system boot mode
if [[ -d "/sys/firmware/efi/" ]]; then
    boot_mode="UEFI"
else
    boot_mode="BIOS"
fi

# Detect CPU vendor and install appropiate ucode package
vendor=$(grep -m1 vendor_id /proc/cpuinfo | cut -d ':' -f2 | tr -d '[:space:]')

if [[ $vendor == "GenuineIntel" ]]; then
    pacman -Sy intel-ucode --noconfirm

elif [[ $vendor == "AuthenticAMD" ]]; then
    pacman -Sy amd-ucode --noconfirm

fi

# /etc/locale.gen configuration
sed -i 's/#$language/$language/' /etc/locale.gen
locale-gen

# /etc/locale.conf configuration
echo "LANG=$language" > /etc/locale.conf

# /etc/vconsole.conf configuration
echo "KEYMAP=$console_keyboard_layout" > /etc/vconsole.conf

# /etc/hostname configuration
echo "$hostname" > /etc/hostname

# /etc/hosts configuration
echo "# The following lines are desirable for IPv4 capable hosts" > /etc/hosts
echo "127.0.0.1       localhost" >> /etc/hosts
echo "" >> /etc/hosts
echo "# The following lines are desirable for IPv6 capable hosts" >> /etc/hosts
echo "::1             localhost ip6-localhost ip6-loopback" >> /etc/hosts
echo "ff02::1         ip6-allnodes" >> /etc/hosts
echo "ff02::2         ip6-allrouters" >> /etc/hosts

# User configuration
useradd -m $username
echo "$username:$password" | chpasswd
usermod -aG wheel $username
sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^#//g' /etc/sudoers

# Tweak nano
sed -i 's/^# include "\/usr\/share\/nano\/\*\.nanorc"/include "\/usr\/share\/nano\/\*\.nanorc"/' /etc/nanorc

# Install GRUB
if [[ $boot_mode == "UEFI" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Arch Linux"
    grub-mkconfig -o /boot/grub/grub.cfg
elif [[ $boot_mode == "BIOS" ]]; then
    grub-install --target=i386-pc /dev/sda
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# Install Pipewire
if [[ $audio_server == "pipewire" ]]; then
    pacman -S pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber --noconfirm
    systemctl enable --global pipewire pipewire-pulse
elif [[ $audio_server == "pulseaudio" ]]; then
    pacman -S pulseaudio --noconfirm
    systemctl enable --global pulseaudio
fi

# Install Xorg
pacman -S xorg --noconfirm

# Install GPU driver
if [[ $gpu_driver == "nvidia" ]]; then
    pacman -S nvidia nvidia-utils nvidia-settings --noconfirm
elif [[ $gpu_drvier == "amd" ]]; then
    pacman -S mesa xf86-video-amdgpu xf86-video-ati libva-mesa-driver vulkan-radeon --noconfirm
elif [[ $gpu_driver == "intel" ]]; then
    pacman -S mesa libva-intel-driver intel-media-driver vulkan-intel --noconfirm
elif [[ $gpu_driver == "vm" ]]; then
    pacman -S mesa xf86-video-vmware --noconfirm
elif [[ $gpu_driver == "nouveau" ]]; then
    pacman -S mesa xf86-video-nouveau libva-mesa-driver --noconfirm
fi

# Install DE
if [[ $de == "gnome" ]]; then
    pacman -S gnome nautilus gdm xdg-utils xdg-user-dirs noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs networkmanager htop git firefox papirus-icon-theme gnome-tweaks gnome-shell-extensions --noconfirm
    pacman -R epiphany gnome-software --noconfirm
    systemctl enable gdm
elif [[ $de == "xfce" ]]; then
    pacman -S xfce4 xdg-utils xdg-user-dirs xfce4-goodies xarchiver xfce4-terminal xfce4-dev-tools lightdm lightdm-slick-greeter noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs networkmanager network-manager-applet htop git firefox papirus-icon-theme --noconfirm
    sed -i 's/#greeter-session=example-gtk-gnome/greeter-session=lightdm-slick-greeter/' /etc/lightdm/lightdm.conf
    systemctl enable lightdm
elif [[ $de == "" ]]; then
    :
fi
systemctl enable NetworkManager

# CUPS installation
if [[ $cups_installation == "yes" ]]; then
    pacman -S cups hplip --noconfirm
    systemctl enable cups
elif [[ $cups_installation == "no" ]]; then
    :
else
    echo "Wrong setting in the config file"
fi

# Disable broken HPLIP-related shortcuts
mv /usr/share/applications/hplip.desktop /usr/share/applications/hplip.desktop.broken
mv /usr/share/applications/hp-uiscan.desktop /usr/share/applications/hp-uiscan.desktop.broken

# Setup swapfile
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
echo "# /swapfile" >> /etc/fstab
echo "/swapfile    none        swap        sw    0 0" >> /etc/fstab

# Disable onboard PC speaker
echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf

# Re-generate initramfs
mkinitcpio -P

# Clean up and exit
while pacman -Qtdq > /dev/null 2>&1; do
    pacman -R $(pacman -Qtdq) --noconfirm
done
yes | pacman -Scc
rm -rf /main.sh
exit
