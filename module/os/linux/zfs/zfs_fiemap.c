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

/*
 * FS_IOC_FIEMAP for regular files.  The map describes the synced
 * block tree: a dirty file is synced first, and nothing is reported
 * as delayed allocation.  Holes are the gaps between extents.
 *
 * A DVA offset locates a block only within its top-level vdev, so
 * the vdev id goes in the high bits of fe_physical, using as few
 * bits as the pool's top-level vdev count needs.  With one top-level
 * vdev fe_physical is the plain offset; otherwise it identifies a
 * block for comparison and is not a device address.
 */

#include <sys/types.h>
#include <sys/sysmacros.h>
#include <sys/kmem.h>
#include <sys/list.h>
#include <sys/dmu.h>
#include <sys/dmu_objset.h>
#include <sys/dmu_traverse.h>
#include <sys/dbuf.h>
#include <sys/dnode.h>
#include <sys/spa.h>
#include <sys/spa_impl.h>
#include <sys/zfeature.h>
#include <sys/vdev_impl.h>
#include <sys/brt.h>
#include <sys/ddt.h>
#include <sys/txg.h>
#include <sys/arc.h>
#include <sys/zio.h>
#include <sys/zfs_znode.h>
#include <sys/zfs_rlock.h>
#include <sys/fiemap.h>
#include <linux/fiemap.h>

typedef struct zfs_fiemap_entry {
	uint64_t fe_logical;
	uint64_t fe_logical_len;
	uint64_t fe_physical;
	uint64_t fe_physical_len;
	uint64_t fe_vdev;
	uint32_t fe_flags;
	list_node_t fe_node;
} zfs_fiemap_entry_t;

typedef struct zfs_fiemap {
	list_t fm_extents[SPA_DVAS_PER_BP];	/* per copy */
	int fm_copies;			/* lists in use */
	uint32_t fm_flags;
	uint32_t fm_extents_max;	/* 0 for a count request */
	uint64_t fm_start;
	uint64_t fm_length;
	uint64_t fm_end;		/* exclusive, at most EOF */
	uint64_t fm_file_size;
	uint64_t fm_block_size;
	uint64_t fm_start_blk;
	uint64_t fm_end_blk;
	uint64_t fm_maxblkid;
	uint64_t fm_vdev_bits;
	uint64_t fm_complete;	/* see zfs_fiemap_complete() */
	boolean_t fm_full;
} zfs_fiemap_t;

/*
 * Nothing more can merge into fe once a later extent has started.
 * A count request counts it, in every list, and frees it, so it
 * holds one extent per list.  A map counts the first list only and
 * stops the walk once that list alone can fill the caller's array.
 */
static void
zfs_fiemap_complete(zfs_fiemap_t *fm, int idx, zfs_fiemap_entry_t *fe)
{
	if (fm->fm_extents_max == 0) {
		fm->fm_complete++;
		list_remove(&fm->fm_extents[idx], fe);
		kmem_free(fe, sizeof (*fe));
	} else if (idx == 0 &&
	    ++fm->fm_complete >= fm->fm_extents_max) {
		fm->fm_full = B_TRUE;
	}
}

static void
zfs_fiemap_add(zfs_fiemap_t *fm, int idx, const zfs_fiemap_entry_t *e)
{
	list_t *l = &fm->fm_extents[idx];
	zfs_fiemap_entry_t *prev = list_tail(l);

	if (prev != NULL) {
		uint64_t pend = prev->fe_logical +
		    prev->fe_logical_len;

		/* Blocks arrive once each, in logical order. */
		if (pend > e->fe_logical) {
			ASSERT(!"fiemap: overlapping extents");
			return;
		}

		if (!(fm->fm_flags & FIEMAP_FLAG_NOMERGE) &&
		    !(e->fe_flags & FIEMAP_EXTENT_DATA_INLINE) &&
		    (prev->fe_flags & ~FIEMAP_EXTENT_MERGED) ==
		    e->fe_flags && pend == e->fe_logical &&
		    prev->fe_vdev == e->fe_vdev &&
		    prev->fe_physical + prev->fe_physical_len ==
		    e->fe_physical) {
			prev->fe_logical_len += e->fe_logical_len;
			prev->fe_physical_len += e->fe_physical_len;
			prev->fe_flags |= FIEMAP_EXTENT_MERGED;
			return;
		}

		zfs_fiemap_complete(fm, idx, prev);
	}

	zfs_fiemap_entry_t *fe = kmem_alloc(sizeof (*fe), KM_SLEEP);
	*fe = *e;
	list_link_init(&fe->fe_node);
	list_insert_tail(l, fe);
}

