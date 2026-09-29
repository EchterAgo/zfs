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
#	FIEMAP maps a written file, an empty file, and a file held in
#	an embedded block pointer.
#
# STRATEGY:
#	1. A 512k file maps extents covering the whole file, the last
#	   one flagged LAST, with NOT_ALIGNED where fiemap-tester
#	   expects it.
#	2. An empty file maps nothing.
#	3. A 50 byte file maps an INLINE extent flagged LAST.
#

verify_runnable "global"

claim="FIEMAP maps written, empty and embedded files."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=128k $TESTPOOL $DISKS

log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=128k count=4
log_must sync_pool $TESTPOOL
log_must test "$(fiemap_nr_extents /$TESTPOOL/f)" -ge 1
log_must fiemap_ends_last /$TESTPOOL/f
log_must test "$(fiemap_logical_sum /$TESTPOOL/f)" -eq 524288
log_must fiemap_check_aligned 131072 /$TESTPOOL/f

log_must touch /$TESTPOOL/empty
log_must sync_pool $TESTPOOL
log_must test "$(fiemap_mapped /$TESTPOOL/empty)" -eq 0

log_must eval "printf '%50s' x > /$TESTPOOL/tiny"
log_must sync_pool $TESTPOOL
log_must fiemap_has_flag inline /$TESTPOOL/tiny
log_must fiemap_ends_last /$TESTPOOL/tiny

log_pass $claim
