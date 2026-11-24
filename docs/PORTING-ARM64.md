# Porting WWE '13 Recomp to ARM64 and iOS

Status of the effort to run the recompilation on Apple Silicon (iPad / iPhone, and Macs as a stepping stone).

## Step 1 – ARM64 CPU side (done)

**Result: the ReXGlue SDK, the codegen tool and both test suites build for Linux ARM64, and every PowerPC
instruction test passes on ARM64 (1464 / 1464).**

The recompiled game code only uses 128-bit SIMDe vector calls (no AVX, no inline assembly). SIMDe lowers them to
ARM NEON, so the generated C++ is portable as is. The x86-specific runtime code (byte swapping, audio
conversion, MMIO and signal handling, FPSCR to host rounding mode) already has ARM64 branches. The AVX2
requirement is a build flag (`-march=x86-64-v3`), not a dependency of the code.

### Bugs found and fixed (`rexglue-patches/0100`–`0103`)

| Patch | Problem on ARM64 | Fix |
| --- | --- | --- |
| 0100 | Cross builds tried to run the ARM64 `rexglue` test generator on the x86 host | Run it through `CMAKE_CROSSCOMPILING_EMULATOR` (empty for native builds) |
| 0101 | `libavcodec` failed to link: `ff_idctdsp_init_aarch64` undefined | Build `libavcodec/aarch64/idctdsp_init_aarch64.c` |
| 0102 | Unit test read `context.rip`; PPC tests forced `-msse4.1 -mssse3` | Use `pc` on ARM64; pass SSE flags only on x86-64 |
| 0103 | **`vsl` returned corrupted vectors**: the hand-written ARM64 branch shifted the carry left instead of right | Use one SIMDe path with variable-count shifts on every architecture |
| 0103 | **`fctiwz` returned INT32_MIN for 2147483647.0**: SIMDe's non-x86 fallback range check is off by one | Emit `rex::ppc_fcti*` helpers that implement PowerPC saturation directly |
| 0103 | **`fctiw`/`fctid` rounded halves away from zero** (x86 rounds to even): the SIMDe fallback ignores the rounding mode | Round with `std::nearbyint`, which follows the host rounding mode that the FPSCR emulation programs |

0103 adds `tests/ppc/asm/instr_fctix_rounding.s`, with regression tests for half-even rounding, exactly
INT32_MAX, and 2^63. These are bugs that would only have appeared in game behaviour (for example wrong physics or
animation values), so the tests matter. The fcti change also makes `fctidz(2^63)` saturate correctly on x86-64,
where it previously returned INT64_MIN.

### Test results on ARM64 (under qemu-aarch64)

- `ppc_tests`: **1464 test cases, all pass** (before the fixes: 5 failed).
- `unit_tests`: 183 pass, 4 skipped, 4 fail. All 4 failures are in `chrono_test.cpp`, for dates in 1601. They
  **fail identically on x86-64 Linux** (checked natively): libstdc++'s `system_clock` counts nanoseconds and
  cannot represent dates before about 1678. This is pre-existing, not ARM-related, and does not affect
  Apple platforms (libc++ counts microseconds).

### How to reproduce (x86-64 Ubuntu 24.04 host)

```bash
sudo dpkg --add-architecture arm64      # plus an arm64 ports.ubuntu.com apt source
sudo apt-get install clang-20 lld-20 g++-aarch64-linux-gnu qemu-user \
  libgtk-3-dev:arm64 libx11-xcb-dev:arm64
# fetch + patch the SDK as tools/setup.sh does, then:
cmake -S ../tools/rexglue -B ../tools/rexglue/out/build/linux-arm64-cross -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_TOOLCHAIN_FILE=$PWD/cmake/toolchains/linux-arm64-cross.cmake \
  -DCMAKE_C_FLAGS=-march=armv8-a -DCMAKE_CXX_FLAGS=-march=armv8-a \
  -DREXGLUE_BUILD_TESTS=ON -DREXGLUE_USE_VULKAN=ON -DREXGLUE_FFMPEG_SHARED=ON
ninja -C ../tools/rexglue/out/build/linux-arm64-cross
qemu-aarch64 -L /usr/aarch64-linux-gnu ../tools/rexglue/out/build/linux-arm64-cross/tests/bin/ppc_tests
```

