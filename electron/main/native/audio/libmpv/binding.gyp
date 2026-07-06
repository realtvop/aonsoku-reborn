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
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
        "MACOSX_DEPLOYMENT_TARGET": "11.0",
        "LD_RUNPATH_SEARCH_PATHS": ["@loader_path"]
      },
      "conditions": [
        [
          "OS=='linux'",
          {
            "ldflags": ["-Wl,-rpath,$$ORIGIN"]
          }
        ]
      ]
    }
  ]
}
