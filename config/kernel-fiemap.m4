dnl # SPDX-License-Identifier: CDDL-1.0
dnl #
dnl # 5.8 API change
dnl # fiemap_check_flags() was replaced by fiemap_prep(), which also
dnl # does the range check and FIEMAP_FLAG_SYNC the VFS did before.
dnl #
AC_DEFUN([ZFS_AC_KERNEL_SRC_FIEMAP_PREP], [
	ZFS_LINUX_TEST_SRC([fiemap_prep], [
		#include <linux/fs.h>
		#include <linux/fiemap.h>
	], [
		struct inode *inode = NULL;
		struct fiemap_extent_info *fei = NULL;
		u64 len = 0;
		int error __attribute__ ((unused));

		error = fiemap_prep(inode, fei, 0, &len, 0);
	])
])

AC_DEFUN([ZFS_AC_KERNEL_FIEMAP_PREP], [
	AC_MSG_CHECKING([whether fiemap_prep() is available])
	ZFS_LINUX_TEST_RESULT([fiemap_prep], [
		AC_MSG_RESULT(yes)
		AC_DEFINE(HAVE_FIEMAP_PREP, 1,
		    [fiemap_prep() is available])
	], [
		AC_MSG_RESULT(no)
	])
])
