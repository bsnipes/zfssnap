# If you like this tool

If you like this tool, [Watch It](https://bitbucket.org/mmichele/zfssnap/follow)
on Bitbucket. If you love it, make a $10 donation to the [FreeBSD foundation](https://www.freebsdfoundation.org/donate).
If you don't like it, [open a ticket](https://bitbucket.org/mmichele/zfssnap/issues)
and explain what can be improved.

# zfsbk Overview

This is a minimalistic utility to fully automate backups for systems using the
outstanding [ZFS](http://en.wikipedia.org/wiki/ZFS) filesystem.

It relies on Snapshots to provide:

* local backups – they help you recover files from earlier in time.
* remote backups – they help you recover whole datasets for system failures.

ZFS snapshots are extremely lightweight on the system (actually cheaper to take
snapshot than not!) and cheap on storage (only changed blocks are saved) and
allow you to restore files from past versions.


# The gist

You run these tools from cron to periodically

* take ZFS snapshots (`zfssnap.sh`)
* serialize and export them remotely (`zfsbk.sh`)

The tools take care of limiting the number of snapshots, so you do not
have to periodically prune old snapshots.

Snapshots can be named so you can create groups of them, e.g. "hourly snapshots",
"newdeplo snapshots" and "exported snapshots".

An additional tool takes care of exporting such snapshots, and uploading them
to a remote server.

# Installation

Installation:

1. place all `*.sh` files of the package into directory `/usr/local/sbin/`
1. (if you'll use remote backups) create a dataset to store backups:

    zfs create zroot/backups    # replace 'zroot' with your pool name

Done! Is your ZFS pool name other than _zroot_? Then set the _ZPOOL_ environment
variable to your zpool name when calling these scripts. See below for more.

Need to control multiple ZFS pools? See section "Managing multiple ZFS Pools" below.

# Snapshot management

You run `zfssnap.sh` for taking snapshots, typically from cron:

    vim /etc/crontab ...
    # take hourly snapshot, keep 24 of them
    @hourly     root    /usr/local/sbin/zfssnap.sh hour 24

This will create, every hour, a new ZFS snapshot tagged 'hour':

    # ls /.zfs/snapshot/
    zbk-hour-20140318-140000
    zbk-hour-20140318-150000
    zbk-hour-20140318-160000

Only 24 of these snapshots will be kept (see Rotation below). The name of each
snapshot comes with format `zbk-[tag]-[date]-[time]`. Date is `YYYYMMDD` and
time is `hhmmss`.

## Snapshot groups

Each snapshot is tagged:

    # create a snapshot tagged 'foobar'. Maintain 10 at all times
    zfssnap.sh foobar 10

Snapshots with the same tag make a **snapshot group**. For example, the
`foobar` group will count up to 10 members at all times.

Multiple groups can exist, just take snapshots with different tags:

    # take 2 'hourly' snaps
    zfssnap.sh hourly 10
    zfssnap.sh hourly 10
    # take 3 'daily' snaps
    zfssnap.sh daily 10
    zfssnap.sh daily 10
    zfssnap.sh daily 10
    # ls /.zfs/snapshot
    zfs-hourly-20140318-140001
    zfs-hourly-20140318-140003
    zfs-daily-20140318-140111
    zfs-daily-20140318-140112
    zfs-daily-20140318-140114

Neither `zfssnap.sh` nor ZFS put a limit on the number of snaps you can
maintain. The tool was tested with over 200. Bear in mind that it's shell
scripts, so inherent limitations of arguments length could get in your way.

I recommend staying under 50 snaps per group and 200 snaps total.

## Snapshot rotation

`zfssnap.sh` takes a new snapshot every time it's run. When the number of
existing snapshots exceeds the given limit, the oldest snapshot of that group
(tag) is removed, so only so many are kept:

    # take snap xyz, then keep only last 2 from xyz group
    zfssnap.sh xyz 2

This bounds the number of snapshots for each group to 2. To remove all snaps in a group, simply pass ''i'' as limit:

    # remove all snaps of group xyz
    zfssnap.sh xyz 0

## Excluding dataset from backup

`zfssnap.sh` takes a recursive backup of the `zroot` pool. If you do not intend
to maintain backups for certain datasets, you can exclude them with the
`EXCLUDES` and `EXTRA_EXCLUDES` **environment variables**:

    # exclude only these datasets
    EXCLUDES=“/mydataset/foobar"
    # exclude these datasets in addition to default exclusions
    EXTRA_EXCLUDES=“/mydataset/foobar"

Notice that these are **dataset names**, not mountpoints! If dataset
`zroot/foo` is at mountpoint `/bar`, specify `/foo` here.

The following datasets, common for FreeBSD users, are excluded by default:

* `/usr/ports`
* `/usr/src`

If you do not want these excluded, pass an empty `EXCLUDES` envvar.

# Recovering files (local backup)

Lost a file? Find it under:

    # list content of michele's home at 2pm (1400)
    ls /.zfs/snapshot/zbk-hour-140000/home/michele

Notice that you must look for the `/.zfs` directory at the root of the dataset actually holding it:

    # list content of michele's home, if /home is on zroot/home
    ls /home/.zfs/snapshot/zbk-hour-140000/michele

# Full snapshot management cron example

    # take 15' backups for the last hour
    */15 * * * * root /usr/local/sbin/zfssnap.sh qrt 4
    # take hourly backups for the 6 hours
    1 * * * * root /usr/local/sbin/zfssnap.sh hourly 6
    # take 6-hours backups for the last day
    1 */6 * * * root /usr/local/sbin/zfssnap.sh 6hr 4
    # take daily backups for the last week
    1 1 * * * root /usr/local/sbin/zfssnap.sh day 7
    # take weekly backups for the last 2 months
    1 1 * * 1 root /usr/local/sbin/zfssnap.sh week 8

# Generating remote backups

The `zfsbk.sh` lets you generate backups and upload them to a remote location.

This takes a snapshot with tag `mybk` and serializes it in file `/backups/zbk-mybk-140000.dump`:

    # generate ZFS streaming package, save to /backups folder
    /usr/local/sbin/zfsbk.sh mybk
    ls /backups
    zfs-mybk-20140318-061900.dump

# Incremental backups

Pass a number to `zfsbk.sh` and it will create incremental snapshots:

    # 1. make full replication if this is the first snap in group
    # 2. else make incremental replication wrt latest snap in group
    # 3. reset the snap group after 1+9 steps have been made
    /usr/local/sbin/zfsbk.sh mybk 10

Incremental packages are named after their snapshot endpoints:

    ls /backups
    zbk-mybk-20140318-140000--zbk-mybk-20140318-150000.dump
    
If the given integer is 1, `zfsbk.sh` sends full replication packages for every
run.

# Uploading backups remotely

`zfsbk.sh` can upload each replication package after generating it, at the end of the run.

Pass the destination coordinates with the `UPLOAD_PATH` environment variable.
Currently, rsync:// and scp:// are supported:

    # take snap, generate backup, upload it to remote server
    UPLOAD_PATH="rsync://user@backup.server.com::server12/" /usr/local/sbin/zfsbk.sh mybk 10

`zfsbk.sh` relies on `zfssnap.sh` to take the snapshot to backup. Therefore, you can exclude
different datasets from its backup by passing the respective `EXCLUDES` or `EXTRA_EXCLUDES`
variables:

    # take selective backup
    EXTRA_EXCLUDES="/jails/test.dom.com" /usr/local/sbin/zfsbk.sh mybk 1

`zfsbk.sh` maintains serialized backups in directory `/backups` after having uploaded them.
If you want to cleanup the backup file locally after uploading it upstream, set the
`CLEAR_BKFILE` environment variable to a non-empty value. `zfsbk.sh` will maintain the local
backup regardless of this variable if the upload failed.

    # delete generated bkfile locally after successful upload
    UPLOAD_PATH="..." CLEAR_BKFILE=yep /usr/local/sbin/zfsbk.sh mybk 7

Ask `zfsbk` to remove an old sequence remotely before uploading a new one:

    # remove all bkfiles of old sequence *remotely* before uploading new one
    UPLOAD_PATH="..." DELETE_OUTDATED="yep" /usr/local/sbin/zfsbk.sh mybk 7

This allows you to cap the size taken by backups at the remote.

# Managing multiple ZFS Pools

Simply run these scripts once for each pool, setting the _ZPOOL_ environment variable
accordingly.

# Summary of control variables

Here's all environment variables controlling the behavior or `zfssnap` and `zfsbk`:

## zfssnap

* `ZPOOL` [str] name of the ZFS pool to operate on.
* `EXCLUDES` [str] space-separated list of dataset names to exclude from snapshots. Overrides defaults.
* `EXTRA_EXCLUDES` [str] space-separated list of dataset names to exclude from snapshots in addition to defaults.

## zfsbk

* `UPLOAD_PATH` [str] Upload generated bkfile to this remote location; 'scp://' or 'rsync://'
* `CLEAR_BKFILE` [any] If non-empty, remove copy of generated bkfile after successful remote upload.
* `DELETE_OUTDATED` [any] If non-empty, remove old backup sequence remotely before uploading first bkfile of a new sequence.


# Ancillaries

## Warranty

By using this software you release the author(s) from any claim.

You are aware that working with filesystems is dangerous and exposes to
complete data loss. This script has been written with care for reliability,
tested for a number of scenarios, and used in a number of servers.

Because of the inherently partial nature of testing, you are aware that this
brings no guarantees that it'll work for your scenario.

**Careful yourself** when working with ZFS snapshots! Check this out:

    # CAREFUL ! These commands destroy your FS !
    
    zfs destroy -r zroot@mysnap     # destroy snapshot 'mysnap' from pool 'zroot'
    zfs destroy -r zroot#mysnap     # destroy all system data, and comment it's 'mysnap'
    # notice that # and @ are next to each other on most keyboards.
    # Sun made a poor choice, or they are adrenaline junkies.

## License

Copyright (c) 2014-present, Michele Mazzucchi
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

