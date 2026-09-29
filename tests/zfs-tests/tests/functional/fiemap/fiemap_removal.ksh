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
#	After a device removal FIEMAP does not report an offset on the
#	indirect vdev as a physical address.
#
# STRATEGY:
#	Removing a device leaves an indirect vdev, and block pointers
#	naming it are remapped when read.  A split block cannot be
#	remapped to one place, so its DVA keeps naming the indirect
#	vdev, whose offsets address no device.  Such an extent must be
#	flagged UNKNOWN, like a gang block, with no address.
#
#	1. Write 64 MiB across two disks and remove one.
#	2. Every extent flagged UNKNOWN has a zero physical offset.
#

verify_runnable "global"

claim="FIEMAP does not report indirect vdev offsets as physical."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

set -A d $DISKS
if (( ${#d[@]} < 2 )); then
	log_unsupported "Needs at least two disks"
fi

log_must zpool create -O recordsize=128k -O compression=off \
    $TESTPOOL ${d[0]} ${d[1]}

log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=1M count=64
log_must sync_pool $TESTPOOL

if ! zpool remove $TESTPOOL ${d[1]} 2>/dev/null; then
	log_unsupported "Pool layout does not support device removal"
fi
log_must zpool wait -t remove $TESTPOOL
log_must sync_pool $TESTPOOL

log_must test "$(fiemap_mapped /$TESTPOOL/f)" -ge 1
log_must eval "fiemap /$TESTPOOL/f | awk '
    \$1 == \"ext\" && \$0 ~ /unknown/ && \$3 != 0 { bad = 1 }
    END { exit bad }'"

log_must zpool status -x $TESTPOOL
log_pass $claim
