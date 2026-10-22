# Plush mascot clips

Drop-in pipeline (green-screen 1:1 clip, first frame = last frame):
1. Box: `python3 matte_green.py <pose> <clip.mp4> frames/<pose>` → 72 × 96px RGBA PNG (last frame dropped for a seamless loop; add `--pingpong` when the clip end ≠ start).
2. Mac: `swift encode_hevc_alpha.swift frames/<pose> ../../Resources/Mascot/Mascot<Pose>.mov 24 0.5`
3. Add the .mov to the cat Resources build phase (pbxproj). `PlushMascot` plays `Mascot<Pose>.mov` if it is bundled, else falls back to the static PNG.

Shipped clips: idle, thinking, executing (ping-pong), done, error. writing uses the static PNG + SwiftUI nod (generated writing clips were unusable).
