# Native Audio Runtime Resources

Generated libmpv runtime bundles live under:

```text
resources/native-audio/<platform>-<arch>/
  aonsoku_libmpv.node
  manifest.json
  libmpv runtime libraries and platform dependencies
```

Create a bundle for the current platform with:

```bash
pnpm native-audio:prepare -- --runtime-dir /path/to/libmpv/runtime
```

Release and CI jobs should provide the platform-specific libmpv runtime files
explicitly and use `--require-runtime-libs` so packages do not depend on a
developer machine's global mpv/libmpv installation.
