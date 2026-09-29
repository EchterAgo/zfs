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
 * Copyright (c) 2026 by the OpenZFS project.
 */

/*
 * Print the FS_IOC_FIEMAP map of a file for the ZTS fiemap tests.
 * One line per extent returned,
 *
 *	ext <logical> <physical> <length> <flags_hex> [flag names]
 *
 * then "mapped <count>".  A failure prints "error <errno> <strerror>"
 * and exits 1.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <getopt.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/fiemap.h>
#include <linux/fs.h>
#include <linux/fiemap.h>

typedef unsigned long long u_ll;

static void
print_flag_names(uint32_t f)
{
	struct { uint32_t bit; const char *name; } tbl[] = {
		{ FIEMAP_EXTENT_LAST,		"last" },
		{ FIEMAP_EXTENT_UNKNOWN,	"unknown" },
		{ FIEMAP_EXTENT_DELALLOC,	"delalloc" },
		{ FIEMAP_EXTENT_ENCODED,	"encoded" },
		{ FIEMAP_EXTENT_DATA_ENCRYPTED,	"encrypted" },
		{ FIEMAP_EXTENT_NOT_ALIGNED,	"not_aligned" },
		{ FIEMAP_EXTENT_DATA_INLINE,	"inline" },
		{ FIEMAP_EXTENT_UNWRITTEN,	"unwritten" },
		{ FIEMAP_EXTENT_MERGED,		"merged" },
		{ FIEMAP_EXTENT_SHARED,		"shared" },
	};

	for (size_t i = 0; i < sizeof (tbl) / sizeof (tbl[0]); i++) {
		if (f & tbl[i].bit)
			printf(" %s", tbl[i].name);
	}
}

static void
usage(void)
{
	fprintf(stderr, "usage: fiemap [-s start] [-l length] "
	    "[-c max_extents] [-f flags] [-SCN] <file>\n"
	    "  -s start        start offset in bytes, default 0\n"
	    "  -l length       length in bytes, default all\n"
	    "  -c max_extents  extent array size, 0 to count,\n"
	    "                  default 1024\n"
	    "  -f flags        request flags to add, as a number\n"
	    "  -S              FIEMAP_FLAG_SYNC\n"
	    "  -C              FIEMAP_FLAG_COPIES (ZFS)\n"
	    "  -N              FIEMAP_FLAG_NOMERGE (ZFS)\n");
}

int
main(int argc, char **argv)
{
	uint64_t start = 0, length = FIEMAP_MAX_OFFSET;
	uint32_t count = 1024;
	uint32_t flags = 0;
	int c;

	while ((c = getopt(argc, argv, "s:l:c:f:SCN")) != -1) {
		switch (c) {
		case 's': start = strtoull(optarg, NULL, 0); break;
		case 'l': length = strtoull(optarg, NULL, 0); break;
		case 'c': count = strtoul(optarg, NULL, 0); break;
		case 'f': flags |= strtoul(optarg, NULL, 0); break;
		case 'S': flags |= FIEMAP_FLAG_SYNC; break;
		case 'C': flags |= FIEMAP_FLAG_COPIES; break;
		case 'N': flags |= FIEMAP_FLAG_NOMERGE; break;
		default: usage(); return (2);
		}
	}

	if (optind >= argc) {
		usage();
		return (2);
	}

	/* O_NONBLOCK so a FIFO opens without a writer. */
	int fd = open(argv[optind], O_RDONLY | O_NONBLOCK);
	if (fd < 0) {
		printf("error %d %s\n", errno, strerror(errno));
		return (1);
	}

	size_t sz = sizeof (struct fiemap) +
	    (size_t)count * sizeof (struct fiemap_extent);
	struct fiemap *fm = calloc(1, sz);
	if (fm == NULL) {
		printf("error %d %s\n", ENOMEM, strerror(ENOMEM));
		close(fd);
		return (1);
	}

	fm->fm_start = start;
	fm->fm_length = length;
	fm->fm_flags = flags;
	fm->fm_extent_count = count;

	if (ioctl(fd, FS_IOC_FIEMAP, fm) < 0) {
		printf("error %d %s\n", errno, strerror(errno));
		free(fm);
		close(fd);
		return (1);
	}

	/* A count request returns no extents. */
	uint32_t n = fm->fm_mapped_extents < count ?
	    fm->fm_mapped_extents : count;
	for (uint32_t i = 0; i < n; i++) {
		struct fiemap_extent *e = &fm->fm_extents[i];
		printf("ext %llu %llu %llu 0x%x",
		    (u_ll)e->fe_logical, (u_ll)e->fe_physical,
		    (u_ll)e->fe_length, e->fe_flags);
		print_flag_names(e->fe_flags);
		printf("\n");
	}
	printf("mapped %u\n", fm->fm_mapped_extents);

	free(fm);
	close(fd);
	return (0);
}
