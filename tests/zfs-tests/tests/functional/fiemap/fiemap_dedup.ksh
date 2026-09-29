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
#	On a dedup dataset a block is SHARED only while the DDT holds
#	more than one reference to it.
#
# STRATEGY:
#	FIEMAP reads reference counts from the DDT ZAP, so the DDT log
#	is flushed every TXG.
#	1. Write a 512k file.  Its four blocks are unique in the DDT
#	   and not SHARED.
#	2. Copy it with dd.  Both files reference the same blocks,
#	   which are duplicates in the DDT, SHARED, at the same
#	   offsets.
#	3. Remove the copy.  The blocks are unique again and the
#	   original is not SHARED.
#

verify_runnable "global"

claim="FIEMAP flags dedup blocks SHARED only with two references."
log_assert $claim

log_must save_tunable DEDUP_LOG_TXG_MAX
log_must set_tunable32 DEDUP_LOG_TXG_MAX 1

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
	log_must restore_tunable DEDUP_LOG_TXG_MAX
}
log_onexit cleanup

log_must zpool create -f -O dedup=on -O compression=off \
    -O recordsize=128k -O xattr=sa $TESTPOOL $DISKS

typeset a=/$TESTPOOL/a
typeset b=/$TESTPOOL/b

log_must dd if=/dev/urandom of=$a bs=128k count=4
log_must sync_pool $TESTPOOL
log_must eval "zdb -D $TESTPOOL | \
    grep -q 'DDT-sha256-zap-unique:.*entries=4'"
log_mustnot fiemap_has_flag shared $a

log_must dd if=$a of=$b bs=128k
log_must sync_pool $TESTPOOL
log_must eval "zdb -D $TESTPOOL | \
    grep -q 'DDT-sha256-zap-duplicate:.*entries=4'"
log_must fiemap_all_flag shared $a
log_must fiemap_all_flag shared $b
log_must test "$(fiemap_physical $a)" = "$(fiemap_physical $b)"

log_must rm $b
log_must sync_pool $TESTPOOL
log_must sync_pool $TESTPOOL
log_must eval "zdb -D $TESTPOOL | \
    grep -q 'DDT-sha256-zap-unique:.*entries=4'"
log_mustnot fiemap_has_flag shared $a

log_pass $claim
