#!/bin/sh

# Exit on errors
set -e

# Determine the version of the running host system.
# Building ISOs for other major versions than the running host system
# is not supported and results in broken images anyway
version=$(uname -r | cut -d "-" -f 1-2) # "12.2-RELEASE" or "13.0-CURRENT"

# Dwnload from either https://download.freebsd.org/ftp/releases/
#                  or https://download.freebsd.org/ftp/snapshots/
VERSIONSUFFIX=$(uname -r | cut -d "-" -f 2) # "RELEASE" or "CURRENT"
FTPDIRECTORY="releases" # "releases" or "snapshots"
if [ "${VERSIONSUFFIX}" = "CURRENT" ] ; then
  FTPDIRECTORY="snapshots"
fi
echo "${FTPDIRECTORY}"

# pkgset="branches/2020Q1" # TODO: Use it
desktop=$1
tag=$2
export cwd=$(realpath | sed 's|/scripts||g')
workdir="/usr/local"
livecd="${workdir}/furybsd"
if [ -z "${arch}" ] ; then
  arch=amd64
fi
cache="${livecd}/${arch}/cache"
base="${cache}/${version}/base"
export packages="${cache}/packages"
iso="${livecd}/iso"
  if [ -n "$CIRRUS_CI" ] ; then
    # On Cirrus CI ${livecd} is in tmpfs for speed reasons
    # and tends to run out of space. Writing the final ISO
    # to non-tmpfs should be an acceptable compromise
    iso="${CIRRUS_WORKING_DIR}/artifacts"
  fi
export uzip="${livecd}/uzip"
export cdroot="${livecd}/cdroot"
ramdisk_root="${cdroot}/data/ramdisk"
vol="furybsd"
label="LIVE"
export DISTRIBUTIONS="kernel.txz base.txz"

# Only run as superuser
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

# Make sure git is installed
# We only need this in case we decide to pull in ingredients from
# other git repositories; this is currently not the case
# if [ ! -f "/usr/local/bin/git" ] ; then
#   echo "Git is required"
#   echo "Please install it with pkg install git or pkg install git-lite first"
#   exit 1
# fi

if [ -z "${desktop}" ] ; then
  export desktop=xfce
fi
edition=$(echo $desktop | tr '[:lower:]' '[:upper:]')
export edition
if [ ! -f "${cwd}/settings/packages.${desktop}" ] ; then
  echo "${cwd}/settings/packages.${desktop} is missing, exiting"
  exit 1
fi

# Get the version tag
if [ -z "$2" ] ; then
  rm /usr/local/furybsd/tag >/dev/null 2>/dev/null || true
  export vol="${desktop}-${version}"
else
  rm /usr/local/furybsd/version >/dev/null 2>/dev/null || true
  echo "${2}" > /usr/local/furybsd/tag
  export vol="${desktop}-${version}-${tag}"
fi

# Get the short git SHA
SHA=$(echo ${CIRRUS_CHANGE_IN_REPO}| cut -c1-7)

if [ -z "${SHA}" ] ; then
  isopath="${iso}/${vol}-${arch}.iso"
else
  isopath="${iso}/${vol}-${SHA}-${arch}.iso"
fi

cleanup()
{
  if [ -n "$CIRRUS_CI" ] ; then
    # On CI systems there is no reason to clean up which takes time
    return 0
  else
    umount ${uzip}/var/cache/pkg >/dev/null 2>/dev/null || true
    umount ${uzip}/dev >/dev/null 2>/dev/null || true
    zpool destroy -f furybsd >/dev/null 2>/dev/null || true
    mdconfig -d -u 0 >/dev/null 2>/dev/null || true
    rm ${livecd}/pool.img >/dev/null 2>/dev/null || true
    rm -rf ${cdroot} >/dev/null 2>/dev/null || true
  fi
}

workspace()
{
  mkdir -p "${livecd}" "${base}" "${iso}" "${packages}" "${uzip}" "${ramdisk_root}/dev" "${ramdisk_root}/etc" >/dev/null 2>/dev/null
  truncate -s 3g "${livecd}/pool.img"
  mdconfig -f "${livecd}/pool.img" -u 0
  gpart create -s GPT md0
  gpart add -t freebsd-zfs md0
  sync ### Needed?
  zpool create furybsd /dev/md0p1
  sync ### Needed?
  zfs set mountpoint="${uzip}" furybsd
  # From FreeBSD 13 on, zstd can be used with zfs in base
  MAJOR=$(uname -r | cut -d "." -f 1)
  if [ $MAJOR -lt 13 ] ; then
    zfs set compression=gzip-6 furybsd 
  else
    zfs set compression=zstd-9 furybsd 
  fi

}

