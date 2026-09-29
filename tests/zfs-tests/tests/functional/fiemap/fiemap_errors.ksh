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
#	FIEMAP fails cleanly on a directory or a FIFO, with
#	EOPNOTSUPP, and on a request flag it does not know, with
#	EBADR.
#
# STRATEGY:
#	1. A directory and a FIFO return EOPNOTSUPP.
#	2. 0x02000000, not a FIEMAP flag, returns EBADR on a regular
#	   file.
#	3. The pool is healthy afterwards.
#

verify_runnable "global"

claim="FIEMAP rejects non-regular files and unknown flags."
log_assert $claim

typeset -r EBADR=53
typeset -r EOPNOTSUPP=95

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=128k $TESTPOOL $DISKS

log_must mkdir /$TESTPOOL/dir
log_must test "$(fiemap_errno /$TESTPOOL/dir)" -eq $EOPNOTSUPP

log_must mkfifo /$TESTPOOL/fifo
log_must test "$(fiemap_errno /$TESTPOOL/fifo)" -eq $EOPNOTSUPP

log_must dd if=/dev/urandom of=/$TESTPOOL/f bs=128k count=1
log_must test "$(fiemap_errno -f 0x02000000 /$TESTPOOL/f)" -eq $EBADR

log_must zpool status -x $TESTPOOL

log_pass $claim
