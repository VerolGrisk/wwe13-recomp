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
and PowerPC tests). It is in the ReXGlue patch series after 0103.

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
REXGLUE_TESTS=1 PPC_BINUTILS_DIR=/path/to/ppc-binutils/bin ./tools/setup-macos.sh
../tools/rexglue/out/build/macos-arm64/tests/bin/RelWithDebInfo/rex_smoke              # interactive
../tools/rexglue/out/build/macos-arm64/tests/bin/RelWithDebInfo/rex_smoke --smoke_seconds=10  # prints PASS/FAIL
```

F or F11 toggles fullscreen, and Esc quits. A smooth sweeping bar and visible white borders on all four
edges mean presentation and Retina scaling are right.

### Known gaps

- Not yet built on a Mac: expect a first round of compile fixes from the CI job.
- Freeze reports on Apple have no host backtraces, per-thread CPU time or thread state.
- The launcher (Windows/Linux) is not ported; on macOS the game is started from Terminal for now.
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
