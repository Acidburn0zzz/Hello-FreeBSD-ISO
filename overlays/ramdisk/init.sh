#!/rescue/sh

PATH="/rescue"

if [ "`ps -o command 1 | tail -n 1 | ( read c o; echo ${o} )`" = "-s" ]; then
	echo "==> Running in single-user mode"
	SINGLE_USER="true"
	kenv boot_mute="NO"
fi

if [ "`ps -o command 1 | tail -n 1 | ( read c o; echo ${o} )`" = "-v" ]; then
	echo "==> Running in verbose mode"
	kenv boot_mute="NO"
fi

# Silence messages if boot_mute="YES" is set
if [ "$(kenv boot_mute)" = "YES" ] ; then
      exec 1>>/dev/null 2>&1
fi

set -x

echo "==> Ramdisk /init.sh running"

if [ "$SINGLE_USER" = "true" ]; then
	echo "Starting interactive shell before doing anything ..."
	sh
fi

echo "==> Remount rootfs as read-write"
mount -u -w /

echo "==> Make mountpoints"
mkdir -p /cdrom
mkdir -p /sysroot
mkdir -p /memdisk

echo "Waiting for Live media to appear"
while : ; do
    [ -e "/dev/iso9660/LIVE" ] && echo "found /dev/iso9660/LIVE" && break
    sleep 1
done

echo "==> Mount /cdrom"
mount_cd9660 /dev/iso9660/LIVE /cdrom

echo "==> Mount /sysroot"
mdmfs -P -F /cdrom/data/system.uzip -o ro md.uzip /sysroot # FIXME: This does not seem to work; why?

if [ "$SINGLE_USER" = "true" ]; then
	echo -n "Enter memdisk size used for read-write access in the live system: "
	read MEMDISK_SIZE
else
	MEMDISK_SIZE="2048"
fi

echo "==> Mount unionfs"
mdmfs -s "${MEMDISK_SIZE}m" md /memdisk || exit 1
mount -t unionfs /memdisk /sysroot

echo "==> Change into /sysroot"
mount -t devfs devfs /sysroot/dev
chroot /sysroot /usr/local/bin/furybsd-init-helper

if [ "$SINGLE_USER" = "true" ]; then
	echo "Starting interactive shell after chroot ..."
	sh
fi

kenv init_shell="/rescue/sh"
exit 0
