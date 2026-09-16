# Legacy Python app

This directory contains the retired Python/Flask/MLX implementation of Local
Digest. It is kept as a historical reference and is separate from the native
macOS app in `../LocalDigest/`.

The shipping app is built only from `../LocalDigest.xcodeproj`. Nothing in this
directory is part of the native target or native runtime. The legacy app has
its own `requirements.txt`, `start.sh`, web assets, Apple Foundation bridge,
and MLX client code.

Do not point the native build at this directory or install its dependencies
into the native app environment.
