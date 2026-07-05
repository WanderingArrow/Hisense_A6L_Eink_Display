# Hisense_A6L_Eink_Display
# Introduction

This repository contains my findings from attempts to make the secondary E-ink panel usable on the Hisense A6L when running a custom ROM such as LineageOS 18.1 GSI. I've worked out how to get the e paper display to wake and to enable the digitiser, but getting this to the finishing line and making a polished implementation is beyond my ability right now, so I'll leave this up for anyone who wants to take it further. I've also included a shell script I was able to make that allows for a facsimile of the e ink flipping process, however currently it's very buggy and regularly crashes the phone -be careful, it's not suitable for daily use. To use it, you just press the e ink button to switch between both screens.
**Disclaimer: This project was done with heavy use of Gemini and Claude - I'm not a programmer, just someone who enjoys learning and using e-readers. Thus, there may be some inaccurate information below, and a risk of damaging your device permanently.**
## Current Project Status
- [x] Rear panel initialization & hardware connection (`epd_connect`)
- [x] Rear digitiser/touch panel activation (`tpenable`)
- [ ] Smooth refresh rates / E-ink waveform mode optimization (currently suffers from ghosting/smearing)
- [ ] A UI to adjust display mode, contrast, etc
- [ ] E-ink side lockscreen functionality
- [ ] Automation script stability (currently experimental and prone to system crashes)

## [See Findings.md for the full technical writeup.](https://github.com/WanderingArrow/Hisense_A6L_Eink_Display/blob/main/Findings.md)
## Prerequisites & Rooting

Before deploying this test script, your Hisense A6L must be running an Android 11 GSI with active root privileges. Please refer to [tombaczynski's Hisense-A6L repository](https://github.com/tombaczynski/Hisense-A6L) for a guide on unlocking the bootloader and patching the initial boot image if you use Magisk.

## Core Environment & GSI Target

- **CPU Architecture:** `arm64-v8a` (64-bit Qualcomm Snapdragon 660 platform).
    
- **Partition Structure:** System-as-Root (SAR) is `true`.
    
- **Target GSI Flavour:** **`arm64_bgS-vndklite`** The scripts in this repository were tested on Andy Yan's lineage-18.1-20240121-UNOFFICIAL-arm64_bgS-vndklite.img. This can be found [here]([Download lineage-18.1-20240121-UNOFFICIAL-arm64_bgS-vndklite.img.xz (Andy Yan's personal builds // GSI)](https://sourceforge.net/projects/andyyan-gsi/files/lineage-18.x/lineage-18.1-20240121-UNOFFICIAL-arm64_bgS-vndklite.img.xz/download)). 
  
    
- **Absolute OS Ceiling:** **Android 11 (API 30)**. Due to the introduction of the Rust-based `keystore2` architecture in Android 12+, the legacy HIDL Keymaster 3.0/4.0 implementation on the Android 9 vendor partition triggers an unrecoverable VINTF manifest mismatch and system-server crash. Android 11 is the hard cryptographic ceiling for using a GSI.



## How to Deploy the Test Script
Because this script interacts directly with low-level kernel display nodes, it requires full root privileges via either Magisk or the recommended GSI.

1. **Enable USB Debugging as root on the phone, in Developer Options**

2. **Push the script to a volatile staging directory:**
    
    Bash
    
    ```
    adb push epd_switch.sh /data/local/tmp/epd_switch.sh
    ```
    
3. **Open a root shell on the device:**
    
    Bash
    
    ```
    adb root
    adb shell
    ```
    
4. **Windows Line-Ending Fix:**
    
    If you cloned or downloaded this repository on a Windows machine, Git may have appended hidden carriage return characters (`\r`) to the line endings. This will cause the Android shell to throw parsing errors. Run `sed` to sanitize the file before executing:
    
    Bash
    
    ```
    sed -i 's/\r//' /data/local/tmp/epd_switch.sh
    ```
    
5. **Grant execution permissions and run:**
    
    Bash
    
    ```
    chmod +x /data/local/tmp/epd_switch.sh
    sh /data/local/tmp/epd_switch.sh
    ```
