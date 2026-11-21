# DS-10 Sample Injector

Please note: Artificially Assisted Software.

Turn the four synthesised drums of the **Korg DS-10** (Nintendo DS) into **sample players**: up to 128 of
your own sounds in one ROM, picked per drum with five knobs in the drum editor. It supports looping, and
looped sounds get an attack / hold / fade envelope.

**[Open the injector](https://cold-inferno.github.io/ds10-sample-injector/)**. It runs entirely in your browser; nothing is
uploaded. You can also download `index.html` and open it offline.

## What you need

- **Your own DS-10 ROM**, dumped from your own cartridge. This project doesn't include or link to any ROM.
  Supported versions:
  - Europe (`YJ9P`)
  - USA (`YJ9E`)
  - Japan (`YJ9J`)

  The DS-10+ isn't supported (yet).
- **Sounds:** WAV works best; most other audio formats work too. Each sound becomes mono 32,768 Hz and is cut
  to 1 second.
- A flashcard or emulator to play the result. Tested on a Nintendo DSi with an R4 card and in melonDS.

## How to use it

1. Drop your DS-10 ROM on the page. It tells you which version it found.
2. Drop your sounds. A file named `001 kick.wav` goes to place 1; anything else fills the next free place.
   You can move sounds around and rename them in the grid.
3. Click **Build ROM**. You get the patched ROM and a cheat sheet as downloads.

Your saves stay compatible: the patched ROM uses the normal DS-10 save format.

## On the DS

In the drum editor, five controls pick the sample (the cheat sheet shows the full grid):

| Control | Positions | Picks |
|---|---|---|
| VCO1 waveform | Triangle, Saw, Square, Noise | the group (×32) |
| VCO2 waveform | Triangle, Saw, Square, Noise | the row (×8) |
| BALANCE | left half / right half | ×1 |
| VCO2 PITCH | left of centre / centre and right | ×2 |
| SYNC | off / on | ×4 |

**Loops:** a WAV with loop points (a `smpl` chunk, which most samplers write) loops on the DS. For looped
sounds:

| Knob | Effect | Range |
|---|---|---|
| EG ATT | fade-in | 0 = instant … 127 ≈ 4 s |
| EG SUS | hold time | 0–126 ≈ 0–12.6 s; 127 = forever |
| EG DEC | fade-out | 0 = instant … 127 ≈ 4 s |

The DS-10 sends no note-off for drums, so a sound with EG SUS at 127 plays until the next hit or until you
stop playback. Pitch per step works as usual in the drum sequencer.

## Known issues

- Loops longer than about half a second, ending after the first second, are shortened with a crossfade so
  they fit in a drum slot.
- The other drum knobs do nothing in the patched ROM. One-shot sounds ignore EG ATT/SUS/DEC.

## How it works

The DS-10 renders each drum patch into a 1-second sample slot in memory and plays that slot. The patch
replaces that rendering with "load sample *n* from the ROM", where *n* comes from the drum's knobs. It adds
looping and an envelope in the sample player, and makes the drum editor's preview play the sample. The full
story, with every change to the ROM, is in [`docs/`](docs/). The patch source is in [`patch/`](patch/).

## License

[PolyForm Noncommercial 1.0.0](LICENSE): free to use, study, modify and share, but not for commercial use.
Korg DS-10 is a trademark of Korg Inc.; this project is not affiliated with Korg or Nintendo.
