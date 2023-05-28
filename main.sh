#!/bin/bash

passwd="ilovelinux"

# Set timezone
ln -sf /usr/share/zoneinfo/Europe/Prague /etc/localtime
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

# Detect CPU vendor and install appropiate ucode package
vendor=$(grep -m1 vendor_id /proc/cpuinfo | cut -d ':' -f2 | tr -d '[:space:]')

if [[ $vendor == "GenuineIntel" ]]; then
    pacman -Sy intel-ucode --noconfirm

elif [[ $vendor == "AuthenticAMD" ]]; then
    pacman -Sy amd-ucode --noconfirm

fi

# /etc/locale.gen configuration
sed -i 's/#cs_CZ.UTF-8/cs_CZ.UTF-8/' /etc/locale.gen
locale-gen

# /etc/locale.conf configuration
echo "LANG=cs_CZ.UTF-8" > /etc/locale.conf

# /etc/vconsole.conf configuration
echo "KEYMAP=cz" > /etc/vconsole.conf

# /etc/hostname configuration
echo "MS-7817" > /etc/hostname

# User configuration
useradd -m bartosz
echo "bartosz:$passwd" | chpasswd
usermod -aG wheel bartosz
sed -i '/%wheel ALL=(ALL:ALL) ALL/s/^#//g' /etc/sudoers

# Tweak nano
sed -i 's/^# include "\/usr\/share\/nano\/\*\.nanorc"/include "\/usr\/share\/nano\/\*\.nanorc"/' /etc/nanorc

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Arch Linux"
grub-mkconfig -o /boot/grub/grub.cfg

# Install Pipewire
pacman -S pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber --noconfirm
systemctl enable --global pipewire pipewire-pulse

# Install Xorg
pacman -S xorg --noconfirm

# Install NVIDIA driver
pacman -S nvidia nvidia-utils nvidia-settings --noconfirm

# Install DE, NetworkManager and stuff
pacman -S gnome nautilus gnome-terminal gdm noto-fonts noto-fonts-cjk noto-fonts-emoji noto-fonts-extra gvfs networkmanager cups cups-pdf hplip --noconfirm
systemctl enable cups
systemctl enable gdm
systemctl enable NetworkManager

# Setup swapfile
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
echo "# /swapfile" >> /etc/fstab
echo "/swapfile    none        swap        sw    0 0" >> /etc/fstab

# Re-generate initramfs
mkinitcpio -P

# Clean up and exit
rm -rf /main.sh
exit
