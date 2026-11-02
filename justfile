# Define the path to the image creation script
img_script := "./img.sh"

# Specify the default target directory
target := "desktop"

# Define default desktop flavour
flavor := "gnome"

# Set the default compression type for the ISO
compression := "lz4"

# Define the name of the generated ISO file (saved as output.iso)
output := flavor + "-aerynos-" + compression

# Allocate default memory size for QEMU
memory := "4096m"

# Specify the path to the QEMU firmware file
firmware := "/usr/share/edk2/x64/OVMF_CODE.4m.fd"

# Print nice help text with syntax and examples.
help:
    @echo 'Supported options:'
    @echo '    just [img_script] [target] [flavor] [compression] [output] [memory] [firmware] recipe'
    @echo '    (most people should only use the flavor, compression, output, or firmware options)'
    @echo 'Examples:'
    @echo '    just build  # will build a quick, lz4 compressed gnome "gnome-aerynos-lz4.iso" by default'
    @echo '    just flavor="gnome" compression="zstd3" output="aerynos-gnome-test" build'
    @echo '    just output="aerynos-gnome-test" memory="8192m" firmware="/usr/share/edk2/x64/OVMF_CODE.4m.fd" boot'
    @echo '    just flavor="cosmic" build-and-boot'
    @just -l

# Build a test flavor iso using compression type (and rename it as appropriate)
build:
    cd {{target}} && sudo {{img_script}} -c {{compression}} -o {{output}} -p {{flavor}}_pkglist

# Boot the specified ISO using QEMU with the specified settings using BIOS firmware
biosboot:
    qemu-system-x86_64 -enable-kvm -m {{memory}} -cdrom {{target}}/{{output}}.iso -device virtio-vga-gl,xres=1920,yres=1080 -display sdl,gl=on,show-cursor=off -cpu host

# Boot the specified ISO using QEMU with the specified settings
boot:
    qemu-system-x86_64 -enable-kvm -m {{memory}} -cdrom {{target}}/{{output}}.iso -drive if=pflash,format=raw,readonly=on,file={{firmware}} -device virtio-vga-gl,xres=1920,yres=1080 -display sdl,gl=on,show-cursor=off -cpu host

# Build a flavor iso using compression type and then boot it using QEMU with specified firmware
build-and-boot: build boot

# Build release For WSL (Windows subsystem for linux)
build-wsl:
    cd wsl && sudo {{img_script}} -c gzip -o aerynos -p minimal_pkglist -y

# Build release ISO for the GNOME flavour
release-gnome:
    #!/usr/bin/env bash
    set -euxo pipefail
    _yyyymm="$(date +%Y.%m)"
    _output="aerynOS-${_yyyymm}-GNOME-live-x86_64"
    just flavor="gnome" compression="zstd19" output="${_output}" build

# Test newly built release ISO for the GNOME flavour
test-gnome-release:
    #!/usr/bin/env bash
    set -euxo pipefail
    _yyyymm="$(date +%Y.%m)"
    _output="aerynOS-${_yyyymm}-GNOME-live-x86_64"
    just flavor="gnome" compression="zstd19" output="${_output}" boot

[confirm('This will delete ALL found .iso images -- continue?')]
_clean:
    @cd {{target}} && sudo rm -vf *.iso

_list-isos:
    cd {{target }} && ls -AFcghlot --block-size=M *.iso

# Clean out existing .iso files in {{target}} (desktop/ by default)
clean: _list-isos && _clean
