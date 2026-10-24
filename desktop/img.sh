#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © 2020 aerynOS Developers
# SPDX-License-Identifier: MPL-2.0
#
# AerynOS prototype linux-desktop ISO image generator
#

set -uo pipefail


die () {
    echo -e "$*"
    exit 1
}

# Root check
if [[ "${UID}" -ne 0 ]]; then
    die "\nThis script MUST be run as root.\n"
fi

# Add escape codes for color
RED='\033[0;31m'
RESET='\033[0m'

declare -A COMPRESSION_ARGS
# The default because it's fast and it's easy to spot regressions in size
COMPRESSION_ARGS["lz4"]="lz4"
# yields 10% extra compression
COMPRESSION_ARGS["lz4hc"]="lz4 -Xhc"
# Almost as quick as lz4 and a fair bit smaller
COMPRESSION_ARGS["zstd3"]="zstd -Xcompression-level 3"
# Good for release images
COMPRESSION_ARGS["zstd19"]="zstd -Xcompression-level 19"
# Only here for comparison with zstd -19
COMPRESSION_ARGS["xz"]="xz -Xbcj x86"

function print_valid_compression_types() {
    echo "Valid compression types are:"
    for key in ${!COMPRESSION_ARGS[@]}; do
        echo "- $key"
    done
}

function usage() {
    echo -e "\nUsage: sudo ./img.sh -c <compression type> -o <output>.iso -p <package list> -t <tmpdir> -y\n"
    print_valid_compression_types
    echo -e "\nThe default compression type is lz4 (quick, easy to spot size regressions)."
    echo -e "-- The best tradeoff between size and speed is zstd3."
    echo -e "\nThe default output is 'aerynos' (becomes 'aerynos.iso')."
    echo -e "\nThe default package list is the file 'gnome_pkglist'."
    echo -e "\nThe default tmp dir is '/tmp' (on some distros, /var/tmp must be used due to permissions)."
    echo -e "\nTip: Adding '-y' specifies that you do not want to be prompted to continue generating the iso."
}

# defaults
ASK="yes"
PACKAGE_LIST="gnome_pkglist"
OUTPUT="aerynos"
TMPDIR="/tmp"

while getopts 'c:o:p:t:hy?' opt
do
  case "$opt" in
  c)
    COMPRESSION="$OPTARG"
    if [[ -z "$COMPRESSION" ]]; then
        echo "No compression type specified."
        usage
        exit 1
    elif [[ -z "${COMPRESSION_ARGS[$COMPRESSION]}" ]]; then
        echo "Invalid compression type "$COMPRESSION" specified."
        usage
        exit 1
    else
        # we're good, carry on
        :
    fi
    ;;
  h)
    usage
    exit 1
    ;;
  o)
    OUTPUT="$OPTARG"
    if [[ -z "${OUTPUT}" ]]; then
        echo "No <output>.iso filename specified."
        usage
        exit 1
    else
        # we're good, carry on
        :
    fi
    ;;
  p)
    PACKAGE_LIST="$OPTARG"
    if [[ -z "${PACKAGE_LIST}" ]]; then
        echo "No package list specified."
        usage
        exit 1
    else
        # we're good, carry on
        :
    fi
    ;;
  t)
    TMPDIR="$OPTARG"
    if [[ -z "${TMPDIR}" ]]; then
        echo "No tmp dir specified."
        usage
        exit 1
    else
        # we're good, carry on
        :
    fi
    ;;
  y)
    # we will check for the value of ${ASK} later on
    ASK="no"
    :
    ;;
  ?)
    usage
    exit 1
    ;;
  esac
done

# Let the user set the COMPRESSION variable and document supported compressors in the README
COMPRESSOR="${COMPRESSION:-lz4}"

WORK="$(dirname $(realpath $0))"
echo ">>> workdir \${WORK}: ${WORK}"
TMPFS="${TMPDIR}/aerynos_iso"
echo ">>> tmpfs dir \${TMPFS}: ${TMPFS}"
ISOLINUX_ASSET_DIR="${WORK}/../iso_assets"
ISOLINUX_CFG="${WORK}/isolinux.cfg"
ISOLINUX_BACKGROUND="${WORK}/biosbackgroundfinal2-1024x768.png"
ISOLINUX_FILES=(
    isolinux.bin
    ldlinux.c32
    vesamenu.c32
    libcom32.c32
    libutil.c32
    libmenu.c32
    libgpl.c32
    reboot.c32
)