base()
{
  # TODO: Signature checking
  if [ ! -f "${base}/base.txz" ] ; then 
    cd ${base}
    fetch https://download.freebsd.org/ftp/${FTPDIRECTORY}/${arch}/${version}/base.txz
  fi
  
  if [ ! -f "${base}/kernel.txz" ] ; then
    cd ${base}
    fetch https://download.freebsd.org/ftp/${FTPDIRECTORY}/${arch}/${version}/kernel.txz
  fi
  cd ${base}
  tar -zxvf base.txz -C ${uzip}
  tar -zxvf kernel.txz -C ${uzip}
  touch ${uzip}/etc/fstab
}

packages()
{
  # We want to try latest rather than quarterly packages for FreeBSD 13
  # Since it that version is bleeding edge anyway, why not also use bleeding edge packages
  # NOTE: Also adjust the Nvidia drivers accordingly below. TODO: Use one set of variables
  MAJOR=$(uname -r | cut -d "." -f 1)
  if [ $MAJOR -lt 13 ] ; then
    echo "Major version < 13, hence using quarterly packages"
  else
    echo "Major version >= 13, hence changing /etc/pkg/FreeBSD.conf to use latest packages"
    sed -i -e 's|quarterly|latest|g' "${uzip}/etc/pkg/FreeBSD.conf"
    rm -f "${uzip}/etc/pkg/FreeBSD.conf-e"
  fi
  cp /etc/resolv.conf ${uzip}/etc/resolv.conf
  mkdir ${uzip}/var/cache/pkg
  mount_nullfs ${packages} ${uzip}/var/cache/pkg
  mount -t devfs devfs ${uzip}/dev
  # FIXME: In the following line, the hardcoded "i386" needs to be replaced by "${arch}" - how?
  cat "${cwd}/settings/packages.common" | sed '/^#/d' | sed '/\!i386/d' | xargs /usr/local/sbin/pkg-static -c "${uzip}" install -y
  while read -r p; do
    /usr/local/sbin/pkg-static -c ${uzip} install -y /var/cache/pkg/"${p}"-0.txz
  done <"${cwd}"/settings/overlays.common
  # TODO: Show dependency tree so that we know why which pkgs get installed
  # cat "${cwd}/settings/packages.common" | sed '/^#/d' | sed '/\!'"${arch}"'/d' | xargs /usr/local/sbin/pkg-static -c "${uzip}" info -d
  # cat "${cwd}/settings/packages.${desktop}" | sed '/^#/d' | sed '/\!'"${arch}"'/d' | xargs /usr/local/sbin/pkg-static -c "${uzip}" info -d
  cat "${cwd}/settings/packages.${desktop}" | sed '/^#/d' | sed '/\!i386/d' | xargs /usr/local/sbin/pkg-static -c "${uzip}" install -y
  if [ -f "${cwd}/settings/overlays.${desktop}" ] ; then
    while read -r p; do
      /usr/local/sbin/pkg-static -c ${uzip} install -y /var/cache/pkg/"${p}"-0.txz
    done <"${cwd}/settings/overlays.${desktop}"
  fi
  # Workaround for kernel-related packages being broken in the default package repository
  # as long as the previous dot release is still supported; FIXME
  # https://forums.freebsd.org/threads/i915kms-package-breaks-on-12-2-release-workaround-build-from-ports.77501/
  # FIXME: Add https://darkness-pi.monwarez.ovh/posts/synth-repository/ properly. How?
  # IGNORE_OSVERSION=yes /usr/local/sbin/pkg-static -c "${uzip}" add https://darkness-pi.monwarez.ovh/amd64/All/drm-fbsd12.0-kmod-4.16.g20200221.txz
  # For now we are just going back to using 12.1 rather than 12.2
  /usr/local/sbin/pkg-static -c ${uzip} info > "${cdroot}/data/system.uzip.manifest"
  cp "${cdroot}/data/system.uzip.manifest" "${isopath}.manifest"
  rm ${uzip}/etc/resolv.conf
  umount ${uzip}/var/cache/pkg
  umount ${uzip}/dev
}

