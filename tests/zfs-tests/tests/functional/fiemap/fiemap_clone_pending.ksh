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
#	A clone is SHARED as soon as it returns, before its TXG syncs,
#	on the source as well as the destination.
#
# STRATEGY:
#	A clone's references wait in the BRT pending trees until
#	its TXG syncs.  Cloning out of a file does not dirty it, so
#	mapping the source takes no sync and has to find the clone
#	there.  Mapping the destination first would sync the pool
#	and hide this, so the source is mapped first.
#
#	1. Write two records and sync.  Nothing is SHARED.
#	2. Clone the second record, and with no sync map the source:
#	   the first record is not SHARED and the second is.
#	3. The destination is SHARED, and both still are after a sync.
#

verify_runnable "global"

claim="FIEMAP reports a clone as shared before its TXG syncs."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=128k -O compression=off $TESTPOOL $DISKS

typeset src=/$TESTPOOL/src
typeset dst=/$TESTPOOL/dst

log_must dd if=/dev/urandom of=$src bs=128k count=2
log_must sync_pool $TESTPOOL
log_mustnot fiemap_has_flag shared $src

log_must clonefile -r $src $dst 131072 0 131072

log_must eval "fiemap $src | awk '
    \$1 == \"ext\" && \$2 == 0 {
	if (\$0 ~ /shared/) bad = 1; seen0 = 1
    }
    \$1 == \"ext\" && \$2 == 131072 {
	if (\$0 !~ /shared/) bad = 1; seen1 = 1
    }
    END { exit (bad || !seen0 || !seen1) }'"

log_must fiemap_has_flag shared $dst
log_must sync_pool $TESTPOOL
log_must fiemap_has_flag shared $src
log_must fiemap_has_flag shared $dst

log_pass $claim
