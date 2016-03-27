#!/bin/bash

# create a 1 GB random drive as seed
dd if=/dev/urandom of=/tmp/random_1Gb.bin bs=1M count=1024

# pool with a single drive
zpool create -o ashift=12 -o autoexpand=on tank sda
zpool export tank
zpool import -d /dev/disk/by-path/ tank

zfs set compression=lz4 tank

mkdir /tank/test
chmod 777 /tank/test

time bonnie++ -d /tank/test -u genomics | tee bonnie_single_drive_empty.csv

zpool destroy tank

# pool with a single drive
zpool create -o ashift=12 -o autoexpand=on tank mirror sda sdg
zpool export tank
zpool import -d /dev/disk/by-path/ tank

zfs set compression=lz4 tank

mkdir /tank/test
chmod 777 /tank/test

time bonnie++ -d /tank/test -u genomics | tee bonnie_mirrored_drive_empty.csv

zpool destroy tank

# pool with a single drive
zpool create -o ashift=12 -o autoexpand=on tank raidz2 sda sdb sdc sdd sde sdf
zpool export tank
zpool import -d /dev/disk/by-path/ tank

zfs set compression=lz4 tank

mkdir /tank/test
chmod 777 /tank/test

time bonnie++ -d /tank/test -u genomics | tee bonnie_raidz2_drive_empty.csv

zpool destroy tank

# pool with a single drive
zpool create -o ashift=12 -o autoexpand=on tank raidz2 sda sdb sdc sdd sde sdf raidz2 sdg sdh sdi sdj sdk sdl
zpool export tank
zpool import -d /dev/disk/by-path/ tank

zfs set compression=lz4 tank

mkdir /tank/test
chmod 777 /tank/test

time bonnie++ -d /tank/test -u genomics | tee bonnie_double_raidz2_drive_empty.csv

zpool destroy tank






