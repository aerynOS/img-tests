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
    exit 1
fi

# Pkg list check
checkPrereqs
test -f ./pkglist-base || die "\nThis script MUST be run from within the virt-manager-vm/ dir with the ./pkglist-base file.\n"
command -v virsh || die "\n${0} assumes that virsh is installed.\n"
command -v virt-manager || die "\n${0} assumes that virt-manager is installed.\n"

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
    aerynos.tmpl > aerynos.xml

virsh -c qemu:///system define aerynos.xml

showStartMessage
showHelp
cleanEnv
unset VMDIR
unset VMNAME
unset ENABLE_SWAY
