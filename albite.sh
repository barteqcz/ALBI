#!/bin/bash

# Install base system
pacstrap -K /mnt base linux linux-firmware linux-headers

# Generate /etc/fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Copy second part of the script to /
cp main.sh /mnt/

# Enter arch-chroot and run second part of the script
arch-chroot /mnt bash main.sh
