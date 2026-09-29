#!/usr/bin/env bash
#
# SPDX-License-Identifier: MPL-2.0
#
# Copyright: © 2024 Serpent OS Developers
#

source ../basic-setup.sh

AOSROOT="${VMDIR:-${PWD}/aosroot}"
AOSNAME="${VMNAME:-aos_virtiofs}"
ENABLE_SWAY="${ENABLE_SWAY:-false}"
# 3D acceleration on NVIDIA hosts needs an egl-headless graphics device using
# the NVIDIA render node instead of enabling OpenGL on the SPICE server.
#   auto  -> enable it when an NVIDIA GPU is detected (default)
#   true  -> always enable it
#   false -> always use the SPICE OpenGL setup (e.g. AMD/Intel GPUs)
USE_HEADLESS_EGL="${USE_HEADLESS_EGL:-auto}"
# Override the render node, e.g. /dev/nvidia1 for a specific GPU.
EGL_RENDERNODE="${EGL_RENDERNODE:-}"

# Echo the device path of the first NVIDIA GPU render node found, if any.
detectNvidiaRendernode() {
    local node
    for node in /dev/nvidia[0-9]*; do
        if [ -c "${node}" ]; then
            printf '%s\n' "${node}"
            return 0
        fi
    done
    return 1
}

showStartMessage() {
    cat <<EOF

You can now start the ${AOSNAME} VM via the virt-manager UI!

----

EOF
}

showHelp() {
    cat <<EOF

If you want to store your machine somewhere else than ${AOSROOT},
just call the script with

    VMDIR="/some/where/else" ./create-virtio-vm.sh

If you want to name your machine something else than ${AOSNAME},
just call the script with 
    
    VMNAME="some_other_name" ./create-virtio-vm.sh

In case you directly want to install Sway as a desktop environment,
call the script with

    ENABLE_SWAY=true ./create-virtio-vm.sh

By default NVIDIA GPUs are detected and 3D acceleration is set up via an
egl-headless graphics device (which NVIDIA requires). You can control this
explicitly with

    USE_HEADLESS_EGL=auto|true|false ./create-virtio-vm.sh

'auto' (the default) only enables it when an NVIDIA GPU is detected, 'true'
always enables it and 'false' always uses the SPICE OpenGL setup. Use
EGL_RENDERNODE to point at a specific GPU, e.g.

    EGL_RENDERNODE="/dev/nvidia1" ./create-virtio-vm.sh

Should you have multiple GPUs in your system and you encounter
artifacts or no screen content at all, check in the VM display
settings that the correct GPU is being used.

EOF
}

if [ "$1" == "help" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    showHelp
    cleanEnv
    unset VMDIR
    unset VMNAME
    unset ENABLE_SWAY
    unset USE_HEADLESS_EGL
    unset EGL_RENDERNODE
    exit 1
fi

# Pkg list check
checkPrereqs
test -f ./pkglist-base || die "\nThis script MUST be run from within the virt-manager-vm/ dir with the ./pkglist-base file.\n"
command -v virsh || die "\n${0} assumes that virsh is installed.\n"
command -v virt-manager || die "\n${0} assumes that virt-manager is installed.\n"

# Decide which 3D acceleration setup to use
case "${USE_HEADLESS_EGL}" in
    auto)
        if [ -z "${EGL_RENDERNODE}" ]; then
            EGL_RENDERNODE="$(detectNvidiaRendernode)" || EGL_RENDERNODE=""
        fi
        if [ -n "${EGL_RENDERNODE}" ]; then
            HEADLESS_EGL=true
        else
            HEADLESS_EGL=false
        fi
        ;;
    true|yes|1)
        HEADLESS_EGL=true
        if [ -z "${EGL_RENDERNODE}" ]; then
            EGL_RENDERNODE="$(detectNvidiaRendernode)" || EGL_RENDERNODE="/dev/nvidia0"
        fi
        ;;
    false|no|0)
        HEADLESS_EGL=false
        ;;
    *)
        die "\nUSE_HEADLESS_EGL must be one of 'auto', 'true' or 'false' (got '${USE_HEADLESS_EGL}').\n"
        ;;
esac

if [[ "${HEADLESS_EGL}" = "true" ]]; then
    MSG="Using egl-headless 3D acceleration via ${EGL_RENDERNODE}..."
else
    MSG="Using SPICE OpenGL 3D acceleration..."
fi
printInfo "${MSG}"

# start with a common base of packages
readarray -t PACKAGES < ../pkglist-base
# add linux-kvm specific packages
PACKAGES+=($(cat ./pkglist-kvm))

if [[ "${ENABLE_SWAY}" = "true" ]]; then
    PACKAGES+=("pkgset-aeryn-sway-minimal")
    PACKAGES+=("pkgset-aeryn-base-desktop")
fi

basicSetup

MSG="Removing previous VM configuration..."
printInfo "${MSG}"
if sudo virsh desc "${AOSNAME}" &> /dev/null; then
    sudo virsh destroy "${AOSNAME}" || true
    sudo virsh undefine "${AOSNAME}" --keep-nvram || die "'virsh undefine aos' failed, exiting."
fi

MSG="Setting up virt-mananger ${AOSNAME} instance from template..."
printInfo "${MSG}"
# In some cases, this will find more than one entry
FOUNDPAYLOADS=($(find /usr/share -name 'OVMF_CODE.*fd' |grep -v secure))
# ... if so, just pick the first one
FOUNDPAYLOAD=${FOUNDPAYLOADS[0]}
# Defaults to the location in Solus
UEFIPAYLOAD="${FOUNDPAYLOAD:-/usr/share/edk2-ovmf/x64/OVMF_CODE.fd}"
MSG="Found \$UEFIPAYLOAD: ${UEFIPAYLOAD}..."
printInfo "${MSG}"
sed -e "s|###AOSNAME###|${AOSNAME}|g" \
    -e "s|###AOSROOT###|${AOSROOT}|g" \
    -e "s|###UEFIPAYLOAD###|${UEFIPAYLOAD}|g" \
    -e "s|###EGL_RENDERNODE###|${EGL_RENDERNODE}|g" \
    aerynos.tmpl > aerynos.xml

# Keep only the graphics configuration matching the chosen 3D setup
if [[ "${HEADLESS_EGL}" = "true" ]]; then
    sed -i -e '/###OPENGL_SPICE_START###/,/###OPENGL_SPICE_END###/d' \
        -e '/###EGL_HEADLESS_START###/d' \
        -e '/###EGL_HEADLESS_END###/d' aerynos.xml
else
    sed -i -e '/###EGL_HEADLESS_START###/,/###EGL_HEADLESS_END###/d' \
        -e '/###OPENGL_SPICE_START###/d' \
        -e '/###OPENGL_SPICE_END###/d' aerynos.xml
fi

virsh -c qemu:///system define aerynos.xml

showStartMessage
showHelp
cleanEnv
unset VMDIR
unset VMNAME
unset ENABLE_SWAY
unset USE_HEADLESS_EGL
unset EGL_RENDERNODE
unset HEADLESS_EGL