/*
 * The DDT and BRT count synced references only.  A clone waits in
 * the BRT pending trees until its TXG syncs, but it has already
 * returned to its caller.
 */
static boolean_t
zfs_fiemap_shared(spa_t *spa, const blkptr_t *bp)
{
	if (ddt_class_contains_open(spa, DDT_CLASS_DUPLICATE, bp))
		return (B_TRUE);
	if (brt_maybe_exists(spa, bp) &&
	    brt_entry_get_refcount(spa, bp) > 0)
		return (B_TRUE);
	return (brt_pending_exists(spa, bp));
}

static void
zfs_fiemap_block(zfs_fiemap_t *fm, spa_t *spa, const blkptr_t *bp,
    uint64_t blkid)
{
	zfs_fiemap_entry_t e = {
		.fe_logical = blkid * fm->fm_block_size,
	};

	if (BP_IS_EMBEDDED(bp)) {
		e.fe_logical_len = BPE_GET_LSIZE(bp);
		e.fe_physical_len = BPE_GET_PSIZE(bp);
		e.fe_flags = FIEMAP_EXTENT_DATA_INLINE |
		    FIEMAP_EXTENT_NOT_ALIGNED;
		if (BP_GET_COMPRESS(bp) != ZIO_COMPRESS_OFF)
			e.fe_flags |= FIEMAP_EXTENT_ENCODED;
		zfs_fiemap_add(fm, 0, &e);
		return;
	}

	e.fe_logical_len = BP_GET_LSIZE(bp);
	if (BP_GET_COMPRESS(bp) != ZIO_COMPRESS_OFF)
		e.fe_flags |= FIEMAP_EXTENT_ENCODED;
	if (BP_IS_ENCRYPTED(bp)) {
		e.fe_flags |= FIEMAP_EXTENT_DATA_ENCRYPTED |
		    FIEMAP_EXTENT_ENCODED;
	}
	if (zfs_fiemap_shared(spa, bp))
		e.fe_flags |= FIEMAP_EXTENT_SHARED;

	/*
	 * After a device removal, report where a block lives now.  A
	 * split block cannot be remapped, and its DVA still names the
	 * indirect vdev, which is not a device.
	 */
	boolean_t indirect[SPA_DVAS_PER_BP] = { B_FALSE };
	blkptr_t rbp;

	if (spa_feature_is_active(spa, SPA_FEATURE_DEVICE_REMOVAL)) {
		rbp = *bp;
		spa_config_enter(spa, SCL_VDEV, FTAG, RW_READER);
		if (spa_remap_blkptr(spa, &rbp, NULL, NULL))
			bp = &rbp;
		for (int d = 0; d < BP_GET_NDVAS(bp); d++) {
			vdev_t *vd = vdev_lookup_top(spa,
			    DVA_GET_VDEV(&bp->blk_dva[d]));
			indirect[d] = (vd != NULL &&
			    vd->vdev_ops == &vdev_indirect_ops);
		}
		spa_config_exit(spa, SCL_VDEV, FTAG);
	}

	int ncopies = MIN(fm->fm_copies, BP_GET_NDVAS(bp));

	for (int d = 0; d < ncopies; d++) {
		const dva_t *dva = &bp->blk_dva[d];
		zfs_fiemap_entry_t c = e;

		if (BP_IS_GANG(bp) || indirect[d]) {
			c.fe_flags |= FIEMAP_EXTENT_UNKNOWN;
		} else {
			c.fe_vdev = DVA_GET_VDEV(dva);
			c.fe_physical = DVA_GET_OFFSET(dva);
			c.fe_physical_len = DVA_GET_ASIZE(dva);
		}
		zfs_fiemap_add(fm, d, &c);
	}
}

