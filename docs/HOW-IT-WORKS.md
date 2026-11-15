# How the DS-10 Sample Injector works

This is the technical story behind the patch: how the Korg DS-10's drum engine was found, and every change
the injector makes to the ROM. Addresses are for the European ROM (`YJ9P`); the US and Japanese addresses are
in [`injector/versions/`](../injector/versions/), found automatically from the EU code by
`injector/find_addresses.py`.

The work was done with melonDS savestates (uncompressed, so main RAM can be read and compared), static
disassembly of the ARM9 code (`llvm-objdump`), armips for the patch, and debug builds that log events and
render calls inside the running game.

## 1. Finding the drum engine (V1.0)

The starting idea was that the DS-10 samples each drum patch and stores it in the save. To test that, three saves
were made on the cart: an empty one, one with a saved song, and the same song with one drum changed. Comparing them
byte by byte showed:

- A song occupies a **12 KB slot**. The first 16 bytes of a slot are an **MD5** of the rest
  (`slot+0x10 … slot+0x300C`).
- Changing one drum changed only **~9 bytes** of parameters plus the checksum. No audio.

So the save stores **settings only**.

### 1.2 The drums are rendered into RAM

melonDS savestates are uncompressed, and main RAM (`0x02000000`, 4 MB) starts at file offset `0x24`. Comparing a
state *inside* the drum editor with one *after leaving it* showed a 64 KB block that changed into audio-like
data. Saved as a WAV, it was the drum. The layout:

- **4 slots of 64 KB** at `0x0219F5B0 + n×0x10000`.
- 16-bit signed mono at **32768 Hz**, so at most 1 second per drum.
- The same addresses appeared in every boot.

Writing a WAV into slot 1 of a savestate (the "bubbles" test) showed that **the DS-10 plays the slot exactly as
it finds it**.

### 1.3 Finding the code

