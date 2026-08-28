#!/usr/bin/env bash
# AerynOS WSL distribution build script
# Builds a fresh AerynOS distribution for WSL 2 from scratch

die () {
    echo -e "$*"
    exit 1
}

# Root check
if [[ "${UID}" -ne 0 ]]; then
    die "\nThis script MUST be run as root.\n"
fi

# If it is root, try to inherit the original user's PATH and HOME
if [[ "$EUID" -eq 0  &&  -n "$SUDO_USER" ]]; then
    export HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    export PATH="/home/$SUDO_USER/.local/bin:/home/$SUDO_USER/.cargo/bin:$PATH"
fi

echo "PATH in script: $PATH"
echo "User: $(whoami): $HOME"

# Add escape codes for color
RED='\033[0;31m'
RESET='\033[0m'

declare -A COMPRESSION_ARGS
COMPRESSION_ARGS["gzip"]="gzip"
# The default because it's fast and it's easy to spot regressions in size
#COMPRESSION_ARGS["lz4"]="lz4"
# yields 10% extra compression
# COMPRESSION_ARGS["lz4hc"]="lz4 -Xhc"
# Almost as quick as lz4 and a fair bit smaller
# COMPRESSION_ARGS["zstd3"]="zstd -Xcompression-level 3"
# Good for release images
# COMPRESSION_ARGS["zstd19"]="zstd -Xcompression-level 19"
# Only here for comparison with zstd -19
# COMPRESSION_ARGS["xz"]="xz -Xbcj x86"

function print_valid_compression_types() {
    echo "Valid compression types are:"
    for key in ${!COMPRESSION_ARGS[@]}; do
        echo "- $key"
    done
}

function usage() {
    echo -e "\nUsage: sudo ./img.sh -o <output>.tar.gz -p <package list> -t <tmpdir> -y\n"
    print_valid_compression_types
    echo -e "\nThe default compression type is gzip (supported by WSL)."
    echo -e "\nThe default output is 'aerynos' (becomes 'aerynos.tar.gz')."
    echo -e "\nThe default package list is the file 'minimal_pkglist'."
    echo -e "\nThe default tmp dir is '/tmp' (on some distros, /var/tmp must be used due to permissions)."
    echo -e "\nTip: Adding '-y' specifies that you do not want to be prompted to continue generating the tar.gz."
}

# defaults
ASK="yes"
PACKAGE_LIST="minimal_pkglist"
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
        echo "No <output>.tar.gz filename specified."
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
COMPRESSOR="gzip"

WORK="$(dirname $(realpath $0))"
echo ">>> workdir \${WORK}: ${WORK}"
TMPFS="${TMPDIR}/aerynos_fs"
echo ">>> tmpfs dir \${TMPFS}: ${TMPFS}"

