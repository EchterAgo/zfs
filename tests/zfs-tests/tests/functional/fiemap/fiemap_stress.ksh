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
#	FIEMAP holds up under repeated and concurrent use.
#
# STRATEGY:
#	1. Map 200 small files back to back.
#	2. Map a 256 MiB file twice and get the same count.
#	3. Map it 300 more times without error.
#	4. Map it 100 times while another file is appended to.
#

verify_runnable "global"

claim="FIEMAP is stable under repeated, large and concurrent use."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=128k $TESTPOOL $DISKS

log_must mkdir /$TESTPOOL/many
for i in $(seq 1 200); do
	dd if=/dev/urandom of=/$TESTPOOL/many/f$i bs=8k count=1 \
	    status=none
done
log_must sync_pool $TESTPOOL
for i in $(seq 1 200); do
	log_must test "$(fiemap_mapped /$TESTPOOL/many/f$i)" -ge 1
done

log_must dd if=/dev/urandom of=/$TESTPOOL/big bs=1M count=256
log_must sync_pool $TESTPOOL
typeset c1=$(fiemap_mapped /$TESTPOOL/big)
typeset c2=$(fiemap_mapped /$TESTPOOL/big)
log_must test "$c1" -ge 1
log_must test "$c1" -eq "$c2"

for i in $(seq 1 300); do
	log_must test -z "$(fiemap_errno /$TESTPOOL/big)"
done

( for i in $(seq 1 400); do
	dd if=/dev/urandom of=/$TESTPOOL/writer bs=128k count=1 \
	    seek=$i conv=notrunc status=none
  done ) &
typeset wpid=$!
for i in $(seq 1 100); do
	log_must test -z "$(fiemap_errno /$TESTPOOL/big)"
done
wait $wpid

log_must zpool status -x $TESTPOOL

log_pass $claim
