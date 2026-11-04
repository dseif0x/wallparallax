# WallParallax

A native macOS menu-bar app that turns your desktop wallpaper into a 3D "window": it tracks your head with the camera and shifts layered wallpapers so near and far elements move at different speeds (head-coupled parallax).

## Features

- **Head tracking** with the built-in camera and Vision face detection, smoothed with a 1€ filter and interpolated to the display's refresh rate.
- **Built-in scenes**, drawn as vector layers so they're sharp at any resolution: *Mountains at Dusk*, *Deep Space*, *Bokeh Orbs*.
- **Photo + Depth Map**: real per-pixel 3D. A Metal mesh is displaced by a grayscale depth map (white = near), so every pixel moves according to its own depth. The depth map can be:
  - a file you pick,
  - a sibling file named like `photo_depth.png` / `photo-depth.png` (found automatically),
  - the depth embedded in iPhone **Portrait mode** photos (HEIC/JPEG), used automatically.
  - **AI depth estimation** for any other photo, on-device, with Apple's Core ML build of [Depth Anything V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small) (Apache-2.0). Click *Download model (48 MB)* once.
  - **Apple Depth Pro** as an optional *High quality* model: much sharper object edges, using the [Core ML conversion](https://huggingface.co/coreml-projects/DepthPro-coreml-normalized-inverse-depth-pruned-10-quantized-linear) (744 MB). The first install takes a few minutes while macOS prepares the model; after that, a photo takes about 15 s. It's under Apple's research license (personal, non-commercial use only).

  Models live in `~/Library/Application Support/WallParallax`. Estimated depth maps are cached there too, so each photo is processed only once per model.

  Depth maps from tools like Depth Anything or MiDaS work as-is. Use *Invert depth map* if near shows up as dark. If no depth is available, the photo falls back to the subject cut-out mode below.
- **Photo (auto 3D)**: pick any photo. Vision cuts out the subject, the hole behind it is filled in, and the subject floats in front of the background.
- **Custom Layers**: pick several transparent PNGs. They're sorted by file name, with the first one farthest back.
- Lean in to zoom, intensity and smoothing sliders, recenter, auto-recenter, multi-monitor support, and launch at login.
- The camera turns off when the wallpaper is disabled, the screen sleeps, or the Mac is locked.

## Build & run

Requires macOS 14+ and Xcode / the Swift toolchain.

```sh
./build.sh            # builds build/WallParallax.app (ad-hoc signed)
open build/WallParallax.app
```

Grant camera access when asked. The app lives in the menu bar (cube icon). Copy it to `/Applications` if you want to use *Launch at login*.

> Because the build is ad-hoc signed, macOS may ask for camera permission again after a rebuild.

## How it works

- `WallpaperWindow` is a borderless, click-through window at desktop level on every screen. It sits above the system wallpaper and below the desktop icons.
- Each scene is a stack of `DepthLayer`s. Depth `1` is far away and moves the most with your head, like the view through a real window. Depth `0` sits at the screen plane and stays put.
- Depth photos are drawn by `DepthRenderer`: a 240-column grid mesh whose vertices sample the depth map in the vertex shader. Depth is slightly dilated and blurred first, so depth edges stretch the background instead of tearing the subject. It only redraws when your head moves.
- `HeadTracker` maps the face's position and size in the camera frame to an x/y/z offset from a calibrated neutral pose.

## Dev

`WallParallax --snapshot <dir> [--photo <image>] [--model depthAnything|depthPro] [--install-model] [--depth-photo <image> [--depth-map <map>]]` renders each scene at a few head positions to PNGs without using the camera. With `--photo`, it also writes the photo's foreground and background layers. With `--depth-photo`, it writes the processed depth map and depth-mesh renders.
