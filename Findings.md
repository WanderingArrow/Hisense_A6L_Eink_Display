## How Hisense Wired Up the Dual-Screen Touch/Display Stack

This section documents the mechanism, reverse-engineered across kernel, HAL, and framework layers. It's ordered as "what we ruled out" then "what's actually happening," since the dead ends are as useful to a future contributor as the answer.

### Driver Architecture: One Driver Source, Two Instances

Both touch controllers - the front LCD's and the rear E-ink's - are driven by the _same_ FocalTech driver source (`ft5x06_ts`), instantiated twice with different I2C addresses and log tags:

- Front panel: I2C address `4-0038`, logs as `TP-ft8xxx-ts`, IRQ 288 on GPIO 67
- Rear panel: I2C address `7-0038`, logs as `TP-ft5x06-ts`, IRQ 294 on GPIO 73

Both IRQs are permanently, independently registered from boot - there is no runtime handover or muxing between them. Kconfig confirms them as genuinely distinct driver instances rather than a shared/static-state bug:

```
CONFIG_TOUCHSCREEN_FT5X06_SUB=y      # rear (secondary) instance
CONFIG_TOUCHSCREEN_FT8XXX=y          # front (primary) instance
CONFIG_FT8XXX_INCELL_CHIP=y
```

###  Dead End: fb_notifier / Kernel Notifier Chain

Initial hypothesis was that the rear driver's `fb_notifier` callback (the standard Linux mechanism a touch driver uses to learn when its display blanks/unblanks) was either mis-registered or listening on the wrong framebuffer index - a classic copy-paste bug.

Disproven directly: toggling `/sys/class/graphics/fb0/blank` and `fb1/blank` manually while watching dmesg showed the rear driver's notifier callback **never fires at all**, on either framebuffer, under any condition. Only the front controller's callback ever logs. This rules out "wrong index," since a wrong-index bug would still show the _rear_ driver's tag firing on the _wrong_ screen's blank event - instead it simply never fires.

This kernel is also built without dynamic tracing (`CONFIG_KPROBES`, `CONFIG_FUNCTION_TRACER`, `CONFIG_PROBE_EVENTS` all disabled), which ruled out confirming this further via ftrace/kprobes on a custom GSI kernel.

###  Dead End: Full Java Framework Trace (six classes, confirmed stock)

Suspecting Hisense patched Android's own display-power path, the entire chain was deodexed (`baksmali` against `services.odex`/`boot.oat`, Android 9 stock, API 28) and traced by hand from the top:

```
PowerManagerService.wakeUp()
  -> Notifier.getSleepingForEpdProject() / setSleepingForEpdProject()   [flag bookkeeping only]
  -> DisplayPowerController                                            [brightness/sensor profile swap only]
  -> DisplayManagerService.requestGlobalDisplayStateInternal()
       -> applyGlobalDisplayStateLocked()                              [iterates all displays uniformly]
  -> LocalDisplayAdapter$LocalDisplayDevice.requestDisplayStateLocked()
  -> LocalDisplayAdapter$LocalDisplayDevice$1.run()
       -> SurfaceControl.setDisplayPowerMode(token, mode)               [terminal AOSP call]
```

Every one of these six classes is **unmodified stock AOSP**. No Hisense branching, no EPD-specific logic, anywhere in the Java framework. This was a genuinely useful negative result - it means none of this needs porting or patching for a custom ROM; it already behaves identically to stock.

###  The Actual Mechanism: Native surfaceflinger + a plain sysfs node

The real logic lives in Hisense's **patched native `surfaceflinger` binary** (`/system/lib64/libsurfaceflinger.so`), not in Java at all. Confirmed via `strings`:

```
setDisplayType:in type=%d, to hal type=%d, mHwcFlagTmp=%d
setEpdMode=%d
connectEpdDisplay=%d
```

