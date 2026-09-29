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
#	A ranged request maps the extents overlapping the range, even
#	with many extents before it under the same indirect block, and
#	flags LAST only when the range reaches the end of the data.
#
# STRATEGY:
#	1. On a 1 MiB file, a 256k window maps at least one extent and
#	   no more than the whole file, and a start past EOF maps
#	   nothing, without error.
#	2. Write every other 4k record of a 2 MiB file, so each record
#	   is its own extent and one indirect block holds them all.
#	   An array of one from 1 MiB returns the record at 1 MiB, not
#	   flagged LAST.
#	3. A range ending at 1 MiB does not flag LAST, and one
#	   reaching EOF does.
#

verify_runnable "global"

claim="FIEMAP restricts its output to the requested range."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=128k $TESTPOOL $DISKS

typeset f=/$TESTPOOL/f
log_must dd if=/dev/urandom of=$f bs=128k count=8
log_must sync_pool $TESTPOOL

typeset whole=$(fiemap_nr_extents $f)
typeset windowed=$(fiemap_nr_extents -s 262144 -l 262144 $f)
log_must test "$windowed" -ge 1
log_must test "$windowed" -le "$whole"
log_must test "$(fiemap_mapped -s 2097152 $f)" -eq 0
log_must test -z "$(fiemap_errno -s 2097152 $f)"

log_must zfs create -o recordsize=4k -o compression=off \
    $TESTPOOL/small
typeset g=/$TESTPOOL/small/gaps
typeset -i i=0
while (( i < 512 )); do
	dd if=/dev/urandom of=$g bs=4k count=1 seek=$i conv=notrunc \
	    status=none || log_fail "write of record $i failed"
	(( i += 2 ))
done
log_must sync_pool $TESTPOOL

log_must test "$(fiemap_mapped -c 0 $g)" -eq 256
log_must test "$(fiemap_logical -s 1048576 -c 1 $g)" = "1048576"
log_mustnot fiemap_has_flag last -s 1048576 -c 1 $g

log_mustnot fiemap_ends_last -s 0 -l 1048576 $g
log_must fiemap_ends_last -s 1048576 $g

log_pass $claim
