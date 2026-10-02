# Libraries

The CircuitPython libraries the firmware needs, kept here so the app can set a
keypad up without fetching them. They're copied to `CIRCUITPY/lib/` as they
are: source, not `.mpy`, so they run on any CircuitPython version the firmware
supports. `../manifest.json` says which board gets which.

| Library | From | Used by |
|---|---|---|
| `pmk/` | Pimoroni, [pmk-circuitpython](https://github.com/pimoroni/pmk-circuitpython) | both boards |
| `adafruit_is31fl3731/` — `__init__.py` and `keybow2040.py` only | Adafruit, [Adafruit_CircuitPython_IS31FL3731](https://github.com/adafruit/Adafruit_CircuitPython_IS31FL3731) | Keybow 2040: its LEDs |
| `adafruit_dotstar.py` | Adafruit, [Adafruit_CircuitPython_DotStar](https://github.com/adafruit/Adafruit_CircuitPython_DotStar) | RGB Keypad: its LEDs |

Each is under the MIT licence. Their `SPDX-FileCopyrightText` lines name the
copyright holders: Sandy Macdonald, 2021, for pmk (in `pmk/__init__.py`), and
the authors at the top of each Adafruit file. The licence:

> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.
