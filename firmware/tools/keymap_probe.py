# Keymap check. Copy over code.py on the CIRCUITPY drive, temporarily.
#
# Press each key in turn; it lights green and the REPL console prints the
# logical number the protocol would give it. Work along the top row first: you
# should see 0, 1, 2, 3 left to right, then 4-7 on the next row, and so on.
#
# If the numbers come out transposed or reversed, change ROTATION in keymap.py
# to match where the USB socket actually is, and run this again.

import time

from pmk import PMK
from pmk.platform.keybow2040 import Keybow2040 as Hardware

from keymap import PHYSICAL_TO_LOGICAL, LOGICAL_TO_PHYSICAL, ROTATION

keybow = PMK(Hardware())
keys = keybow.keys

print("Keymap probe — ROTATION = %r" % ROTATION)
print("logical -> physical: %r" % (LOGICAL_TO_PHYSICAL,))
print("Press keys; expect 0-3 along the top row, left to right.")

pressed = [False] * 16

while True:
    keybow.update()
    for physical, key in enumerate(keys):
        logical = PHYSICAL_TO_LOGICAL[physical]
        if key.pressed and not pressed[logical]:
            pressed[logical] = True
            row, col = divmod(logical, 4)
            print("logical %2d  (row %d, column %d)  physical %2d" % (logical, row + 1, col + 1, physical))
            key.set_led(0, 255, 0)
        elif not key.pressed and pressed[logical]:
            pressed[logical] = False
            key.set_led(0, 0, 0)
    time.sleep(0.005)