BINARIES=(
    moss
    systemd-nspawn
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
test -f "${WORK}/${PACKAGE_LIST}" || die "\nThe specified package list file ${PACKAGE_LIST} does not exist.\n"

# start with a common base of packages
readarray -t PACKAGES < "${WORK}/../pkglist-base"

# add specific packages
PACKAGES+=($(sed -E -e '/^\s*$/d' -e '/^[[:space:]]*#.*$/d' "${WORK}/${PACKAGE_LIST}"))

cleanup () {
    if [[ -z "${TMPFS}" || "${TMPFS}" == "" ]]; then
        echo "\$TMPFS is not set (or is empty), cannot clean up -- exiting."
        exit 1
    fi
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
    for v in BOOT CACHE CHROOT MOSS MOUNT RUST_BACKTRACE SFSDIR; do
        unset "${v}" || true
    done
}

build() {
    # From here on, exit from script on any non-zero exit status command result
    set -e

    export BOOT="${TMPFS}/boot"
    export CACHE="${WORK}/cached_stones"
    export MOUNT="${TMPFS}/mount"
    export SFSDIR="${TMPFS}/aerynosfs"
    export CHROOT="systemd-nspawn --as-pid2 --private-users=identity --user=0 --quiet"

    # Use a permanent cache for downloaded .stones
    mkdir -pv "${CACHE}"

    # Stash boot assets
    mkdir -pv "${BOOT}"

    # Get it right first time.
    mkdir -pv "${MOUNT}" "${SFSDIR}"
    chown -Rc root:root "${MOUNT}" "${SFSDIR}"
    # Only chmod directories
    chmod -Rc u=rwX,g=rX,o=rX "${MOUNT}" "${SFSDIR}"

    export RUST_BACKTRACE=1

    export MOSS="moss -D ${SFSDIR} --cache ${CACHE}"

    echo ">>> Add volatile AerynOS repository to ${SFSDIR}/ ..."
    time ${MOSS} repo add volatile https://build.aerynos.dev --root-index channel=main,version=stream/volatile || die_and_cleanup "Adding moss repo failed!"

    #echo ">>> Add local repo to ${SFSDIR}/ ..."
    #time ${MOSS} repo add local file:///home/ermo/.cache/local_repo/x86_64/stone.index -p10 || die_and_cleanup "Adding moss repo failed!"

    echo ">>> Install packages to ${SFSDIR}/ ..."
    time ${MOSS} install -y "${PACKAGES[@]}" || die_and_cleanup "Installing packages failed!"

    echo ">>> Set up basic environment in ${SFSDIR}/ ..."
    time ${CHROOT} -D "${SFSDIR}" systemd-firstboot --force --delete-root-password --locale=en_US.UTF-8 --timezone=UTC --root-shell=/usr/bin/bash && echo ">>>>> systemd-firstboot run done."

    # create user home directory
    mkdir "${SFSDIR}/home"
    chown -R root:root "${SFSDIR}/home"
    # create mail group
    time ${CHROOT} -D "${SFSDIR}" groupadd mail
    # create mail directory for users
    mkdir -p "${SFSDIR}/var/spool/mail"
    chown -R root:root "${SFSDIR}/var/spool/mail"
    # copy init file for wsl
    cp -R ${WORK}/osroot/* "${SFSDIR}/."
    chown -R root:root "${SFSDIR}/etc"

    echo ">>> Roll back and prune to keep only initially installed state and remove downloads ..."
#    time ${MOSS} state activate 1 -y || die_and_cleanup "Failed to activate initial state in ${TMPFS}/ !"
    time ${MOSS} state prune -k 1 --include-newer -y || die_and_cleanup "Failed to prune moss state in ${TMPFS}/ !"

    # Remove downloaded .stones to lower size of generated ISO
    rm -rf "${SFSDIR}"/.moss/cache/downloads/*

    SFSSIZE=$(du -BMiB -s ${TMPFS}|cut -f1|sed -e 's|MiB||g')
    echo ">>> ${SFSDIR} size: ${SFSSIZE} MiB"

    # Show the contents that will get included to satisfy ourselves that the source dirs specified below are sufficient
    ls -la "${SFSDIR}/"

    # Compress with gzip for WSL
    tar -czf "${OUTPUT}.tar.gz" -C "${SFSDIR}" .

    # create .wsl as well
    cp "${OUTPUT}.tar.gz" "${OUTPUT}.wsl"

    # The gnarly sed operation is here because the uutils-coreutils `ls` does not output the unit next to the size
    echo "Successfully built $(ls -s --block-size=M ${OUTPUT}.tar.gz | sed 's|\([[:digit:]]+*\) \(.*\)$|\1M \2|g') using ${COMPRESSOR} compression."

    echo -e "==============================================================="
    echo -e "=                       AerynOS WSL                           ="
    echo -e "==============================================================="
    echo -e "${GREEN}Build complete!${RESET}"
    echo -e "${YELLOW}Output: "
    echo -e "   ${OUTPUT}.tar.gz"
    echo -e "   ${OUTPUT}.wsl"
    echo -e "   ${RESET}"
    echo -e "On Windows, run: "
    echo -e "   wsl --import AerynOS <install_dir> ${OUTPUT}.tar.gz"
    echo -e "or "
    echo -e "   wsl --install --from-file ${OUTPUT}.wsl [--location <install_dir>]"
    echo -e "or "
    echo -e "   double-click ${OUTPUT}.wsl to install"
    echo -e ""
    echo -e "Then start it: wsl -d AerynOS"
    echo -e ""
    echo -e "${YELLOW}First boot instructions:${RESET}"
    echo -e "  - Run: wsl -d AerynOS"
    echo -e "  - Create user if needed:"
    echo -e "    sudo useradd -m your_username"
    echo -e "    sudo passwd your_username"
    echo -e "    sudo usermod -aG sudo your_username"
    echo -e ""
    echo -e "${YELLOW}Post-install tasks:${RESET}"
    echo -e "  - sudo moss sync -u  # Update package index"
    echo -e "  - sudo moss install <packages>  # Install more packages"
    echo -e ""
    echo -e "==============================================================="

    final_cleanup
}

ask_to_continue () {
    # Show a status page up front before generating the iso to avoid surprises

    echo -e "\nGenerating AerynOS WSL tarball & .wsl image using:\n"
    echo -e "- compression : ${COMPRESSOR}"
    echo -e "- package list: ${PACKAGE_LIST}"
    echo -e "- output name : ${OUTPUT}.tar.gz & ${OUTPUT}.wsl"
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
