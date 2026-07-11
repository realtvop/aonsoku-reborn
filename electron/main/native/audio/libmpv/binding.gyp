{
  "variables": {
    "aonsoku_libmpv_include_dir%": "<!(node -e \"process.stdout.write(process.env.AONSOKU_LIBMPV_INCLUDE_DIR || '')\")",
    "aonsoku_libmpv_lib_dir%": "<!(node -e \"process.stdout.write(process.env.AONSOKU_LIBMPV_LIB_DIR || '')\")",
    "aonsoku_libmpv_library%": "<!(node -e \"process.stdout.write(process.env.AONSOKU_LIBMPV_LIBRARY || '-lmpv')\")"
  },
  "targets": [
    {
      "target_name": "aonsoku_libmpv",
      "sources": ["src/aonsoku_libmpv.cc"],
      "include_dirs": ["<(aonsoku_libmpv_include_dir)"],
      "library_dirs": ["<(aonsoku_libmpv_lib_dir)"],
      "libraries": ["<(aonsoku_libmpv_library)"],
      "cflags_cc": ["-std=c++17"],
      "xcode_settings": {
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
        "MACOSX_DEPLOYMENT_TARGET": "11.0",
        "LD_RUNPATH_SEARCH_PATHS": ["@loader_path"]
      },
      "conditions": [
        [
          "OS=='mac'",
          {
            "sources": ["src/system_media_session.mm"],
            "link_settings": {
              "libraries": [
                "-framework AppKit",
                "-framework Foundation",
                "-framework MediaPlayer",
              ],
            }
          }
        ],
        [
          "OS=='win'",
          {
            "sources": ["src/system_media_session_win.cc"],
            "libraries": ["windowsapp.lib"],
            "defines": ["WINVER=0x0A00", "_WIN32_WINNT=0x0A00"],
            "msvs_settings": {
              "VCCLCompilerTool": {
                "AdditionalOptions": ["/std:c++17"]
              }
            }
          }
        ],
        [
          "OS=='linux'",
          {
            "sources": ["src/system_media_session_linux.cc"],
            "cflags": ["<!@(pkg-config --cflags dbus-1)"],
            "libraries": ["<!@(pkg-config --libs dbus-1)"],
            # `$$ORIGIN` survives gyp's `$$` -> `$` makefile expansion, and the
            # single quotes stop the shell from expanding `$ORIGIN` to empty
            # before g++ receives it. Without the quotes the addon is linked
            # with an empty rpath and cannot find libmpv.so next to it at
            # runtime (the dynamic loader then reports
            # `libmpv.so.2: cannot open shared object file`). `-z origin` marks
            # that $ORIGIN is used so the loader expands it.
            "ldflags": [
              "-Wl,-z,origin",
              "-Wl,-rpath,'$$ORIGIN'"
            ]
          }
        ],
        [
          "OS!='mac' and OS!='win' and OS!='linux'",
          {
            "sources": ["src/system_media_session_stub.cc"]
          }
        ]
      ]
    }
  ]
}
