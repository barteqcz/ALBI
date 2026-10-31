# ALBI

ALBI is a Bash-based installer for setting up an Arch Linux system from an Arch Linux live environment. It prepares selected storage devices, installs the base system, configures the bootloader and initramfs, creates a user account, and installs the software selected in `config.conf`.

> **Warning: this installer can permanently erase data.** Any selected root, `/home`, `/boot`, or EFI target may be formatted. Read the configuration and the installer's final destructive-operation summary carefully. Back up important data before running it.

## Features

- **UEFI and BIOS support:** detects the boot mode and configures GRUB for the corresponding firmware mode.
- **Filesystem choices:** ext2, ext3, ext4, Btrfs, and XFS for selected filesystem targets.
- **Btrfs layout:** when Btrfs is selected for `/`, ALBI creates a `root` subvolume. If no separate `/home` device is selected, it also creates a `home` subvolume and mounts it at `/home`. Btrfs mounts use `compress=zstd:1`.
- **Optional separate mounts:** supports separate devices for `/home` and `/boot`.
- **Optional LUKS encryption:** encrypts the selected root device and, when configured, a separate `/home` device with the same passphrase. `/boot` and the EFI System Partition remain unencrypted.
- **Existing LVM support:** can use existing logical volumes and activate their volume groups. ALBI does not create, remove, or resize physical volumes, volume groups, or logical volumes.
- **Kernel selection:** standard, LTS, or Zen kernels.
- **Bootloader setup:** installs GRUB and checks the generated kernel, initramfs, and boot configuration. In UEFI mode, it can also install the removable-media fallback loader.
- **System configuration:** hostname, user account, timezone, locale, and TTY keyboard layout.
- **Software selection:** NetworkManager, PipeWire, GPU drivers, GNOME, Plasma, XFCE, printing support, and zram swap.
- **Optional mirror selection:** can generate an HTTPS mirror list with Reflector for the selected country or countries.
- **Preflight checks:** checks network access, configuration values, required commands, storage targets, and boot layout before formatting.

## Requirements

- An Arch Linux live ISO or a compatible Arch Linux installation environment.
- Root privileges.
- A working internet connection and DNS resolution. The installer checks connectivity using `ping`.
- A prepared disk/partition layout. **ALBI does not create partition tables or partitions.** Create the required partitions before running it.
- The host utilities needed by the selected installation options. These include the Arch installation tools (`pacman`, `pacstrap`, `genfstab`, and `arch-chroot`), storage utilities, and filesystem formatters. Depending on the configuration, ALBI also requires `cryptsetup`, `reflector`, `mkfs.fat`, Btrfs utilities, or LVM utilities. The script checks for the required commands before it starts formatting.

For UEFI installations, boot the live environment in UEFI mode and provide an EFI System Partition. For BIOS installations, provide the whole disk on which GRUB should be installed. A GPT disk used for BIOS boot must already contain a BIOS Boot Partition.

## Quick start

Run ALBI from the directory where you want `config.conf` to be created. The script uses the **current working directory** for this file.

```bash
chmod +x 'albi(3).sh'
sudo './albi(3).sh'
```

On the first run, ALBI creates `config.conf`, restricts its permissions, prints a message, and exits. This is intentional: no installation is started on that first run.

Edit the generated configuration:

```bash
sudo nano config.conf
```

Set the correct devices, filesystems, passwords, and system options. Then run the installer again:

```bash
sudo './albi(3).sh'
```

ALBI reviews the settings and runs its preflight checks. Before formatting, it prints the devices that will be erased and any boot locations that will be modified. To proceed, you must type the exact uppercase word:

```text
ERASE
```

Any other response aborts before partition formatting begins.

## Configuration

`config.conf` uses `key="value"` entries. The first run generates a commented template with defaults. Keep values quoted, especially values containing spaces or special characters.

### Storage and filesystems