/*
 * Whether the subtree under bp, span level 0 blocks from first,
 * holds anything the request can report.
 */
static boolean_t
zfs_fiemap_want(const zfs_fiemap_t *fm, const blkptr_t *bp,
    uint64_t first, uint64_t span)
{
	return (!BP_IS_HOLE(bp) && first < fm->fm_end_blk &&
	    first <= fm->fm_maxblkid &&
	    (fm->fm_start_blk <= first ||
	    fm->fm_start_blk - first < span));
}

/*
 * Start reads of the indirect children before walking them, so the
 * walk does not wait for each in turn.  Level 0 block pointers are
 * reported from their parent and never read.
 */
static void
zfs_fiemap_prefetch(const zfs_fiemap_t *fm, spa_t *spa,
    const dnode_phys_t *dnp, const blkptr_t *cbp,
    const zbookmark_phys_t *zb, int epb)
{
	int clevel = zb->zb_level - 1;

	if (clevel == 0)
		return;

	uint64_t span =
	    bp_span_in_blocks(dnp->dn_indblkshift, clevel);

	for (int i = 0; i < epb; i++) {
		uint64_t blkid = zb->zb_blkid * epb + i;
		arc_flags_t aflags = ARC_FLAG_NOWAIT |
		    ARC_FLAG_PREFETCH | ARC_FLAG_PRESCIENT_PREFETCH;
		zbookmark_phys_t czb;

		if (!zfs_fiemap_want(fm, &cbp[i], blkid * span, span))
			continue;

		SET_BOOKMARK(&czb, zb->zb_objset, zb->zb_object,
		    clevel, blkid);
		(void) arc_read(NULL, spa, &cbp[i], NULL, NULL,
		    ZIO_PRIORITY_ASYNC_READ,
		    ZIO_FLAG_CANFAIL | ZIO_FLAG_SPECULATIVE,
		    &aflags, &czb);
	}
}

static int
zfs_fiemap_walk(zfs_fiemap_t *fm, spa_t *spa, const dnode_phys_t *dnp,
    const blkptr_t *bp, const zbookmark_phys_t *zb)
{
	uint64_t span = bp_span_in_blocks(dnp->dn_indblkshift,
	    zb->zb_level);

	if (fm->fm_full ||
	    !zfs_fiemap_want(fm, bp, zb->zb_blkid * span, span))
		return (0);

	if (zb->zb_level == 0) {
		zfs_fiemap_block(fm, spa, bp, zb->zb_blkid);
		return (0);
	}

	arc_flags_t aflags = ARC_FLAG_WAIT;
	arc_buf_t *buf;
	int epb = BP_GET_LSIZE(bp) >> SPA_BLKPTRSHIFT;
	int error = arc_read(NULL, spa, bp, arc_getbuf_func, &buf,
	    ZIO_PRIORITY_ASYNC_READ, ZIO_FLAG_CANFAIL, &aflags, zb);
	if (error != 0)
		return (error);

	const blkptr_t *cbp = buf->b_data;
	zfs_fiemap_prefetch(fm, spa, dnp, cbp, zb, epb);

	for (int i = 0; i < epb && error == 0; i++) {
		zbookmark_phys_t czb;

		cond_resched();
		if (fatal_signal_pending(current)) {
			error = SET_ERROR(EINTR);
			break;
		}

		SET_BOOKMARK(&czb, zb->zb_objset, zb->zb_object,
		    zb->zb_level - 1, zb->zb_blkid * epb + i);
		error = zfs_fiemap_walk(fm, spa, dnp, &cbp[i], &czb);
	}

	arc_buf_destroy(buf, &buf);
	return (error);
}

