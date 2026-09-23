# Translation between the key numbering the protocol uses and the hardware's own.
#
# The protocol numbers keys the way you look at the device: 0-15, left to right,
# top to bottom.
#
#     0  1  2  3      <- row 1, the broad category
#     4  5  6  7      <- row 2
#     8  9 10 11      <- row 3
#    12 13 14 15      <- row 4, fires the action
#
# The Keybow's own numbering runs up the columns, starting bottom-left:
#
#     3  7 11 15
#     2  6 10 14
#     1  5  9 13
#     0  4  8 12
#
# Which physical key is "top-left" depends on how the device is turned, and the
# USB socket is the only clue. ROTATION describes where the socket is, so the
# logical numbering above always matches what you see.
#
# VERIFY THIS ON THE REAL DEVICE before trusting it: run tools/keymap_probe.py,
# which lights each key you press and prints the logical number it was given.

# Where the USB socket sits when the keypad faces you: "top", "left", "bottom"
# or "right".
ROTATION = "top"

ROWS = 4
COLS = 4


def _physical(row, col):
    """Hardware index of the key at (row, col) in the logical, as-you-see-it grid."""
    if ROTATION == "top":
        r, c = row, col
    elif ROTATION == "bottom":
        r, c = ROWS - 1 - row, COLS - 1 - col
    elif ROTATION == "left":
        r, c = COLS - 1 - col, row
    elif ROTATION == "right":
        r, c = col, ROWS - 1 - row
    else:
        raise ValueError("ROTATION must be top, bottom, left or right")
    # Hardware counts up the columns from the bottom-left.
    return c * ROWS + (ROWS - 1 - r)


LOGICAL_TO_PHYSICAL = [_physical(row, col) for row in range(ROWS) for col in range(COLS)]

PHYSICAL_TO_LOGICAL = [0] * (ROWS * COLS)
for _logical, _phys in enumerate(LOGICAL_TO_PHYSICAL):
    PHYSICAL_TO_LOGICAL[_phys] = _logical
