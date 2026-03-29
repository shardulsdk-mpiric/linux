.. SPDX-License-Identifier: GPL-2.0

================================
Apple File System (APFS) for Linux
================================

Overview
========

APFS (Apple File System) is a proprietary filesystem developed by Apple Inc.,
introduced with macOS 10.13 (High Sierra) in 2017 and iOS 10.3 (2017).  It
replaces HFS+ and is the default filesystem on all modern Apple platforms.

Key features of APFS:

- Space-sharing containers: multiple volumes share a common block pool
- Copy-on-write metadata and data
- Crash protection via checksummed object tree
- Snapshots (read-only point-in-time volume copies)
- Clones (instant file/directory copies with copy-on-write sharing)
- Inline compression (zlib and LZFSE algorithms)
- Encryption (per-file and per-volume; not yet supported in this driver)
- 64-bit inode numbers and nanosecond timestamps
- Unicode normalization (NFC) for filenames
- Case-insensitive or case-sensitive configurations

Container and Volume Architecture
===================================

An APFS container (NX superblock) occupies a block device and manages a pool
of blocks shared among one or more volumes.  Each volume (APFS superblock) has
its own object map and directory tree, but allocates blocks from the shared
container pool.

To mount a specific volume, use the ``vol=N`` mount option where N is the
zero-based volume index within the container.  If omitted, volume 0 is mounted.

Mount Options
=============

``vol=N``
	Mount volume number N (default: 0).

``snap=NAME``
	Mount the snapshot with the given name as a read-only view.

``tier2=DEVICE``
	Path to a secondary block device for Fusion Drive containers.

``uid=N``
	Override the UID for all files (useful for single-user media).

``gid=N``
	Override the GID for all files.

``readwrite``
	Allow write access.  By default, mounts are read-only for safety.
	Write support is experimental; use with caution and always keep backups.

``cknodes``
	Verify the Fletcher-64 checksum of every B-tree node read from disk.
	This adds overhead but can detect silent corruption early.

Snapshots
=========

Snapshots can be created via the ``APFS_IOC_TAKE_SNAPSHOT`` ioctl on any
directory file descriptor within the volume::

	struct apfs_ioctl_snap_name snap = { .name = "my-snapshot" };
	ioctl(dirfd, APFS_IOC_TAKE_SNAPSHOT, &snap);

Existing snapshots can be mounted read-only with the ``snap=NAME`` option.

Kernel Configuration
====================

Enable ``CONFIG_APFS_FS`` (``Filesystems → Apple File System (APFS) support``).
The driver depends on ``CONFIG_ZLIB_INFLATE`` for decompressing zlib-compressed
files.  LZFSE decompression is built in.

Known Limitations
=================

- Encryption (SoftwareAES, AES-XTS data protection) is not implemented.
- Clones and reflinks are read-only at the moment; creating new clones is not
  supported.
- Fusion Drive (``tier2``) read path is functional; write path is experimental.

References
==========

- Apple APFS Reference: https://developer.apple.com/support/downloads/Apple-File-System-Reference.pdf
- Upstream out-of-tree driver: https://github.com/linux-apfs/linux-apfs-rw
