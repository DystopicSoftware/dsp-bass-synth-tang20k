# Physical Modeling Digital Bass Synthesizer (FPGA)

A real-time, physical modeling digital bass synthesizer implemented entirely in hardware on a **Gowin Tang Nano 20K FPGA**. The DSP architecture is heavily inspired by Faust models and the Karplus-Strong string synthesis algorithm, featuring a Python-based GUI for live parameter control via UART.

## 🛠️ Hardware & Architecture Overview
*   **FPGA:** Gowin GW2A-LV18PG256C8/I7 (Tang Nano 20K).
*   **Audio Output:** PT8121 DAC via custom I2S Transmitter (16-bit Mono duplicated to Stereo, ~48kHz Sample Rate).
*   **Clocking:** 27 MHz system clock, divided to 1.5 MHz for the I2S bit clock (`hp_bck`).
*   **Memory:** Native Gowin BSRAM block inference for a 2048-sample feedback delay line and a 4800-sample excitation pre-load buffer.
*   **Communications:** 115200 Baud UART receiver paired with a hardware byte-assembler and an IP Core FIFO for clock-domain crossing and protocol decoding (4-bit Command, 12-bit Payload).

## 🧮 DSP Implementation Details
The synthesizer core (`dsp_core.v`) runs a pipelined mathematical loop using **strict Q15 signed fixed-point arithmetic**. 

*   **Excitation Model:** Uses a pre-calculated bipolar noise burst with an exponential decay envelope sent from Python. This prevents DC shockwaves in the delay line while providing a sharp, metallic "slap" transient.
*   **Signal Chain:** 
    1.  **Dynamic One-Pole Lowpass Filter:** Controlled by pitch and an LFO (Wobble effect).
    2.  **Non-Linear Saturator:** Hard-clipping overdrive effect with dynamic headroom scaling.
    3.  **Gain Compensation:** Normalizes energy added by the saturator to maintain loop stability.
    4.  **DC Blocker:** Eliminates residual DC offsets before feeding the signal back into the string model.
*   **Arithmetic Protections:** All subtraction and addition nodes use explicit sign-extension (17/18-bit) before 34-bit multiplication to prevent 2's complement overflows. Proper mathematical rounding (`+ 16384` before `>>> 15` truncation) is implemented to eliminate limit-cycle quantization noise (hiss) when the string is at rest.

## 🔬 Hardware Verification & Debugging
The stabilization of the DSP loop and control logic was achieved using in-system logic analysis via the **Gowin Analyzer Oscilloscope (GAO)**:

1.  **UART Synchronization Fix:** Initial GAO captures revealed missed trigger events due to byte-misalignment in the serial stream. This was resolved by implementing a 10ms hardware watchdog/timeout in the byte assembler (`top.v`) to force idle resets, ensuring 100% command integrity.
2.  **DSP Overflow & Noise Floor:** GAO traces of internal signed buses (`input_to_filter`, `dc_block_out`) exposed destructive MSB sign-inversions during high-resonance filter states and zero-state limit cycles. The arithmetic pipeline was rebuilt with expanded accumulator registers and truncation-rounding, resulting in an artifact-free output with a true digital zero noise-floor.
3.  **Master Attenuation:** A safe Q12 digital attenuator was added at the end of the DSP chain to prevent analog clipping at the external DAC without sacrificing internal mathematical headroom.

## 🚀 How to Run

1.  **Synthesize:** Open the `.gprj` in Gowin EDA, configure the physical constraints (`mapeos.cst`) and timing constraints (`timing.sdc` at 27MHz), and generate the bitstream.
2.  **Flash:** Program the SRAM/Flash of the Tang Nano 20K.
3.  **Connect:** Ensure the PT8121 DAC is connected to the assigned I2S pins.
4.  **Run GUI:** Execute `python src/test_slap.py`. The script will automatically pre-load the excitation buffer via UART and open the Faust-style control interface.
