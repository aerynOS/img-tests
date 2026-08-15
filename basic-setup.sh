#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: © 2023-2025 Serpent OS Developers
# SPDX-FileCopyrightText: © 2025- AerynOS Developers
# SPDX-License-Identifier: MPL-2.0
#

# shared-setup.sh:
# script with shared utility functions for conveniently creating a
# clean AerynOS root directory  directory suitable for use as the
# root in AerynOS systemd-nspawn container or linux-kvm kernel driven
# qemu-kvm virtual machine.

# target dirs
# use a default aosroot
AOSROOT="${DESTDIR:-${PWD}/aosroot}"
BOULDERCACHE="${HOME}/.cache/boulder"
CHROOT="sudo systemd-nspawn --as-pid2 --private-users=identity --user=0 --quiet"

# utility functions
BOLD='\033[1m'
RED='\033[0;31m'
RESET='\033[0m'
YELLOW='\033[0;33m'

printInfo () {
    local INFO="${BOLD}INFO${RESET}"
    echo -e "${INFO} ${*}"
}

printWarning () {
    local WARNING="${YELLOW}${BOLD}WARNING${RESET}"
    echo -e "${WARNING} ${*}"
}

printError () {
    local ERROR="${RED}${BOLD}ERROR${RESET}"
    echo -e "${ERROR} ${*}"
}

die() {
    printError "${*} failed, exiting.\n"
    exit 1
}

checkPrereqs () {
    printInfo "Checking prerequisites..."
    test -f ./pkglist-base || die "\nRun this script from the root of the img-tests/ repo clone!\n"
    test -x $(command -v moss) || die "\n${0} assumes moss is installed. See https://github.com/AerynOS/os-tools/\n"
}

# base packages
readarray -t PACKAGES < ./pkglist-base

#echo "${PACKAGES[@]}"
#die "Test of PACKAGES."

createNssswitchConf () {
    cat << EOF > ./nsswitch.conf
passwd:         files systemd
group:          files [SUCCESS=merge] systemd
shadow:         files systemd
gshadow:        files systemd

hosts:          mymachines resolve [!UNAVAIL=return] files myhostname dns
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files
EOF
}

basicSetup () {
    # NB: This will fail if moss is an alias!
    local moss="$(command -v moss)"
    printInfo "Using moss binary found here: ${moss} ($(${moss} version))"

    MSG="Removing old ${AOSROOT} directory..."
    printInfo "${MSG}"
    sudo rm -rf "${AOSROOT}" || die "${MSG}"

    MSG="Making sure ${BOULDERCACHE} directory exists..."
    printInfo "${MSG}"
    sudo mkdir -pv "${BOULDERCACHE}"

    MSG="Creating new ${AOSROOT} directory w/baselayout skeleton..."
    printInfo "${MSG}"
    sudo mkdir -pv "${AOSROOT}"/{etc,proc,run,sys,var,var/local,"${BOULDERCACHE}"} || die "${MSG}"

    # No longer necessary -- moss triggers have been fixed to respect trigger dep order now
    #MSG="Ensuring that we get a working nss-systemd-compatible nssswitch.conf..."
    #printInfo "${MSG}"
    #createNssswitchConf || die "${MSG}"
    #sudo cp -v ./nsswitch.conf "${AOSROOT}"/etc/ || die "${MSG}"

    MSG="Ensuring that various network protocols function..."
    printInfo "${MSG}"
    sudo cp -va /etc/protocols "${AOSROOT}"/etc/ || die "${MSG}"

    MSG="Adding volatile AerynOS repository..."
    printInfo "${MSG}"
    sudo ${moss} -D "${AOSROOT}" -y repo add volatile https://build.aerynos.dev --root-index version=stream/volatile -p0 || die "${MSG}"

    MSG="Installing packages..."
    printInfo "${MSG}"
    sudo ${moss} -D "${AOSROOT}" -y --cache "${BOULDERCACHE}" install "${PACKAGES[@]}" || die "${MSG}"

    MSG="Setting up basic environment in ${AOSROOT}/ ..."
    printInfo "${MSG}"
    time ${CHROOT} -D "${AOSROOT}" systemd-firstboot --force --delete-root-password --locale=en_US.UTF-8 --timezone=UTC --root-shell=/usr/bin/bash && echo ">>>>> systemd-firstboot run done."

    MSG="Configuring live user..."
    printInfo "${MSG}"
    time ${CHROOT} -D "${AOSROOT}" useradd -c "Live User" -d "/home/live" -G "audio,adm,wheel,render,input,users" -m -U -s "/usr/bin/bash" live
    sudo cp -Rv ./desktop/rootfs_extra/etc/sudoers.d "${AOSROOT}/etc/"
    ${CHROOT} -D "${AOSROOT}" chown -R live:live /home/live
    ${CHROOT} -D "${AOSROOT}" passwd -d live

    MSG="Setting /etc/issue ..."
    printInfo "${MSG}"
    sudo rm -vf issue
    test -f "${AOSROOT}"/etc/issue && cp -v "${AOSROOT}"/etc/issue issue
    echo -e "By default, the live and root users have no passwords.\n\n" >> issue
    sudo mv -v issue "${AOSROOT}"/etc/issue

    MSG="Preparing local-x86_64 profile directory..."
    printInfo "${MSG}"
    sudo mkdir -pv "${AOSROOT}/${BOULDERCACHE}/repos/local-x86_64/" || die "${MSG}"

    MSG="Creating a moss stone.index file for the local-x86_64 profile..."
    printInfo "${MSG}"
    sudo ${moss} -y index "${AOSROOT}/${BOULDERCACHE}/repos/local-x86_64/" || die "${MSG}"

    MSG="Adding local-x86_64 profile to list of active repositories..."
    printInfo "${MSG}"
    sudo chroot ${AOSROOT} moss -y repo add local-x86_64 "file://${BOULDERCACHE}/repos/local-x86_64/stone.index" -p10 || die "${MSG}"
}

# clean up env
cleanEnv () {
    unset BOULDERCACHE
    unset MSG
    unset PACKAGES
    unset AOSROOT
    unset CHROOT

    unset BOLD
    unset RED
    unset RESET
    unset YELLOW
}
