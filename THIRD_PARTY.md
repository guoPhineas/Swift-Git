# Third-party cryptography

`Sources/CSHA1DC` contains the unmodified `sha1.c`, `sha1.h`, `ubc_check.c` and
`ubc_check.h` files from [sha1collisiondetection](https://github.com/cr-marcstevens/sha1collisiondetection),
revision `a06f1adbe5522f3c939cd6a3f13d5ec7f4c1a988`.

The authors are Marc Stevens and Dan Shumow. The implementation is MIT-licensed;
the original notices and `Sources/CSHA1DC/LICENSE.txt` are retained. A copy of the
license is also included in the Swift_Git resource bundle for app distribution.
The `sha-mbles-1.bin` collision fixture comes from the same revision and license.

This dependency provides a cryptographic primitive with collision detection.
Repository formats, pack/delta parsing, protocol negotiation, checkout and clone
remain implemented in Swift. No Git C implementation or libgit2 is linked.