These are custom binder-callable methods compiled directly into surfaceflinger, invoked from Java's `EpdManagerService` via a Hisense-specific `SurfaceControl`/`ISurfaceComposer` binder extension (`SurfaceFlinger: setEpdMode=3` visible in logcat). This explains why the Java-layer trace above came up clean: the actual EPD-aware code isn't Java at all, and doesn't touch any of the classes a framework port would normally target.

Critically, **the touch wake-up is not done via any binder/HAL call** - it's a plain sysfs write, confirmed by directly stracing the surfaceflinger process while flipping the device:

```
openat(AT_FDCWD, "/sys/ctp1/ctp_func/tpenable", O_RDWR)
write(fd, "1\n", 2)     // or "0\n" to disable
```

`surfaceflinger` wakes/sleeps the rear touch controller by writing `1`/`0` directly to `/sys/ctp1/ctp_func/tpenable`, alongside its `epd_display_type`/`epd_display_mode` writes for the panel itself. This is the single sysfs write that solves the entire "rear touch never wakes on GSI" problem - no binary swap, no framework port, no HAL work required to replicate it.

Confirmed independently and repeatably:

```sh
echo 1 > /sys/ctp1/ctp_func/tpenable
getevent -l /dev/input/eventN     # rear touch node - find via `getevent -pl`
```

produces immediate, clean multitouch (`ABS_MT_POSITION_X/Y`, `BTN_TOUCH`) events.

###  Sysfs Node Reference (fb1 = rear E-ink panel)

All confirmed present and functional on both stock Android 9 and the LineageOS 18.1 GSI - these are kernel-driver-exposed nodes, independent of which surfaceflinger binary is running.

| Node                                           | Purpose                                                                               | Notes                                                                                                              |
| ---------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `/sys/ctp1/ctp_func/tpenable`                  | Rear digitiser enable                                                                 | `1`/`0`. **The core discovery** - not gated by any framework/HAL path.                                             |
| `/sys/ctp1/ctp_func/gesture`                   | Gesture wake config                                                                   | Untested                                                                                                           |
| `/sys/ctp1/ctp_func/gesturefingers`            | Gesture finger count                                                                  | Untested                                                                                                           |
| `/sys/ctp1/ctp_func/gesturepos`                | Gesture position data                                                                 | Untested                                                                                                           |
| `/sys/ctp1/ctp_func/glove`                     | Glove mode                                                                            | Untested                                                                                                           |
| `/sys/ctp1/ctp_func/hall`                      | Hall sensor (flip detection?) link                                                    | Untested                                                                                                           |
| `/sys/ctp1/ctp_func/irqawake`                  | IRQ wake config                                                                       | Untested                                                                                                           |
| `/sys/ctp1/ctp_func/tp_work_mode`              | Touch panel work mode                                                                 | Untested                                                                                                           |
| `/sys/ctp1/ctp_func/tptypeswitch`              | Likely front/rear panel type selector                                                 | Untested                                                                                                           |
| `/sys/class/graphics/fb1/blank`                | Standard fbdev blank (`0`=on, `4`=off)                                                | Necessary but not sufficient alone - panel stays in MDSS-level `suspend` per `msm_fb_panel_status` even after this |
| `/sys/class/graphics/fb1/epd_connect`          | **Actual panel wake trigger.** `echo 1` brings `msm_fb_panel_status` out of `suspend` | The missing piece `blank` alone doesn't provide                                                                    |
| `/sys/class/graphics/fb1/msm_fb_panel_status`  | Read-only panel state (`suspend`/active)                                              | Diagnostic - confirms whether `epd_connect` actually worked                                                        |
| `/sys/class/graphics/fb1/epd_display_mode`     | Refresh waveform mode                                                                 | Only 2 of likely many modes identified so far                                                            |
| `/sys/class/graphics/fb1/epd_commit_bitmap`    | Commits pending framebuffer content to panel                                          | `echo 1`                                                                                                           |
| `/sys/class/graphics/fb1/epd_force_clear`      | Forces a full refresh/ghosting clear                                                  | Purpose-built alternative to faking a touch event to force a redraw                                                |
| `/sys/class/graphics/fb1/epd_contrast`         | Contrast                                                                              | Stock default: `0`                                                                                                 |
| `/sys/class/graphics/fb1/epd_black_threshold`  | Black-point threshold                                                                 | Stock default: `30`                                                                                                |
| `/sys/class/graphics/fb1/epd_white_threshold`  | White-point threshold                                                                 | Stock default: `23`                                                                                                |
| `/sys/class/graphics/fb1/epd_vcom`             | Panel VCOM calibration                                                                | **Likely fine at stock value - changing could possibly damage the screen.**                            |
| `/sys/class/leds/epd-backlight/brightness`     | Rear frontlight                                                                       | Scale `0`-`255`                                                                                                    |
| `/sys/class/leds/epd-backlight/max_brightness` | Frontlight max value                                                                  | Read-only                                                                                                          |

