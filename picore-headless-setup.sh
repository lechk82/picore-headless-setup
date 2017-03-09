#/bin/bash

PICORE_ARCH="armv6"
PICORE_VERSION="8.x"
PICORE_SUBVERSION="8.1.5"
PICORE_KERNEL_VERSION="4.4.39"

WORK_DIR=~/picore-$PICORE_SUBVERSION
MNT_DIR="$WORK_DIR/mnt"

IMG_BLOCKSIZE=512
IMG_BLOCKS=204800 # 512 * 204800 = 104857600 (~100MB)

SSID="yourssid"
WLANPASS="yourpass"

WGET_OPTS="--proxy=off"

PICORE_BASE_URL="http://distro.ibiblio.org/tinycorelinux"
PICORE_REPOSITORY_URL="$PICORE_BASE_URL/$PICORE_VERSION/$PICORE_ARCH"
PICORE_RELEASES_URL="$PICORE_REPOSITORY_URL/releases/RPi"
PICORE_PACKAGES_URL="$PICORE_REPOSITORY_URL/tcz"
PICORE_PACKAGE_EXTESION="tcz"
PICORE_RELEASE_URL="$PICORE_RELEASES_URL/piCore-$PICORE_SUBVERSION.zip"
PICORE_KERNEL_SUFFIX="-$PICORE_KERNEL_VERSION-piCore+"
PICORE_LOCAL_PACKAGE_PATH="tce/optional"
PICORE_LOCAL_MYDATA="tce/mydata"

PICORE_PACKAGES=(	"file"\
					"ncurses"\
					"nano"\
)

PICORE_PACKAGES_WLAN_CLIENT=(	"libnl"\
								"libiw"\
								"wireless$PICORE_KERNEL_SUFFIX"\
								"wireless_tools"\
								"wpa_supplicant"\
								"openssl"\
								"openssh"\
)

WPA_SUPPLICANT_CONF="
ctrl_interface=/var/run/wpa_supplicant
network={
ssid=\"$SSID\"
psk=\"$WLANPASS\"
}
"

BOOTLOCAL_SCRIPT="#!/bin/sh
/usr/sbin/startserialtty &
echo ondemand > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
/sbin/modprobe i2c-dev
sleep 2
/usr/local/sbin/wpa_supplicant -B -D wext -i wlan0 -c /opt/wpa_supplicant.conf &
/sbin/udhcpc -b -i wlan0 -x hostname:$(/bin/hostname) -p /var/run/udhcpc.wlan0.pid &
/usr/local/etc/init.d/openssh start
"

##############################################################################

PICORE_PACKAGES=("${PICORE_PACKAGES[@]}" "${PICORE_PACKAGES_WLAN_CLIENT[@]}")
DEPENDENCIES=(	"wget"\
				"md5sum"\
				"unzip"\
				"dd"\
				"sudo losetup"\
				"sudo kpartx"\
				"sudo parted"\
				"sudo e2fsck"\
				"sudo resize2fs"\
				"mount"\
				"umount"\
				"cat"\
				"awk"\
				"tar"
)

function prepare_dirs(){
    [ -d $WORK_DIR ] || mkdir $WORK_DIR
    [ -d $MNT_DIR ] || mkdir $MNT_DIR
}

function command_exists() {
    type "$1" &> /dev/null ;
}

function validate_url(){
    if [[ `wget $WGET_OPTS -S --spider $1  2>&1 | grep 'HTTP/1.1 200 OK'` ]]; then return 0; else return 1; fi
}

function check_dependencies(){
	echo "*** Check dependencies ***"
	for i in "${DEPENDENCIES[@]}"
    	do
    		echo -ne $i
    		if command_exists $i ; then
    			echo " OK"
    		else
    			echo " ERROR. Please install $i and rerun."
    			exit 1
    		fi
    done
}

function get_release(){
    echo "*** Downloading PiCore Release ***"
    echo -ne " * PiCore $PICORE_SUBVERSION" "($PICORE_RELEASE_URL)"    
    if validate_url $PICORE_RELEASE_URL;
    then
    	echo " OK";
    	if [ -f "$WORK_DIR/piCore-$PICORE_SUBVERSION.zip" ] ; then
    	    rm "$WORK_DIR/piCore-$PICORE_SUBVERSION.zip"
    	fi
    	wget -N $WGET_OPTS $PICORE_RELEASE_URL -P $WORK_DIR &&
    	unzip -o "$WORK_DIR/piCore-$PICORE_SUBVERSION.zip" -d $WORK_DIR &&
    	cd $WORK_DIR;
    	md5sum -c "piCore-$PICORE_SUBVERSION.img.md5.txt";
    	[ $? -eq 0 ] || (cd -; exit $?;)
    	cd -; 
    else
    	echo " ERROR: url not available";
    	exit 1;
    fi
}

