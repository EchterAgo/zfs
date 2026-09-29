#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

#
# Copyright (c) 2026 by the OpenZFS project.  All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/fiemap/fiemap.kshlib

#
# DESCRIPTION:
#	Blocks that sit next to each other on a vdev merge into one
#	extent, including on raidz and when compressed, where a block
#	allocates more than its physical size.
#
# STRATEGY:
#	1. On a raidz1 pool write 1 MiB of random 128k records, and
#	   1 MiB of compressible ones to an lz4 dataset.
#	2. From zdb's DVAs, count the runs of blocks where each block
#	   starts on the same vdev where the one before it ends.
#	3. FIEMAP maps exactly that many extents, and sets
#	   NOT_ALIGNED from the offsets and lengths it reports, not
#	   the allocated size.  If no two blocks landed next to each
#	   other, nothing was tested.
#

verify_runnable "global"

claim="FIEMAP merges blocks that are adjacent by allocated size."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

# Print "<runs> <blocks>" for a file, from its level 0 DVAs.
function zdb_runs
{
	typeset ds=$1 file=$2
	typeset obj=$(get_objnum $file)
	typeset -i n=0 blocks=0 pend=-1 off asz
	typeset pv="" v o a

	zdb -ddddd $ds $obj |
	    awk '$2 == "L0" && $3 ~ /:/ {print $3}' |
	    while IFS=: read v o a; do
		off=16#$o
		asz=16#$a
		if [[ $v != "$pv" ]] || (( off != pend )); then
			(( n += 1 ))
		fi
		pv=$v
		(( pend = off + asz ))
		(( blocks += 1 ))
	done
	echo $n $blocks
}

set -A d $DISKS
if (( ${#d[@]} < 3 )); then
	log_unsupported "Needs three disks for raidz1"
fi

log_must zpool create -O recordsize=128k -O compression=off \
    $TESTPOOL raidz1 ${d[0]} ${d[1]} ${d[2]}
# zdb reads a name without a slash as the pool, not its root dataset.
log_must zfs create $TESTPOOL/raw
log_must zfs create -o compression=lz4 $TESTPOOL/comp

typeset raw=/$TESTPOOL/raw/r
typeset comp=/$TESTPOOL/comp/c
log_must dd if=/dev/urandom of=$raw bs=128k count=8
log_must file_write -o create -f $comp -b 131072 -c 8 -d 1
log_must sync_pool $TESTPOOL

typeset -i merged=0
for pair in "$TESTPOOL/raw $raw" "$TESTPOOL/comp $comp"; do
	set -- $pair
	typeset runs=$(zdb_runs $1 $2)
	typeset -i want=${runs% *} blocks=${runs#* }
	typeset -i got=$(fiemap_nr_extents $2)

	log_note "$2: $blocks blocks in $want runs, FIEMAP maps $got"
	log_must test $blocks -eq 8
	log_must test $got -eq $want
	log_must fiemap_check_aligned 131072 $2
	(( want < blocks )) && (( merged += 1 ))
done

if (( merged == 0 )); then
	log_unsupported "No adjacent blocks, nothing to merge"
fi

log_pass $claim
