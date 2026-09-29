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
#	By default FIEMAP reports the first DVA of each block.  With
#	FIEMAP_FLAG_COPIES it reports every DVA, each at its own
#	physical offset, and no copy's extent spans a hole.
#
# STRATEGY:
#	1. One record on a copies=2 dataset maps one extent by default
#	   and two with -C, at different physical offsets.
#	2. Write every other record of a 4 MiB copies=2 file with no
#	   sync between, so the second copies of neighbouring records
#	   are likely adjacent on disk.  With -C every extent is one
#	   written record, each record appears twice, and a count
#	   request agrees.  An extent spanning a hole would claim the
#	   hole holds data.
#

verify_runnable "global"

claim="FIEMAP_FLAG_COPIES reports every copy of a block."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=128k -O compression=off $TESTPOOL $DISKS
log_must zfs create -o copies=2 $TESTPOOL/c2

typeset f=/$TESTPOOL/c2/f
log_must dd if=/dev/urandom of=$f bs=128k count=1
log_must sync_pool $TESTPOOL

log_must test "$(fiemap_nr_extents $f)" -eq 1
log_must test "$(fiemap_nr_extents -C $f)" -eq 2
typeset phys=$(fiemap_physical -C $f)
log_mustnot test "${phys% *}" = "${phys#* }"

typeset g=/$TESTPOOL/c2/gaps
typeset -i i=0
while (( i < 32 )); do
	log_must dd if=/dev/urandom of=$g bs=128k count=1 seek=$i \
	    conv=notrunc
	(( i += 2 ))
done
log_must sync_pool $TESTPOOL

log_must test "$(fiemap_nr_extents -C $g)" -eq 32
log_must eval "fiemap -C $g | awk '
    \$1 == \"ext\" && (\$2 % 262144 != 0 || \$4 != 131072) { bad = 1 }
    END { exit bad }'"
log_must test "$(fiemap_mapped -C -c 0 $g)" -eq 32

log_pass $claim
