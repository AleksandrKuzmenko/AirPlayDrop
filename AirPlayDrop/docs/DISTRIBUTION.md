# Distribution model

The `0.1.0-alpha` release is source-first. Users install FFmpeg and FFprobe
separately; this repository does not bundle or link multimedia binaries. The
project therefore avoids making licensing claims about a particular FFmpeg
build and does not publish unsigned application archives.

The `v0.1.0-alpha` tag identifies the released source. Pushing a version tag
reruns the Xcode 15.4 verification gate, creates an archive from that exact
commit, writes a SHA-256 checksum, and attaches both files to a GitHub
prerelease. Moving or reusing a published version tag is not supported.

A future binary release must use Developer ID signing, the hardened runtime,
notarization, universal-architecture testing, a reproducible archive and
checksums. Before bundling FFmpeg, maintainers must review the exact configure
flags, LGPL/GPL obligations, source-offer requirements, and attribution.
Mac App Store distribution would additionally require a sandbox-compatible
helper architecture and is not a goal of this alpha.