/*
 * A count request completes the last extent of each list.  A map
 * that reached EOF flags LAST on the extent emitted last, which is
 * in the last list holding anything: COPIES emits the lists in
 * order, and a reader stops at LAST.
 */
static void
zfs_fiemap_finish(zfs_fiemap_t *fm)
{
	zfs_fiemap_entry_t *fe;

	if (fm->fm_extents_max == 0) {
		for (int i = 0; i < fm->fm_copies; i++) {
			fe = list_tail(&fm->fm_extents[i]);
			if (fe != NULL)
				zfs_fiemap_complete(fm, i, fe);
		}
		return;
	}

	if (fm->fm_full || fm->fm_end < fm->fm_file_size)
		return;

	for (int i = fm->fm_copies - 1; i >= 0; i--) {
		if ((fe = list_tail(&fm->fm_extents[i])) != NULL) {
			fe->fe_flags |= FIEMAP_EXTENT_LAST;
			return;
		}
	}
}

/*
 * Sync a dirty dnode so the walk sees every write.  With the whole
 * file locked this takes at most TXG_CONCURRENT_STATES syncs, as in
 * dmu_offset_next().  On a failmode=continue pool give up rather
 * than hold the lock while the pool is suspended.
 */
static int
zfs_fiemap_sync(spa_t *spa, dnode_t *dn)
{
	int wflags = 0;

	if (spa_get_failmode(spa) == ZIO_FAILURE_MODE_CONTINUE)
		wflags = TXG_WAIT_SUSPEND;

	for (int i = 0; i < TXG_CONCURRENT_STATES; i++) {
		if (!dnode_is_dirty(dn))
			break;

		int error = txg_wait_synced_flags(spa_get_dsl(spa),
		    spa_last_synced_txg(spa) + 1, wflags);
		if (error != 0) {
			ASSERT3U(error, ==, ESHUTDOWN);
			return (SET_ERROR(EIO));
		}
	}

	return (0);
}

static int
zfs_fiemap_assemble(struct inode *ip, zfs_fiemap_t *fm)
{
	znode_t *zp = ITOZ(ip);
	zfsvfs_t *zfsvfs = ZTOZSB(zp);
	zfs_locked_range_t *lr;
	dnode_phys_t *dnp;
	dnode_t *dn;
	spa_t *spa;
	int error;

	if ((error = zfs_enter_verify_zp(zfsvfs, zp, FTAG)) != 0)
		return (error);

	error = dnode_hold(zfsvfs->z_os, zp->z_id, FTAG, &dn);
	if (error != 0) {
		zfs_exit(zfsvfs, FTAG);
		return (error);
	}
	spa = dmu_objset_spa(dn->dn_objset);

	/*
	 * The walk reads indirect blocks by address, so no part
	 * of the file may be rewritten, and its old blocks freed,
	 * until it is done.
	 */
	lr = zfs_rangelock_enter(&zp->z_rangelock, 0, UINT64_MAX,
	    RL_READER);

	fm->fm_file_size = i_size_read(ip);
	if (fm->fm_start >= fm->fm_file_size)
		goto out;
	fm->fm_end = fm->fm_start +
	    MIN(fm->fm_length, fm->fm_file_size - fm->fm_start);

	if ((error = zfs_fiemap_sync(spa, dn)) != 0)
		goto out;

	spa_config_enter(spa, SCL_VDEV, FTAG, RW_READER);
	fm->fm_vdev_bits =
	    highbit64(spa->spa_root_vdev->vdev_children - 1);
	spa_config_exit(spa, SCL_VDEV, FTAG);

	rw_enter(&dn->dn_struct_rwlock, RW_READER);

	dnp = dn->dn_phys;
	fm->fm_block_size = dn->dn_datablksz;
	fm->fm_maxblkid = dnp->dn_maxblkid;
	fm->fm_start_blk = fm->fm_start / fm->fm_block_size;
	fm->fm_end_blk = howmany(fm->fm_end, fm->fm_block_size);

	for (int i = 0; i < dnp->dn_nblkptr && error == 0; i++) {
		zbookmark_phys_t zb;
		blkptr_t bp;

		/* spa_sync() updates dn_blkptr under db_rwlock. */
		rw_enter(&dn->dn_dbuf->db_rwlock, RW_READER);
		bp = dnp->dn_blkptr[i];
		rw_exit(&dn->dn_dbuf->db_rwlock);

		SET_BOOKMARK(&zb, dmu_objset_id(dn->dn_objset),
		    dn->dn_object, dnp->dn_nlevels - 1, i);
		error = zfs_fiemap_walk(fm, spa, dnp, &bp, &zb);
	}

	rw_exit(&dn->dn_struct_rwlock);

	if (error == 0)
		zfs_fiemap_finish(fm);
out:
	zfs_rangelock_exit(lr);
	dnode_rele(dn, FTAG);
	zfs_exit(zfsvfs, FTAG);

	return (error);
}

