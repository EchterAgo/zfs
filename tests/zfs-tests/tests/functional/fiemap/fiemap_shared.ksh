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
#	A block clone and its source map the same physical offsets and
#	both carry SHARED.  An independent copy of the same data maps
#	elsewhere and is not SHARED.
#
# STRATEGY:
#	1. Write a 512k file and clone it.
#	2. Both files are SHARED, at identical physical offsets.
#	3. Copy the source with dd.  The copy maps other offsets and
#	   is not SHARED, although its blocks are allocated near
#	   cloned ones and pass the BRT's coarse range filter.
#

verify_runnable "global"

claim="FIEMAP flags cloned extents SHARED at the source's offsets."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=128k $TESTPOOL $DISKS

log_must dd if=/dev/urandom of=/$TESTPOOL/src bs=128k count=4
log_must sync_pool $TESTPOOL

log_must clonefile -f /$TESTPOOL/src /$TESTPOOL/clone 0 0 524288
log_must sync_pool $TESTPOOL

log_must fiemap_has_flag shared /$TESTPOOL/src
log_must fiemap_has_flag shared /$TESTPOOL/clone
log_must test "$(fiemap_physical /$TESTPOOL/src)" = \
    "$(fiemap_physical /$TESTPOOL/clone)"

log_must dd if=/$TESTPOOL/src of=/$TESTPOOL/indep bs=128k
log_must sync_pool $TESTPOOL

log_mustnot test "$(fiemap_physical /$TESTPOOL/src)" = \
    "$(fiemap_physical /$TESTPOOL/indep)"
log_mustnot fiemap_has_flag shared /$TESTPOOL/indep

log_pass $claim