BINARIES=(
    fallocate
    mkfs.vfat
    mksquashfs
    moss
    mount
    sync
    systemd-nspawn
    xorriso
)
# up front check for necessary binaries
BINARY_NOT_FOUND=0
echo -e "\nChecking for necessary prerequisites..."
# 'all entries in the BINARIES array'
for b in ${BINARIES[@]}; do
    command -v ${b} > /dev/null 2>&1
    if [[ ! ${?} -eq 0 ]]; then
        echo -e "- ${b} ${RED}not found${RESET} in \$PATH."
        BINARY_NOT_FOUND=1
    else
        echo "- found ${b}"
    fi
done

if [[ ${BINARY_NOT_FOUND} -gt 0 ]]; then
    die "\nNecessary prerequisites not met, please install missing tool(s).\n"
else
    echo -e "\nAll necessary binaries found."
fi

# Pkg list check
test -f "${WORK}/../pkglist-base" || die "\nThis script MUST be able to find the ../pkglist-base file.\n"
test -f "${WORK}/shared-desktop-base" || die "\nThis script MUST be able to find the ./shared-desktop-base file.\n"
test -f "${WORK}/${PACKAGE_LIST}" || die "\nThe specified package list file ${PACKAGE_LIST} does not exist.\n"
test -f "${ISOLINUX_CFG}" || die "\nThis script MUST be able to find the ./isolinux.cfg file.\n"
test -f "${ISOLINUX_BACKGROUND}" || die "\nMissing BIOS background asset ${ISOLINUX_BACKGROUND}.\n"
for f in "${ISOLINUX_FILES[@]}"; do
    test -f "${ISOLINUX_ASSET_DIR}/${f}" || die "\nMissing ${ISOLINUX_ASSET_DIR}/${f}.\n"
done

# start with a common base of packages
readarray -t PACKAGES < "${WORK}/../pkglist-base"

# add the shared desktop baseline of packages (kernels, utilities, VM stuff, fonts etc.)
PACKAGES+=($(sed -E -e '/^\s*$/d' -e '/^[[:space:]]*#.*$/d' "${WORK}/shared-desktop-base"))

# add Desktop Environment specific packages
PACKAGES+=($(sed -E -e '/^\s*$/d' -e '/^[[:space:]]*#.*$/d' "${WORK}/${PACKAGE_LIST}"))

test -f ${WORK}/initrdlist || die "\nThis script MUST be run from within the desktop/ dir with the ./initrd file.\n"
readarray -t initrd < "${WORK}/initrdlist"