| Setting | Purpose | Accepted values / examples |
|---|---|---|
| `root_part` | Device or existing logical volume for `/` | `/dev/nvme0n1p2`, `/dev/sda2`, `/dev/VG/root`, or `none` when an existing root is already mounted at `/mnt` |
| `root_part_filesystem` | Filesystem for `/` when `root_part` is selected | `ext2`, `ext3`, `ext4`, `btrfs`, `xfs` |
| `separate_home_part` | Optional device or logical volume for `/home` | Device path or `none` |
| `separate_home_part_filesystem` | Filesystem for separate `/home` | `ext2`, `ext3`, `ext4`, `btrfs`, `xfs` |
| `separate_boot_part` | Optional device or logical volume for `/boot` | Device path or `none` |
| `separate_boot_part_filesystem` | Filesystem for separate `/boot` | `ext2`, `ext3`, `ext4`, `btrfs`, `xfs` |

A filesystem setting is used only when its corresponding partition/device is enabled. For example, `separate_home_part_filesystem` is ignored when `separate_home_part="none"`.

If `root_part="none"`, an existing root filesystem must already be mounted at `/mnt`. ALBI then installs into that mounted target rather than formatting a new root device.

### Encryption

| Setting | Purpose | Values |
|---|---|---|
| `luks_encryption` | Enable LUKS encryption for the selected root and optional separate `/home` device | `yes`, `no` |
| `luks_passphrase` | Passphrase used for the LUKS devices | Set a non-empty passphrase when encryption is enabled |

Important encryption constraints:

- Encryption requires a selected `root_part`; it cannot be used with `root_part="none"`.
- Encryption requires a separate `/boot` device. That `/boot` device is not encrypted.
- A separate `/home` device is encrypted with the same passphrase as root when encryption is enabled.
- The EFI System Partition is not encrypted.
- ALBI configures the initramfs and GRUB kernel parameters for the selected encrypted devices.

### Firmware and bootloader

ALBI detects UEFI or BIOS mode from the environment in which it is running. The generated configuration includes the relevant settings for the detected mode.

**UEFI settings:**

| Setting | Purpose | Values |
|---|---|---|
| `efi_part` | EFI System Partition device | For example, `/dev/nvme0n1p1` |
| `efi_part_mountpoint` | Where to mount the EFI System Partition | `/boot/efi` or `/efi` |
| `grub_install_fallback` | Install GRUB to the UEFI removable-media fallback path | `yes`, `no` |

The EFI partition must be a partition with an EFI System Partition type. ALBI always reformats it as FAT32.

**BIOS setting:**

| Setting | Purpose | Values |
|---|---|---|
| `grub_disk` | Whole disk to which GRUB will be installed | For example, `/dev/sda` or `/dev/nvme0n1` |

For BIOS boot on a GPT disk, a BIOS Boot Partition must already exist.

### Kernel, mirrors, and system identity

| Setting | Purpose | Values / examples |
|---|---|---|
| `kernel_variant` | Kernel package to install | `normal`, `lts`, `zen` |
| `mirror_location` | Country or comma-separated countries for Reflector; `none` keeps the current mirror configuration | `none`, `Poland`, `Germany`, `Poland,Germany` |
| `timezone` | Timezone from `/usr/share/zoneinfo` | `Europe/Warsaw`, `Europe/Prague`, etc. |
| `hostname` | System hostname | 1–63 lowercase letters, digits, and internal hyphens; must start and end with a letter or digit |

The CPU vendor is detected automatically and the corresponding Intel or AMD microcode package is installed when recognized.

### User and locale

| Setting | Purpose | Notes |
|---|---|---|
| `username` | Login name for the new user | Must start with a lowercase letter or underscore; up to 32 characters; lowercase letters, digits, `_`, and `-` are accepted after the first character |
| `full_username` | Optional full name / GECOS field | May be left empty |
| `password` | Password for the new user | Must not be empty |
| `language` | System locale | Must be present in the live environment's `/etc/locale.gen` |
| `tty_keyboard_layout` | TTY keymap | Must be listed by `localectl list-keymaps` |

The new user is added to the `wheel` group, and ALBI enables the wheel sudo rule.

### Software selection

| Setting | Purpose | Accepted values |
|---|---|---|
| `install_nm` | Install and enable NetworkManager | `yes`, `no` |
| `install_pipewire` | Install PipeWire audio components and WirePlumber | `yes`, `no` |
| `gpu` | Select graphics driver packages | `amd`, `intel`, `nvidia`, `other`, `none`, `intel+nvidia`, `amd+nvidia`, `intel+amd`, `amd+amd` |
| `de` | Desktop environment | `gnome`, `plasma`, `xfce`, `none` |
| `install_cups` | Install and enable printing services | `yes`, `no` |
| `create_swap` | Configure zram swap | `yes`, `no` |

