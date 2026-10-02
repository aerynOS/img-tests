# Here be dragons 🔥🐉

🚨🚧🚧🚧🚨

As aerynOS is under heavy development, the image generation scripts in this repository are provided as is, with no explicit or implied warranty or support.

If you break your computer because you used these scripts or AerynOS in its current state, you get to keep both pieces.

## Build an ISO (can be used as an installer)

    just compression=zstd3 build
    # run 'just help' to see available recipes and options

## Build and boot an ISO for quick smoke testing

    just compression=zstd3 build-and-boot

If you need to update the firmware path:

    just compression=zstd3 firmware="<some path to OVMF_CODE.fd or OVMF_CODE.4m.fd>" build-and-boot

## Manually create an installable / booting desktop image

    cd desktop/
    sudo ./img.sh
    truncate -s 10G disk.img
    qemu-system-x86_64 -enable-kvm -m 4096m -cdrom aosvalidator.iso -drive if=pflash,format=raw,readonly=on,file=/usr/share/qemu/edk2-x86_64-code.fd -device virtio-vga-gl -display sdl,gl=on -cpu host -serial stdio -device virtio-blk-pci,drive=main -drive id=main,if=none,file=disk.img,format=raw -boot c

Drop the `-boot c` after you've booted the VM, formatted with `fdisk` and installed with `sudo lichen`

# Credits 

The boot splash image/theme used in this project is based on:
CRT Amber GRUB Theme by Jacksaur
https://github.com/Jacksaur/CRT-Amber-GRUB-Theme

Which is itself inspired by:
Fallout 4 terminal-style artwork
https://www.nexusmods.com/fallout4/images/170842
