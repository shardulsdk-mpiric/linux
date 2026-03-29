.. SPDX-License-Identifier: GPL-2.0

============================
APFS Driver Testing & Status
============================

This document tracks the testing performed on the in-tree APFS driver
during development.  It is intended as an internal reference and will
be replaced by a proper test plan before any upstream submission.

Test Environment
================

- **Kernel**: 7.0-rc5 (commit cbfffcca2bf0 + APFS patch series)
- **Architecture**: x86_64
- **VM**: QEMU (i440FX + PIIX), KASAN enabled, PREEMPT(lazy)
- **Test tool**: mkapfs from apfsprogs (https://github.com/linux-apfs/apfsprogs)
- **Images**: loop-mounted sparse files, various sizes (32M to 1G)

Image Variants Created
======================

All images created with ``mkapfs`` on Linux:

==================================  ====  ==========================================
Image                               Size  Notes
==================================  ====  ==========================================
apfs-basic.img                     256M  Default case-insensitive
apfs-case-sensitive.img            256M  ``mkapfs -s`` (case-sensitive)
apfs-normalization-sensitive.img   256M  ``mkapfs -z`` (normalization-sensitive)
apfs-strict-names.img             256M  ``mkapfs -s -z`` (case + norm sensitive)
apfs-small.img                      32M  Minimum viable container
apfs-large.img                       1G  Larger container
apfs-fixed-uuid.img               256M  Fixed container/volume UUIDs
apfs-populated.img                 256M  Populated with test data (see below)
==================================  ====  ==========================================

Smoke Tests Performed (2026-03-29)
==================================

1. Module load/unload
---------------------

- ``insmod apfs.ko`` — success, no errors
- Module taints kernel as OOT (expected for development)

2. Mount/unmount cycle
----------------------

- Read-only mount of freshly formatted image — success
- Read-write mount with ``-o readwrite`` — success
- Unmount — clean, no errors
- Re-mount read-only after write — success, data persisted

3. Bug found and fixed: use-after-free (KASAN)
-----------------------------------------------

Initial mount triggered a KASAN slab-use-after-free in ``apfs_getattr()``
and a subsequent crash in ``apfs_show_options()``.

**Root cause**: ``apfs_free_fc()`` freed ``ctx->sbi`` after a successful
mount, but ``sb->s_fs_info`` still referenced it.

**Fix**: Set ``ctx->sbi = NULL`` after successful superblock activation
in ``apfs_get_tree()``.

**Commit**: ``apfs: fix use-after-free of sb_info after successful mount``

4. Write path (readwrite mount)
-------------------------------

On a freshly formatted 256M image, the following operations succeeded:

- ``mkdir`` — directories, nested subdirectories
- ``echo > file`` — file creation with content
- ``dd if=/dev/zero bs=1M count=32`` — large file write (32MB)
- ``ln`` — hard link creation
- ``ln -s`` — symbolic link creation
- ``touch`` — empty file creation
- ``for i in $(seq 1 500)`` — bulk file creation (500 files in one dir)
- ``sync`` — explicit flush
- ``umount`` — clean unmount with transaction commit

5. Read path (read-only remount of written data)
-------------------------------------------------

After unmounting the written image and remounting read-only:

- ``ls -laR`` — full recursive directory listing correct
- ``cat file1.txt`` — file content ``hello`` read back correctly
- ``stat file1.txt`` — inode 19, size 6, links 2, timestamps populated,
  birth time present
- ``readlink symlink_to_file1`` — resolved to ``file1.txt``
- ``ls manyfiles/ | wc -l`` — 500 files present
- ``md5sum bigfile.bin`` — ``58f06dd588d8ffb3beb46ada6309436b`` (correct
  for 32MB of zeros)

6. Kernel log analysis
----------------------

No warnings, no errors, no KASAN reports after the UAF fix.  Only
expected informational messages about write-mode status.

What Has NOT Been Tested Yet
============================

The following areas require testing before any upstream consideration:

Functional gaps
---------------

- **Read-only mount of macOS-created images** — images from real macOS
  (via hdiutil/diskutil) exercise more on-disk format variants than
  mkapfs
- **Snapshot mount** — ``mount -t apfs -o snap=NAME``
- **Snapshot creation** — ``APFS_IOC_TAKE_SNAPSHOT`` ioctl
- **Multi-volume containers** — ``mount -t apfs -o vol=1``
- **Fusion Drive (tier2)** — ``mount -t apfs -o tier2=PATH``
- **Inline compression** — zlib (type 3/4) and LZFSE (type 7/8)
  compressed files
- **Extended attributes** — set/get/list xattrs, large xattrs (dstream)
- **Unicode normalization** — case-insensitive and normalization-
  insensitive filename matching
- **Special files** — block/char devices, FIFOs, sockets
- **Large directories** — 10K+ entries
- **Deep directory trees** — 100+ levels
- **Maximum filename length** — 255-byte UTF-8 names
- **Filesystem full** — ENOSPC handling
- **Concurrent access** — multiple readers/writers
- **Clone/reflink** — ``cp --reflink`` if supported

Stress and correctness
----------------------

- **xfstests generic suite** — the standard filesystem conformance tests
- **fsck after writes** — ``apfsck`` to verify on-disk consistency
- **Power-failure simulation** — dm-flakey or similar to test crash
  recovery
- **Memory pressure** — cgroup-limited mounts
- **Lockdep** — extended runs with lockdep enabled
- **KASAN/KMSAN/KCSAN** — sanitizer runs beyond the initial smoke test

Performance
-----------

- **fio** — sequential/random read/write throughput and latency
- **bonnie++** — mixed workload benchmarks
- **compilebench** — simulate kernel tree operations
- **Comparison** — APFS vs ext4/btrfs/xfs on equivalent workloads

Upstream readiness
------------------

- **checkpatch.pl** — coding style compliance
- **sparse** — static analysis (``make C=1``)
- **coccinelle** — semantic patches
- **W=1 build** — extra compiler warnings
- **Documentation** — complete API and design documentation
- **Reviewed-by** — at minimum, review from the APFS author (eafer)
  and HFS+ maintainer (Viacheslav Dubeyko)