function make_image(){
    echo "*** Creating Custom PiCore Image ***"
    
    echo " * Generating empty image (be patient)"
    sudo dd bs=$IMG_BLOCKSIZE count=$IMG_BLOCKS if=/dev/zero of=$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img   
    
    echo " * Cloning into custom image (be patient)"
    SRC="$(sudo losetup -f --show $WORK_DIR/piCore-$PICORE_SUBVERSION.img)"
    DEST="$(sudo losetup -f --show $WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img)"
    sudo dd if=$SRC of=$DEST
    
    echo " * Init custom image loop device"
    sudo losetup -d $SRC $DEST
    
    echo " * Setup custom image partitions"
    tmp=$(sudo kpartx -l "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img" | awk '{ print $1 }' )
    IFS=$'\n' read -rd '' -a parts <<<"$tmp"
    sudo kpartx -a "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img"
    ln -s /dev/mapper/${parts[0]} "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img1"
    ln -s /dev/mapper/${parts[1]} "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img2"
    
    echo " * Resize custom image partition"
    tmp=$(sudo parted -m -s "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img" unit s print | awk --field-separator=":" '{print $2}')
    IFS=$'\n' read -rd '' -a size <<<"$tmp"
    start=${size[2]::-1}
    end=$((${size[0]::-1}-1))
    sudo parted -s "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img" unit s rm 2
    sudo parted -s "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img" unit s mkpart primary $start $end
    sudo kpartx -d "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img"
    sudo kpartx -a "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img"
    
    echo " * Check custom image partition"
    sudo e2fsck -f "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img2"
    sudo resize2fs "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img2"
    
    echo " * Mount custom image partition"
    sudo mount "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img2" $MNT_DIR
}

function cleanup(){
    echo "*** Cleaning up ***"
    sudo umount $MNT_DIR && [ -d "$MNT_DIR" ] && rm "$MNT_DIR" -r
    sudo kpartx -d "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img" 
    [ -L "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img1" ] && rm "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img1"
    [ -L "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img2" ] && rm "$WORK_DIR/piCore-$PICORE_SUBVERSION.custom.img2"
    [ -e "$WORK_DIR/piCore-$PICORE_SUBVERSION.zip" ] && rm "$WORK_DIR/piCore-$PICORE_SUBVERSION.zip"
}

function test_package_urls(){
    echo "*** Cheking package URLs ***"
    for i in "${PICORE_PACKAGES[@]}"
    do
        URL="$PICORE_PACKAGES_URL/$i.$PICORE_PACKAGE_EXTESION"
        echo -ne " * $i" "($URL)"
        if validate_url $URL;
        then 
            echo " OK";
        else 
            echo " ERROR: url not available"; 
            cleanup
            exit 1;
        fi
    done
}

function get_packages(){
    echo "*** Downlaoding packages ***"
    for i in "${PICORE_PACKAGES[@]}"
    do
        URL="$PICORE_PACKAGES_URL/$i.$PICORE_PACKAGE_EXTESION"
        echo " * $i" "($URL)"
        sudo wget -N $WGET_OPTS $URL -P "$MNT_DIR/$PICORE_LOCAL_PACKAGE_PATH/"
    	sudo wget -N $WGET_OPTS "$URL.md5.txt" -P "$MNT_DIR/$PICORE_LOCAL_PACKAGE_PATH/"
    done
}
function make_onboot_list(){
    echo "*** Adding packages to onboot.lst ***"
    sudo sh -c "> $MNT_DIR/tce/onboot.lst"
    for i in "${PICORE_PACKAGES[@]}"
    do
    	sudo sh -c "echo $i.tcz >> $MNT_DIR/tce/onboot.lst"
    done
    
    sudo sh -c "echo rng-tools-5.tcz >> $MNT_DIR/tce/onboot.lst"
    sudo cat "$MNT_DIR/tce/onboot.lst"
}

function config_wpa_supplicant(){
    sudo sh -c "echo '$WPA_SUPPLICANT_CONF' > '$MNT_DIR/$PICORE_LOCAL_MYDATA/opt/wpa_supplicant.conf'"
	sudo sh -c "echo -e 'opt/wpa_supplicant.conf' >> '$MNT_DIR/$PICORE_LOCAL_MYDATA/opt/.filetool.lst'"
}

function config_bootlocal(){
    sudo sh -c "echo '$BOOTLOCAL_SCRIPT' > '$MNT_DIR/$PICORE_LOCAL_MYDATA/opt/bootlocal.sh'"
}

function make_mydata(){
    echo "*** Adjust mydata.tgz ***"
    [ -d "$MNT_DIR/$PICORE_LOCAL_MYDATA" ] || sudo mkdir "$MNT_DIR/$PICORE_LOCAL_MYDATA"
    sudo tar xfz "$MNT_DIR/$PICORE_LOCAL_MYDATA.tgz" -C "$MNT_DIR/$PICORE_LOCAL_MYDATA"
    
    echo " * WPA Supplicant"
    config_wpa_supplicant
    
    echo " * bootlocal.sh"
    config_bootlocal
    
    echo " * finalizing"
    cd "$MNT_DIR/$PICORE_LOCAL_MYDATA"
    sudo tar -zcf ../mydata.tgz .
    cd -
}

check_dependencies
prepare_dirs
get_release
make_image
test_package_urls
get_packages
make_onboot_list
make_mydata
cleanup