The melonDS GDB stub worked once and then refused connections, so the code was found by **static analysis**
(Apple's `llvm-objdump` on the ARM9 binary) combined with savestate data. The steps:

1. **The slot pointer** is stored in four objects at `0x02267E80 + n×0x2E0`. They are C++ objects (first word
   = vtable `0x02073038`): the **drum sample voices**.
2. **Their vtable** led to the playback routine (`0x02023968`) and to `setSample(ptr, len, note)`
   (`0x0202390C`).
3. **Calls to setSample** led to the two places where finished drum audio is copied into a slot.
   `CopyToSlot(renderer, slot, 32768)` lives at `0x0201E808` and is called from:
   - `0x02033194`: loading a session (loop over the four drums, index in `r9`)
   - `0x0205F02C`: leaving the drum editor (index in `r6`)
4. **For reading files**, the game's own Nitro SDK functions are used:
   - `FS_InitFile` `0x02008928`
   - `FS_OpenFile` `0x02008C08`
   - `FS_ReadFile` `0x02008D4C`
   - `FS_CloseFile` `0x02008C50`

   They were found where the game loads `/data/demo/ds10demo03.dat`.
5. **Free space for new code.** The ARM9 binary is uncompressed with no overlays. Its ITCM autoload block (fast
   on-chip code RAM at `0x01FF8000`, 32 KB) uses only `0x320` bytes. All three savestates showed the rest of the
   ITCM as zero.

### 1.4 First patched ROM: a fixed Amen kit

Both `CopyToSlot` calls were redirected to new code that reads `/data/amen/d1..d4.pcm` from the ROM into the slot.
It worked in melonDS immediately, but **didn't boot on the R4**.

The cause was ndstool's repacking, not the patch. A plain unpack and repack of the *untouched* ROM also failed to
boot. ndstool rewrites the header's ROM-control words (`0x60–0x67`) and the secure-area CRC (`0x6C`). Restoring the
cartridge's original values and recomputing the header CRC fixed it. The build does this automatically now.

### 1.5 The selector

To find which byte holds which knob, savestates were made with one control changed each and compared. Each drum
patch is **31 bytes**:

- **In RAM:** at `session + 0x5AA8 + n×31`, read by `0x0203A348`.
- **In a save or song file:** at `0x2B3C + n×31`.
- **The controls:** parameter 6 = VCO1 wave, 7 = VCO2 wave, 8 = VCO2 pitch (−63…+63), 9 = balance (0–127),
  10 = sync.

The loader computes the sample number from these five bytes and opens `/data/smp/NNN.pcm`.

### 1.6 The editor preview (the hard part)

Changing a knob reloads the slot (hooked in the editor's knob handler at `0x02032910`). Making the editor's
repeating preview *play* that slot took several test ROMs:

- **preview1 – no sound.** In the editor the pattern player stops. The DS-10 previews the edited drum on
  **synth voice 1**, retriggered by a small editor sequencer. A note-on sent to the sample voice did nothing.
- **preview2 – silence.** The plan: hook the synth voice's render (vtable entry 3) and overwrite its output with
  the sample voice. The synth went silent, which proved the hook worked, but the sample didn't play. The
  savestate showed the note-on never arrived, because the **event types** had been read one off. In ARM jump
  tables the target is the instruction address + 8. For both voice classes: **1 = note-off, 2 = note-on**
  (byte 4 = note, byte 5 = velocity; the editor sends `0x7F3C`).
- **preview3 – sound, but loud, truncated and "weird".**
- **preview4 – silent.** Rerouting the sample voice's output didn't work, because the game reconnects the voices
  every audio block.
- **The debug build** (`build_lib.py --debug`) counted calls inside the ROM. For every preview-synth render, the
  game made **four** sample-voice renders. So the game still renders all four drum voices in the editor, into
  channels the editor doesn't play. preview3 had rendered the edited drum a second time on top: 2× speed, with
  half of each block thrown away.
- **The editor's recorder** captures the preview, so it could be compared with the source sample. It showed the
  editor's chain amplifies synth 1's channel **~3.1×** relative to a sample voice's output, which made a full-scale
  sample clip.
- **The final version.** The hook lets the game render the sample voice (once per block, as normal) and
  **copies that finished block** into synth 1's channel, scaled by 81/256. Confirmed correct in sound and level.

---

## 2. Looping, the envelope and the editor preview (V1.1)

### 2.1 Looping

The sample voice's playback loop holds the position at the end of the sample (`0x02023A1C`, 5 instructions).
That spot now calls `LoopCheck`:

- **A looped slot** jumps back by the loop length.
- **Anything else** runs the original clamp.

The loop information travels in the sample file's header. On load, the first loop sample is also copied just
past the end, so interpolation across the wrap is clean on any note.

### 2.2 Attack, sustain and decay

**There is no note-off.** The event log showed that lifting a drum pad sends nothing, and neither does the
sequencer, so a looped sound needed its own way to end.

**The knob bytes.** Savestates with one knob changed each located EG ATT, EG DEC and EG SUS as patch
parameters 20, 21 and 22.

**The hook.** The sample voice's render (vtable entry 3) is now `SampleVoiceRender`, which runs for every drum
voice in every block. It drives the voice's own envelope object:

| Envelope field | Meaning |
|---|---|
| `+0x10` | state; state 2 makes the game leave the level alone |
| `+0x11` | "released" flag |
| `+0x14` | level; full is `0xB33333` |

**Attack.** It sets state 2, clears "released" so the game's note-on doesn't reset the envelope, and ramps up
from 0. In the sequencer, a release for the previous hit (event type 1, 5 or 25) arrives in the same block
as the next note-on and would re-enable the game's own envelope. Those releases are dropped when an attack
starts.

### 2.3 The drum-editor preview

**How the editor plays its preview.** It plays the edited drum through synth voice 1 and an end stage
(`M+0x160`), which writes the editor's stereo output and fades each preview note after one second.

**The audio pipeline.** Per 64-sample block, the mixer render (`0x0201DB74`) renders the voices first
(both synth voices, then the four drum sample voices), then the end stage, then a recorder (`M+0x164`).
The DS sound hardware plays the mixer's output directly: SPU channels 0/1 loop over a ring of two 64-sample
blocks per channel (`0x021E63C0`/`0x021E64C0`). A sound alarm toggles `mixer+0x16` every block to say which
half is playing; the mixer fills the other half.

**The pause before each preview note.** The recorder captures one second after every preview note (that
recording is what the original game turns into the drum sample). When it's full, the mixer spends 64 blocks
clearing the end stage's delay lines instead of rendering it, and nothing writes the output ring. In the
original game the preview has faded by then, so the ring loops silence; with a looped sample it looped the
last two blocks, which sounded like a scratchy buzz.

**What changed:**

- The end stage's render (vtable entry 3) is hooked. After it runs, its output is replaced with the edited
  drum's sample voice block, in both channels. That removes the 1-second fade.
- The sample voice's render hook also copies the edited drum's block into both channels of the half the
  mixer is filling (`mixer+0x24 + 8 × (mixer+0x16 XOR 1)`), every block in the drum editor. That keeps the
  ring fed during the 64-block pause, so the preview plays straight through.

---

## 3. What changed in the ROM (compared with the original)

Everything else, including the ARM7 binary and the save format, is unchanged.

### 3.1 ARM9 code and data

| Address | Original | V1.1 | Purpose |
|---|---|---|---|
| `0x0205F02C` | `bl 0x0201E808` (`EBFEFDF5`) | `bl LoadSlotFromR6` (`EBFE64BB`) | leaving the drum editor: load the sample |
| `0x02033194` | `bl 0x0201E808` (`EBFFAD9B`) | `bl LoadSlotFromR9` (`EBFF1465`) | loading a session: load each drum's sample |
| `0x02032910` | `strb r6,[r0,#0xAA8]` (`E5C06AA8`) | `bl DrumParamChanged` (`EBFF16FE`) | knob handler: reload when a selector knob changes |
| `0x02023A1C`…`2C` | end-of-sample clamp (5 insns) | `bl LoopCheck` + 4 × `nop` | looping |
| `0x02072FDC` | `.word 0x020219B8` | `.word 0x01FF8558` | synth voice render → `SynthVoiceRender` |
| `0x02073044` | `.word 0x02023968` | `.word 0x01FF86E0` | sample voice render → `SampleVoiceRender` |
| `0x020730F0` | `.word 0x02024578` | `.word 0x01FF85EC` | editor end stage render → `EditStageRender` |

### 3.2 New code in ITCM

The ITCM autoload block grew by `0x2000` bytes. The extra room is for the debug build; the release uses
`0x74D`. `build_lib.py` now stops if the code ever outgrows the room.

| ITCM | Routine | What it does |
|---|---|---|
| `0x01FF8320` | `LoadSlotFromR6/R9` | remember the audio object; take the drum number |
| `0x01FF833C` | `LoadSlot` | sample number from the knobs, read `/data/smp/NNN.pcm`, fill the loop table, silence the rest, guard sample after the loop |
| `0x01FF8510` | `DrumParamChanged` | store the knob value; reload on selector knobs (params 6–10) |
| `0x01FF8558` | `SynthVoiceRender` | editor preview voice: forward note-ons to the edited drum, render the synth |
| `0x01FF85EC` | `EditStageRender` / `PutPreview` | editor: replace the end stage's stereo output with the sample voice's block |
| `0x01FF8670` | `LoopCheck` | wrap at the loop end, or the original clamp |
| `0x01FF86E0` | `SampleVoiceRender` | per drum voice per block: note-on detection, attack / hold / fade |
| `0x01FF889C` | `EditorOut` | drum editor: copy the edited drum's block into the half of the output ring being filled |
| `0x01FF8934` | `DrumPatch`, `DivideU` | helpers |
| `0x01FF86C0`, `…89B4` | `LoopTable`, `EnvTable` | per slot: loop {length, end}; envelope {blocks, fade step, fading, attack step} |
| `0x01FF89F8` | `PostNoteOn` | add a note-on (type 2, `0x7F3C`) to a voice's queue with interrupts off |

### 3.3 Files

- **`/data/smp/NNN.pcm`:** a 4-byte header, then the samples.
  - Byte 0: format (0 = s16, 1 = s8).
  - Byte 1: loop flag.
  - Bytes 2–3: loop start.
  - The loop end is the end of the data.
- **`/data/demo/ds10init.dat`** and the **header** are handled as in V1.0: the INIT kit, and the restored
  ROM-control words and secure-area CRC.

---

## 4. Reference

| Thing | Where |
|---|---|
| Drum slots | `session + 0x5F10 + n×0x10000` (session = `0x021996A0`, slot 1 = `0x0219F5B0` in every boot seen) |
| Drum patches | `session + 0x5AA8 + n×31`; song file `0x2B3C + n×31`; save slot +0x100 |
| Edited part / drum | `session + 0x45F14` (2 = drums) / `+0x45F18` |
| Audio object `M` | `+0x13C` editor preview sequencer, `+0x14C` four drum sample voices, `+0x164` recorder, `+0x170` session, `+0x190` mode (2 = drum editor) |
| Preview voice | `[[M+0x13C]+0x3C]+0x18` (synth voice 1) |
| Voice queue | entries of 8 bytes at `[voice+4]`, count byte at `voice+8`; output channel entry at `voice+0x1C`, block length at `voice+0x10` (64) |
| Sample voice | vtable `0x02073038`: render `0x02023968`, events `0x02023A90`; `+0x34` step, `+0x38` position, `+0x3C` base note, `+0x40` length, `+0x44` slot |
| Synth voice | vtable `0x02072FD0`: render `0x020219B8`, events `0x0202270C` |


## 5. Known issues and ideas

- **Long loops:** a loop longer than half a second that ends after the first second is replaced with a
  crossfaded loop inside the first second, so it repeats sooner than in the original sample.
- **Ideas:** the envelope for one-shot sounds as well; reverse playback, a start offset or the drum
  editor's distortion, all of which can be applied while a sample is loaded; more than 128 places with two
  more on/off controls; DS-10+ support.
