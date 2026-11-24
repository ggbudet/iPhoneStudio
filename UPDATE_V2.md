# iPhone Studio v2

Replace the files in the existing GitHub repository with the files in this archive, commit and push. Keep the .git directory. Wait for a successful Actions build and install the new IPA with Sideloadly. Close the old Windows client and launch Windows/Start.bat from the updated folder. Both sides must be version 2.

The preview now uses VideoToolbox H.264, a persistent USB-forwarded TCP connection, length-prefixed Annex B access units and PyAV decoding. Default requested capture: 1080p60. Preview is capped at 1920 pixels on the longer side. Recordings are still made on the phone and copied to PC after Stop. Apply settings before recording. The displayed FPS is measured on PC, not a promise of capture performance. The preview drops frames under congestion and reconnects after disconnection. A 4K capture mode may reduce actual preview throughput. Audio is included in recordings if microphone permission is granted, not in the live preview.

Validation: Python syntax and Swift parser passed on Linux. Full iOS SDK compilation and physical USB testing require GitHub Actions and an actual device. If Actions fails, send the first compiler error from the build log. If preview is slow, report both displayed FPS counters and capture settings.
