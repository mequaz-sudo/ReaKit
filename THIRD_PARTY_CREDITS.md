# Third-Party Credits

ReaKit stands on the shoulders of the REAPER JSFX community. The knob and
button styles listed below derive from other authors' work and are included
here alongside EON Studios' original code (MIT — see LICENSE). Huge thanks to
all of them.

---

## Analog VU (`rk_vu.jsfx-inc`)

Original EON Studios code, written clean-room in 2026 to replace an earlier
port of ZenoMOD's VU meter that shipped in versions before 1.3.0. Nothing in
it is copied from another plugin: the movement is a damped second-order system
whose two constants were solved against the VU standard's step response, and
the scale is computed every frame from the physics of a VU (a needle that is
linear in rectified amplitude, so each dB mark sits at 10^(dB/20)). That same
equation appears in Lubomir I. Ivanov's 2009 tutorial "Designing an analog VU
meter in DSP", which is acknowledged here as the published reference for it.

## Knob styles (`knobs_kbsg.jsfx-inc`)

- **BirdBird** — the look of the rainbow-arc knob (style 9), after his Very
  Important Compressor. ReaKit 1.5.3 and earlier carried a few lines of his
  drawing code; the knob has been EON Studios' own code since September 2026.
- **Joanny / MacFizz** — the blue pot knob (style 6).
- **Spice Pro** — the blue arc-fill knob (style 10).
- **Witti Sound** — the clean arc + dot knob (style 4).

## Button styles (`buttons_kbsg.jsfx-inc`)

- **Joanny** — the green checkbox style.
- **Spice** — the segmented-bar selector style.

## The free effects

They have their own repository since 2026-09-28,
[ReaKit FX](https://github.com/mequaz-sudo/ReaKit-FX), and their credits went
with them: Saturation, 3-Band EQ and DDC by Michael Gruhn (LOSER), the
De-Esser's crossover and peak compressor by Lubomir I. Ivanov (Liteon), each
under its author's terms; GainKit by EON Studios (MIT). See that repository's
`LICENSE.md` and `THIRD_PARTY_CREDITS.md`.

---

All remaining widgets — including the hardware-inspired knob styles (SSL, Neve,
API, Pultec, Vari-Mu, MPC, Ableton, Pro Tools, FabFilter, Serum, Roland,
encoders, jog wheels and both 2026 additions), the full slider/fader library,
the remaining buttons, the analog VU and all of the meters DSP/drawing — are original
EON Studios code, drawn from hardware reference photos, not from other plugins'
source.