Clang 20 is required. Clang 18 with libstdc++ 13 does not provide `std::expected`.

The game itself was not built here, because building it needs your `default.xex` for codegen. On your Mac,
codegen and the game build happen locally against your own files.

## What step 1 found for the next steps (Apple-specific work)

These parts work on Linux ARM64 but need Apple-specific code:

1. **Build system rejects Apple.** The SDK's `CMakeLists.txt` stops with "ReXGlue supports Windows and Linux
   only". It needs a macOS/iOS platform branch (`REX_PLATFORM_MAC` already exists in `platform.h`).
   FFmpeg already ships `config_macos_aarch64.h`.
2. **Signal context layout.** `exception_handler_posix.cpp` and `mmio_handler.cpp` read the Linux
   `mcontext` (`regs`, `__reserved` + `FPSIMD_MAGIC`). Darwin uses `uc_mcontext->__ss` / `__ns`. MMIO and
   write-watch depend on this, so it must be ported for the GPU emulation to work.
3. **Guest memory.** About 8 GB of fixed-address mappings: 4 GB virtual, plus physical mirrors through
   `shm_open`. On iOS this needs the `com.apple.developer.kernel.extended-virtual-addressing` and
   `increased-memory-limit` entitlements, and probably Mach VM (`mach_make_memory_entry_64` + `vm_map`)
   instead of `shm_open`. `MAP_FIXED_NOREPLACE` is Linux-only; there is already a fallback.
4. **Threads and timers.** `SIGRTMIN`-based thread signals, `timer_create(SIGEV_THREAD_ID)`, `eventfd` and
   `sched_setaffinity` are Linux-only. They need Darwin equivalents (dispatch sources, kqueue, Mach
   semaphores).
5. **Window and input.** Only GTK and Win32 window backends exist. iOS needs a UIKit/`CAMetalLayer` surface.
   SDL3 is already vendored and supports iOS, game controllers and touch.
6. **Graphics.** The Vulkan backend has to run on MoltenVK. This is the highest-risk part; to be measured
   on macOS first.
7. **Game project.** `src/wwe13_app.h` uses GTK for error dialogs, and `release_diagnostics.cpp` and
   `single_instance.cpp` have Linux/Windows-only paths.

## Step 2 – macOS (in progress)

Code for the Apple platform, written without a Mac and checked by the **macOS port build check**
workflow (`.github/workflows/macos-port.yml`, macOS arm64 runner, Xcode's compiler, native unit
and PowerPC tests). It is in the ReXGlue patch series after 0103 (0104, 0105, 0106 with the
fixes from the first native build, 0107 for 16 KB host pages, 0108 for function aliases, and
0109–0115 from the first game boot).

| Area | Change |
| --- | --- |
| Build | Apple platform (`macos-arm64` / `ios-arm64`), AppleClang 16+ accepted, no `-mcmodel`, `-force_load` instead of `--whole-archive`, no `librt`, `arm64` processor name matched, `@loader_path` rpaths, `_XOPEN_SOURCE` + `_DARWIN_C_SOURCE` on ReXGlue code only |
| Window | New SDL3 backend (`window_sdl`, `windowed_app_context_sdl`, `windowed_app_main_sdl`): Retina-aware sizes, keyboard, text input, mouse, wheel, touch, file drop, fullscreen, cursor auto-hide; also used for iOS later |
| Graphics | `MetalLayerSurface` + `VK_EXT_metal_surface`, so MoltenVK presents to the SDL window's `CAMetalLayer` (portability enumeration was already there) |
| SDL3 | Video, Metal, haptic and sensor turned on for Apple builds only |
| Signals | Darwin `mcontext` (`__ss` / `__ns` / `__es.__esr`) read and written back; **SIGBUS handled like SIGSEGV** (Darwin raises SIGBUS for protection faults, which MMIO and write-watch use) |
| Threads | Mach semaphores (Darwin has no `sem_init`), `SIGUSR1`/`SIGUSR2` instead of real-time signals, `pthread_threadid_np`, Darwin thread names, no affinity, no `SCHED_FIFO` |
| Memory | `mach_vm_region` instead of `/proc/self/maps`, `MAP_FIXED_NOREPLACE` emulated (a commit never wipes committed memory), short `shm_open` names (Darwin limit 31), no `*64` functions |
| Other | `_NSGetExecutablePath` for the executable folder, fibers on Darwin `ucontext`, freeze logger without `/proc` (no host backtraces on Apple yet) |
| Game | macOS preset and `tools/setup-macos.sh` / `tools/build-macos.sh`; native alert instead of GTK; diagnostics read CPU, OS and RAM through `sysctl`; Darwin crash-handler PC and thread names |

