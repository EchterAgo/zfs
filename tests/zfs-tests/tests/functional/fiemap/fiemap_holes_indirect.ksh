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

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/fiemap/fiemap.kshlib

#
# DESCRIPTION:
#	Data on both sides of a hole covering a whole indirect block
#	maps at the right offsets.
#
# STRATEGY:
#	With 128k records an indirect block spans 128 MiB.  Write one
#	record at 0 and one at 256 MiB, which leaves the block pointer
#	for 128 MiB to 256 MiB a hole at level 1.  The file maps two
#	extents, at 0 and 256 MiB, and the second carries LAST.
#

verify_runnable "global"

claim="FIEMAP maps data around a hole spanning an indirect block."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -O recordsize=128k -O compression=off \
    $TESTPOOL $DISKS

typeset f=/$TESTPOOL/bighole
log_must dd if=/dev/urandom of=$f bs=128k count=1
log_must dd if=/dev/urandom of=$f bs=128k count=1 seek=2048 \
    conv=notrunc
log_must sync_pool $TESTPOOL

log_must test "$(fiemap_logical $f)" = "0 268435456"
log_must test "$(fiemap_logical_sum $f)" -eq 262144
log_must fiemap_ends_last $f

log_pass $claim
