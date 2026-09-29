// SPDX-License-Identifier: CDDL-1.0
/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * https://opensource.org/license/CDDL-1.0.
 */

/*
 * Copyright (c) 2018, Lawrence Livermore National Security, LLC.
 */

#ifndef	_SYS_FIEMAP_H
#define	_SYS_FIEMAP_H

/*
 * ZFS extensions to the FIEMAP request flags.  COPIES reports every
 * DVA of each block: all first copies, then all second copies, and
 * so on.  NOMERGE reports one extent per block.
 */
#define	FIEMAP_FLAG_COPIES	0x08000000
#define	FIEMAP_FLAG_NOMERGE	0x04000000

#ifdef _KERNEL

#define	ZFS_FIEMAP_FLAGS_COMPAT	(FIEMAP_FLAG_SYNC)
#define	ZFS_FIEMAP_FLAGS_ZFS	\
	(FIEMAP_FLAG_COPIES | FIEMAP_FLAG_NOMERGE)

struct inode;
struct fiemap_extent_info;

extern int zfs_fiemap(struct inode *ip,
    struct fiemap_extent_info *fei, uint64_t start, uint64_t len,
    uint32_t flags);

#endif /* _KERNEL */
#endif	/* _SYS_FIEMAP_H */
