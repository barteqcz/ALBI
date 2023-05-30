#!/bin/bash

# Install base system
echo "Installing base system..."
pacstrap -K /mnt base linux linux-firmware linux-headers > /dev/null

# Generate /etc/fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Copy second part of the script to /
cp main.sh /mnt/

# Copy config file to /
cp config.conf /mnt/

# Enter arch-chroot and run second part of the script
arch-chroot /mnt bash main.sh
