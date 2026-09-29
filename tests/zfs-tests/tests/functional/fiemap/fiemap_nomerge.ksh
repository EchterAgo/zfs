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
#	FIEMAP_FLAG_NOMERGE reports one extent per block, where the
#	default merges contiguous blocks.
#
# STRATEGY:
#	1. Write 16 blocks of 4k.
#	2. With -N the file maps 16 extents, as a count request says.
#	3. The default maps no more extents than that.
#

verify_runnable "global"

claim="FIEMAP_FLAG_NOMERGE reports one extent per block."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=4k $TESTPOOL $DISKS

log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=4k count=16
log_must sync_pool $TESTPOOL

typeset merged=$(fiemap_nr_extents /$TESTPOOL/f)
typeset unmerged=$(fiemap_nr_extents -N /$TESTPOOL/f)
log_note "merged=$merged nomerge=$unmerged"

log_must test "$unmerged" -eq 16
log_must test "$(fiemap_mapped -N -c 0 /$TESTPOOL/f)" -eq 16
log_must test "$merged" -le "$unmerged"

log_pass $claim