Input nodes (device names vary by boot, confirm via `getevent -pl`):

|Device name|Purpose|
|---|---|
|`qpnp_pon`|Power key (`KEY_POWER`) - shares node with `KEY_VOLUMEDOWN`|
|(flip sensor, unnamed in this dump)|Flip/E-ink button - `KEY_LEFT_UP`, keycode `616`|
|`proximity_extend_back_1`|Rear proximity sensor (`ABS_DISTANCE`) - probed but did not report live values in testing; likely needs its own enable node, not yet found|
|`light_extend_back_1`|Rear ambient light sensor (`ABS_X`, `ABS_MISC`) - same as above, present but silent|

###  Open Problem: Refresh Quality / Waveform Modes

Only two `epd_display_mode` values have been empirically identified:

- `6` - full flash / clear ghosting, confirmed smooth/clean
- `3` - partial refresh, confirmed visibly jerky/smeary; matches stock's own `"reading"` mode name from logcat (`set e-paper mode:reading:3`) - likely a fast, low-greyscale mode being used where a fuller mode is needed
- `2` - also tested, also jittery/smeary in practice despite being logged as `"picture"` mode on stock (`set e-paper mode:picture:2`) - unclear why this underperforms mode 6 in testing so far

Standard E Ink waveform terminology (GC16/GL16/DU/A2, roughly full-greyscale-slow through binary-fast) strongly suggests Hisense's integer values map onto a larger, undocumented mode table than the two number found through observed logcat output. `epd_vcom` (panel calibration voltage) is also a strong suspect for contributing to the smearing/ghosting observed - VCOM is normally factory-calibrated per physical panel unit, and an incorrect value produces exactly this symptom regardless of which waveform mode is active.

**This is the main open technical problem for anyone picking this project up**: enumerating the true `epd_display_mode` range and confirming whether `epd_vcom` is being read/applied correctly under the GSI would likely fix the remaining image-quality issues outright.

###  Open Problem: Lockscreen / Live Compositing

Powering the rear panel via the mechanisms above does **not** get you live, interactive content on it - only whatever frame was last committed. `dumpsys SurfaceFlinger` confirms the rear display exists as a real, hotplugged display device (`hwcId=1`, `powerMode=2`) with its own independent `layerStack`, entirely separate from the primary display's - meaning Android's window manager has no default routing of any content (lockscreen or otherwise) onto it. Stock Hisense solves this via `EpdManagerService` explicitly bitmap-compositing content onto the EPD framebuffer through custom surfaceflinger binder methods; a GSI has no equivalent path.

Directions worth exploring for a future contributor:

- Getting the rear display onto the _same_ layerStack as the primary (display mirroring), so lockscreen/UI content composites there automatically
- A cruder stopgap: `screencap` the current frame before switching/locking and `dd` it directly into `/dev/graphics/fb1` for a static (non-interactive) image
