#!/bin/bash

source config.conf

# Partitioning
mkfs.ext4 $main_part
mkfs.fat -F32 $efi_part
mount $main_part /
mkdir -p /mnt/boot/efi
mount $efi_part /mnt/boot/efi

# Install base system
pacstrap -K /mnt base linux linux-firmware linux-headers

# Generate /etc/fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Copy second part of the script to /
cp main.sh /mnt/

# Enter arch-chroot and run second part of the script
arch-chroot /mnt bash main.sh