rc()
{
  if [ ! -f "${uzip}/etc/rc.conf" ] ; then
    touch ${uzip}/etc/rc.conf
  fi
  if [ ! -f "${uzip}/etc/rc.conf.local" ] ; then
    touch ${uzip}/etc/rc.conf.local
  fi
  cat "${cwd}/settings/rc.conf.common" | xargs chroot "${uzip}" sysrc -f /etc/rc.conf.local
  cat "${cwd}/settings/rc.conf.${desktop}" | xargs chroot "${uzip}" sysrc -f /etc/rc.conf.local
}


repos()
{
  # This is just an example of how a git repo needs to be structured
  # so that it can be consumed directly here
  # if [ ! -d "${cwd}/overlays/uzip/furybsd-common-settings" ] ; then
  #   git clone https://github.com/probonopd/furybsd-common-settings.git ${cwd}/overlays/uzip/furybsd-common-settings
  # else
  #   cd ${cwd}/overlays/uzip/furybsd-common-settings && git pull
  # fi
  true
}

user()
{
  mkdir -p ${uzip}/usr/home/liveuser/Desktop
  # chroot ${uzip} echo furybsd | chroot ${uzip} pw mod user root -h 0
  chroot ${uzip} pw useradd liveuser -u 1000 \
  -c "Live User" -d "/home/liveuser" \
  -g wheel -G operator -m -s /usr/local/bin/zsh -k /usr/share/skel -w none
  chroot ${uzip} pw groupadd liveuser -g 1000
  # chroot ${uzip} echo furybsd | chroot ${uzip} pw mod user liveuser -h 0
  chroot ${uzip} chown -R 1000:1000 /usr/home/liveuser
  chroot ${uzip} pw groupmod wheel -m liveuser
  chroot ${uzip} pw groupmod video -m liveuser
  chroot ${uzip} pw groupmod webcamd -m liveuser
}

dm()
{
  case $desktop in
    'kde')
      ;;
    'gnome')
      ;;
    'lumina')
      ;;
    'mate')
      chroot ${uzip} sed -i '' -e 's/memorylocked=128M/memorylocked=256M/' /etc/login.conf
      chroot ${uzip} cap_mkdb /etc/login.conf
      ;;
    'xfce')
      ;;
  esac
}

# Generate on-the-fly packages for the selected overlays
pkg()
{
  cd "${packages}"
  while read -r p; do
    sh -ex "${cwd}/scripts/build-pkg.sh" -m "${cwd}/overlays/uzip/${p}"/manifest -d "${cwd}/overlays/uzip/${p}/files"
  done <"${cwd}"/settings/overlays.common
  if [ -f "${cwd}/settings/overlays.${desktop}" ] ; then
    while read -r p; do
      sh -ex "${cwd}/scripts/build-pkg.sh" -m "${cwd}/overlays/uzip/${p}"/manifest -d "${cwd}/overlays/uzip/${p}/files"
    done <"${cwd}/settings/overlays.${desktop}"
  fi
  cd -
}

# Put Nvidia driver at location in which initgfx expects it
initgfx()
{
  if [ "${arch}" != "i386" ] ; then
    MAJOR=$(uname -r | cut -d "." -f 1)
    if [ $MAJOR -lt 13 ] ; then
      PKGS="quarterly"
    else
      PKGS="latest"
    fi
    wget -c "https://pkg.freebsd.org/FreeBSD:${MAJOR}:amd64/${PKGS}/All/nvidia-driver-440.100_1.txz" -P "${cache}"
    mkdir -p "${uzip}/usr/local/nvidia/440/"
    tar xf "${cache}"/nvidia-driver-*.txz -C "${uzip}/usr/local/nvidia/440/"
    ls "${uzip}/usr/local/nvidia/440/+COMPACT_MANIFEST"
  fi
  
  ls
  # TODO: initgfx also wants:
  # /boot/drm_legacy/
  # drm.ko
  # drm2.ko
  # i915kms.ko
  # linker.hints
  # mach64.ko
  # mga.ko
  # r128.ko
  # radeonkms.ko
  # savage.ko
  # sis.ko
  # tdfx.ko
  # via.ko
}

script()
{
  if [ -e "${cwd}/settings/script.${desktop}" ] ; then
    # cp "${cwd}/settings/script.${desktop}" "${uzip}"/tmp/script
    # chmod +x "${uzip}"/tmp/script
    # chroot "${uzip}" /tmp/script
    # rm "${uzip}"/tmp/script
    "${cwd}/settings/script.${desktop}"
  fi
}

