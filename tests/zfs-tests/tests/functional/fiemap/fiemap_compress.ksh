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
#	Compressed extents are ENCODED, and incompressible ones on
#	the same dataset are not.  NOT_ALIGNED follows the offsets and
#	lengths FIEMAP reports, not the compressed size.
#
# STRATEGY:
#	1. On an lz4 dataset write 1 MiB of a repeated byte, which
#	   compresses without becoming holes.  Every extent is
#	   ENCODED, NOT_ALIGNED is set exactly where fiemap-tester
#	   expects it, and the extents still cover the whole file.
#	2. Random data on the same dataset is not ENCODED.
#

verify_runnable "global"

claim="FIEMAP flags compressed extents ENCODED."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=128k $TESTPOOL $DISKS
log_must zfs create -o compression=lz4 $TESTPOOL/comp

typeset z=/$TESTPOOL/comp/z
log_must file_write -o create -f $z -b 131072 -c 8 -d 1
log_must sync_pool $TESTPOOL
log_must fiemap_all_flag encoded $z
log_must fiemap_check_aligned 131072 $z
log_must test "$(fiemap_logical_sum $z)" -eq "$(stat -c %s $z)"

log_must dd if=/dev/urandom of=/$TESTPOOL/comp/r bs=128k count=8
log_must sync_pool $TESTPOOL
log_mustnot fiemap_has_flag encoded /$TESTPOOL/comp/r

log_pass $claim