Notes:

- `gpu="none"` is accepted only when `de="none"`.
- Hybrid GPU choices install `switcheroo-control`; NVIDIA hybrid configurations also install `nvidia-prime`.
- NVIDIA package selection depends on the chosen kernel variant.
- When `create_swap="yes"`, ALBI installs `zram-generator` and configures zram to use half of system RAM with Zstandard compression.
- When CUPS is enabled, ALBI installs printing packages and enables the printing and Avahi services. With a desktop environment selected, it also installs `system-config-printer`.
- Setting `install_nm="no"` means ALBI will not install or enable NetworkManager; make sure the installed system will have a network configuration appropriate for your setup.

## Storage and LVM limitations

ALBI expects storage devices and partitions to exist already. It formats selected targets, but it does not create or resize partitions.

Existing LVM logical volumes can be selected using paths such as `/dev/VG/root`. ALBI may activate an existing volume group, but it will not create, remove, or resize PVs, VGs, or LVs. The supported LVM arrangement uses physical volumes backed directly by ordinary disks or partitions. ALBI supports creating LUKS inside a selected existing logical volume (**LUKS-on-LVM**).

The following layouts are not supported by this installer:

- LVM-on-LUKS or an already-open encrypted LVM mapping used as an installation target.
- RAID-backed LVM physical volumes.
- Selecting an LVM physical volume directly; select an existing logical volume instead.
- Inactive logical volumes specified only by a `/dev/mapper/...` path; use `/dev/<VG>/<LV>` for an inactive LV.

Before formatting, ALBI also checks that selected targets are valid block devices, are not mounted or active swap, do not overlap one another, and are not parent/child devices of another selected target.

## What the installer does

1. Loads `config.conf`, displays the selected options, and validates configuration values.
2. Checks internet and DNS connectivity and verifies required host commands.
3. Detects and, when needed, activates existing LVM volume groups.
4. Validates storage devices, filesystems, and UEFI/BIOS boot requirements.
5. Optionally prepares a mirror list with Reflector.
6. Prints a destructive-operation summary and waits for the explicit `ERASE` confirmation.
7. Formats and mounts the selected devices. On UEFI systems, it formats the EFI System Partition as FAT32.
8. Installs the Arch base system and selected kernel, then generates `/etc/fstab`.
9. Enters the target system with `arch-chroot` to configure locale, timezone, hostname, user, packages, services, initramfs, and GRUB.
10. Verifies important boot files and configuration, removes temporary installer files, and unmounts the filesystems it mounted.

## Security notes

- **Treat `config.conf` as a secrets file.** It contains the user password and may contain the LUKS passphrase in plaintext. ALBI sets its permissions to `600`, but you should still keep it out of version control and avoid sharing it.
- After a successful installation, ALBI removes the source `config.conf` as part of its cleanup. If installation fails, it intentionally retains the configuration so you can inspect it and retry.
- The `ERASE` prompt is a final safeguard, not a substitute for checking device names. Confirm every listed target against your intended disk layout before proceeding.
- Test unfamiliar layouts in a virtual machine first, and keep independent backups of any data you need.

## Troubleshooting

- **`Run this installer as root.`** Run it with `sudo` or from a root shell.
- **`config.conf was generated successfully...`** This is the expected first-run behavior. Edit the file and run ALBI again.
- **No internet connection / DNS isn't working.** Configure networking in the live environment before running the installer.
- **A required command is missing.** Install or make the relevant utility available in the live environment. The missing command may depend on the selected filesystem, encryption, mirror, firmware, or LVM options.
- **Selected TTY keymap isn't available / locale was not found.** Choose a keymap listed by `localectl list-keymaps` and a locale present in `/etc/locale.gen` in the live environment.
- **`/mnt` is already mounted.** When installing to a new root device, unmount the existing `/mnt` target first. To reuse an existing root, set `root_part="none"` and ensure the intended root filesystem is mounted at `/mnt`.
- **Installation fails after formatting begins.** Review the error output and retained `config.conf`. Some disk operations may already have happened; do not assume the previous system is unchanged.

## License

No license information is specified in the supplied installer script. Add a `LICENSE` file and update this section if you intend to distribute the project under a particular license.