### Building on the Mac

```bash
brew install cmake ninja molten-vk vulkan-loader   # plus Xcode 16 or newer
./tools/setup-macos.sh      # fetch + patch + build the SDK (Xcode clang, arm64)
mkdir -p game && cp /path/to/your/WWE13/default.xex game/
./tools/codegen.sh          # recompile your default.xex
./tools/build-macos.sh
```

### Smoke test without game files

`rex_smoke` (built with the tests) opens a window through the platform backend, presents with
Vulkan (MoltenVK on Apple) and draws an ImGui overlay over a moving test pattern. It also reserves
the real guest memory layout and triggers MMIO traps, the path that raises SIGBUS on Darwin. It
shows window size, DPI, fullscreen state, frame rate and recent input events.

```bash
brew install molten-vk vulkan-loader
./tools/build-ppc-binutils-macos.sh      # PowerPC as/ld/nm with VMX128, into ../tools/ppc-binutils-vmx128
REXGLUE_TESTS=1 PPC_BINUTILS_DIR=$PWD/../tools/ppc-binutils-vmx128/bin ./tools/setup-macos.sh
../tools/rexglue/out/build/macos-arm64/tests/bin/RelWithDebInfo/rex_smoke              # interactive
../tools/rexglue/out/build/macos-arm64/tests/bin/RelWithDebInfo/rex_smoke --smoke_seconds=10  # prints PASS/FAIL
```

F or F11 toggles fullscreen, and Esc quits. A smooth sweeping bar and visible white borders on all four
edges mean presentation and Retina scaling are right.

### First native build (patch 0106)

Built on a Mac for the first time (Xcode 27.2, macOS 27, Apple A18 Pro). Patch 0106 has the compile
and link fixes:

- **Linking:** FFmpeg exports through ld64's `-exported_symbols_list` (ld64 has no `--version-script`).
  The tests link `rexsystem` directly on Apple, because CMake has no `$<LINK_GROUP:RESCAN>` for ld64.
- **libc++:** Apple's libc++ has no `std::move_only_function` and no `std::chrono::clock_cast`.
  `rex::move_only_function` and `rex::chrono::clock_cast` replace them on every platform. The first is
  the standard type where the library has it.
- **Darwin code that 0104 missed:** the `mach_vm_region` helpers in `memory_posix.cpp` were inside
  `#if REX_PLATFORM_LINUX`; the `*64` file functions; `getpagesize`; macOS library names (the Vulkan
  loader is also looked for next to the executable, in an app bundle and in the Homebrew prefix);
  the RenderDoc header; socket headers and `select`; `endian.h`; and `std::min`/`max` calls that mix
  `size_t` and `uint64_t`, which are different types on Darwin.

Results on the Mac:

| Test | Result |
| --- | --- |
| `rex_smoke --smoke_seconds=10` | **PASS**: SDL3 window, MoltenVK on the Apple GPU, Retina 2560x1440 at about 300 fps; guest memory reserved at `0x8000000000`, MMIO read and write traps fire (SIGBUS path) |
| `unit_tests` | 191 cases: 186 pass, 5 skipped, 0 fail (with 0107; before it, 6 to 10 failed in guest memory) |
| `ppc_tests` | **1464 test cases, all pass** natively (with 0108 and the VMX128 assembler below) |

