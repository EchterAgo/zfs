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
#	An array sized to the count from a count request returns the
#	whole map.  That is the count-then-fill sequence the FIEMAP
#	documentation describes.
#
# STRATEGY:
#	1. On one disk, write every other 128k record of 60, then
#	   1 MiB of contiguous records at the end.  Each lone record
#	   is its own extent, and the tail's eight records merge into
#	   one.  A walk that stopped at the first tail record would
#	   report the tail short and never reach EOF.  A stripe would
#	   spread the tail across vdevs and hide that.
#	2. Count the extents, then ask for exactly that many and for
#	   one more.  Both return the same extents, the last flagged
#	   LAST.
#

verify_runnable "global"

claim="An array sized to the counted extents returns the whole map."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

typeset disk=$(echo $DISKS | awk '{print $1}')
log_must zpool create -O recordsize=128k -O compression=off \
    $TESTPOOL $disk

typeset file=/$TESTPOOL/f
typeset -i i=0
while (( i < 60 )); do
	log_must dd if=/dev/urandom of=$file bs=128k count=1 seek=$i \
	    conv=notrunc
	(( i += 2 ))
done
log_must dd if=/dev/urandom of=$file bs=128k count=8 seek=60 \
    conv=notrunc
log_must sync_pool $TESTPOOL

typeset -i cnt=$(fiemap_mapped -c 0 $file)
log_note "count request reports $cnt extents"
log_must test $cnt -ge 2

typeset -i exact=$(fiemap_nr_extents -c $cnt $file)
typeset -i more=$(fiemap_nr_extents -c $((cnt + 1)) $file)
log_note "asked $cnt got $exact, asked $((cnt + 1)) got $more"
log_must test $exact -eq $more
typeset -i datasz
(( datasz = 38 * 131072 ))
log_must test "$(fiemap_logical_sum -c $cnt $file)" -eq $datasz
log_must fiemap_ends_last -c $cnt $file
log_must fiemap_ends_last -c $((cnt + 1)) $file

log_pass $claim