static int
zfs_fiemap_fill(zfs_fiemap_t *fm, struct fiemap_extent_info *fei)
{
	uint64_t mask = fm->fm_block_size - 1;

	if (fm->fm_extents_max == 0) {
		fei->fi_extents_mapped =
		    MIN(fm->fm_complete, UINT32_MAX);
		return (0);
	}

	for (int i = 0; i < fm->fm_copies; i++) {
		list_t *l = &fm->fm_extents[i];
		zfs_fiemap_entry_t *fe;

		for (fe = list_head(l); fe != NULL;
		    fe = list_next(l, fe)) {
			uint64_t llen = MIN(fe->fe_logical_len,
			    fm->fm_file_size - fe->fe_logical);
			uint64_t phys = fe->fe_physical;
			uint32_t flags = fe->fe_flags;

			if (!ISP2(fm->fm_block_size) ||
			    ((fe->fe_logical | llen | phys) & mask))
				flags |= FIEMAP_EXTENT_NOT_ALIGNED;
			if (fm->fm_vdev_bits != 0) {
				phys |= fe->fe_vdev <<
				    (64 - fm->fm_vdev_bits);
			}

			int error = fiemap_fill_next_extent(fei,
			    fe->fe_logical, phys, llen, flags);
			if (error < 0)
				return (-error);
			if (error == 1)
				return (0);
		}
	}

	return (0);
}

/*
 * Returns a positive errno.  fiemap_fill_next_extent() returns a
 * negative one, which zfs_fiemap_fill() converts.
 */
int
zfs_fiemap(struct inode *ip, struct fiemap_extent_info *fei,
    uint64_t start, uint64_t len, uint32_t flags)
{
	zfs_fiemap_t *fm = kmem_zalloc(sizeof (*fm), KM_SLEEP);
	zfs_fiemap_entry_t *fe;
	int error;

	fm->fm_copies = 1;
	if (flags & FIEMAP_FLAG_COPIES)
		fm->fm_copies = SPA_DVAS_PER_BP;
	fm->fm_flags = flags;
	fm->fm_extents_max = fei->fi_extents_max;
	fm->fm_start = start;
	fm->fm_length = len;
	for (int i = 0; i < SPA_DVAS_PER_BP; i++) {
		list_create(&fm->fm_extents[i],
		    sizeof (zfs_fiemap_entry_t),
		    offsetof(zfs_fiemap_entry_t, fe_node));
	}

	error = zfs_fiemap_assemble(ip, fm);
	if (error == 0)
		error = zfs_fiemap_fill(fm, fei);

	for (int i = 0; i < SPA_DVAS_PER_BP; i++) {
		list_t *l = &fm->fm_extents[i];

		while ((fe = list_remove_head(l)) != NULL)
			kmem_free(fe, sizeof (*fe));
		list_destroy(l);
	}
	kmem_free(fm, sizeof (*fm));

	return (error);
}
