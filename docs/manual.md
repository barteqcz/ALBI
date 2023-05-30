### This is a list of available options that can be applied in the config file. Those variables are responsible for particular actions during the installation process. Here is the explanation of possible usage:

### Timezone
`timezone` - This is a definition of the timezone, that should be used in the system. The full list of available timezones is available [here](https://github.com/barteqcz/albi/blob/main/files/timezone_temp)

### User configuration
`username` - It can be anything that fits a Linux username. It can't begin with a number

`password` - It can be anything. I recommend setting a strong password

### Locales settings
`language` - The list of available languages is available [here](https://github.com/barteqcz/albi/blob/main/files/lang_temp)

`console_keyboard_layout` - This keyboard layout will be used systemwide as a console keyboard layout. But take it into account, that it won't be used in graphical environment. Full list is available [here](https://github.com/barteqcz/albi/blob/main/files/keymap_temp)

### Hostname
`hostname` - This is the hostname of the machine

### Audio server setting
Possible values:

`pipewire` - Installs pipewire audio server
`pulseaudio` - Installs pulseaudio
`none` - doesn't install any audio server

### GPU driver setting
Possible values:

`nvidia` - Installs NVIDIA GPU driver
`amd` - Installs AMD GPU driver
`intel` - Installs Intel GPU driver
`vm` - Installs vmware GPU driver
`nouveau` - Installs Nouveau GPU driver (open-source driver meant to work with NVIDIA GPUs)
`none` - Doesn't install any GPU driver

### Desktop environment setting
Possible values:

`gnome` - Installs GNOME desktop environment
`xfce` - Installs XFCE desktop environment
`none` - Doesn't install any DE

### CUPS instlallation
`cups_installation` - Installs CUPS printing support

### Swapfile installation
`create_swapfile` - Decide whether swapfile should be created or not
`swapfile_size_gb` - Select size for the swapfile (if it's gonna be created)