cleanup () {
    if [[ -z "${TMPFS}" || "${TMPFS}" == "" ]]; then
        echo "\$TMPFS is not set (or is empty), cannot clean up -- exiting."
        exit 1
    fi
    echo -e "\nSpace used on ${TMPFS} prior to cleaning up:"
    du -csx -BM "${TMPFS}"
    echo -e "\nCleaning up existing dirs, files and mount points..."
    # clean up dirs (if something fails here, let the remaining lines take care of it)
    rm -rf "${TMPFS}"/* || echo "- Removing ${TMPFS}/* failed."

    # umount existing mount recursively and lazily
    test -d "${TMPFS}"/* && { umount -Rlv "${TMPFS}"/* || echo "- Recursive unmounting of ${TMPFS}/* failed." ;}

    # clean leftover existing *.img
    test -e "${TMPFS}"/*.img && { rm -vf "${TMPFS}"/*.img || echo "- Removing leftover ${TMPFS}/*.img files failed." ;}

    echo "- Cleanup done."
}
cleanup

die_and_cleanup() {
    cleanup
    die $*
}


final_cleanup() {
    cleanup

    # all exported variables need to be unset
    for v in BOOT CACHE CHROOT MOSS MOUNT RUST_BACKTRACE AFSDIR; do
        unset "${v}" || true
    done
}

build() {
    # From here on, exit from script on any non-zero exit status command result
    set -e

    export BOOT="${TMPFS}/boot"
    export CACHE="${WORK}/cached_stones"
    export MOUNT="${TMPFS}/mount"
    export AFSDIR="${TMPFS}/aerynosfs"
    export CHROOT="systemd-nspawn --as-pid2 --private-users=identity --user=0 --quiet"

    # Use a permanent cache for downloaded .stones
    mkdir -pv "${CACHE}"

    # Stash boot assets
    mkdir -pv "${BOOT}"

    # Get it right first time.
    mkdir -pv "${MOUNT}" "${AFSDIR}"
    chown -Rc root:root "${MOUNT}" "${AFSDIR}"
    # Only chmod directories
    chmod -Rc u=rwX,g=rX,o=rX "${MOUNT}" "${AFSDIR}"

    export RUST_BACKTRACE=1

    export MOSS="moss -D ${AFSDIR} --cache-dir ${CACHE}"

    echo ">>> Add volatile AerynOS repository to ${AFSDIR}/ ..."
    time ${MOSS} repo add volatile https://cdn.aerynos.dev --root-index channel=main,version=stream/volatile --comment "..."|| die_and_cleanup "Adding moss repo failed!"

    #echo ">>> Add local repo to ${AFSDIR}/ ..."
    #time ${MOSS} repo add local file:///home/ermo/.cache/local_repo/x86_64/stone.index -p10 || die_and_cleanup "Adding moss repo failed!"

    echo ">>> Install packages to ${AFSDIR}/ ..."
    du -csx -BM ${TMPFS}
    time ${MOSS} pkg add -y "${PACKAGES[@]}" || die_and_cleanup "Installing packages failed!"
    du -csx -BM ${TMPFS}

    echo ">>> Set up basic environment in ${AFSDIR}/ ..."
    time ${CHROOT} -D "${AFSDIR}" systemd-firstboot --force --delete-root-password --locale=en_US.UTF-8 --timezone=UTC --root-shell=/usr/bin/bash && echo ">>>>> systemd-firstboot run done."

    echo ">>> Force enable systemd presets in ${AFSDIR}/ ..."
    time ${CHROOT} -D "${AFSDIR}" systemctl preset-all --force --system && echo ">>>>> systemctl preset-all --system run done."

    echo ">>> Force enable systemd global user presets in ${AFSDIR}/ ..."
    time ${CHROOT} -D "${AFSDIR}" systemctl preset-all --force --global && echo ">>>>> systemctl preset-all --global run done."

    echo ">>> Configuring live user."
    time ${CHROOT} -D "${AFSDIR}" useradd -c "Live User" -d "/home/live" -G "audio,adm,wheel,render,input,users" -m -U -s "/usr/bin/bash" live
    cp -R ${WORK}/rootfs_extra/etc/* "${AFSDIR}/etc/."
    chown -R root:root "${AFSDIR}/etc"
    ${CHROOT} -D "${AFSDIR}" chown -R live:live /home/live
    ${CHROOT} -D "${AFSDIR}" passwd -d live

    echo ">>> Forcibly refreshing flatpak."
    time ${CHROOT} -D "${AFSDIR}" flatpak update --system --appstream --no-deps --no-related -v

    echo ">>> Extract assets..."
    cp -av "${AFSDIR}/usr/lib/systemd/boot/efi/systemd-bootx64.efi" "${BOOT}/bootx64.efi"
    cp -av "${AFSDIR}"/usr/lib/modules/*/vmlinux "${BOOT}/kernel"

    echo ">>> Install dracut in ${AFSDIR}/ ..."
    du -csx -BM ${TMPFS}
    time ${MOSS} pkg add "${initrd[@]}" -y || die_and_cleanup "Failed to install initrd packages!"

    echo ">>> Regenerate dracut..."
    kver=$(ls "${AFSDIR}/usr/lib/modules")
    time ${CHROOT} -D "${AFSDIR}/" \
        dracut --early-microcode --hardlink -N --nomdadmconf --nolvmconf \
            --kver ${kver} --add "bash dash systemd lvm dm dmsquash-live plymouth" \
            --fwdir /usr/lib/firmware --tmpdir /tmp --zstd --strip /initrd -v \
            --add-drivers "amdgpu hyperv_drm i915 nouveau qxl radeon simpledrm vboxvideo virtio-gpu vmwgfx xe"
    mv -v "${AFSDIR}/initrd" "${BOOT}/initrd"

    echo ">>> Generate name-version-release file for use by e.g. distrowatch..."
    time ${MOSS} pkg list --installed |gawk '{print $1 " " $2}' |sort -h > "${OUTPUT}.iso.nvr"

    echo ">>> Roll back and prune to keep only initially installed state and remove downloads ..."
    time ${MOSS} state activate 1 -y || die_and_cleanup "Failed to activate initial state in ${TMPFS}/ !"
    time ${MOSS} state remove 2 -y || die_and_cleanup "Failed to prune moss state in ${TMPFS}/ !"

    # Remove downloaded .stones to lower size of generated ISO
    rm -rf "${AFSDIR}"/.moss/cache/downloads/*

    AFSSIZE=$(du -BMiB -s ${TMPFS}|cut -f1|sed -e 's|MiB||g')
    echo ">>> ${AFSDIR} size: ${AFSSIZE} MiB"

    echo ">>> Generate the LiveOS image structure..."
    mkdir -pv "${TMPFS}/root/LiveOS/"

    # Show the contents that will get included to satisfy ourselves that the source dirs specified below are sufficient
    ls -la "${AFSDIR}/"

    echo ">>> Compress the LiveOS squashfs.img using the ${COMPRESSOR} compression preset..."
    time mksquashfs "${AFSDIR}"/* "${AFSDIR}/.moss" "${TMPFS}/root/LiveOS/squashfs.img" \
      -root-becomes LiveOS -keep-as-directory -b 1M -progress -comp ${COMPRESSION_ARGS[$COMPRESSOR]}

    echo ">>> Create and mount the efi.img backing file..."
    EFI_SIZE=$(du -c "${BOOT}/bootx64.efi" "${BOOT}/kernel" "${BOOT}/initrd" "${WORK}/live-os.conf" | grep total | awk '{print $1}')
    EFI_SIZE=$((EFI_SIZE + 1024)) # Add some buffer space
    fallocate -l ${EFI_SIZE}K "${TMPFS}/efi.img"
    mkfs.vfat -F 16 "${TMPFS}/efi.img" -n EFIBOOTISO
    mount -vo loop "${TMPFS}/efi.img" "${MOUNT}"

    echo ">>> Set up EFI image..."
    mkdir -pv "${MOUNT}/EFI/Boot/"
    cp -v "${BOOT}/bootx64.efi" "${MOUNT}/EFI/Boot/bootx64.efi"
    sync
    mkdir -pv "${MOUNT}/loader/entries/"
    cp -v "${WORK}/live-os.conf" "${MOUNT}/loader/entries/"
    cp -v "${BOOT}/kernel" "${MOUNT}/"
    cp -v "${BOOT}/initrd" "${MOUNT}/"
    umount -Rlv "${MOUNT}"

    echo ">>> Run fsck on the newly built EFI image..."
    fsck.vfat -av "${TMPFS}/efi.img"

    echo ">>> Put the new EFI image in the correct place..."
    mkdir -pv "${TMPFS}/root/EFI/Boot"
    cp -v "${TMPFS}/efi.img" "${TMPFS}/root/EFI/Boot/efiboot.img"

    echo ">>> Copy the isolinux bootloader and BIOS warning assets..."
    mkdir -pv "${TMPFS}/root/isolinux/"
    for f in "${ISOLINUX_FILES[@]}"; do
        cp -v "${ISOLINUX_ASSET_DIR}/${f}" "${TMPFS}/root/isolinux/."
    done
    cp -v "${ISOLINUX_CFG}" "${TMPFS}/root/isolinux/isolinux.cfg"
    cp -v "${ISOLINUX_BACKGROUND}" "${TMPFS}/root/isolinux/."

    echo ">>> Create the ISO file..."
    xorriso -as mkisofs \
        -o "${WORK}/${OUTPUT}.iso" \
        -R -J -v -d -N \
        -x "${OUTPUT}.iso" \
        -hide-rr-moved \
        -isohybrid-mbr ${WORK}/../iso_assets/isohdpfx.bin \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -boot-load-size 4 \
        -boot-info-table \
        -no-emul-boot \
        -eltorito-alt-boot \
        -e EFI/Boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -V "AERYNOSLIVE" -A "AERYNOSLIVE" \
        "${TMPFS}/root"

    # The gnarly sed operation is here because the uutils-coreutils `ls` does not output the unit next to the size
    echo "Successfully built $(ls -s --block-size=M ${OUTPUT}.iso | sed 's|\([[:digit:]]+*\) \(.*\)$|\1M \2|g') using ${COMPRESSOR} compression."

    final_cleanup
}

ask_to_continue () {
    # Show a status page up front before generating the iso to avoid surprises

    echo -e "\nGenerating AerynOS linux-desktop ISO image using:\n"
    echo -e "- compression : ${COMPRESSOR}"
    echo -e "- package list: ${PACKAGE_LIST}"
    echo -e "- output name : ${OUTPUT}.iso"
    echo -e "- tmp dir     : ${TMPDIR}"

    if [[ "${ASK}" == "yes" ]]; then
        echo -e "\nWould you like to continue? (Tip: Use 'sudo ./img.sh -y' to avoid seeing this prompt)"
        select yn in "Yes" "No"; do
          case $yn in
            Yes ) build && exit 0;;
            No ) die_and_cleanup "\nUser aborted script.\n";;
          esac
        done
    else
        echo -e "\nUser invoked with '-y' flag, continuing without prompting..."
        build && exit 0
    fi
}

ask_to_continue

# ensure that e.g. CTRL+C cleans up after itself
trap final_cleanup EXIT
