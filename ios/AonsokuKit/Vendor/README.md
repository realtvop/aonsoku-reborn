# Embedded Tailscale

Aonsoku packages the official `tailscale/libtailscale` C runtime, pinned to
`d1dc45d039edb7759ecbee6ba2aea0c4bca884b8` (tailscale.com v1.104.1).
Its thin `EmbeddedTailscaleNode` Swift facade uses the same C/tsnet APIs as
upstream TailscaleKit. The feature is available only on iOS 18.1 and later;
the static archive keeps the host application's iOS 16 deployment target.

Before opening/building the Xcode project or resolving AonsokuKit:

```sh
# Requires Xcode and Go 1.27.1. This does not require a Tailscale account.
bash scripts/build-ios-tailscale.sh
```

The generated `CTailscale.xcframework` is ignored by Git. It contains device
arm64 and Simulator arm64/x86_64 slices. CI builds/caches the same artifact.
Set `TAILSCALE_GO` to an absolute Go executable if it is not on PATH; normal
Go module proxy/checksum settings apply. No authentication keys or node state
belong in this directory. See `Tailscale-LICENSE` for the BSD-3-Clause license.