### 16 KB host pages (patch 0107)

Apple silicon uses 16 KB pages, but most guest heaps use 4 KB pages. `mprotect` on a 4 KB-aligned
address that is not 16 KB-aligned fails, so 4 KB `BaseHeap::Alloc` and `Protect` calls failed.
Linux ARM64 under qemu used 4 KB pages, so step 1 did not show it.

With 0107, when one host page holds several guest pages, the page table keeps the exact 4 KB
protection (what the guest sees through `QueryProtect`, old-protection values and so on), and each
host page gets the most permissive protection of the committed guest pages inside it. Alloc, Protect,
Release (with `protect_on_release`), Save and Restore all go through this. Physical heaps keep
write-watched host pages read-only, so committing a neighbouring guest page does not drop a GPU
write watch. Heaps whose page size is at least the host page size (every heap on Windows and on
4 KB-page Linux) are unchanged.

The trade-off: a no-access or read-only 4 KB guest page that shares a 16 KB host page with a more
accessible committed page does not fault on the host. That only matters for a game that relies on a
4 KB guard page next to live data. The unit tests check protection bookkeeping and the recovery
callback, not real hardware faults on such pages, so watch for this when booting the game.

### PowerPC test assembler and function aliases (patch 0108)

The instruction tests assemble with `-mvmx128` (Xbox 360 VMX128), which upstream binutils does
not have. The SDK's bundled assembler is GNU binutils 2.24 with Xenia's VMX128 patch, but only for
x86-64 Linux and Windows. `tools/build-ppc-binutils-macos.sh` builds the same thing natively for
macOS: binutils 2.24 (checksum-verified) plus Xenia's patch, kept in
`tools/ppc-binutils/binutils-2.24-vmx128.patch`. Binutils 2.24 predates Apple silicon and Xcode's
current C defaults, so the script gives the build triple explicitly and compiles as gnu89 with those
errors relaxed. The macOS CI job uses the same script.

With that assembler, the tests then failed to compile with "aliases are not supported on darwin".
Codegen emitted every recompiled function as a weak alias `X` of `__imp__X`, so that a hand-written
`PPC_FUNC(X)` can replace it, and Mach-O has no symbol aliases. That would have broken every game
build on Apple too. With 0108, codegen emits `PPC_FUNC_ALIAS(X)`: the same alias as before on
Linux and Windows, and on Apple a weak `X` that tail-calls `__imp__X` (`[[clang::musttail]]`, so a
jump, not an extra call). A strong hand-written `X` still replaces it at link time.

### Launcher

The launcher (`launcher2/`, SDL3 + Dear ImGui) is built by `tools/build-macos.sh` together with the
game. The script puts both, with the game's FFmpeg libraries, in `out/macos-arm64/`, the same layout
as the Linux release folder:

```bash
./tools/build-macos.sh
out/macos-arm64/wwe13-launcher
```

**Play** starts `./wwe13` from the launcher's folder with `posix_spawn`, as on Linux; settings,
`userdata` and `logs` live there too. Put the game folder at `out/macos-arm64/WWE 13`, or pick it on
the Game files page. Rebuilding replaces only the launcher, the game and the two libraries.

Mac fixes:

- `core/internal/miniz_impl.c` defined `_LARGEFILE64_SOURCE` on every platform, which made miniz call
  glibc's `fopen64`/`stat64`; Darwin does not have them. Skipped on Apple, where the plain functions
  are already 64-bit.
