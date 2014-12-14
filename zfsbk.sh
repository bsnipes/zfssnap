#! /bin/sh

# change this to the name of your ZFS pool. Or set ZPOOL envvar at runtime
zpool=${ZPOOL:-"zroot"}

# name of backup to take
bkname=${1:-"default"}
# make a backup collection having 1 full and N-1 incremental backups.
# set to 1 to avoid incrementals and always take full dumps.
max_incremental=${2:-"4"}

usage () {
    echo "Usage:"
    echo "zfsbk.sh <bkname> [numincr]"
    echo "Takes & sends backup with given name. If snapshots with"
    echo "this name exist, backup incrementally. Limit incremental"
    echo "backup sequences to 'numincr' steps (default 1 = alw. full)."
    echo
    echo "Optional envvars:"
    echo "UPLOAD_PATH   upload generated backup to this path. scp:// or rsync://"
    echo "CLEAR_BKFILE  remove local backup file at the end of the process."
}

failmsg () {
    echo $*
    echo
    usage
    exit 1
}

verify_zpool () {
    zpool status $zpool >/dev/null 2>&1 || failmsg "ZFS pool '$zpool' not found. Fix your \$ZPOOL envvar."
}

verify_zpool

echo $bkname | grep -qiE '^[a-z0-9]+$' || failmsg "Given bkname is invalid. Want alphanumeric."
echo "$max_incremental" | grep -qE '^[1-9][0-9]*$' || failmsg "Invalid number of backups sequence steps, want positive integer."

export PATH=$PATH:/usr/local/bin

# list snapshots by decreasing time. Arguments: [name] restrict listing to this tag
list_named_snaps () {
    local bkname=$1
    snapdir="/.zfs/snapshot"
    for i in $snapdir/zbk-$bkname-*
    do
        test -e "$i" && (echo $i |sed "s@^$snapdir/@@")
    done | sort -r
}

# remove all datasets for a given tag. Arguments: $1 -> bkname
reset_sequence () {
    local bkname=$1
    list_named_snaps $bkname | while read snapname
    do
        zfs destroy -r $zpool@$snapname
    done
}

# take snapshot
#echo ./zfssnap.sh $bkname $max_incremental
if ! ./zfssnap.sh $bkname $max_incremental
then
    echo "Error creating snapshot! Code $?"
    exit 1
fi

# get label
num_snaps=`list_named_snaps $bkname | awk 'END {print NR}'`
label_latest=`list_named_snaps $bkname | awk NR==1`

# decide what to do based on how many snapshots were found
if [ $num_snaps -eq 0 ]
then
    # no snapshots. Something's wrong
    echo "Error, no snapshots found for $bkname!"
    list_named_snaps $bkname
    exit 1
elif [ $num_snaps -eq 1 ]
then
    # first snapshot. Send full
    bkfile="/backups/${label_latest}.dump"
    #echo zfs send -R $zpool@$label_latest
    zfs send -R $zpool@$label_latest 2>/dev/null > $bkfile
else
    # n-th snapshot. Send incrementally
    label_2ndlatest=`list_named_snaps $bkname | awk NR==2`
    bkfile="/backups/${label_latest}--${label_2ndlatest}.dump"
    #echo zfs send -i $label_2ndlatest -R $zpool@$label_latest
    zfs send -i $label_2ndlatest -R $zpool@$label_latest 2>/dev/null > $bkfile
fi

if [ $num_snaps -eq $max_incremental ]
then
    # finished the incremental sequence. Take full backup next time
    echo "Sequence of $max_incremental increm steps complete. Resetting."
    reset_sequence $bkname
fi


# upload backup to remote location
if [ "x$UPLOAD_PATH" != x ]
then
    upload_excode=1 # assume failure, override with actual outcome
    #echo "Archiving $bkfile remotely..."
    if echo "$UPLOAD_PATH" | grep -qE '^rsync://'
    then
        rsync -qz $bkfile ${UPLOAD_PATH#rsync://}
        upload_excode=$?
    elif echo "$UPLOAD_PATH" | grep -qE '^scp://'
    then
        SCP_PATH=${UPLOAD_PATH#scp://}
        if [ "$num_snaps" -eq 1 -a "x$DELETE_OUTDATED" != x ]
        then
            echo "Clearing old zbk-${bkname}* sequence remotely..."
            echo "rm zbk-${bkname}*" | sftp -q -b- $SCP_PATH
        fi
        scp -BCq $bkfile "$SCP_PATH"
        upload_excode=$?
    else
        echo "UPLOAD_PATH not understood! '$UPLOAD_PATH'"
        echo "Expecting rsync://.. or scp://.."
        exit 1
    fi
    # remove local backup if requested & upload was successful
    if [ $upload_excode -eq 0 -a "x$CLEAR_BKFILE" != x ]
    then
        # remove backup file if requested
        rm -f $bkfile
    fi
fi

