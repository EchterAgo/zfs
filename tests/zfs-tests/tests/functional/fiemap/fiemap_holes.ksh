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
#	Holes are not reported.  They are the gaps between extents,
#	and a file ending in a hole still flags its last extent LAST.
#
# STRATEGY:
#	1. Write records 0 and 9 with no sync between, so their blocks
#	   are likely adjacent on disk.  The hole between them still
#	   makes two extents.
#	2. A file with no data maps nothing.
#	3. Extend a 256k file to 4 MiB.  The data maps 256k, and its
#	   last extent carries LAST.
#

verify_runnable "global"

claim="FIEMAP reports holes as gaps and flags LAST before a hole."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -O recordsize=128k -O compression=off \
    $TESTPOOL $DISKS

typeset f=/$TESTPOOL/sparse
log_must dd if=/dev/urandom of=$f bs=128k count=1
log_must dd if=/dev/urandom of=$f bs=128k count=1 seek=9 conv=notrunc
log_must sync_pool $TESTPOOL
log_must test "$(fiemap_logical $f)" = "0 1179648"
log_must test "$(fiemap_logical_sum $f)" -eq 262144
log_mustnot fiemap_has_flag unwritten $f
log_must fiemap_ends_last $f

log_must truncate -s 1M /$TESTPOOL/allhole
log_must sync_pool $TESTPOOL
log_must test "$(fiemap_mapped /$TESTPOOL/allhole)" -eq 0

typeset t=/$TESTPOOL/tail
log_must dd if=/dev/urandom of=$t bs=128k count=2
log_must truncate -s 4M $t
log_must sync_pool $TESTPOOL
log_must test "$(fiemap_logical_sum $t)" -eq 262144
log_must fiemap_ends_last $t

log_pass $claim