- `core/gpus.cpp` found no GPU, so the Play page said "THIS PC CAN'T RUN IT" and refused to start:
  volk only dlopens bare names (not Homebrew's `/opt/homebrew/lib` or an app bundle), and MoltenVK is
  a portability driver that is only listed when the instance enables
  `VK_KHR_portability_enumeration`. On Apple the launcher now also tries the game's loader paths and
  enables portability enumeration; it lists the Apple GPU with the same ID the game uses.

Checked by running the launcher's own `BuildLaunchPlan` + `StartGame` (what Play calls): the game
started from `out/macos-arm64/` with the chosen game folder and was still running after the
20-second early-exit watch.

### First game boot (patches 0109–0115)

Codegen and the game build work on the Mac (72,827 functions; codegen takes about 40 s). The game
boots to the attract-mode demo match and the menus, with sound and input. To get there:

| Problem | Fix |
| --- | --- |
| `timer_queue.cpp` does not compile with Xcode 16 (libc++ 19 hides `std::jthread`) | 0109: `std::thread` plus a stop flag |
| Most game sources fail: `#include <version>` finds the repository's `VERSION` file (case-insensitive file system) | 0113: on Apple the project root is searched with `-iquote` only |
| The game cannot load FFmpeg: the dylibs were copied under their full version names, not the `@rpath` install names | 0113: copy under the install names, as on Linux |
| Crash handler: Darwin's PC is an integer, and `pthread_setname_np` takes only a name | `src/release_diagnostics.cpp` |
| Vulkan device rejected: Apple GPUs have no geometry shaders | 0115: `vulkan_require_geometry_shader` defaults to false on Apple (the SDK's fallback paths) |
| **Black screen: startup deadlock** on a critical section with a lock count but no owner | 0110: recompiled code did not add the 0x1000 host offset for the 0xE0000000 heap on Apple silicon, so guest code and the kernel saw that heap 4 KB apart. Now on for Apple arm64, with a startup check that both sides agree |
| Purple screen: the rectangle-list fallback vertex shader was invalid SPIR-V and used a `gl_PerVertex` local that SPIRV-Cross cannot declare in MSL | 0111. All 13 shaders seen convert and compile with the Metal compiler |
| A failed pipeline was recompiled and logged on every draw | 0112: failed pipelines are remembered; `--dump_shaders` now works for Vulkan |

Running it (from the build folder; the launcher passes the same options):

```bash
./wwe13 "/path/to/WWE 13" --fullscreen=false --ignore_offset_for_ranged_allocations=true \
  --mnk_mode=true --user_data_root=$PWD/userdata
```

**Window froze on the loading screen (0114).** The game kept running (demo match, crowd and
commentary audio, menus, input) but the window stayed on the loading screen. The presenter requests
paints from the guest-output thread, and the SDL backend's per-window "paint pending" flag was an
unguarded map the UI thread clears on dispatch; a request racing a dispatch was dropped, and the
presenter (which also dedups pending paints) never painted again. The flags are now guarded.

With 0114 the game boots through the logo video and the loading screen to the attract-mode demo
match ("Press START button"); Start leads to the save-data notice. Loading is slow: the demo match
appears about 2 minutes after launch.

Not problems, though they look like them in the log:

- `NtCreateFile FAILED: GAME:\Sound\English(US)<bank>.bnk`, repeated: Wwise tries a language-specific
  loose file first each time it reopens a bank to stream media, then finds the bank in the `sfx`
  table of the `.pck` packages. Every bank loads.
- Bursts of failed physical allocations: the game probing free memory, as on Linux (patch 0038).

### Known gaps

- Freeze reports on Apple have no host backtraces, per-thread CPU time or thread state.
- No `.app` bundle yet (the launcher is started from Terminal or Finder as a plain executable), and
  the launcher is not built in CI.
- iOS: `shm_open` is not allowed in the app sandbox, so guest memory needs Mach memory entries
  (`mach_make_memory_entry_64` + `vm_map`), and the ~8 GB layout needs the extended virtual
  addressing entitlement.

## Planned next steps

- **Step 2 – macOS (Apple Silicon):** add the Apple platform to the SDK build, port items 2–4 for Darwin, and
  use a window via SDL3/Metal layer with MoltenVK. Run codegen and boot the game on the MacBook to measure
  graphics compatibility.
- **Step 3 – iOS / iPadOS:** add an Xcode/CMake iOS target, entitlements, file import through the Files app,
  controller support and touch controls, and a GitHub Actions macOS job that builds an unsigned IPA for
  sideloading.
- **Step 4 – performance tuning on the iPad mini.**
