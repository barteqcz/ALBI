# ALBI

A single-file Bash installer for Arch Linux. You describe the machine in one config file (`config.conf`), review a summary, and the script does the rest: formatting, optional LUKS encryption and LVM, base system, bootloader, users, desktop, and drivers.

> [!WARNING]
> **This script formats disks.** Everything on the partitions you select is erased. Read the summary and the final confirmation carefully, and try it in a virtual machine before using it on real hardware.

## Features

- **Config-driven:** run it once to generate a commented `config.conf`, edit it, run it again.
- **Safe config parser:** `config.conf` is parsed, never executed as shell code. Unknown or duplicate keys are rejected.
- **UEFI and BIOS:** detected automatically. GRUB is the bootloader.
- **Filesystems:** ext2/3/4, btrfs, xfs. On btrfs, `/` and `/home` are created as subvolumes (zstd compression).
- **Separate partitions:** optional `/home`, `/boot`, `/var`, `/tmp`.
- **Encryption:** LUKS for root and data partitions, or LVM on LUKS (see below).
- **LVM:** let the installer build LVM inside LUKS, or point it at logical volumes you created yourself.
- **Kernels:** `linux`, `linux-lts`, `linux-zen`.
- **Desktops:** GNOME, KDE Plasma, Xfce, MATE, Cinnamon, or none.
- **GPU drivers:** AMD, Intel, NVIDIA, hybrid combinations, or none.
- **Extras:** PipeWire, CUPS, zram swap, NetworkManager or systemd-networkd, Bluetooth, mirror selection with `reflector`.
- **Pre-flight checks:** devices, overlaps, mounts, active swap, existing LVM/RAID signatures, locale, keymap, time zone, hostname, and more are validated before anything is formatted.
- **Clean teardown:** on failure or interruption the installer unmounts, deactivates its LVM volume group, and closes its LUKS mappings.

## Requirements

- The official Arch Linux live ISO, booted as root.
- A working Internet connection.
- Your disk already partitioned (for example with `cfdisk` or `fdisk`):
  - a root partition,
  - a separate `/boot` partition if you use encryption,
  - an EFI system partition (UEFI) or a BIOS boot partition (BIOS on a GPT disk),
  - optionally partitions for `/home`, `/var`, `/tmp`.

## Quick start

```bash
# On the Arch live ISO, as root:
curl -o albi.sh https://raw.githubusercontent.com/barteqcz/ALBI/main/albi.sh

bash albi.sh      # first run: generates config.conf and exits
nano config.conf  # edit it
bash albi.sh      # second run: shows a summary, asks for confirmation, installs
```

After the first run, `config.conf` appears in the current directory with mode `600`. The second run validates everything, shows a summary, asks for a final confirmation listing every device that will be erased, and then installs.

## Configuration

`config.conf` is a list of `key="value"` lines. The generated file documents every option inline. The main ones:

| Section | Keys | Notes |
| --- | --- | --- |
| Filesystems | `root_part_filesystem`, `separate_*_part_filesystem` | `ext2`, `ext3`, `ext4`, `btrfs`, `xfs` (or `none`) |
| Partitions | `root_part`, `separate_home_part`, `separate_boot_part`, `separate_var_part`, `separate_tmp_part` | Device paths, or `none` |
| Encryption | `luks_encryption`, `luks_passphrase` | `yes`/`no`. Requires a separate `/boot` |
| LVM on LUKS | `lvm_on_luks`, `lvm_vg_name`, `lvm_home_size`, `lvm_var_size`, `lvm_tmp_size` | See [LVM](#lvm) |
| UEFI | `efi_part`, `efi_part_mountpoint`, `grub_install_fallback` | Mountpoint: `/boot/efi` or `/efi` |
| BIOS | `grub_disk` | Whole disk to install GRUB to |
| Network | `network_management` | `network-manager`, `systemd-networkd`, `none` |
| Kernel | `kernel_variant` | `normal`, `lts`, `zen` |
| Mirrors | `mirror_location` | Comma-separated country list, or `none` |
| System | `timezone`, `hostname`, `language`, `tty_keyboard_layout` | Validated against the live system |
| User | `username`, `full_username`, `password` | A `wheel` user with sudo is created |
| Software | `install_pipewire`, `gpu`, `de`, `install_cups` | `gpu`: `amd`, `intel`, `nvidia`, `other`, `none`, or `intel+nvidia`, `amd+nvidia`, `intel+amd`, `amd+amd` |
| Swap | `create_swap` | `yes` creates zram swap |

Set `root_part="none"` to install into a root filesystem you have already mounted at `/mnt`.

### Security notes

- `config.conf` can contain your password and LUKS passphrase in plain text. It is created with mode `600`, and after a successful installation both values are blanked.
- **Do not commit `config.conf`.** Add it to `.gitignore`.
- The config copy staged inside the new system is removed at the end of the installation.

## LVM

Two supported approaches. Both need a separate, unencrypted `/boot` partition when encryption is involved.

### 1. Let the installer create LVM on LUKS

The installer encrypts `root_part`, creates a volume group inside the LUKS container, and creates the logical volumes. The root volume gets all the space left after the sized volumes.

```ini
luks_encryption="yes"
luks_passphrase="..."
lvm_on_luks="yes"
lvm_vg_name="archlinux"
lvm_home_size="100G"       # or none (then /home lives on the root volume)
lvm_var_size="20G"         # or none
lvm_tmp_size="none"

root_part="/dev/sda2"      # plain partition that will be encrypted
separate_home_part="none"  # keep these three at none in this mode
separate_var_part="none"
separate_tmp_part="none"
separate_home_part_filesystem="ext4"   # required when lvm_home_size is set
separate_var_part_filesystem="xfs"     # required when lvm_var_size is set
```

Sizes use an integer followed by an uppercase unit: `512M`, `20G`, `1T`. The installer refuses a volume group name that already exists and checks that the sizes fit, leaving at least 20 GiB for root.

### 2. Use LVM you created yourself

Create the volumes in the live environment, then point the config at them:

```bash
cryptsetup luksFormat /dev/sda2 && cryptsetup open /dev/sda2 cryptlvm
pvcreate /dev/mapper/cryptlvm && vgcreate vg /dev/mapper/cryptlvm
lvcreate -L 50G -n root vg && lvcreate -l 100%FREE -n home vg
```

```ini
lvm_on_luks="no"
luks_encryption="no"          # the container already exists
root_part="/dev/vg/root"
separate_home_part="/dev/vg/home"
```

An open LUKS container under the selected volumes is detected, and is unlocked at boot automatically (`rd.luks.name` for the root, `/etc/crypttab` for data volumes). Plain LVM without LUKS needs no special settings.

### Not supported

- **LUKS on LVM** for `/` (`luks_encryption="yes"` with a logical volume as `root_part`) is refused. The standard LVM-on-LUKS order is used instead.
- Selecting a partition that is an LVM physical volume or a RAID member (select the logical volume or the assembled array instead).
- An encrypted or LVM-backed `/boot`.

## What the installer does

1. Loads and validates `config.conf`, shows a summary, and asks for confirmation.
2. Checks the Internet connection, the settings, the devices, and the mirror country before touching any disk.
3. Lists every device that will be erased and asks for a second confirmation.
4. Sets up encryption and LVM, formats, and mounts.
5. Runs `pacstrap`, generates `fstab`, and runs a configuration script in the new system: packages in a single transaction, locale, time zone, hostname, network, user and sudo, zram swap, GRUB, initramfs (systemd-based hooks, with `sd-encrypt` before `lvm2`), and cleanup.
6. Unmounts everything and closes the LUKS mappings it opened.

Bug reports with the layout you used and the output you saw are welcome.
