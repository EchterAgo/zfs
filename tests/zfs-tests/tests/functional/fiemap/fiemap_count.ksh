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
#	FIEMAP honours fm_extent_count.  Zero counts the extents
#	without returning any, and an array smaller than the map is
#	filled without flagging its last extent LAST.
#
# STRATEGY:
#	1. Write two 64k regions with a hole between.  The hole makes
#	   at least two extents however the blocks are allocated.
#	2. A count request reports as many extents as a full map.
#	3. An array of one returns one extent, not flagged LAST.
#

verify_runnable "global"

claim="FIEMAP honours fm_extent_count."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=4k $TESTPOOL $DISKS
log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=4k count=16
log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=4k count=16 seek=48
log_must sync_pool $TESTPOOL

typeset full=$(fiemap_mapped /$TESTPOOL/f)
log_must test "$full" -ge 2

log_must test "$(fiemap_mapped -c 0 /$TESTPOOL/f)" -eq "$full"
log_must test "$(fiemap_nr_extents -c 0 /$TESTPOOL/f)" -eq 0

log_must test "$(fiemap_nr_extents -c 1 /$TESTPOOL/f)" -eq 1
log_mustnot fiemap_has_flag last -c 1 /$TESTPOOL/f

log_pass $claim
