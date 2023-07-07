This is a list of available options that can be applied in the config file. Those variables are responsible for particular actions during the installation process. Here is the explanation of possible usage:

### Kernel variant
`kernel_variant` - This allows you to select which kernel variant do you wanna install.

Possible values:

`normal` - Installs normal kernel

`lts` - Installs LTS kernel

`zen` - Installs ZEN kernel

### Timezone
`timezone` - This is a definition of the timezone, that should be used in the system. The full list of available timezones is available [here](https://github.com/barteqcz/albi/blob/main/files/timezone_temp)

### User configuration
`username` - It can be anything that fits a Linux username rules. It can't begin with a number

`password` - It can be anything. I recommend setting a strong password

### Locales settings
`language` - Sets selected language systemwide. The full list of available languages is available [here](https://github.com/barteqcz/albi/blob/main/files/lang_temp)

`console_keyboard_layout` - This keyboard layout will be used systemwide as a console keyboard layout. But take into account, that it won't be used in graphical environment. Full list is available [here](https://github.com/barteqcz/albi/blob/main/files/keymap_temp)

### Hostname
`hostname` - This is the hostname of the machine

### GRUB settings
#### BIOS
`grub_disk` - This allows you to select the drive where GRUB (BIOS) is to be installed

#### UEFI
`efi_partition` - This allows you to select the EFI partition for GRUB (UEFI) installation

### Audio server setting
`audio_server` - This allows you to install selected audio server

Possible values:

`pipewire` - Installs pipewire audio server

`pulseaudio` - Installs pulseaudio

`none` - Doesn't install any audio server

### GPU driver setting
`gpu_driver` - This allows you to pick what GPU driver should be installed (if any)

Possible values:

`nvidia` - Installs NVIDIA GPU driver

`amd` - Installs AMD GPU driver

`intel` - Installs Intel GPU driver

`vm` - Installs vmware GPU driver

`nouveau` - Installs Nouveau GPU driver (open-source driver meant to work with NVIDIA GPUs)

`none` - Doesn't install any GPU driver

### Desktop environment setting
`de` - This allows you to pick what desktop environment should be installed (if any)

Possible values:

`gnome` - Installs GNOME desktop environment

`plasma` - Installs KDE Plasma desktop environment

`xfce` - Installs XFCE desktop environment

`none` - Doesn't install any DE

### CUPS installation setting
`cups_installation` - This allows you to select whether CUPS should be installed or not

Possible values: `yes` and `no`

### Swapfile installation
`create_swapfile` - Decide whether swapfile should be created or not

Possible values: `yes` and `no`

`swapfile_size_gb` - Select size for the swapfile (if it's gonna be created)

Possible values are **only numbers**

### Custom packages
`custom_packages` - This allows you to define custom packages, which you wanna install in the system. The packages should be separated by spaces.