uzip() 
{
  install -o root -g wheel -m 755 -d "${cdroot}"
  zfs set mountpoint="/" furybsd ### If we can get the pool to mount at /, then maybe we can do away with reroot, chroot, nullfs?
  sync ### Needed?
  cd ${cwd} && zpool export furybsd && while zpool status furybsd >/dev/null; do :; done 2>/dev/null
  sync ### Needed?
  ### mkuzip -S -d -o "${cdroot}/data/system.uzip" "${livecd}/pool.img" ### It is already compressed by zfs
  ls -lh "${livecd}/pool.img"
}

ramdisk() 
{
  cp -R "${cwd}/overlays/ramdisk/" "${ramdisk_root}"
  sync ### Needed?
  cd ${cwd} && zpool import furybsd && zfs set mountpoint=/usr/local/furybsd/uzip furybsd
  sync ### Needed?
  cd "${uzip}" && tar -cf - rescue | tar -xf - -C "${ramdisk_root}"
  touch "${ramdisk_root}/etc/fstab"
  cp ${uzip}/etc/login.conf ${ramdisk_root}/etc/login.conf
  makefs -b '10%' "${cdroot}/data/ramdisk.ufs" "${ramdisk_root}"
  gzip -f "${cdroot}/data/ramdisk.ufs"
  rm -rf "${ramdisk_root}"
}

boot() 
{
  cp -R "${cwd}/overlays/boot/" "${cdroot}"
  cd "${uzip}" && tar -cf - boot | tar -xf - -C "${cdroot}"
  sync ### Needed?
  cd ${cwd} && zpool export furybsd && mdconfig -d -u 0
  sync ### Needed?
  # The name of a dependency for zfs.ko changed, violating POLA
  # If we are loading both modules, then at least 13 cannot boot, hence only load one based on the FreeBSD major version
  MAJOR=$(uname -r | cut -d "." -f 1)
  if [ $MAJOR -lt 13 ] ; then
    echo "Major version < 13, hence using opensolaris.ko"
    sed -i -e 's|opensolaris_load=".*"|opensolaris_load="YES"|g' "${cdroot}"/boot/loader.conf
    rm -f "${cdroot}"/boot/loader.conf-e
    sed -i -e 's|cryptodev_load=".*"|cryptodev_load="NO"|g' "${cdroot}"/boot/loader.conf
    rm -f "${cdroot}"/boot/loader.conf-e
    sed -i -e 's|tmpfs_load=".*"|tmpfs_load="YES"|g' "${cdroot}"/boot/loader.conf
    rm -f "${cdroot}"/boot/loader.conf-e
  else
    echo "Major version >= 13, hence using cryptodev.ko"
    sed -i -e 's|cryptodev_load=".*"|cryptodev_load="YES"|g' "${cdroot}"/boot/loader.conf
    rm -f "${cdroot}"/boot/loader.conf-e
    sed -i -e 's|opensolaris_load=".*"|opensolaris_load="NO"|g' "${cdroot}"/boot/loader.conf
    rm -f "${cdroot}"/boot/loader.conf-e
    sed -i -e 's|tmpfs_load=".*"|tmpfs_load="NO"|g' "${cdroot}"/boot/loader.conf
    rm -f "${cdroot}"/boot/loader.conf-e
  fi
  sync ### Needed?
}

tag()
{
  if [ -n "$CIRRUS_CI" ] ; then
    SHA=$(echo "${CIRRUS_CHANGE_IN_REPO}" | head -c 7)
    URL="https://${CIRRUS_REPO_CLONE_HOST}/${CIRRUS_REPO_FULL_NAME}/commit/${SHA}"
    echo "${URL}"
    echo "${URL}" > "${cdroot}/.url"
    echo "${URL}" > "${uzip}/.url"
    echo "Setting extended attributes 'url' and 'sha' on '/.url'"
    setextattr user sha "${SHA}" "${uzip}/.url"
    setextattr user url "${URL}" "${uzip}/.url"
  fi
}

image()
{
  sh "${cwd}/scripts/mkisoimages-${arch}.sh" -b "${label}" "${isopath}" "${cdroot}"
  sync ### Needed?
  md5 "${isopath}" > "${isopath}.md5"
  echo "$isopath created"
}

cleanup
workspace
repos
pkg
base
packages
initgfx
rc
user
dm
script
tag
uzip
ramdisk
boot
image
