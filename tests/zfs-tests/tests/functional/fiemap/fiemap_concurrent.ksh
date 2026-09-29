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
#	Mapping a file, whole or in part, while the same file is being
#	written succeeds and leaves the pool healthy.
#
# STRATEGY:
#	Writes dirty the dnode again and spa_sync() rewrites its block
#	pointers, including indirect blocks shared with a range being
#	mapped.  A debug build asserts on overlapping extents, so this
#	also reaches those checks.
#
#	1. Rewrite random records of a 64 MiB file in the background,
#	   syncing every 32 writes.
#	2. Meanwhile map the whole file and random 1 MiB ranges of it
#	   150 times each.  Every call succeeds.
#	3. The pool reports no errors.
#

verify_runnable "global"

claim="FIEMAP is safe while the same file is being written."
log_assert $claim

function cleanup
{
	[[ -n $wpid ]] && kill $wpid 2>/dev/null
	wait 2>/dev/null
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -O recordsize=128k -O compression=off \
    $TESTPOOL $DISKS

typeset f=/$TESTPOOL/racer
log_must dd if=/dev/urandom of=$f bs=1M count=64
log_must sync_pool $TESTPOOL

( typeset -i i=0
  while (( i < 400 )); do
	dd if=/dev/urandom of=$f bs=128k count=1 \
	    seek=$((RANDOM % 512)) conv=notrunc status=none \
	    2>/dev/null
	(( i += 1 ))
	if (( i % 32 == 0 )); then
		sync_pool $TESTPOOL >/dev/null 2>&1
	fi
  done ) &
typeset wpid=$!

typeset -i i=0 off
while (( i < 150 )); do
	log_must test -z "$(fiemap_errno $f)"
	log_must test "$(fiemap_mapped $f)" -ge 1
	(( off = (RANDOM % 64) * 1048576 ))
	log_must test -z "$(fiemap_errno -s $off -l 1048576 $f)"
	(( i += 1 ))
done

wait $wpid
wpid=""

log_must sync_pool $TESTPOOL
log_must test -z "$(fiemap_errno $f)"
log_must zpool status -x $TESTPOOL
log_pass $claim
