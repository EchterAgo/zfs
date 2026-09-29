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
#	Extents on an encrypted dataset are DATA_ENCRYPTED, and so, as
#	FIEMAP requires, also ENCODED.
#

verify_runnable "global"

claim="FIEMAP flags encrypted extents ENCRYPTED and ENCODED."
log_assert $claim

function cleanup
{
	datasetexists $TESTPOOL && destroy_pool $TESTPOOL
}
log_onexit cleanup

log_must zpool create -o feature@block_cloning=enabled \
    -O recordsize=128k $TESTPOOL $DISKS

typeset passphrase="fiemap-secret"
log_must eval "echo $passphrase | zfs create" \
    "-o encryption=aes-256-gcm -o keyformat=passphrase" \
    "-o keylocation=prompt $TESTPOOL/enc"

log_must dd if=/dev/urandom of=/$TESTPOOL/enc/e bs=128k count=4
log_must sync_pool $TESTPOOL

log_must fiemap_all_flag encrypted /$TESTPOOL/enc/e
log_must fiemap_all_flag encoded /$TESTPOOL/enc/e

log_pass $claim
